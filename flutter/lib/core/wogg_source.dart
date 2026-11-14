import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:meta/meta.dart';

import 'models.dart';
import 'resilient_http_client.dart';

/// Data-only catalogue adapter for the original WoGG website. Android plugin
/// bytes supply reviewed configuration; they are never loaded or executed.
class WoggSource {
  final Future<String> Function(String, Map<String, String>) read;
  final Future<Uint8List> Function(String, Map<String, String>) readBytes;
  final Future<List<CmsEpisode>> Function(String) listShare;
  final Future<List<CmsEpisode>> Function(String, Completer<void>)?
      listShareWithCancellation;
  final Duration shareTimeout;
  final _configs =
      <String, ({WoggPluginConfiguration value, DateTime expires})>{};
  final _selectedOrigins = <String, String>{};

  WoggSource({
    required this.read,
    required this.readBytes,
    required this.listShare,
    this.listShareWithCancellation,
    this.shareTimeout = const Duration(seconds: 18),
  });

  static bool supports(CmsSite site) {
    if (site.type != 3 ||
        !RegExp(r'^csp_wogg(?:guard)?$', caseSensitive: false)
            .hasMatch(site.api.trim())) {
      return false;
    }
    if (site.pluginReference.trim().isNotEmpty) return true;
    try {
      final ext = jsonDecode(site.ext);
      return ext is Map && (ext['siteUrl'] ?? '').toString().trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Correct only provably mismatched labels in an older WoGG detail snapshot.
  /// The stable episode references remain the authority for playback routing.
  static CmsVideo normalizeCachedVideoLabels(CmsSite site, CmsVideo video) {
    if (!supports(site)) return video;
    var changed = false;
    final lines = <CmsLine>[];
    for (final (index, line) in video.lines.indexed) {
      final providers =
          line.episodes.map((episode) => episode.cloudProvider).toSet();
      var name = line.name;
      if (providers.length == 1 && !providers.contains(null)) {
        final provider = providers.single!;
        final claimed = _labelProviders(name);
        if (claimed.isNotEmpty &&
            (claimed.length != 1 || !claimed.contains(provider))) {
          final ordinal =
              RegExp(r'\s+(\d+)$').firstMatch(name)?.group(1) ?? '${index + 1}';
          name = '${_providerLabel(provider)} $ordinal';
        }
      }
      changed |= name != line.name;
      lines.add(name == line.name
          ? line
          : CmsLine(name: name, episodes: line.episodes));
    }
    if (!changed) return video;
    return CmsVideo(
      id: video.id,
      title: video.title,
      poster: video.poster,
      remarks: video.remarks,
      year: video.year,
      area: video.area,
      actor: video.actor,
      description: video.description,
      tag: video.tag,
      lines: lines,
      sourceWarnings: video.sourceWarnings,
    );
  }

  /// Recover the known 0.5.15 provider-label bug without guessing a new file.
  /// This is a read-only view of the bookmark; it does not migrate storage.
  static WatchHistoryEntry normalizeCachedBookmark(
      CmsSite site, CmsVideo video, WatchHistoryEntry bookmark) {
    if (!supports(site) ||
        bookmark.site != site.key ||
        bookmark.id != video.id ||
        bookmark.episode.trim().isEmpty ||
        video.lines.any((line) => line.name == bookmark.line)) {
      return bookmark;
    }
    // Only the exact provider names/aliases emitted by the reviewed source
    // qualify. A title that merely mentions a provider is not migration proof.
    final old = RegExp(
            r'^(UC网盘|UC|优汐|夸克网盘|夸克|quark|百度网盘|百度|baidu|嘟嘟|阿里云盘|阿里网盘|阿里|alipan|aliyundrive) ([1-9][0-9]*)$',
            caseSensitive: false)
        .firstMatch(bookmark.line);
    if (old == null) return bookmark;
    final oldProviders = _labelProviders(old.group(1)!);
    if (oldProviders.length != 1) return bookmark;
    final ordinal = old.group(2)!;
    final candidates = video.lines.where((line) =>
        RegExp(r'\s+([1-9][0-9]*)$').firstMatch(line.name)?.group(1) ==
        ordinal);
    // Share failures leave gaps in these numbers. Never use the list index.
    if (candidates.length != 1) return bookmark;
    final candidate = candidates.single;
    final providers =
        candidate.episodes.map((episode) => episode.cloudProvider).toSet();
    if (providers.length != 1 ||
        providers.contains(null) ||
        providers.single == oldProviders.single ||
        candidate.episodes
                .where((episode) => episode.name == bookmark.episode)
                .length !=
            1) {
      return bookmark;
    }
    final claimed = _labelProviders(candidate.name);
    if (claimed.isNotEmpty &&
        (claimed.length != 1 || !claimed.contains(providers.single))) {
      return bookmark;
    }
    return WatchHistoryEntry(
      site: bookmark.site,
      id: bookmark.id,
      title: bookmark.title,
      poster: bookmark.poster,
      line: candidate.name,
      episode: bookmark.episode,
      index: bookmark.index,
      position: bookmark.position,
      duration: bookmark.duration,
      updated: bookmark.updated,
    );
  }

  /// Locate a saved file exactly; an unresolvable bookmark carries no progress.
  /// Stored indices cannot identify a file after a partial share listing.
  static (int lineIndex, int episodeIndex)? resolveCachedBookmarkTarget(
      CmsSite site, CmsVideo video, WatchHistoryEntry bookmark) {
    if (!supports(site) ||
        bookmark.site != site.key ||
        bookmark.id != video.id) {
      return null;
    }
    final normalized = normalizeCachedBookmark(site, video, bookmark);
    if (normalized.episode.trim().isEmpty) return null;
    final lines =
        video.lines.indexed.where((entry) => entry.$2.name == normalized.line);
    if (lines.length != 1) return null;
    final line = lines.single;
    final episodes = line.$2.episodes.indexed
        .where((entry) => entry.$2.name == normalized.episode);
    if (episodes.length != 1) return null;
    return (line.$1, episodes.single.$1);
  }

  static const categories = [
    {'type_id': '1', 'type_name': '电影'},
    {'type_id': '2', 'type_name': '剧集'},
    {'type_id': '44', 'type_name': '臻彩'},
    {'type_id': '6', 'type_name': '短漫剧'},
    {'type_id': '3', 'type_name': '动漫'},
    {'type_id': '4', 'type_name': '综艺'},
    {'type_id': '46', 'type_name': '纪录片'},
    {'type_id': '5', 'type_name': '音乐'},
  ];

  String _scope(CmsSite site) => sha256
      .convert(utf8.encode(jsonEncode([
        site.subscriptionId,
        site.sourceKey,
        site.pluginReference,
        site.ext,
        site.headers,
        site.isEffectivelyPrivate,
      ])))
      .toString();

  static Uri _origin(String address) {
    final value = Uri.tryParse(address.trim());
    if (value == null ||
        !['http', 'https'].contains(value.scheme) ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      throw const FormatException('玩偶站点地址无效');
    }
    return value.replace(
        path: value.path.endsWith('/') ? value.path : '${value.path}/');
  }

  Future<WoggPluginConfiguration> _configuration(CmsSite site) async {
    Object? ext;
    try {
      ext = jsonDecode(site.ext);
    } catch (_) {/* Optional JSON ext. */}
    if (ext is Map && (ext['siteUrl'] ?? '').toString().trim().isNotEmpty) {
      return WoggPluginConfiguration(
        origins: [_origin(ext['siteUrl'].toString()).toString()],
        userAgent: 'Mozilla/5.0',
      );
    }
    final scope = _scope(site);
    final existing = _configs[scope];
    if (existing != null && DateTime.now().isBefore(existing.expires)) {
      return existing.value;
    }
    final declaration = site.pluginReference.trim();
    final parts = declaration.split(RegExp(';md5;', caseSensitive: false));
    if (parts.length > 2 ||
        (parts.length == 2 &&
            !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(parts[1]))) {
      throw const FormatException('玩偶插件摘要格式无效');
    }
    final uri = Uri.tryParse(parts.first);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('玩偶源需要原订阅插件或明确的 siteUrl');
    }
    final bytes = await readBytes(uri.toString(), site.headers)
        .timeout(const Duration(seconds: 25));
    if (parts.length == 2 &&
        md5.convert(bytes).toString() != parts[1].toLowerCase()) {
      throw const FormatException('玩偶插件摘要不匹配，请刷新原订阅');
    }
    final result = WoggPluginConfiguration.extract(bytes);
    if (_configs.length >= 32) _configs.remove(_configs.keys.first);
    _configs[scope] = (
      value: result,
      expires: DateTime.now().add(const Duration(minutes: 5))
    );
    return result;
  }

  Future<String> invoke(CmsSite site, String method, List<Object?> args,
      {Completer<void>? cancellation, bool allowDetailRecovery = true}) async {
    void check() {
      if (cancellation?.isCompleted == true) {
        throw const FormatException('搜索已取消');
      }
    }

    check();
    if (!supports(site)) throw const FormatException('不是 WoGG 源');
    method = const {
          'home': 'homeContent',
          'homeVod': 'homeVideoContent',
          'category': 'categoryContent',
          'search': 'searchContent',
          'detail': 'detailContent',
        }[method] ??
        method;
    String path;
    final expectedTitle = method == 'detailContent' && args.length > 1
        ? args[1]?.toString().trim() ?? ''
        : '';
    final expectedYear = method == 'detailContent' && args.length > 2
        ? args[2]?.toString().trim() ?? ''
        : '';
    Future<String> recoverDetail() async {
      check();
      final raw = jsonDecode(await invoke(
          site, 'searchContent', [expectedTitle],
          cancellation: cancellation));
      final candidates = (raw['list'] as List)
          .whereType<Map>()
          .where((item) =>
              _sameTitle(expectedTitle, item['vod_name']?.toString() ?? '',
                  expectedYear) &&
              (_year(expectedYear).isEmpty ||
                  _year(item['vod_year']?.toString() ?? '').isEmpty ||
                  _year(expectedYear) ==
                      _year(item['vod_year']?.toString() ?? '')))
          .toList();
      if (candidates.length != 1) {
        throw const FormatException('旧版影片编号已失效，原站未找到唯一对应条目，请在当前源重新搜索选择');
      }
      final id = candidates.single['vod_id'].toString();
      final recovered = jsonDecode(await invoke(
          site, 'detailContent', [id, expectedTitle, expectedYear],
          cancellation: cancellation, allowDetailRecovery: false));
      final videos = recovered['list'];
      if (videos is List && videos.isNotEmpty && videos.first is Map) {
        final video = videos.first as Map;
        video['wogg_share_errors'] = [
          ...(video['wogg_share_errors'] as List? ?? const []),
          {'line': '观看记录', 'message': '已重新匹配原站影片，请重新选择原文件播放'}
        ];
      }
      return jsonEncode(recovered);
    }

    var page = 1;
    switch (method) {
      case 'homeContent':
      case 'homeVideoContent':
        path = '';
      case 'categoryContent':
        final category = args.isEmpty ? '' : args[0].toString();
        page = args.length > 1 ? int.tryParse(args[1].toString()) ?? 1 : 1;
        if (page < 1 || !RegExp(r'^\d+$').hasMatch(category)) {
          throw const FormatException('玩偶分类或页码无效');
        }
        final slots = List<String>.filled(12, '');
        slots[0] = category;
        slots[8] = '$page';
        if (args.length > 3 && args[3] is Map) {
          for (final entry in (args[3] as Map).entries) {
            final slot = int.tryParse(entry.key.toString());
            if (slot == null || slot < 0 || slot > 11) {
              throw const FormatException('玩偶筛选项无效');
            }
            slots[slot] = Uri.encodeQueryComponent(entry.value.toString());
          }
        }
        path = 'vodshow/${slots.join('-')}.html';
      case 'searchContent':
        if (args.length > 2 && (int.tryParse(args[2].toString()) ?? 1) > 1) {
          return jsonEncode({'list': [], 'page': args[2], 'pagecount': 1});
        }
        final keyword = args.isEmpty ? '' : args[0].toString().trim();
        if (keyword.isEmpty) return jsonEncode({'list': []});
        path =
            'vodsearch/-------------.html?wd=${Uri.encodeQueryComponent(keyword)}';
      case 'detailContent':
        final ids = args.isEmpty ? null : args[0];
        final id = ids is List && ids.isNotEmpty
            ? ids.first.toString()
            : ids?.toString() ?? '';
        if (!RegExp(r'^\d+$').hasMatch(id)) {
          if (allowDetailRecovery && expectedTitle.isNotEmpty) {
            return recoverDetail();
          }
          throw const FormatException('玩偶详情编号无效');
        }
        path = 'voddetail/$id.html';
      default:
        throw const FormatException('玩偶播放由原网盘线路解析');
    }
    final config = await _configuration(site);
    check();
    final scope = _scope(site);
    final origins = <String>{
      if (_selectedOrigins[scope] != null) _selectedOrigins[scope]!,
      // Prefer HTTPS on the same imported host. Never invent a different site.
      for (final origin in config.origins)
        if (Uri.parse(origin).scheme == 'http')
          Uri.parse(origin).replace(scheme: 'https').toString(),
      ...config.origins,
    };
    Document? document;
    Uri? base;
    for (final origin in origins) {
      check();
      try {
        final candidate = _origin(origin).resolve(path);
        // Subscription download credentials must not escape to catalogue hosts.
        final body = await read(candidate.toString(), {
          'User-Agent': config.userAgent,
        }).timeout(const Duration(seconds: 12));
        check();
        if (utf8.encode(body).length > 2 * 1024 * 1024) {
          throw const FormatException('玩偶目录响应过大');
        }
        final parsed = html.parse(body);
        if (!parsed.documentElement!.text.contains('玩偶') ||
            parsed.querySelector('div.module-item, div.module-search-item, '
                    'div.video-info, div.video-info-items, #search') ==
                null) {
          continue;
        }
        document = parsed;
        base = candidate;
        if (_selectedOrigins.length >= 32 &&
            !_selectedOrigins.containsKey(scope)) {
          _selectedOrigins.remove(_selectedOrigins.keys.first);
        }
        _selectedOrigins[scope] = origin;
        break;
      } catch (_) {
        check();
      }
    }
    if (document == null || base == null) {
      if (method == 'detailContent' &&
          allowDetailRecovery &&
          expectedTitle.isNotEmpty) {
        return recoverDetail();
      }
      throw const FormatException('玩偶原站暂时无法访问，请稍后重试或更新原订阅');
    }
    if (method == 'detailContent') {
      final actualTitle = document
              .querySelector('div.video-cover div.module-item-pic img')
              ?.attributes['alt'] ??
          _text(document.querySelector('h1'));
      final years = <String>{
        for (final tag in document.querySelectorAll('.video-info-aux a'))
          if (_year(_text(tag)).isNotEmpty) _year(_text(tag)),
        for (final row in document.querySelectorAll('div.video-info-items'))
          if (const ['年代：', '年份：']
              .contains(_text(row.querySelector('span.video-info-itemtitle'))))
            if (_year(_text(row.querySelector('div.video-info-item')))
                .isNotEmpty)
              _year(_text(row.querySelector('div.video-info-item'))),
      };
      if (expectedTitle.isNotEmpty &&
          (!_sameTitle(expectedTitle, actualTitle, expectedYear) ||
              _year(expectedYear).isNotEmpty &&
                  years.isNotEmpty &&
                  (years.length != 1 || years.single != _year(expectedYear)))) {
        if (allowDetailRecovery) return recoverDetail();
        throw const FormatException('原站影片与观看记录不一致，请重新搜索选择');
      }
      final id = args[0] is List
          ? (args[0] as List).first.toString()
          : args[0].toString();
      return jsonEncode(await _detail(document, base, id, check, cancellation));
    }
    final entries = _listing(document, base, search: method == 'searchContent');
    final result = <String, dynamic>{
      'list': entries,
      'page': page,
      'pagecount': _pageCount(document, page, entries.isNotEmpty),
      'limit': entries.length,
      'total': entries.length,
    };
    if (method == 'homeContent') {
      result['class'] = categories;
      result['filters'] = _filters();
    }
    return jsonEncode(result);
  }

  static String _year(String value) =>
      RegExp(r'^(?:19|20)\d{2}$').hasMatch(value.trim()) ? value.trim() : '';

  static bool _sameTitle(String expected, String actual, String year) {
    (String, String) identity(String value, String metadataYear) {
      var result = value
          .toLowerCase()
          .replaceAll(RegExp(r'[\s:：·・,，.。\-—_《》<>（）()]'), '');
      final trailing = result.length > 4
          ? RegExp(r'(?:19|20)\d{2}$').firstMatch(result)?.group(0) ?? ''
          : '';
      final suffix =
          _year(metadataYear).isNotEmpty ? _year(metadataYear) : trailing;
      if (trailing.isNotEmpty && suffix == trailing) {
        result = result.substring(0, result.length - 4);
      }
      return (result, suffix);
    }

    final a = identity(expected, year);
    final b = identity(actual, '');
    return a.$1.isNotEmpty &&
        a.$1 == b.$1 &&
        (a.$2.isEmpty || b.$2.isEmpty || a.$2 == b.$2);
  }

  static List<Map<String, dynamic>> _listing(Document doc, Uri base,
      {required bool search}) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in doc.querySelectorAll(
        search ? 'div.module-search-item' : 'div.module-item')) {
      final anchor = item.querySelector(
          search ? 'div.video-info-header h3 a' : 'div.module-item-pic > a');
      final id = RegExp(r'/voddetail/(\d+)\.html')
          .firstMatch(anchor?.attributes['href'] ?? '')
          ?.group(1);
      if (id == null || !seen.add(id)) continue;
      final image = item.querySelector('.module-item-pic img');
      result.add({
        'vod_id': id,
        'vod_name': search
            ? _text(anchor)
            : anchor?.attributes['title'] ?? _text(anchor),
        'vod_pic': _image(image, base),
        'vod_remarks': _text(item.querySelector(search
            ? '.video-info-header a.video-serial'
            : '.module-item-text')),
        'vod_year': _text(item.querySelector('.module-item-caption span')),
      });
    }
    return result;
  }

  Future<Map<String, dynamic>> _detail(Document doc, Uri base, String id,
      void Function() check, Completer<void>? cancellation) async {
    final image = doc.querySelector('div.video-cover div.module-item-pic img');
    final title = image?.attributes['alt'] ?? _text(doc.querySelector('h1'));
    final video = <String, dynamic>{
      'vod_id': id,
      'vod_name': title,
      'vod_pic': _image(image, base)
    };
    const fields = {
      '备注：': 'vod_remarks',
      '导演：': 'vod_director',
      '主演：': 'vod_actor',
      '年代：': 'vod_year',
      '剧情：': 'vod_content'
    };
    for (final row in doc.querySelectorAll('div.video-info-items')) {
      final label = _text(row.querySelector('span.video-info-itemtitle'));
      final key = fields[label];
      if (key != null) {
        video[key] = _text(row.querySelector('div.video-info-item'))
            .replaceAll('[收起部分]', '');
      }
    }
    final jobs = <({String? share, String label})>[];
    final seen = <String>{};
    var index = 0;
    final tabs = doc.querySelectorAll('.module-tab-item.downtab-item');
    final panels = doc.querySelectorAll('.module-downlist');
    final links = doc
        .querySelectorAll('div.module-row-info > a')
        .where((link) =>
            (link.attributes['data-clipboard-text'] ?? '').trim().isNotEmpty)
        .toList();
    for (final (rowIndex, link) in links.indexed) {
      final raw = (link.attributes['data-clipboard-text'] ?? '').trim();
      String? share;
      try {
        share = _normalizeClipboardShare(raw);
      } on FormatException {
        // An ambiguous password or URL stays an explicit failed original line.
      }
      if (!seen.add(share ?? raw)) continue;
      index++;
      var label = '';
      // The original site can put several tabbed shares in one downlist.
      // Prefer a one-to-one tab/row association; use panel grouping only when
      // its cardinality actually matches the tabs. Neither may override the
      // provider identified by the original share URL.
      if (tabs.length == links.length) {
        label = _tabLabel(tabs[rowIndex]);
      } else if (tabs.length == panels.length) {
        Element? ancestor = link.parent;
        while (ancestor != null) {
          final panel = panels.indexOf(ancestor);
          if (panel >= 0) {
            label = _tabLabel(tabs[panel]);
            break;
          }
          ancestor = ancestor.parent;
        }
      }
      final provider = _shareProvider(share ?? raw);
      final claimed = _labelProviders(label);
      if (label.isEmpty ||
          provider != null &&
              claimed.isNotEmpty &&
              (claimed.length != 1 || !claimed.contains(provider))) {
        label = _providerLabel(provider);
      }
      label = '$label $index';
      jobs.add((share: share, label: label));
    }
    final results = List<Map<String, dynamic>?>.filled(jobs.length, null);
    final failures = List<Map<String, String>?>.filled(jobs.length, null);
    final active = <Completer<void>>{};
    var cursor = 0;
    final subscription = cancellation?.future.asStream().listen((_) {
      for (final token in active.toList()) {
        if (!token.isCompleted) token.complete();
      }
    });
    Future<void> worker() async {
      while (cursor < jobs.length) {
        check();
        final position = cursor++;
        final job = jobs[position];
        final token = Completer<void>();
        active.add(token);
        try {
          if (job.share == null) throw const FormatException('分享地址或提取码不明确');
          final work = Future<List<CmsEpisode>>.sync(() =>
              listShareWithCancellation?.call(job.share!, token) ??
              listShare(job.share!));
          final cancelled = token.future.then<List<CmsEpisode>>(
              (_) => throw const FormatException('分享读取已取消'));
          final episodes = await Future.any([work, cancelled])
              .timeout(shareTimeout, onTimeout: () {
            if (!token.isCompleted) token.complete();
            throw TimeoutException('原分享目录读取超时');
          });
          check();
          if (episodes.isEmpty) throw const _EmptyShareException();
          results[position] = {
            'name': job.label,
            'episodes': episodes
                .map((episode) => {
                      'name': episode.name,
                      'url': episode.url,
                      if (episode.headers.isNotEmpty)
                        'headers': episode.headers,
                    })
                .toList(),
          };
          if (episodes.any((episode) =>
              episode.playbackSession['listingWarning'] is String &&
              (episode.playbackSession['listingWarning'] as String)
                  .isNotEmpty)) {
            // Keep real episodes and report incomplete directory metadata.
            // Never echo provider responses, identifiers or account data.
            failures[position] = {
              'line': job.label,
              'message': '目录返回不完整或总数不一致，已保留原网盘实际返回的视频，请稍后重试',
            };
          }
        } catch (error) {
          check();
          failures[position] = {
            'line': job.label,
            'message': _classifyShareFailure(job.share, error),
          };
        } finally {
          active.remove(token);
        }
      }
    }

    try {
      await Future.wait(
          [for (var i = 0; i < 3 && i < jobs.length; i++) worker()]);
      check();
    } finally {
      await subscription?.cancel();
      for (final token in active.toList()) {
        if (!token.isCompleted) token.complete();
      }
    }
    final lines = results.whereType<Map<String, dynamic>>().toList();
    final errors = failures.whereType<Map<String, String>>().toList();
    if (lines.isEmpty) {
      final remarksText = '${video['vod_remarks'] ?? ''} ${_text(doc.querySelector('.video-info-header'))}';
      final isUpcoming = RegExp(r'敬请期待|即将上映|未上映|未开播').hasMatch(remarksText);
      final allDeadOrEmpty = errors.isNotEmpty &&
          errors.every((e) {
            final msg = e['message'] ?? '';
            return msg.contains('目录为空') || msg.contains('已取消或已失效');
          });
      if (isUpcoming && (index == 0 || allDeadOrEmpty)) {
        throw const FormatException('该影片暂未上线（敬请期待），原站暂无可用正片分享');
      }
      if (index == 0) {
        throw const FormatException('玩偶原站尚未提供此片分享');
      }
      if (allDeadOrEmpty) {
        throw const FormatException('原站网盘分享链接已失效或目录为空，请尝试搜索其他片源');
      }
      throw const FormatException('玩偶原网盘分享暂不可用，请检查网盘登录或分享状态');
    }
    // Native CMS parsing accepts structured lines, preserving episode headers
    // and opaque provider references without delimiter-based re-encoding.
    video['lines'] = lines;
    if (errors.isNotEmpty) video['wogg_share_errors'] = errors;
    return {
      'list': [video]
    };
  }

  static String _classifyShareFailure(String? share, Object error) {
    if (share == null) return '原分享地址或提取码不明确，请检查原站分享信息';
    if (error is _EmptyShareException) return '该网盘分享目录为空';
    if (error is TimeoutException) return '该备用分享响应超时，已跳过';
    final text = error.toString();
    if (text.contains('已取消或已失效') || text.contains('网盘请求失败（404）')) {
      return '该网盘分享链接已取消或已失效';
    }
    return '原网盘分享暂不可用，请检查网盘登录或分享状态';
  }

  static String _normalizeClipboardShare(String raw) {
    final normalized = ResilientHttpClient.normalizeCloudShareUrl(
      raw,
      strictClipboard: true,
    );
    if (normalized == null || normalized.isEmpty) {
      throw const FormatException('分享地址或提取码不明确');
    }
    return normalized;
  }

  static String _tabLabel(Element tab) =>
      _text(tab).replaceFirst(RegExp(r'\s*\d+$'), '').trim();

  static String? _shareProvider(String share) {
    final uri = Uri.tryParse(share);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host == 'drive.uc.cn' || host == 'fast.uc.cn') return 'uc';
    if (host == 'pan.quark.cn') return 'quark';
    if (host == 'pan.baidu.com') return 'baidu';
    if (const {
      'www.alipan.com',
      'alipan.com',
      'www.aliyundrive.com',
      'aliyundrive.com'
    }.contains(host)) {
      return 'ali';
    }
    return null;
  }

  static Set<String> _labelProviders(String label) {
    final text = label.toLowerCase();
    return {
      if (RegExp(r'(^|[^a-z])uc([^a-z]|$)|优汐').hasMatch(text)) 'uc',
      if (text.contains('夸克') || text.contains('quark')) 'quark',
      if (text.contains('百度') || text.contains('baidu') || text.contains('嘟嘟'))
        'baidu',
      if (text.contains('阿里') ||
          text.contains('alipan') ||
          text.contains('aliyundrive'))
        'ali',
    };
  }

  static String _providerLabel(String? provider) =>
      const {
        'uc': 'UC网盘',
        'quark': '夸克网盘',
        'baidu': '百度网盘',
        'ali': '阿里云盘',
      }[provider] ??
      '原站分享';

  static String _text(Element? element) =>
      (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _image(Element? image, Uri base) {
    final raw = image?.attributes['data-src'] ?? image?.attributes['src'] ?? '';
    if (raw.isEmpty) return '';
    final uri = base.resolve(raw.replaceFirst('/db.php?url=', ''));
    return ['http', 'https'].contains(uri.scheme) ? uri.toString() : '';
  }

  static int _pageCount(Document doc, int page, bool hasItems) {
    var count = page;
    for (final link in doc.querySelectorAll('.page a, .pagination a')) {
      final number = int.tryParse(_text(link));
      if (number != null && number > count) count = number;
      final href = link.attributes['href'] ?? '';
      final match = RegExp(r'/vodshow/([^-]*)-.*\.html').firstMatch(href);
      if (match != null) {
        final slots = Uri.tryParse(href)
                ?.path
                .split('/')
                .last
                .replaceFirst('.html', '')
                .split('-') ??
            [];
        final candidate = slots.length == 12 ? int.tryParse(slots[8]) : null;
        if (candidate != null && candidate > count) count = candidate;
      }
    }
    return count;
  }

  static Map<String, Object> _filters() {
    Map<String, Object> dimension(
            String key, String name, List<String> values) =>
        {
          'key': key,
          'name': name,
          'value': [
            {'n': '全部', 'v': ''},
            for (final value in values) {'n': value, 'v': value},
          ],
        };
    final years =
        dimension('11', '年代', [for (var y = 2026; y >= 2011; y--) '$y']);
    final areas = dimension('1', '地区', [
      '中国大陆',
      '中国香港',
      '中国台湾',
      '美国',
      '韩国',
      '日本',
      '西班牙',
      '泰国',
      '法国',
      '英国',
      '德国',
      '印度',
      '其他'
    ]);
    final genres = dimension('3', '类型', [
      '喜剧',
      '爱情',
      '动作',
      '恐怖',
      '科幻',
      '剧情',
      '犯罪',
      '奇幻',
      '战争',
      '悬疑',
      '武侠',
      '冒险',
      '古装',
      '历史',
      '惊悚'
    ]);
    return {
      for (final id in ['1', '2', '44']) id: [genres, years, areas],
      '3': [years, areas],
      '4': [years, areas],
      '46': [years],
      '6': [
        dimension('3', '类型', [
          '男频',
          '女频',
          '都市',
          '甜宠',
          '年代',
          '穿越',
          '古装',
          '亲情',
          '奇幻',
          '萌宝',
          '重生',
          '冒险',
          '逆袭',
          '虐恋',
          '复仇',
          '修仙',
          '鉴宝'
        ]),
        years
      ],
      '5': [
        dimension('5', '字母',
            [for (var i = 65; i <= 90; i++) String.fromCharCode(i), '0-9'])
      ],
    };
  }
}

/// Reviewed data locations for the original subscription variants. Package and
/// inner DEX hashes are paired; imported code is never evaluated.
class WoggPluginConfiguration {
  final List<String> origins;
  final String userAgent;
  const WoggPluginConfiguration(
      {required this.origins, required this.userAgent});

  static const int _maxArchiveBytes = 16 * 1024 * 1024;
  static const int _maxDexBytes = 16 * 1024 * 1024;
  static const int _ftyNativeSize = 102440;
  static const Set<String> _ftyNativeShas = {
    'd5d8adee01e1bdc4c18b445e19ce7c94fb296ca6dce6f18a08786504fc961f01',
    'fac9e3937d9928e437ebff79bc5164df418a6adb212494ef21c273579b045dcb',
  };

  static WoggPluginConfiguration extract(Uint8List bytes) {
    const profiles = {
      'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096': (
        dex: '3d92d4cd3d3c11896d4a2a576e06fd68748b4944c6bc2330357c4c2085ffa47d',
        offset: 1620732, uaMask: 974,
        originMasks: [1112, 1852, 1824, 1782, 1412],
      ),
      '88e67402129e7db92669fb351397ecd4d09709e6c70b577f22a19cfb0ad5f204': (
        dex: 'ca0f07bd6f82fa9508e7dbe72157e15e478dbf2a2d60d255a4aea4c6d1cb35f1',
        offset: 1724260, uaMask: 1947,
        originMasks: [2183, 731, 581, 1275, 1715],
      ),
      '6f88b2001d45018aad4e7293566ef739be92dee85c123db4cc062539973fe799': (
        dex: 'b28e57ec8b7e965572a374284c836650b1af753d52ef1d68c6e8f0a7af2ee0f9',
        offset: 1585832, uaMask: 3081,
        originMasks: [1908, 388, 2452, 1453, 2595],
      ),
      '805128011cf4e3b63fdbc998840c7b51ba1c07d8f53754d55541818aaada5781': (
        dex: '2cbefde6313a5a65ad80dd8aeedb42339653de8810680e5ee2b2a0249598d6c9',
        offset: 1596392, uaMask: 680,
        originMasks: [1323, 432, 1310, 2725, 1625],
      ),
    };
    if (bytes.isEmpty || bytes.length > _maxArchiveBytes) {
      throw const FormatException('玩偶插件包为空或超过大小限制');
    }
    if (bytes.length < 22 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      throw const FormatException('此版本玩偶插件尚未完成适配，请保留原订阅并更新应用');
    }
    final profile = profiles[sha256.convert(bytes).toString()];
    Uint8List member(Archive archive, String name, {String? onMissing}) {
      final matches =
          archive.files.where((f) => f.name == name && f.isFile).toList();
      if (matches.length != 1 || matches.single.size > _maxDexBytes) {
        throw FormatException(onMissing ?? '玩偶插件结构无效');
      }
      return Uint8List.fromList(matches.single.content);
    }

    Archive outerArchive;
    try {
      outerArchive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw FormatException(
        profile == null ? '此版本玩偶插件尚未完成适配，请保留原订阅并更新应用' : '玩偶插件结构无效',
      );
    }

    if (profile == null) {
      final native = member(
        outerArchive,
        'assets/ftyguard_v8.so',
        onMissing: '此版本玩偶插件尚未完成适配，请保留原订阅并更新应用',
      );
      final nativeSha = sha256.convert(native).toString();
      if (native.length != _ftyNativeSize ||
          !_ftyNativeShas.contains(nativeSha)) {
        throw const FormatException('此版本玩偶插件尚未完成适配，请保留原订阅并更新应用');
      }
    }

    final payload = member(outerArchive, 'assets/ftyshinidie.guard');
    for (var i = 0; i < payload.length; i++) {
      if (const [1, 2, 5, 6].contains(payload[i])) payload[i] ^= 7;
    }
    final Archive innerArchive;
    try {
      innerArchive = ZipDecoder().decodeBytes(payload, verify: true);
    } catch (_) {
      throw const FormatException('玩偶插件结构无效');
    }
    final dex = member(innerArchive, 'classes.dex');
    if (profile != null) {
      if (sha256.convert(dex).toString() != profile.dex) {
        throw const FormatException('玩偶插件数据校验失败');
      }
      if (profile.offset < 0 || profile.offset + 1548 * 2 > dex.length) {
        throw const FormatException('玩偶插件数据校验失败');
      }
      final data =
          ByteData.sublistView(dex, profile.offset, profile.offset + 1548 * 2);
      String decode(int start, int length, int mask) => String.fromCharCodes([
            for (var i = start; i < start + length; i++)
              data.getUint16(i * 2, Endian.little) ^ mask,
          ]);
      return _validatedConfiguration(
        origins: [
          decode(796, 26, profile.originMasks[0]),
          decode(822, 31, profile.originMasks[1]),
          decode(853, 21, profile.originMasks[2]),
          decode(874, 26, profile.originMasks[3]),
          decode(900, 20, profile.originMasks[4]),
        ],
        userAgent: decode(43, 111, profile.uaMask),
      );
    }
    return extractFromDex(dex);
  }

  static WoggPluginConfiguration _validatedConfiguration({
    required List<String> origins,
    required String userAgent,
  }) {
    if (origins.isEmpty || origins.length > 16) {
      throw const FormatException('玩偶插件数据校验失败');
    }
    final cleanOrigins = <String>[];
    for (final raw in origins) {
      if (raw.isEmpty ||
          raw.length > 2048 ||
          RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(raw)) {
        throw const FormatException('玩偶插件数据校验失败');
      }
      final uri = Uri.tryParse(raw);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        throw const FormatException('玩偶插件数据校验失败');
      }
      cleanOrigins.add(raw);
    }
    if (userAgent.isEmpty ||
        userAgent.length > 512 ||
        RegExp(r'[\r\n\x00]').hasMatch(userAgent)) {
      throw const FormatException('玩偶插件数据校验失败');
    }
    return WoggPluginConfiguration(origins: cleanOrigins, userAgent: userAgent);
  }

  /// Extracts `WoGG` origins and user-agent structurally from an unexecuted
  /// DEX bytecode table + `<clinit>` XOR-masked short array.
  @visibleForTesting
  static WoggPluginConfiguration extractFromDex(Uint8List dex) {
    Never failDex() => throw const FormatException('玩偶插件数据校验失败');
    if (dex.length < 112 || dex.length > _maxDexBytes) failDex();
    if (dex[0] != 0x64 ||
        dex[1] != 0x65 ||
        dex[2] != 0x78 ||
        dex[3] != 0x0a ||
        dex[4] != 0x30 ||
        dex[5] != 0x33 ||
        dex[7] != 0x00) {
      failDex();
    }
    final bd = ByteData.sublistView(dex);
    int u16(int off) {
      if (off < 0 || off + 2 > dex.length) failDex();
      return bd.getUint16(off, Endian.little);
    }

    int u32(int off) {
      if (off < 0 || off + 4 > dex.length) failDex();
      return bd.getUint32(off, Endian.little);
    }

    if (u32(32) != dex.length || u32(36) != 112 || u32(40) != 0x12345678) {
      failDex();
    }

    ({int value, int next}) uleb(int off) {
      var value = 0;
      for (var i = 0; i < 5; i++) {
        if (off + i >= dex.length) failDex();
        final byte = dex[off + i];
        if (i == 4 && byte > 15) failDex();
        value += (byte & 0x7f) << (i * 7);
        if ((byte & 0x80) == 0) return (value: value, next: off + i + 1);
      }
      failDex();
    }

    List<int> tableOffsets(int headerOff, int stride) {
      final count = u32(headerOff);
      final offset = u32(headerOff + 4);
      if (count > 262144 || offset + count * stride > dex.length) failDex();
      return List<int>.generate(count, (i) => offset + i * stride);
    }

    final stringPtrs = tableOffsets(56, 4);
    final typePtrs = tableOffsets(64, 4);
    final protoPtrs = tableOffsets(72, 12);
    final fieldPtrs = tableOffsets(80, 8);
    final methodPtrs = tableOffsets(88, 8);
    final classPtrs = tableOffsets(96, 32);

    final stringCache = List<String?>.filled(stringPtrs.length, null);
    String readString(int index) {
      if (index < 0 || index >= stringPtrs.length) failDex();
      final cached = stringCache[index];
      if (cached != null) return cached;
      final strOff = u32(stringPtrs[index]);
      final hdr = uleb(strOff);
      final utf16Len = hdr.value;
      if (utf16Len > 1048576) failDex();
      var p = hdr.next;
      final units = <int>[];
      while (units.length < utf16Len) {
        if (p >= dex.length) failDex();
        final b0 = dex[p++];
        if (b0 > 0 && b0 < 0x80) {
          units.add(b0);
        } else if ((b0 & 0xe0) == 0xc0) {
          if (p >= dex.length) failDex();
          final b1 = dex[p++];
          if ((b1 & 0xc0) != 0x80) failDex();
          final v = ((b0 & 0x1f) << 6) | (b1 & 0x3f);
          if (v < 0x80 && v != 0) failDex();
          units.add(v);
        } else if ((b0 & 0xf0) == 0xe0) {
          if (p + 1 >= dex.length) failDex();
          final b1 = dex[p++];
          final b2 = dex[p++];
          if ((b1 & 0xc0) != 0x80 || (b2 & 0xc0) != 0x80) failDex();
          final v = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f);
          if (v < 0x800) failDex();
          units.add(v);
        } else {
          failDex();
        }
      }
      if (p >= dex.length || dex[p] != 0) failDex();
      final decoded = String.fromCharCodes(units);
      stringCache[index] = decoded;
      return decoded;
    }

    String readType(int index) {
      if (index < 0 || index >= typePtrs.length) failDex();
      return readString(u32(typePtrs[index]));
    }

    String protoSig(int protoIdx) {
      if (protoIdx < 0 || protoIdx >= protoPtrs.length) failDex();
      final pOff = protoPtrs[protoIdx];
      final ret = readType(u32(pOff + 4));
      final paramsOff = u32(pOff + 8);
      if (paramsOff == 0) return '$ret()';
      final n = u32(paramsOff);
      if (n > 256 || paramsOff + 4 + n * 2 > dex.length) failDex();
      final params = <String>[
        for (var i = 0; i < n; i++) readType(u16(paramsOff + 4 + i * 2)),
      ];
      return '$ret(${params.join(',')})';
    }

    int insnWidth(int codeOff, int unit, int size) {
      if (unit < 0 || unit >= size) failDex();
      final ins = codeOff + 16 + unit * 2;
      final w0 = u16(ins);
      final int width;
      if (w0 == 0x0100) {
        if (unit + 4 > size) failDex();
        width = 4 + u16(ins + 2) * 2;
      } else if (w0 == 0x0200) {
        if (unit + 2 > size) failDex();
        width = 2 + u16(ins + 2) * 4;
      } else if (w0 == 0x0300) {
        if (unit + 4 > size) failDex();
        final elemWidth = u16(ins + 2);
        final elemCount = u32(ins + 4);
        if (elemWidth > 16 || elemCount > 65536) failDex();
        width = 4 + ((elemWidth * elemCount + 1) ~/ 2);
      } else {
        final op = w0 & 0xff;
        if (op == 0x18) {
          width = 5;
        } else if (op == 0x03 ||
            op == 0x06 ||
            op == 0x09 ||
            op == 0x14 ||
            op == 0x17 ||
            op == 0x1b ||
            (op >= 0x24 && op <= 0x26) ||
            (op >= 0x2a && op <= 0x2c) ||
            (op >= 0x6e && op <= 0x72) ||
            (op >= 0x74 && op <= 0x78)) {
          width = 3;
        } else if (op == 0x02 ||
            op == 0x05 ||
            op == 0x08 ||
            op == 0x13 ||
            op == 0x15 ||
            op == 0x16 ||
            op == 0x19 ||
            op == 0x1a ||
            op == 0x1c ||
            op == 0x1f ||
            op == 0x20 ||
            op == 0x22 ||
            op == 0x23 ||
            op == 0x29 ||
            (op >= 0x2d && op <= 0x3d) ||
            (op >= 0x44 && op <= 0x6d) ||
            (op >= 0x90 && op <= 0xaf) ||
            (op >= 0xd0 && op <= 0xe2)) {
          width = 2;
        } else {
          width = 1;
        }
      }
      if (width < 1 || unit + width > size) failDex();
      return width;
    }

    const woggCls = 'Lcom/github/catvod/spider/WoGG;';
    int? woggClassOff;
    for (final cOff in classPtrs) {
      if (readType(u32(cOff)) == woggCls) {
        if (woggClassOff != null) failDex();
        woggClassOff = cOff;
      }
    }
    if (woggClassOff == null) failDex();
    final classDataOff = u32(woggClassOff + 24);
    if (classDataOff == 0) failDex();

    var p = classDataOff;
    final counts = <int>[];
    for (var i = 0; i < 4; i++) {
      final r = uleb(p);
      if (r.value > 65536) failDex();
      counts.add(r.value);
      p = r.next;
    }
    for (var i = 0; i < counts[0] + counts[1]; i++) {
      p = uleb(p).next;
      p = uleb(p).next;
    }
    final methods = <({String name, String sig, int offset, int size})>[];
    for (final count in counts.sublist(2)) {
      var index = 0;
      for (var i = 0; i < count; i++) {
        final d = uleb(p);
        p = uleb(d.next).next;
        final c = uleb(p);
        p = c.next;
        index += d.value;
        if (index < 0 || index >= methodPtrs.length) failDex();
        final mPtr = methodPtrs[index];
        final owner = readType(u16(mPtr));
        final sig = protoSig(u16(mPtr + 2));
        final name = readString(u32(mPtr + 4));
        if (owner == woggCls && c.value != 0) {
          final size = u32(c.value + 12);
          if (size == 0 || size > 65536 || c.value + 16 + size * 2 > dex.length) {
            failDex();
          }
          methods.add((name: name, sig: sig, offset: c.value, size: size));
        }
      }
    }

    final clinitIdx =
        methods.indexWhere((m) => m.name == '<clinit>' && m.sig == 'V()');
    if (clinitIdx < 0) failDex();
    final clinit = methods[clinitIdx];
    if (clinit.size < 14 || u16(clinit.offset + 2) != 0) failDex();
    final start = clinit.offset + 16;
    if (u16(start) != 0x0013 ||
        u16(start + 4) != 0x0023 ||
        readType(u16(start + 6)) != '[S' ||
        u16(start + 8) != 0x0026 ||
        u16(start + 14) != 0x0069) {
      failDex();
    }
    final count = u16(start + 2);
    final payloadUnit = 4 + u32(start + 10);
    final fieldIdx = u16(start + 16);
    if (fieldIdx < 0 || fieldIdx >= fieldPtrs.length) failDex();
    final fPtr = fieldPtrs[fieldIdx];
    if (readType(u16(fPtr)) != woggCls || readType(u16(fPtr + 2)) != '[S') {
      failDex();
    }
    if (count == 0 ||
        count > 8192 ||
        payloadUnit < 10 ||
        payloadUnit + 4 + count > clinit.size) {
      failDex();
    }
    final payload = start + payloadUnit * 2;
    if (u16(payload) != 0x0300 ||
        u16(payload + 2) != 2 ||
        u32(payload + 4) != count) {
      failDex();
    }
    final values =
        List<int>.generate(count, (i) => u16(payload + 8 + i * 2));

    final maskBySlice = <String, int>{};
    final byMethod = <String, List<String>>{};
    for (final m in methods) {
      Map<int, int>? headerRegs;
      var regs = <int, int>{};
      final decodedList = <String>[];
      var u = 0;
      while (u < m.size) {
        final width = insnWidth(m.offset, u, m.size);
        final ins = m.offset + 16 + u * 2;
        final w0 = u16(ins);
        final op = w0 & 0xff;
        if (w0 != 0x0100 && w0 != 0x0200 && w0 != 0x0300) {
          if (op == 0x12) {
            var v = (w0 >> 12) & 0xf;
            if (v >= 8) v -= 16;
            regs[(w0 >> 8) & 0xf] = v;
          } else if (op == 0x13) {
            final raw = u16(ins + 2);
            regs[w0 >> 8] = raw >= 0x8000 ? raw - 0x10000 : raw;
          } else if (op == 0x14) {
            regs[w0 >> 8] = u32(ins + 2).toSigned(32);
          } else if (op == 0x15) {
            regs[w0 >> 8] = (u16(ins + 2) << 16).toSigned(32);
          } else if (op == 0x01) {
            final dst = (w0 >> 8) & 0xf;
            final src = (w0 >> 12) & 0xf;
            final v = regs[src];
            if (v != null) {
              regs[dst] = v;
            } else {
              regs.remove(dst);
            }
          } else if (op == 0x02) {
            final dst = w0 >> 8;
            final v = regs[u16(ins + 2)];
            if (v != null) {
              regs[dst] = v;
            } else {
              regs.remove(dst);
            }
          } else if (op == 0x03) {
            final dst = u16(ins + 2);
            final v = regs[u16(ins + 4)];
            if (v != null) {
              regs[dst] = v;
            } else {
              regs.remove(dst);
            }
          } else if (op == 0x0a ||
              op == 0x0c ||
              op == 0x1a ||
              op == 0x1b ||
              op == 0x22) {
            regs.remove(w0 >> 8);
          } else if (op == 0x2b || op == 0x2c) {
            headerRegs ??= Map<int, int>.from(regs);
          } else if (op == 0x28 ||
              op == 0x29 ||
              op == 0x2a ||
              (op >= 0x0e && op <= 0x11) ||
              op == 0x27) {
            if (headerRegs != null) regs = Map<int, int>.from(headerRegs);
          } else if ((op == 0x71 || op == 0x77) && u + 2 < m.size) {
            final mIdx = u16(ins + 2);
            if (mIdx >= methodPtrs.length) failDex();
            final targetSig = protoSig(u16(methodPtrs[mIdx] + 2));
            if (targetSig == 'Ljava/lang/String;([S,I,I,I)') {
              int? rS, rL, rM;
              if (op == 0x71 && ((w0 >> 12) & 0xf) == 4) {
                final w2 = u16(ins + 4);
                rS = (w2 >> 4) & 0xf;
                rL = (w2 >> 8) & 0xf;
                rM = (w2 >> 12) & 0xf;
              } else if (op == 0x77 && (w0 >> 8) == 4) {
                final base = u16(ins + 4);
                rS = base + 1;
                rL = base + 2;
                rM = base + 3;
              }
              if (rS != null && rL != null && rM != null) {
                final st = regs[rS];
                final ln = regs[rL];
                final rawMk = regs[rM];
                if (st != null &&
                    ln != null &&
                    rawMk != null &&
                    st >= 0 &&
                    ln >= 0 &&
                    st + ln <= values.length) {
                  final mk = rawMk & 0xffff;
                  maskBySlice['$st:$ln'] = mk;
                  decodedList.add(String.fromCharCodes([
                    for (var i = st; i < st + ln; i++) values[i] ^ mk,
                  ]));
                }
              }
            }
          }
        }
        u += width;
      }
      if (decodedList.isNotEmpty) {
        (byMethod[m.name] ??= <String>[]).addAll(decodedList);
      }
    }

    String decodeSlice(int st, int ln) {
      final mk = maskBySlice['$st:$ln'];
      if (mk == null || st + ln > values.length) failDex();
      return String.fromCharCodes([
        for (var i = st; i < st + ln; i++) values[i] ^ mk,
      ]);
    }

    const originSlices = [
      (796, 26),
      (822, 31),
      (853, 21),
      (874, 26),
      (900, 20),
    ];
    final List<String> origins;
    if (originSlices.every((s) => maskBySlice.containsKey('${s.$1}:${s.$2}'))) {
      origins = [for (final s in originSlices) decodeSlice(s.$1, s.$2)];
    } else {
      final keyStrings = byMethod['getKey'] ?? const <String>[];
      origins = keyStrings
          .where((s) => s.startsWith('http://') || s.startsWith('https://'))
          .toList();
    }

    final String? userAgent;
    if (maskBySlice.containsKey('43:111')) {
      userAgent = decodeSlice(43, 111);
    } else {
      final initStrings = byMethod['<init>'] ?? const <String>[];
      final uaCands =
          initStrings.where((s) => s.startsWith('Mozilla/')).toList();
      userAgent = uaCands.length == 1 ? uaCands.single : null;
    }
    if (userAgent == null) failDex();
    return _validatedConfiguration(origins: origins, userAgent: userAgent);
  }
}

class _EmptyShareException implements Exception {
  const _EmptyShareException();
}

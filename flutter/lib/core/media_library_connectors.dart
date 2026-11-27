import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'smb2_client.dart';

/// Unified external media library protocol dispatcher supporting Jellyfin, Plex,
/// WebDAV media folders, AList/OpenList NAS, pure SMB2 / NAS shares, and
/// persistent on-device local media collections alongside [EmbyLibrary].
class ExternalMediaLibrary {
  static const String jellyfinPrefix = 'jellyfin://account/';
  static const String plexPrefix = 'plex://account/';
  static const String webdavPrefix = 'webdavlib://account/';
  static const String alistPrefix = 'alist://account/';
  static const String smbPrefix = 'smbnas://account/';
  static const String localPrefix = 'localfile://account/';
  static const String folderTag = 'media-folder';

  static const Set<String> _videoExtensions = <String>{
    '.mp4',
    '.mkv',
    '.mov',
    '.m4v',
    '.avi',
    '.ts',
    '.m2ts',
    '.flv',
    '.webm',
    '.wmv',
    '.rmvb',
    '.m3u8',
  };

  static bool isVideoFileName(String name) {
    final lower = name.trim().toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExtensions.contains(lower.substring(dot));
  }

  static String cleanMediaTitle(String fileName) {
    String decoded;
    try {
      decoded = Uri.decodeComponent(fileName);
    } catch (_) {
      decoded = fileName;
    }
    final trimmed = decoded.split(RegExp(r'[/\\]')).last.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot > 0 &&
        _videoExtensions.contains(trimmed.substring(dot).toLowerCase())) {
      return trimmed.substring(0, dot).trim();
    }
    return trimmed;
  }

  static String encodeFolderId(String target) =>
      Uri(scheme: 'mmfolder', host: 'open', queryParameters: {'id': target})
          .toString();

  static String decodeFolderId(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.scheme == 'mmfolder') {
      return uri.queryParameters['id'] ?? '';
    }
    return raw;
  }

  static bool isSupportedSite(CmsSite site) =>
      site.api.startsWith(jellyfinPrefix) ||
      site.api.startsWith(plexPrefix) ||
      site.api.startsWith(webdavPrefix) ||
      site.api.startsWith(alistPrefix) ||
      site.api.startsWith(smbPrefix) ||
      site.api.startsWith(localPrefix);

  static bool isPlayableScheme(String url) =>
      url.startsWith('mmjellyfin://play?') ||
      url.startsWith('mmplex://play?') ||
      url.startsWith('mmwebdav://play?') ||
      url.startsWith('mmalist://play?') ||
      url.startsWith('mmsmb://play?') ||
      url.startsWith('mmlocal://play?');

  static bool isPrivateImage(String rawUrl) {
    final frag = Uri.tryParse(rawUrl)?.fragment ?? '';
    return frag.startsWith('mm-jf=') || frag.startsWith('mm-plex=');
  }

  static Future<Map<String, String>> imageHeaders(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return const <String, String>{};
    if (uri.fragment.startsWith('mm-jf=')) {
      final key = uri.fragment.substring(6);
      final lib = await JellyfinLibrary.openByKey(key);
      return {'X-Emby-Token': lib.token};
    }
    if (uri.fragment.startsWith('mm-plex=')) {
      final key = uri.fragment.substring(8);
      final lib = await PlexLibrary.openByKey(key);
      return {'X-Plex-Token': lib.token};
    }
    return const <String, String>{};
  }

  static Future<(List<CmsCategory>, CmsListing)> home(CmsSite site) async {
    if (site.api.startsWith(jellyfinPrefix)) {
      return (await JellyfinLibrary.open(site)).home();
    }
    if (site.api.startsWith(plexPrefix)) {
      return (await PlexLibrary.open(site)).home();
    }
    if (site.api.startsWith(webdavPrefix)) {
      return (await WebDavMediaLibrary.open(site)).home();
    }
    if (site.api.startsWith(alistPrefix)) {
      return (await AlistNasLibrary.open(site)).home();
    }
    if (site.api.startsWith(smbPrefix)) {
      return (await SmbNasLibrary.open(site)).home();
    }
    if (site.api.startsWith(localPrefix)) {
      return (await LocalDeviceLibrary.open(site)).home();
    }
    throw const FormatException('不支持的媒体库协议');
  }

  static Future<CmsListing> list(
    CmsSite site,
    String categoryId,
    String query,
    int page,
  ) async {
    if (site.api.startsWith(jellyfinPrefix)) {
      return (await JellyfinLibrary.open(site)).list(categoryId, query, page);
    }
    if (site.api.startsWith(plexPrefix)) {
      return (await PlexLibrary.open(site)).list(categoryId, query, page);
    }
    if (site.api.startsWith(webdavPrefix)) {
      return (await WebDavMediaLibrary.open(site)).list(categoryId, query, page);
    }
    if (site.api.startsWith(alistPrefix)) {
      return (await AlistNasLibrary.open(site)).list(categoryId, query, page);
    }
    if (site.api.startsWith(smbPrefix)) {
      return (await SmbNasLibrary.open(site)).list(categoryId, query, page);
    }
    if (site.api.startsWith(localPrefix)) {
      return (await LocalDeviceLibrary.open(site)).list(categoryId, query, page);
    }
    return const CmsListing();
  }

  static Future<CmsVideo> detail(CmsSite site, CmsVideo fallback) async {
    if (site.api.startsWith(jellyfinPrefix)) {
      return (await JellyfinLibrary.open(site)).detail(fallback.id);
    }
    if (site.api.startsWith(plexPrefix)) {
      return (await PlexLibrary.open(site)).detail(fallback.id, fallback);
    }
    if (site.api.startsWith(webdavPrefix)) {
      return (await WebDavMediaLibrary.open(site)).detail(fallback);
    }
    if (site.api.startsWith(alistPrefix)) {
      return (await AlistNasLibrary.open(site)).detail(fallback);
    }
    if (site.api.startsWith(smbPrefix)) {
      return (await SmbNasLibrary.open(site)).detail(fallback);
    }
    if (site.api.startsWith(localPrefix)) {
      return (await LocalDeviceLibrary.open(site)).detail(fallback);
    }
    return fallback;
  }

  static Future<CmsEpisode> resolve(CmsSite site, CmsEpisode episode) async {
    if (site.api.startsWith(jellyfinPrefix)) {
      return (await JellyfinLibrary.open(site)).resolve(episode);
    }
    if (site.api.startsWith(plexPrefix)) {
      return (await PlexLibrary.open(site)).resolve(episode);
    }
    if (site.api.startsWith(webdavPrefix)) {
      return (await WebDavMediaLibrary.open(site)).resolve(episode);
    }
    if (site.api.startsWith(alistPrefix)) {
      return (await AlistNasLibrary.open(site)).resolve(episode);
    }
    if (site.api.startsWith(smbPrefix)) {
      return (await SmbNasLibrary.open(site)).resolve(episode);
    }
    if (site.api.startsWith(localPrefix)) {
      return (await LocalDeviceLibrary.open(site)).resolve(episode);
    }
    return episode;
  }

  static String _nonce() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static Uri _validateHttpBase(String address, String label) {
    final u = Uri.tryParse(address.trim());
    if (u == null ||
        !['http', 'https'].contains(u.scheme.toLowerCase()) ||
        u.host.isEmpty) {
      throw FormatException('请输入有效的 HTTP / HTTPS $label 服务器地址');
    }
    final cleanPath = u.path.replaceFirst(RegExp(r'/+$'), '');
    return u.replace(path: cleanPath, query: null, fragment: null);
  }
}

/// Real Jellyfin Media Server connector (`jellyfin://account/<key>`).
class JellyfinLibrary {
  final Uri base;
  final String user;
  final String token;
  final String device;
  final String accountKey;

  const JellyfinLibrary._(
    this.base,
    this.user,
    this.token,
    this.device,
    this.accountKey,
  );

  static Future<SubscriptionEntry> login(
    String address,
    String username,
    String password, {
    required String group,
    required bool isPrivate,
  }) async {
    final base = ExternalMediaLibrary._validateHttpBase(address, 'Jellyfin');
    final prefs = await SharedPreferences.getInstance();
    final device =
        prefs.getString('jellyfin.device') ?? ExternalMediaLibrary._nonce();
    await prefs.setString('jellyfin.device', device);
    final authClient = JellyfinLibrary._(base, '', '', device, '');
    final json = await authClient._api(
      '/Users/AuthenticateByName',
      body: {'Username': username.trim(), 'Pw': password},
    );
    final user = json['User']?['Id']?.toString() ?? '';
    final token = json['AccessToken']?.toString() ?? '';
    if (user.isEmpty || token.isEmpty) {
      throw const FormatException('Jellyfin 没有返回有效账户令牌');
    }
    final key = sha256.convert(utf8.encode('jf|$base|$user')).toString();
    // Verify real library access before saving the library entry.
    final verified = JellyfinLibrary._(base, user, token, device, key);
    final views = await verified._api('/Users/$user/Views');
    if (views['Items'] is! List) {
      throw StateError('Jellyfin 未返回有效媒体库目录，请检查该账号的库访问权限');
    }
    final name = 'Jellyfin · ${username.trim()}';
    await prefs.setString(
      'jellyfin.account.$key',
      jsonEncode({
        'base': base.toString(),
        'user': user,
        'token': token,
        'device': device,
      }),
    );
    final api = '${ExternalMediaLibrary.jellyfinPrefix}$key';
    return SubscriptionEntry(
      id: 'jellyfin_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'Jellyfin',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'jellyfin_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<JellyfinLibrary> open(CmsSite site) =>
      openByKey(site.api.substring(ExternalMediaLibrary.jellyfinPrefix.length));

  static Future<JellyfinLibrary> openByKey(String key) async {
    final raw = (await SharedPreferences.getInstance())
        .getString('jellyfin.account.$key');
    if (raw == null) throw StateError('请在本机重新登录 Jellyfin');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return JellyfinLibrary._(
      Uri.parse(map['base'].toString()),
      map['user'].toString(),
      map['token'].toString(),
      map['device'].toString(),
      key,
    );
  }

  Uri _url(String path, [Map<String, String>? params]) =>
      base.replace(path: '${base.path}$path', queryParameters: params);

  Future<Map<String, dynamic>> _api(
    String path, {
    Map<String, String>? params,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline =
        Timer(const Duration(seconds: 15), () => client.close(force: true));
    try {
      final req = await client.openUrl(
        body == null ? 'GET' : 'POST',
        _url(path, params),
      );
      req.followRedirects = false;
      final authHeader =
          'MediaBrowser Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="1"${token.isNotEmpty ? ', Token="$token"' : ''}';
      req.headers.set('Authorization', authHeader);
      req.headers.set('X-Emby-Authorization', authHeader);
      if (token.isNotEmpty) {
        req.headers.set('X-Emby-Token', token);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close();
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw StateError('Jellyfin 拒绝访问，请检查账号密码或媒体库权限');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('Jellyfin HTTP ${resp.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const FormatException('Jellyfin 响应过大');
        }
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const FormatException('Jellyfin 未返回有效 JSON 数据');
      }
      return Map<String, dynamic>.from(decoded);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  CmsVideo _card(Map i, [List<CmsLine> lines = const []]) {
    final id = i['Id']?.toString() ?? '';
    final tags = i['ImageTags'];
    return CmsVideo(
      id: id,
      title: i['Name']?.toString() ?? '',
      year: i['ProductionYear']?.toString() ?? '',
      description: i['Overview']?.toString() ?? '',
      poster: _url('/Items/$id/Images/Primary', {
        if (tags is Map && tags['Primary'] is String)
          'tag': tags['Primary'].toString(),
        'maxWidth': '500',
      }).replace(fragment: 'mm-jf=$accountKey').toString(),
      lines: lines,
    );
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final views = await _api('/Users/$user/Views');
    final groups = (views['Items'] as List? ?? const [])
        .whereType<Map>()
        .map((v) => CmsCategory(
              id: v['Id']?.toString() ?? '',
              name: v['Name']?.toString() ?? '媒体库',
            ))
        .where((c) => c.id.isNotEmpty)
        .toList();
    return (groups, await list('', '', 1));
  }

  Future<CmsListing> list(String parent, String query, int page) async {
    const limit = 40;
    final j = await _api(
      '/Users/$user/Items',
      params: {
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series,Video',
        'Fields': 'Overview,ProductionYear',
        'Limit': '$limit',
        'StartIndex': '${(page - 1) * limit}',
        if (parent.isNotEmpty) 'ParentId': parent,
        if (query.isNotEmpty) 'SearchTerm': query,
      },
    );
    final cards = (j['Items'] as List? ?? const [])
        .whereType<Map>()
        .map((v) => _card(v))
        .toList();
    final total =
        j['TotalRecordCount'] as int? ?? (page - 1) * limit + cards.length;
    return CmsListing(
      page: page,
      pageCount: max(page, (total / limit).ceil()),
      videos: cards,
    );
  }

  Future<CmsVideo> detail(String id) async {
    final item = await _api(
      '/Users/$user/Items/$id',
      params: {'Fields': 'Overview,MediaSources'},
    );
    final episodes = <CmsEpisode>[];
    void add(Map row) {
      final name = row['Name']?.toString() ?? '正片';
      final sources = row['MediaSources'];
      final sid = sources is List && sources.isNotEmpty
          ? sources.first['Id']?.toString()
          : row['Id']?.toString();
      episodes.add(
        CmsEpisode(
          name: row['ParentIndexNumber'] == null
              ? name
              : 'S${row['ParentIndexNumber']}E${row['IndexNumber']} $name',
          url: Uri(
            scheme: 'mmjellyfin',
            host: 'play',
            queryParameters: {
              'id': row['Id']?.toString() ?? '',
              'source': sid ?? row['Id']?.toString() ?? '',
            },
          ).toString(),
        ),
      );
    }

    if (item['Type'] == 'Series') {
      var start = 0;
      while (start < 10000) {
        final j = await _api(
          '/Shows/$id/Episodes',
          params: {
            'UserId': user,
            'Fields': 'MediaSources',
            'Limit': '200',
            'StartIndex': '$start',
          },
        );
        final rows = (j['Items'] as List? ?? const []).whereType<Map>().toList();
        rows.forEach(add);
        start += rows.length;
        final total = (j['TotalRecordCount'] as num?)?.toInt() ?? start;
        if (rows.isEmpty || start >= total) break;
      }
    } else {
      add(item);
    }
    return _card(item, [
      if (episodes.isNotEmpty) CmsLine(name: 'Jellyfin', episodes: episodes),
    ]);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final p = Uri.parse(episode.url).queryParameters;
    final id = p['id'] ?? '';
    final sid = p['source'] ?? id;
    if (id.isEmpty) throw const FormatException('Jellyfin 媒体编号缺失');
    final authHeader =
        'MediaBrowser Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="1", Token="$token"';
    final headers = <String, String>{
      'X-Emby-Token': token,
      'Authorization': authHeader,
    };
    try {
      final info = await _api(
        '/Items/$id/PlaybackInfo',
        body: {
          'UserId': user,
          if (sid.isNotEmpty) 'MediaSourceId': sid,
          'IsPlayback': true,
          'EnableDirectPlay': false,
          'EnableDirectStream': true,
          'EnableTranscoding': true,
        },
      );
      final sources = (info['MediaSources'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final chosen = sources
              .where((s) => s['Id']?.toString() == sid)
              .firstOrNull ??
          (sources.isNotEmpty ? sources.first : null);
      final session = info['PlaySessionId']?.toString() ?? '';
      if (chosen != null) {
        final direct = chosen['SupportsDirectStream'] == true ||
            chosen['SupportsDirectPlay'] == true;
        final transcode = chosen['TranscodingUrl']?.toString() ?? '';
        if (!direct && transcode.isNotEmpty) {
          final uri = Uri.parse('${base.toString()}/').resolve(transcode);
          return CmsEpisode(name: episode.name, url: uri.toString(), headers: headers);
        }
        final stream = _url('/Videos/$id/stream', {
          'Static': 'true',
          'MediaSourceId': chosen['Id']?.toString() ?? sid,
          if (session.isNotEmpty) 'PlaySessionId': session,
          'DeviceId': device,
        });
        return CmsEpisode(name: episode.name, url: stream.toString(), headers: headers);
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // Fall back to direct stream URL if server does not expose PlaybackInfo.
    }
    final stream = _url('/Videos/$id/stream', {
      'Static': 'true',
      'MediaSourceId': sid,
      'DeviceId': device,
    });
    return CmsEpisode(name: episode.name, url: stream.toString(), headers: headers);
  }
}

/// Real Plex Media Server connector (`plex://account/<key>`).
class PlexLibrary {
  final Uri base;
  final String token;
  final String accountKey;

  const PlexLibrary._(this.base, this.token, this.accountKey);

  static Future<SubscriptionEntry> login(
    String address,
    String token, {
    String label = '',
    required String group,
    required bool isPrivate,
  }) async {
    final base = ExternalMediaLibrary._validateHttpBase(address, 'Plex');
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) {
      throw const FormatException('请填写 X-Plex-Token');
    }
    final probe = PlexLibrary._(base, cleanToken, '');
    final sections = await probe._api('/library/sections');
    if (sections['MediaContainer'] is! Map) {
      throw const FormatException('该地址未返回有效的 Plex MediaContainer 响应，请检查服务器地址');
    }
    final key = sha256.convert(utf8.encode('plex|$base|$cleanToken')).toString();
    final name = label.trim().isNotEmpty
        ? 'Plex · ${label.trim()}'
        : 'Plex · ${base.host}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'plex.account.$key',
      jsonEncode({'base': base.toString(), 'token': cleanToken}),
    );
    final api = '${ExternalMediaLibrary.plexPrefix}$key';
    return SubscriptionEntry(
      id: 'plex_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'Plex',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'plex_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<PlexLibrary> open(CmsSite site) =>
      openByKey(site.api.substring(ExternalMediaLibrary.plexPrefix.length));

  static Future<PlexLibrary> openByKey(String key) async {
    final raw =
        (await SharedPreferences.getInstance()).getString('plex.account.$key');
    if (raw == null) throw StateError('请在本机重新配置 Plex');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return PlexLibrary._(
      Uri.parse(map['base'].toString()),
      map['token'].toString(),
      key,
    );
  }

  Uri _url(String path, [Map<String, String>? params]) =>
      base.replace(path: '${base.path}$path', queryParameters: params);

  Future<Map<String, dynamic>> _api(
    String path, {
    Map<String, String>? params,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline =
        Timer(const Duration(seconds: 15), () => client.close(force: true));
    try {
      final req = await client.getUrl(_url(path, params));
      req.followRedirects = false;
      req.headers.set('Accept', 'application/json');
      req.headers.set('X-Plex-Token', token);
      final resp = await req.close();
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw StateError('Plex Token 无效或无权访问该媒体库');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('Plex HTTP ${resp.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const FormatException('Plex 响应过大');
        }
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const FormatException('Plex 返回的数据格式无效');
      }
      return Map<String, dynamic>.from(decoded);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  CmsVideo _card(Map item, [List<CmsLine> lines = const []]) {
    final rk = item['ratingKey']?.toString() ?? '';
    final thumb = item['thumb']?.toString() ?? '';
    final poster = thumb.isNotEmpty
        ? _url(thumb.startsWith('/') ? thumb : '/$thumb')
            .replace(fragment: 'mm-plex=$accountKey')
            .toString()
        : '';
    return CmsVideo(
      id: rk,
      title: item['title']?.toString() ?? '',
      year: item['year']?.toString() ?? '',
      description: item['summary']?.toString() ?? '',
      poster: poster,
      lines: lines,
    );
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final j = await _api('/library/sections');
    final container = j['MediaContainer'] as Map? ?? const {};
    final dirs = (container['Directory'] as List? ?? const [])
        .whereType<Map>()
        .where((d) {
          final t = d['type']?.toString() ?? '';
          return t == 'movie' || t == 'show' || t == 'video';
        })
        .map((d) => CmsCategory(
              id: d['key']?.toString() ?? '',
              name: d['title']?.toString() ?? 'Plex',
            ))
        .where((c) => c.id.isNotEmpty)
        .toList();
    if (dirs.isEmpty) return (dirs, const CmsListing());
    for (final dir in dirs) {
      final listing = await list(dir.id, '', 1);
      if (listing.videos.isNotEmpty) {
        return (dirs, listing);
      }
    }
    return (dirs, const CmsListing());
  }

  Future<CmsListing> list(String sectionId, String query, int page) async {
    const limit = 40;
    final start = (page - 1) * limit;
    final path = query.isNotEmpty
        ? '/search'
        : (sectionId.isNotEmpty
            ? '/library/sections/$sectionId/all'
            : '/library/recentlyAdded');
    final j = await _api(
      path,
      params: {
        if (query.isNotEmpty) 'query': query,
        'X-Plex-Container-Start': '$start',
        'X-Plex-Container-Size': '$limit',
      },
    );
    final container = j['MediaContainer'] as Map? ?? const {};
    final items = (container['Metadata'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => _card(m))
        .toList();
    final total =
        (container['totalSize'] as num?)?.toInt() ?? start + items.length;
    return CmsListing(
      page: page,
      pageCount: max(page, (total / limit).ceil()),
      videos: items,
    );
  }

  Future<CmsVideo> detail(String ratingKey, CmsVideo fallback) async {
    final j = await _api('/library/metadata/$ratingKey');
    final container = j['MediaContainer'] as Map? ?? const {};
    final metaList =
        (container['Metadata'] as List? ?? const []).whereType<Map>().toList();
    if (metaList.isEmpty) return fallback;
    final item = metaList.first;
    final episodes = <CmsEpisode>[];

    void addMediaItem(Map row) {
      final media = (row['Media'] as List? ?? const []).whereType<Map>();
      String? partKey;
      for (final m in media) {
        final parts = (m['Part'] as List? ?? const []).whereType<Map>();
        if (parts.isNotEmpty && parts.first['key'] != null) {
          partKey = parts.first['key'].toString();
          break;
        }
      }
      if (partKey == null || partKey.isEmpty) return;
      final epName = row['title']?.toString() ?? '正片';
      final season = row['parentIndex'];
      final epNum = row['index'];
      final label = (season != null && epNum != null)
          ? 'S${season}E$epNum $epName'
          : epName;
      episodes.add(
        CmsEpisode(
          name: label,
          url: Uri(
            scheme: 'mmplex',
            host: 'play',
            queryParameters: {'part': partKey},
          ).toString(),
        ),
      );
    }

    if (item['type'] == 'show') {
      final leaves = await _api('/library/metadata/$ratingKey/allLeaves');
      final lContainer = leaves['MediaContainer'] as Map? ?? const {};
      (lContainer['Metadata'] as List? ?? const [])
          .whereType<Map>()
          .forEach(addMediaItem);
    } else {
      addMediaItem(item);
    }
    return _card(item, [
      if (episodes.isNotEmpty) CmsLine(name: 'Plex', episodes: episodes),
    ]);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final part = Uri.parse(episode.url).queryParameters['part'] ?? '';
    if (part.isEmpty) throw const FormatException('Plex 播放路径缺失');
    final stream = _url(part.startsWith('/') ? part : '/$part');
    return CmsEpisode(
      name: episode.name,
      url: stream.toString(),
      headers: {'X-Plex-Token': token},
    );
  }
}

/// Real WebDAV PROPFIND media library connector (`webdavlib://account/<key>`).
///
/// Enforces RFC 4918 Multi-Status (`207` / `<multistatus>`) validation so HTML
/// login pages returning `HTTP 200` fail with a clear protocol error instead of
/// silently masquerading as an empty WebDAV directory.
class WebDavMediaLibrary {
  final Uri base;
  final String username;
  final String password;

  const WebDavMediaLibrary._(this.base, this.username, this.password);

  Map<String, String> get _authHeaders {
    if (username.isEmpty && password.isEmpty) return const <String, String>{};
    final encoded = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $encoded'};
  }

  static Future<SubscriptionEntry> login(
    String address, {
    String username = '',
    String password = '',
    String label = '',
    required String group,
    required bool isPrivate,
  }) async {
    final base = ExternalMediaLibrary._validateHttpBase(address, 'WebDAV');
    final lib = WebDavMediaLibrary._(base, username.trim(), password);
    await lib._propfind(base);
    final key = sha256
        .convert(utf8.encode('webdavlib|$base|${username.trim()}'))
        .toString();
    final name = label.trim().isNotEmpty
        ? 'WebDAV · ${label.trim()}'
        : 'WebDAV · ${base.host}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'webdavlib.account.$key',
      jsonEncode({
        'base': base.toString(),
        'user': username.trim(),
        'pass': password,
      }),
    );
    final api = '${ExternalMediaLibrary.webdavPrefix}$key';
    return SubscriptionEntry(
      id: 'webdavlib_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'WebDAV',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'webdavlib_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<WebDavMediaLibrary> open(CmsSite site) async {
    final key = site.api.substring(ExternalMediaLibrary.webdavPrefix.length);
    final raw = (await SharedPreferences.getInstance())
        .getString('webdavlib.account.$key');
    if (raw == null) throw StateError('请在本机重新配置 WebDAV 媒体库');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return WebDavMediaLibrary._(
      Uri.parse(map['base'].toString()),
      map['user']?.toString() ?? '',
      map['pass']?.toString() ?? '',
    );
  }

  static final RegExp _multistatusRe = RegExp(
    r'<(?:\w+:)?multistatus\b',
    caseSensitive: false,
  );
  static final RegExp _htmlDocRe = RegExp(
    r'<!doctype\s+html|<html\b|<head\b|<body\b',
    caseSensitive: false,
  );

  static bool isValidPropfindXml(String body) =>
      _multistatusRe.hasMatch(body) && !_htmlDocRe.hasMatch(body);

  static List<({String href, String displayName, bool isDir})> parsePropfindXml(
    String xml,
    Uri requestUri,
  ) {
    final results = <({String href, String displayName, bool isDir})>[];
    final responseRe = RegExp(
      r'<(?:\w+:)?response\b[^>]*>([\s\S]*?)</(?:\w+:)?response>',
      caseSensitive: false,
    );
    final hrefRe = RegExp(
      r'<(?:\w+:)?href\b[^>]*>([\s\S]*?)</(?:\w+:)?href>',
      caseSensitive: false,
    );
    final displayRe = RegExp(
      r'<(?:\w+:)?displayname\b[^>]*>([\s\S]*?)</(?:\w+:)?displayname>',
      caseSensitive: false,
    );
    final collectionRe = RegExp(
      r'<(?:\w+:)?collection\b[^>]*/?>',
      caseSensitive: false,
    );
    final reqPath = _normalizedPath(requestUri.path);
    for (final m in responseRe.allMatches(xml)) {
      final block = m.group(1) ?? '';
      final rawHref = hrefRe.firstMatch(block)?.group(1)?.trim() ?? '';
      if (rawHref.isEmpty) continue;
      final resolved = requestUri.resolve(rawHref);
      final cleanPath = _normalizedPath(resolved.path);
      if (cleanPath == reqPath) continue;
      final isDir = collectionRe.hasMatch(block) || rawHref.endsWith('/');
      final disp = displayRe.firstMatch(block)?.group(1)?.trim() ?? '';
      final seg = cleanPath.split('/').where((s) => s.isNotEmpty).toList();
      final fallbackName = seg.isEmpty ? cleanPath : _safeDecode(seg.last);
      final name = disp.isNotEmpty ? disp : fallbackName;
      results.add((href: resolved.toString(), displayName: name, isDir: isDir));
    }
    return results;
  }

  static String _normalizedPath(String raw) {
    final trimmed = raw.replaceFirst(RegExp(r'/+$'), '');
    return _safeDecode(trimmed);
  }

  static String _safeDecode(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  Future<List<({String href, String displayName, bool isDir})>> _propfind(
    Uri uri,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline =
        Timer(const Duration(seconds: 15), () => client.close(force: true));
    try {
      final target =
          uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
      final req = await client.openUrl('PROPFIND', target);
      req.followRedirects = false;
      req.headers.set('Depth', '1');
      req.headers.set('Accept', 'application/xml, text/xml');
      _authHeaders.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close();
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw StateError('WebDAV 认证失败，请检查账号和密码');
      }
      if (resp.statusCode == 405) {
        throw const FormatException('该地址不支持 WebDAV PROPFIND 协议（HTTP 405），请确认 WebDAV 路径');
      }
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        throw FormatException(
          'WebDAV 地址发生了重定向（HTTP ${resp.statusCode}），可能是网页登录跳转，请填写正确的 WebDAV 目录地址',
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('WebDAV HTTP ${resp.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) break;
        bytes.addAll(chunk);
      }
      final body = utf8.decode(bytes, allowMalformed: true);
      final contentType = (resp.headers.contentType?.mimeType ?? '').toLowerCase();
      if (contentType.contains('html') ||
          _htmlDocRe.hasMatch(body) ||
          (resp.statusCode != 207 && !isValidPropfindXml(body)) ||
          !isValidPropfindXml(body)) {
        throw FormatException(
          'WebDAV 协议校验失败：服务器返回了网页或非标准响应（HTTP ${resp.statusCode}），而非 WebDAV 目录列表',
        );
      }
      return parsePropfindXml(body, target);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  List<CmsVideo> _buildCards(
    List<({String href, String displayName, bool isDir})> entries, {
    String query = '',
  }) {
    final q = query.trim().toLowerCase();
    final cards = <CmsVideo>[];
    for (final e in entries.where((e) => e.isDir)) {
      if (q.isNotEmpty && !e.displayName.toLowerCase().contains(q)) continue;
      cards.add(
        CmsVideo(
          id: ExternalMediaLibrary.encodeFolderId(e.href),
          title: e.displayName,
          remarks: '文件夹',
          tag: ExternalMediaLibrary.folderTag,
        ),
      );
    }
    for (final e in entries.where(
      (e) => !e.isDir && ExternalMediaLibrary.isVideoFileName(e.displayName),
    )) {
      if (q.isNotEmpty && !e.displayName.toLowerCase().contains(q)) continue;
      cards.add(
        CmsVideo(
          id: e.href,
          title: ExternalMediaLibrary.cleanMediaTitle(e.displayName),
          remarks: 'WebDAV 直连',
        ),
      );
    }
    return cards;
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final entries = await _propfind(base);
    final cats = <CmsCategory>[
      const CmsCategory(id: '__root__', name: '根目录'),
      for (final e in entries.where((e) => e.isDir))
        CmsCategory(id: e.href, name: e.displayName),
    ];
    final cards = _buildCards(entries);
    return (cats, CmsListing(page: 1, pageCount: 1, videos: cards));
  }

  Future<CmsListing> list(String categoryId, String query, int page) async {
    final decoded = ExternalMediaLibrary.decodeFolderId(categoryId.trim());
    final target =
        (decoded.isEmpty || decoded == '__root__') ? base : Uri.parse(decoded);
    final entries = await _propfind(target);
    return CmsListing(
      page: 1,
      pageCount: 1,
      videos: _buildCards(entries, query: query),
    );
  }

  Future<CmsVideo> detail(CmsVideo fallback) async {
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      remarks: 'WebDAV 原画直连',
      lines: [
        CmsLine(
          name: 'WebDAV',
          episodes: [
            CmsEpisode(
              name: fallback.title.isEmpty ? '正片' : fallback.title,
              url: Uri(
                scheme: 'mmwebdav',
                host: 'play',
                queryParameters: {'url': fallback.id},
              ).toString(),
            ),
          ],
        ),
      ],
    );
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final raw = Uri.parse(episode.url).queryParameters['url'] ?? '';
    if (raw.isEmpty) throw const FormatException('WebDAV 视频路径缺失');
    return CmsEpisode(name: episode.name, url: raw, headers: _authHeaders);
  }
}

/// Real AList / OpenList / NAS API connector (`alist://account/<key>`).
class AlistNasLibrary {
  final Uri base;
  final String token;
  final String rootPath;

  const AlistNasLibrary._(this.base, this.token, this.rootPath);

  static Future<SubscriptionEntry> login(
    String address, {
    String username = '',
    String password = '',
    String rootPath = '/',
    String label = '',
    required String group,
    required bool isPrivate,
  }) async {
    final base = ExternalMediaLibrary._validateHttpBase(address, 'AList / OpenList');
    var token = '';
    final cleanRoot = rootPath.trim().isEmpty ? '/' : rootPath.trim();
    final probe = AlistNasLibrary._(base, '', cleanRoot);
    if (username.trim().isNotEmpty) {
      final auth = await probe._post('/api/auth/login', {
        'username': username.trim(),
        'password': password,
      });
      token = auth['data']?['token']?.toString() ?? '';
      if (token.isEmpty) {
        throw StateError('AList / OpenList 登录未返回有效令牌，请检查账号和密码');
      }
    }
    final authed = AlistNasLibrary._(base, token, cleanRoot);
    await authed._listDir(authed.rootPath, page: 1);
    final key = sha256
        .convert(utf8.encode('alist|$base|${authed.rootPath}|${username.trim()}'))
        .toString();
    final name = label.trim().isNotEmpty
        ? 'AList · ${label.trim()}'
        : 'AList / OpenList · ${base.host}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'alist.account.$key',
      jsonEncode({
        'base': base.toString(),
        'token': token,
        'rootPath': authed.rootPath,
      }),
    );
    final api = '${ExternalMediaLibrary.alistPrefix}$key';
    return SubscriptionEntry(
      id: 'alist_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'AList',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'alist_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<AlistNasLibrary> open(CmsSite site) async {
    final key = site.api.substring(ExternalMediaLibrary.alistPrefix.length);
    final raw =
        (await SharedPreferences.getInstance()).getString('alist.account.$key');
    if (raw == null) throw StateError('请在本机重新配置 AList / OpenList');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return AlistNasLibrary._(
      Uri.parse(map['base'].toString()),
      map['token']?.toString() ?? '',
      map['rootPath']?.toString() ?? '/',
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline =
        Timer(const Duration(seconds: 15), () => client.close(force: true));
    try {
      final req = await client.postUrl(base.replace(path: '${base.path}$path'));
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      if (token.isNotEmpty) {
        req.headers.set('Authorization', token);
      }
      req.write(jsonEncode(body));
      final resp = await req.close();
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) break;
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        throw FormatException(
          'AList / OpenList 协议校验失败：服务器返回了非 JSON 内容（HTTP ${resp.statusCode}）',
        );
      }
      if (decoded is! Map) {
        throw const FormatException('AList / OpenList 响应格式无效');
      }
      final json = Map<String, dynamic>.from(decoded);
      final code = (json['code'] as num?)?.toInt() ?? resp.statusCode;
      if (code != 200) {
        throw StateError(json['message']?.toString() ?? 'AList HTTP $code');
      }
      return json;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  Future<({List<Map> rows, int total})> _listDir(
    String dirPath, {
    int page = 1,
    int perPage = 100,
  }) async {
    final res = await _post('/api/fs/list', {
      'path': dirPath,
      'password': '',
      'page': page,
      'per_page': perPage,
      'refresh': false,
    });
    final data = res['data'] as Map? ?? const {};
    final content = data['content'];
    final rows = content is List ? content.whereType<Map>().toList() : const <Map>[];
    final total = (data['total'] as num?)?.toInt() ?? rows.length;
    return (rows: rows, total: total);
  }

  String _joinPath(String dir, String name) {
    final cleanDir = dir.endsWith('/') ? dir : '$dir/';
    return '$cleanDir$name';
  }

  List<CmsVideo> _buildCards(String dir, List<Map> rows) {
    final cards = <CmsVideo>[];
    for (final r in rows.where((e) => e['is_dir'] == true)) {
      final fname = r['name']?.toString() ?? '';
      if (fname.isEmpty) continue;
      final childPath = _joinPath(dir, fname);
      cards.add(
        CmsVideo(
          id: ExternalMediaLibrary.encodeFolderId(childPath),
          title: fname,
          remarks: '文件夹',
          tag: ExternalMediaLibrary.folderTag,
        ),
      );
    }
    for (final e in rows.where((e) =>
        e['is_dir'] != true &&
        ExternalMediaLibrary.isVideoFileName(e['name']?.toString() ?? ''))) {
      final fname = e['name']?.toString() ?? '';
      cards.add(
        CmsVideo(
          id: _joinPath(dir, fname),
          title: ExternalMediaLibrary.cleanMediaTitle(fname),
          poster: e['thumb']?.toString() ?? '',
          remarks: 'AList 直连',
        ),
      );
    }
    return cards;
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final res = await _listDir(rootPath, page: 1);
    final cats = <CmsCategory>[
      CmsCategory(id: rootPath, name: '全部目录'),
      for (final r in res.rows.where((e) => e['is_dir'] == true))
        CmsCategory(
          id: _joinPath(rootPath, r['name']?.toString() ?? ''),
          name: r['name']?.toString() ?? '目录',
        ),
    ];
    final cards = _buildCards(rootPath, res.rows);
    final pageCount = max(1, (res.total / 100).ceil());
    return (cats, CmsListing(page: 1, pageCount: pageCount, videos: cards));
  }

  Future<CmsListing> list(String categoryId, String query, int page) async {
    if (query.trim().isNotEmpty) {
      try {
        final res = await _post('/api/fs/search', {
          'parent': rootPath,
          'keywords': query.trim(),
          'scope': 0,
          'page': page,
          'per_page': 40,
        });
        final rows =
            (res['data']?['content'] as List? ?? const []).whereType<Map>();
        final videos = rows
            .where((e) =>
                e['is_dir'] != true &&
                ExternalMediaLibrary.isVideoFileName(e['name']?.toString() ?? ''))
            .map((e) {
              final parent = e['parent']?.toString() ?? rootPath;
              final fname = e['name']?.toString() ?? '';
              return CmsVideo(
                id: _joinPath(parent, fname),
                title: ExternalMediaLibrary.cleanMediaTitle(fname),
                remarks: 'AList 搜索',
              );
            })
            .toList();
        return CmsListing(page: page, pageCount: page, videos: videos);
      } catch (_) {}
    }
    final decoded = ExternalMediaLibrary.decodeFolderId(categoryId.trim());
    final dir = decoded.isEmpty ? rootPath : decoded;
    final res = await _listDir(dir, page: page);
    final pageCount = max(page, (res.total / 100).ceil());
    return CmsListing(
      page: page,
      pageCount: pageCount,
      videos: _buildCards(dir, res.rows),
    );
  }

  Future<CmsVideo> detail(CmsVideo fallback) async {
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      poster: fallback.poster,
      remarks: 'AList / OpenList',
      lines: [
        CmsLine(
          name: 'AList 原画',
          episodes: [
            CmsEpisode(
              name: fallback.title.isEmpty ? '正片' : fallback.title,
              url: Uri(
                scheme: 'mmalist',
                host: 'play',
                queryParameters: {'path': fallback.id},
              ).toString(),
            ),
          ],
        ),
      ],
    );
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final path = Uri.parse(episode.url).queryParameters['path'] ?? '';
    if (path.isEmpty) throw const FormatException('AList 文件路径缺失');
    final res = await _post('/api/fs/get', {'path': path, 'password': ''});
    final data = res['data'] as Map? ?? const {};
    var rawUrl = data['raw_url']?.toString().trim() ?? '';
    if (rawUrl.isNotEmpty && rawUrl.startsWith('/')) {
      rawUrl = base.resolve(rawUrl).toString();
    }
    if (rawUrl.isEmpty) {
      final sign = data['sign']?.toString().trim() ?? '';
      final encodedPath = path
          .split('/')
          .map(Uri.encodeComponent)
          .join('/');
      final directUri = base.replace(
        path: '${base.path}/d${encodedPath.startsWith('/') ? encodedPath : '/$encodedPath'}',
        queryParameters: sign.isNotEmpty ? {'sign': sign} : null,
      );
      rawUrl = directUri.toString();
    }
    final headers = <String, String>{};
    final rawHeaders = data['header'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null && '$v'.trim().isNotEmpty) {
          headers['$k'] = '$v';
        }
      });
    }
    if (token.isNotEmpty && rawUrl.startsWith(base.origin)) {
      headers.putIfAbsent('Authorization', () => token);
    }
    return CmsEpisode(name: episode.name, url: rawUrl, headers: headers);
  }
}

/// Pure SMB2 share library (`smbnas://account/<key>`) with optional separate
/// WebDAV companion browsing mode.
///
/// Pure SMB connects directly over TCP/445 via [Smb2Client], enumerates real
/// nested directories & videos, and streams selected videos via
/// [SmbMediaStreamProxy] (HTTP 206 Range seeking for AVPlayer & MPV).
class SmbNasLibrary {
  final String host;
  final int port;
  final String share;
  final String username;
  final String password;
  final String webdavCompanionUrl;

  const SmbNasLibrary._({
    required this.host,
    required this.port,
    required this.share,
    required this.username,
    required this.password,
    required this.webdavCompanionUrl,
  });

  static Future<SubscriptionEntry> configure({
    required String host,
    int port = 445,
    required String share,
    String username = '',
    String password = '',
    String webdavCompanionUrl = '',
    String label = '',
    required String group,
    required bool isPrivate,
  }) async {
    final cleanHost = host
        .trim()
        .replaceFirst(RegExp(r'^smb://', caseSensitive: false), '')
        .replaceFirst(RegExp(r'/+$'), '');
    if (cleanHost.isEmpty) {
      throw const FormatException('请输入 SMB 主机地址或局域网 IP');
    }
    final cleanShare = share
        .trim()
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '')
        .replaceFirst(RegExp(r'/+$'), '');
    final cleanCompanion = webdavCompanionUrl.trim();
    if (cleanCompanion.isEmpty && cleanShare.isEmpty) {
      throw const FormatException('请填写 SMB 共享目录名称（例如 Movies）');
    }

    // Actively verify connectivity BEFORE saving so invalid/unauthorized shares
    // never leave behind a fake/empty library entry.
    if (cleanCompanion.isNotEmpty) {
      final davUri =
          ExternalMediaLibrary._validateHttpBase(cleanCompanion, 'SMB 伴随 WebDAV');
      final dav = WebDavMediaLibrary._(davUri, username.trim(), password);
      await dav._propfind(davUri);
    } else {
      final smb = await Smb2Client.connect(
        host: cleanHost,
        port: port,
        share: cleanShare,
        username: username.trim(),
        password: password,
      );
      try {
        await smb.listDirectory('');
      } finally {
        await smb.close();
      }
    }

    final key = sha256
        .convert(
          utf8.encode(
            'smb|$cleanHost:$port/$cleanShare|${username.trim()}|$cleanCompanion',
          ),
        )
        .toString();
    final name = label.trim().isNotEmpty
        ? 'SMB · ${label.trim()}'
        : 'SMB · $cleanHost${cleanShare.isNotEmpty ? '/$cleanShare' : ''}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'smbnas.account.$key',
      jsonEncode({
        'host': cleanHost,
        'port': port,
        'share': cleanShare,
        'user': username.trim(),
        'pass': password,
        'webdav': cleanCompanion,
      }),
    );
    final api = '${ExternalMediaLibrary.smbPrefix}$key';
    return SubscriptionEntry(
      id: 'smbnas_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'SMB',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'smbnas_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<SmbNasLibrary> open(CmsSite site) async {
    final key = site.api.substring(ExternalMediaLibrary.smbPrefix.length);
    final raw =
        (await SharedPreferences.getInstance()).getString('smbnas.account.$key');
    if (raw == null) throw StateError('请在本机重新配置 SMB 共享');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return SmbNasLibrary._(
      host: map['host']?.toString() ?? '',
      port: (map['port'] as num?)?.toInt() ?? 445,
      share: map['share']?.toString() ?? '',
      username: map['user']?.toString() ?? '',
      password: map['pass']?.toString() ?? '',
      webdavCompanionUrl: map['webdav']?.toString() ?? '',
    );
  }

  WebDavMediaLibrary? _companionDav() {
    if (webdavCompanionUrl.isEmpty) return null;
    final uri = Uri.tryParse(webdavCompanionUrl);
    if (uri == null || !uri.hasScheme) return null;
    return WebDavMediaLibrary._(uri, username, password);
  }

  Future<List<Smb2Entry>> _listSmbEntries(String relativePath) async {
    final smb = await Smb2Client.connect(
      host: host,
      port: port,
      share: share,
      username: username,
      password: password,
    );
    try {
      return await smb.listDirectory(relativePath);
    } finally {
      await smb.close();
    }
  }

  List<CmsVideo> _buildSmbCards(List<Smb2Entry> entries, {String query = ''}) {
    final q = query.trim().toLowerCase();
    final cards = <CmsVideo>[];
    for (final e in entries.where((e) => e.isDir)) {
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) continue;
      cards.add(
        CmsVideo(
          id: ExternalMediaLibrary.encodeFolderId(e.relativePath),
          title: e.name,
          remarks: '文件夹',
          tag: ExternalMediaLibrary.folderTag,
        ),
      );
    }
    for (final e in entries.where(
      (e) => !e.isDir && ExternalMediaLibrary.isVideoFileName(e.name),
    )) {
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) continue;
      cards.add(
        CmsVideo(
          id: e.relativePath,
          title: ExternalMediaLibrary.cleanMediaTitle(e.name),
          remarks: 'SMB 直连',
        ),
      );
    }
    return cards;
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final dav = _companionDav();
    if (dav != null) return dav.home();
    final entries = await _listSmbEntries('');
    final cats = <CmsCategory>[
      CmsCategory(id: '', name: share.isEmpty ? host : share),
      for (final e in entries.where((e) => e.isDir))
        CmsCategory(id: e.relativePath, name: e.name),
    ];
    return (
      cats,
      CmsListing(page: 1, pageCount: 1, videos: _buildSmbCards(entries)),
    );
  }

  Future<CmsListing> list(String categoryId, String query, int page) async {
    final dav = _companionDav();
    if (dav != null) return dav.list(categoryId, query, page);
    final dirPath = ExternalMediaLibrary.decodeFolderId(categoryId.trim());
    final entries = await _listSmbEntries(dirPath);
    return CmsListing(
      page: 1,
      pageCount: 1,
      videos: _buildSmbCards(entries, query: query),
    );
  }

  Future<CmsVideo> detail(CmsVideo fallback) async {
    final dav = _companionDav();
    if (dav != null && fallback.id.startsWith('http')) {
      return dav.detail(fallback);
    }
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      remarks: 'SMB 局域网共享',
      lines: [
        CmsLine(
          name: 'SMB 直连',
          episodes: [
            CmsEpisode(
              name: fallback.title.isEmpty ? '正片' : fallback.title,
              url: Uri(
                scheme: 'mmsmb',
                host: 'play',
                queryParameters: {'path': fallback.id},
              ).toString(),
            ),
          ],
        ),
      ],
    );
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final dav = _companionDav();
    if (dav != null && episode.url.startsWith('mmwebdav://')) {
      return dav.resolve(episode);
    }
    final params = Uri.parse(episode.url).queryParameters;
    final relPath = params['path'] ?? params['url'] ?? '';
    if (relPath.isEmpty) {
      throw const FormatException('SMB 视频路径缺失');
    }
    final proxy = await SmbMediaStreamProxy.open(
      host: host,
      port: port,
      share: share,
      username: username,
      password: password,
      relativePath: relPath,
    );
    return CmsEpisode(
      name: episode.name,
      url: proxy.url.toString(),
      playbackSession: {'smbStreamProxy': proxy},
    );
  }
}

/// On-device persistent local media library (`localfile://account/<key>`).
///
/// Copies picked files into `<Documents>/MarcoLocalMedia/<key>/` and stores
/// container-relative paths so iOS temporary picker cleanup and container UUID
/// rotation across app restarts never break previously imported videos.
class LocalDeviceLibrary {
  final List<({String title, String path})> files;

  const LocalDeviceLibrary._(this.files);

  @visibleForTesting
  static Future<Directory> Function()? storageRootProviderOverride;

  static Future<Directory> _resolveStorageRoot() async {
    final override = storageRootProviderOverride;
    if (override != null) return override();
    return getApplicationDocumentsDirectory();
  }

  static Future<SubscriptionEntry> createFromPaths(
    List<String> paths, {
    String label = '当前设备影片',
    required String group,
    required bool isPrivate,
  }) async {
    final cleaned = paths
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (cleaned.isEmpty) {
      throw const FormatException('请至少选择一个本机视频文件');
    }
    final existingSources = <File>[];
    for (final p in cleaned) {
      final f = File(p);
      if (await f.exists()) {
        existingSources.add(f);
      }
    }
    if (existingSources.isEmpty) {
      throw const FormatException('所选本机视频文件不可读取，请重新选择');
    }

    final key = sha256
        .convert(
          utf8.encode(
            'local|${DateTime.now().microsecondsSinceEpoch}|${cleaned.join('|')}',
          ),
        )
        .toString();

    Directory? mediaDir;
    Directory? rootDir;
    try {
      rootDir = await _resolveStorageRoot();
      mediaDir = Directory('${rootDir.path}/MarcoLocalMedia/$key');
      await mediaDir.create(recursive: true);
    } catch (_) {
      mediaDir = null;
      rootDir = null;
    }

    final items = <Map<String, String>>[];
    for (var i = 0; i < existingSources.length; i++) {
      final src = existingSources[i];
      final rawName = src.uri.pathSegments.isNotEmpty
          ? src.uri.pathSegments.last
          : src.path.split(RegExp(r'[/\\]')).last;
      final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final title = ExternalMediaLibrary.cleanMediaTitle(rawName);
      if (mediaDir != null && rootDir != null) {
        final relPath = 'MarcoLocalMedia/$key/${i}_$safeName';
        final dest = File('${rootDir.path}/$relPath');
        if (src.absolute.path != dest.absolute.path) {
          await src.copy(dest.path);
        }
        items.add({
          'title': title,
          'relPath': relPath,
          'path': dest.path,
        });
      } else {
        items.add({'title': title, 'path': src.path});
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('localfile.account.$key', jsonEncode(items));
    final api = '${ExternalMediaLibrary.localPrefix}$key';
    return SubscriptionEntry(
      id: 'localfile_$key',
      name: label,
      group: group,
      isPrivate: isPrivate,
      format: 'Local',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'localfile_$key', 'name': label, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<LocalDeviceLibrary> open(CmsSite site) async {
    final key = site.api.substring(ExternalMediaLibrary.localPrefix.length);
    final raw = (await SharedPreferences.getInstance())
        .getString('localfile.account.$key');
    if (raw == null) return const LocalDeviceLibrary._([]);
    Directory? rootDir;
    try {
      rootDir = await _resolveStorageRoot();
    } catch (_) {
      rootDir = null;
    }
    final list = <({String title, String path})>[];
    for (final m in (jsonDecode(raw) as List? ?? const []).whereType<Map>()) {
      final title = m['title']?.toString() ?? '本地视频';
      final relPath = m['relPath']?.toString() ?? '';
      final absPath = m['path']?.toString() ?? '';
      String resolvedPath = absPath;
      if (relPath.isNotEmpty && rootDir != null) {
        final candidate = '${rootDir.path}/$relPath';
        if (await File(candidate).exists()) {
          resolvedPath = candidate;
        }
      }
      if (resolvedPath.isNotEmpty) {
        list.add((title: title, path: resolvedPath));
      }
    }
    return LocalDeviceLibrary._(list);
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    return (
      const [CmsCategory(id: 'all', name: '本机影片')],
      await list('all', '', 1),
    );
  }

  Future<CmsListing> list(String categoryId, String query, int page) async {
    final q = query.trim().toLowerCase();
    final videos = files
        .where((f) => q.isEmpty || f.title.toLowerCase().contains(q))
        .map((f) => CmsVideo(
              id: f.path,
              title: f.title,
              remarks: '本机文件',
            ))
        .toList();
    return CmsListing(page: 1, pageCount: 1, videos: videos);
  }

  Future<CmsVideo> detail(CmsVideo fallback) async {
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      remarks: '本机文件',
      lines: [
        CmsLine(
          name: '本机直放',
          episodes: [
            CmsEpisode(
              name: fallback.title,
              url: Uri(
                scheme: 'mmlocal',
                host: 'play',
                queryParameters: {'path': fallback.id},
              ).toString(),
            ),
          ],
        ),
      ],
    );
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final path = Uri.parse(episode.url).queryParameters['path'] ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      throw StateError('本机视频文件已不存在或无法读取，请重新导入');
    }
    return CmsEpisode(name: episode.name, url: path);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class EmbyLibrary {
  final Uri base;
  final String user, token, device;
  const EmbyLibrary._(this.base, this.user, this.token, this.device);
  static const prefix = 'emby://account/';
  static String _nonce() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String composeServerAddress({
    required bool useHttps,
    required String hostOrUrl,
    String port = '',
    String path = '',
  }) {
    var raw = _cleanInput(hostOrUrl);
    if (raw.isEmpty) {
      throw const FormatException('请输入 Emby 服务器地址');
    }
    final webIdx = raw.toLowerCase().indexOf('/web/');
    if (webIdx > 0) {
      raw = raw.substring(0, webIdx);
    } else if (raw.toLowerCase().endsWith('/web')) {
      raw = raw.substring(0, raw.length - 4);
    }
    final hasExplicitScheme = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
    ).hasMatch(raw);
    if (hasExplicitScheme) {
      final u = Uri.tryParse(raw);
      if (u == null ||
          !['http', 'https'].contains(u.scheme.toLowerCase()) ||
          u.host.isEmpty) {
        throw const FormatException('请输入含 HTTP 或 HTTPS 的 Emby 服务器根地址');
      }
      var cleanPath = u.path.replaceFirst(RegExp(r'/+$'), '');
      final extraPath = _normalizeSubPath(path);
      if (cleanPath.isEmpty && extraPath.isNotEmpty) {
        cleanPath = extraPath;
      }
      final trimmedPort = port.trim();
      final explicitPort = int.tryParse(trimmedPort);
      if (trimmedPort.isNotEmpty &&
          (explicitPort == null || explicitPort < 1 || explicitPort > 65535)) {
        throw const FormatException('端口号需为 1–65535 的数字');
      }
      return u
          .replace(
            scheme: u.scheme.toLowerCase(),
            port: u.hasPort ? u.port : explicitPort,
            path: cleanPath,
            query: null,
            fragment: null,
          )
          .toString();
    }

    final scheme = useHttps ? 'https' : 'http';
    final cleanSub = _normalizeSubPath(path);
    final hostAndPath = raw.replaceFirst(RegExp(r'^/+'), '');
    final baseProbe = Uri.tryParse('$scheme://$hostAndPath');
    if (baseProbe == null ||
        baseProbe.host.isEmpty ||
        baseProbe.userInfo.isNotEmpty ||
        baseProbe.hasQuery) {
      throw const FormatException('请输入有效的 Emby 服务器域名或 IP');
    }
    var effectivePath = baseProbe.path.replaceFirst(RegExp(r'/+$'), '');
    if (effectivePath.isEmpty && cleanSub.isNotEmpty) {
      effectivePath = cleanSub;
    }
    final trimmedPort = port.trim();
    int? parsedPort;
    if (trimmedPort.isNotEmpty) {
      parsedPort = int.tryParse(trimmedPort);
      if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
        throw const FormatException('端口号需为 1–65535 的数字');
      }
    }
    final targetPort = baseProbe.hasPort
        ? baseProbe.port
        : (parsedPort ?? (useHttps ? null : 8096));
    return baseProbe
        .replace(
          port: targetPort,
          path: effectivePath,
          query: null,
          fragment: null,
        )
        .toString();
  }

  static String _cleanInput(String value) => value
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .replaceAll('：', ':')
      .replaceAll('／', '/')
      .trim();

  static String _normalizeSubPath(String rawPath) {
    final cleaned = _cleanInput(rawPath)
        .replaceAll(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'^/+'), '');
    return cleaned.isEmpty ? '' : '/$cleaned';
  }

  static Uri _normalizeRoot(String address) {
    var cleaned = _cleanInput(address);
    if (cleaned.isEmpty) {
      throw const FormatException('请输入 Emby 服务器根地址');
    }
    final hash = cleaned.indexOf('#');
    if (hash >= 0 && cleaned.toLowerCase().contains('/web/')) {
      cleaned = cleaned.substring(0, hash);
    }
    final lower = cleaned.toLowerCase();
    final webIdx = lower.indexOf('/web/');
    if (webIdx > 0) {
      cleaned = cleaned.substring(0, webIdx).replaceFirst(RegExp(r'/+$'), '');
    } else if (lower.endsWith('/web')) {
      cleaned =
          cleaned.substring(0, cleaned.length - 4).replaceFirst(RegExp(r'/+$'), '');
    }
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(cleaned)) {
      cleaned = 'http://$cleaned';
    }
    final u = Uri.tryParse(cleaned);
    if (u == null ||
        !['http', 'https'].contains(u.scheme.toLowerCase()) ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment) {
      throw const FormatException('请输入含 HTTP 或 HTTPS 的 Emby 服务器根地址');
    }
    final path = u.path.replaceFirst(RegExp(r'/+$'), '');
    return u.replace(scheme: u.scheme.toLowerCase(), path: path);
  }

  static Uri _openSavedBase(String rawBase) => _normalizeRoot(rawBase);

  static int _effectivePort(Uri u) =>
      u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);

  static bool _isAllowedRedirect(Uri origin, Uri next) {
    if (!['http', 'https'].contains(next.scheme.toLowerCase())) return false;
    if (origin.host.toLowerCase() != next.host.toLowerCase()) return false;
    if (origin.scheme == next.scheme) {
      return _effectivePort(origin) == _effectivePort(next);
    }
    return origin.scheme == 'http' && next.scheme == 'https';
  }

  static Future<String> _probeHttpEmbyHint(Uri httpsUri) async {
    final candidates = <Uri>[
      httpsUri.replace(
        scheme: 'http',
        port: httpsUri.hasPort && httpsUri.port != 443 ? httpsUri.port : 8096,
        path: '${httpsUri.path}/System/Info/Public',
        query: null,
        fragment: null,
      ),
      if (httpsUri.hasPort && httpsUri.port != 8096)
        httpsUri.replace(
          scheme: 'http',
          port: 8096,
          path: '/emby/System/Info/Public',
          query: null,
          fragment: null,
        ),
    ];
    for (final probeUrl in candidates) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final timer = Timer(
        const Duration(seconds: 4),
        () => client.close(force: true),
      );
      try {
        final req = await client.getUrl(probeUrl);
        req.followRedirects = false;
        req.headers.set('Accept', 'application/json');
        final resp = await req.close();
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final bodyBytes = await resp
              .fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
          final decoded = jsonDecode(utf8.decode(bodyBytes));
          if (decoded is Map &&
              (decoded['Id'] != null || decoded['ServerName'] != null)) {
            final serverName = decoded['ServerName']?.toString().trim() ?? '';
            final title = serverName.isNotEmpty ? '「$serverName」' : 'Emby 服务';
            return '该服务器未开启 HTTPS，已在 ${probeUrl.scheme}://${probeUrl.host}:${probeUrl.port} 检测到 $title，请切换为 HTTP（端口 ${probeUrl.port}）后重试';
          }
        }
      } catch (_) {
      } finally {
        timer.cancel();
        client.close(force: true);
      }
    }
    return '';
  }

  static Future<SubscriptionEntry> login(
    String address,
    String username,
    String password, {
    required String group,
    required bool isPrivate,
    String label = '',
  }) async {
    final trimmedInput = _cleanInput(address);
    final rawHasScheme = RegExp(
      r'^[a-zA-Z][a-zA-Z0-9+.-]*://',
    ).hasMatch(trimmedInput);
    final bareRoot = _normalizeRoot(trimmedInput);
    final userSpecifiedEmby = bareRoot.path.toLowerCase().endsWith('/emby');
    final prefs = await SharedPreferences.getInstance();
    final device = prefs.getString('emby.device') ?? _nonce();
    if (!await prefs.setString('emby.device', device)) {
      throw StateError('无法保存设备标识');
    }
    final candidateBases = <Uri>[
      if (userSpecifiedEmby)
        bareRoot
      else ...[
        bareRoot.replace(path: '${bareRoot.path}/emby'),
        bareRoot,
      ],
      if (!rawHasScheme && !bareRoot.hasPort && bareRoot.scheme == 'http') ...[
        bareRoot.replace(port: 8096, path: '${bareRoot.path}/emby'),
        bareRoot.replace(port: 8096),
      ],
    ];
    Uri activeBase = candidateBases.first;
    Map<String, dynamic>? authJson;
    Object? lastErr;
    for (final candidate in candidateBases) {
      try {
        final attempt = EmbyLibrary._(candidate, '', '', device);
        final res = await attempt._apiWithResolvedBase(
          '/Users/AuthenticateByName',
          body: {'Username': username.trim(), 'Pw': password},
        );
        activeBase = res.$1;
        authJson = res.$2;
        break;
      } catch (e) {
        lastErr = e;
        if (e is StateError && e.message.contains('拒绝访问')) rethrow;
        if ((e is HandshakeException || e is TlsException) &&
            candidate.scheme == 'https') {
          final hint = await _probeHttpEmbyHint(candidate);
          if (hint.isNotEmpty) {
            throw StateError(hint);
          }
          rethrow;
        }
      }
    }
    if (authJson == null) {
      if (lastErr != null) {
        Error.throwWithStackTrace(lastErr, StackTrace.current);
      }
      throw StateError('无法连接到 Emby 服务器');
    }
    final user = authJson['User']?['Id'];
    final token = authJson['AccessToken'];
    if (user is! String || user.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('Emby 没有返回有效账户');
    }
    final authed = EmbyLibrary._(activeBase, user, token, device);
    final views = await authed._api('/Users/$user/Views');
    if (views['Items'] is! List) {
      throw StateError('Emby 未返回有效媒体库目录，请检查当前账号的媒体库访问权限');
    }
    var serverTitle = label.trim();
    if (serverTitle.isEmpty) {
      try {
        final sys = await authed._api('/System/Info/Public');
        final sName = sys['ServerName']?.toString().trim() ?? '';
        if (sName.isNotEmpty) serverTitle = sName;
      } catch (_) {}
    }
    final key = sha256.convert(utf8.encode('$activeBase\n$user')).toString();
    final name = serverTitle.isNotEmpty
        ? (serverTitle.startsWith('Emby') ? serverTitle : 'Emby · $serverTitle')
        : 'Emby · ${username.trim()}';
    final api = '$prefix$key';
    if (!await prefs.setString(
      'emby.account.$key',
      jsonEncode({
        'base': activeBase.toString(),
        'user': user,
        'token': token,
        'device': device,
      }),
    )) {
      throw StateError('无法保存 Emby 登录状态');
    }
    return SubscriptionEntry(
      id: 'emby_$key',
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'Emby',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'emby_$key', 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<EmbyLibrary> open(CmsSite site) async {
    final key = site.api.substring(prefix.length);
    final value = (await SharedPreferences.getInstance()).getString(
      'emby.account.$key',
    );
    if (value == null) throw StateError('请在本机重新登录 Emby');
    final s = jsonDecode(value);
    return EmbyLibrary._(
      _openSavedBase(s['base']),
      s['user'],
      s['token'],
      s['device'],
    );
  }

  static bool isImage(String raw) =>
      Uri.tryParse(raw)?.fragment.startsWith('mm-emby=') == true;

  static Future<Map<String, String>> imageHeaders(String raw) async {
    final uri = Uri.parse(raw);
    final account = uri.fragment.substring(8);
    final library = await open(
      CmsSite(key: account, name: 'Emby', type: 1, api: '$prefix$account'),
    );
    if (uri.origin != library.base.origin ||
        !uri.path.startsWith('${library.base.path}/Items/') ||
        !RegExp(r'/Items/[a-zA-Z0-9_-]+/Images/Primary$').hasMatch(uri.path)) {
      throw const FormatException('Emby 海报地址与账户不匹配');
    }
    return {'X-Emby-Token': library.token};
  }

  Uri _url(String path, [Map<String, String>? params]) =>
      base.replace(path: base.path + path, queryParameters: params);

  Future<Map<String, dynamic>> _api(
    String path, {
    Map<String, String>? params,
    Map? body,
  }) async {
    return (await _apiWithResolvedBase(path, params: params, body: body)).$2;
  }

  Future<(Uri, Map<String, dynamic>)> _apiWithResolvedBase(
    String path, {
    Map<String, String>? params,
    Map? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline = Timer(
      const Duration(seconds: 15),
      () => client.close(force: true),
    );
    try {
      var activeBase = base;
      var target = _url(path, params);
      final method = body == null ? 'GET' : 'POST';
      final bodyBytes = body == null ? null : utf8.encode(jsonEncode(body));
      final authHeader =
          'MediaBrowser Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="1.0.0"${token.isNotEmpty ? ', Token="$token"' : ''}';
      for (var hop = 0; hop < 6; hop++) {
        final r = await client.openUrl(method, target);
        r.followRedirects = false;
        r.headers.set('Accept', 'application/json');
        r.headers.set('User-Agent', 'MarcoMovie/1.0');
        r.headers.set('Authorization', authHeader);
        r.headers.set('X-Emby-Authorization', authHeader);
        if (token.isNotEmpty) r.headers.set('X-Emby-Token', token);
        if (bodyBytes != null) {
          r.headers.contentType = ContentType.json;
          r.add(bodyBytes);
        }
        final response = await r.close();
        final sc = response.statusCode;
        if (sc == 301 || sc == 302 || sc == 303 || sc == 307 || sc == 308) {
          final loc = response.headers.value(HttpHeaders.locationHeader)?.trim() ?? '';
          await response.drain<void>();
          if (loc.isEmpty) {
            throw HttpException('Emby 重定向地址缺失（HTTP $sc）');
          }
          final next = target.resolve(loc);
          if (!_isAllowedRedirect(activeBase, next)) {
            throw StateError('Emby 拒绝跨源或降级重定向，请检查服务器地址');
          }
          if (next.scheme != activeBase.scheme) {
            activeBase = activeBase.replace(
              scheme: next.scheme,
              port: next.hasPort ? next.port : (next.scheme == 'https' ? 443 : 80),
            );
          }
          target = next;
          continue;
        }
        if (sc == 401 || sc == 403) {
          throw StateError('Emby 拒绝访问，请检查账号或重新登录');
        }
        if (sc < 200 || sc >= 300) {
          throw HttpException('Emby HTTP $sc');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 4 * 1024 * 1024) {
            throw const FormatException('Emby 响应过大');
          }
          bytes.addAll(chunk);
        }
        final parsed = bytes.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        return (activeBase, parsed);
      }
      throw const HttpException('Emby 重定向次数过多');
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  CmsVideo _card(Map i, [List<CmsLine> lines = const []]) {
    final id = i['Id'] as String;
    final tags = i['ImageTags'];
    return CmsVideo(
      id: id,
      title: i['Name']?.toString() ?? '',
      year: i['ProductionYear']?.toString() ?? '',
      description: i['Overview']?.toString() ?? '',
      poster:
          _url('/Items/$id/Images/Primary', {
                if (tags is Map && tags['Primary'] is String)
                  'tag': tags['Primary'],
                'maxWidth': '500',
              })
              .replace(
                fragment:
                    'mm-emby=' +
                    sha256.convert(utf8.encode('$base\n$user')).toString(),
              )
              .toString(),
      lines: lines,
    );
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final views = await _api('/Users/$user/Views');
    final groups = (views['Items'] as List)
        .whereType<Map>()
        .map((v) => CmsCategory(id: v['Id'], name: v['Name']))
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
    final cards = (j['Items'] as List)
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
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id))
      throw const FormatException('Emby 媒体编号无效');
    final item = await _api(
      '/Users/$user/Items/$id',
      params: {'Fields': 'Overview,MediaSources'},
    );
    final episodes = <CmsEpisode>[];
    void add(Map row) {
      final name = row['Name']?.toString() ?? '正片';
      final sources = row['MediaSources'];
      final firstSource =
          sources is List && sources.isNotEmpty && sources.first is Map
              ? sources.first as Map
              : null;
      final sid = firstSource?['Id'] ?? row['Id'];
      final itemId = row['Id']?.toString() ?? '';
      final seasonNum = (row['ParentIndexNumber'] as num?)?.toInt();
      final epNum = (row['IndexNumber'] as num?)?.toInt();
      final rawMediaPath = (firstSource?['Path']?.toString() ?? '').trim();
      var origFile = '';
      var dirPath = '';
      if (rawMediaPath.isNotEmpty) {
        final normPath = rawMediaPath.replaceAll('\\', '/');
        final slash = normPath.lastIndexOf('/');
        if (slash >= 0) {
          origFile = normPath.substring(slash + 1);
          dirPath = normPath.substring(0, slash);
        } else {
          origFile = normPath;
        }
      }
      episodes.add(
        CmsEpisode(
          name: seasonNum == null
              ? name
              : (epNum != null ? 'S${seasonNum}E$epNum $name' : name),
          url: Uri(
            scheme: 'mmemby',
            host: 'play',
            queryParameters: {'id': itemId, 'source': (sid ?? itemId).toString()},
          ).toString(),
          sourceSeasonNumber: seasonNum,
          sourceEpisodeNumber: epNum,
          sourceItemId: itemId,
          originalFileName: origFile,
          directoryPath: dirPath,
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
        final rows = j['Items'] as List;
        rows.whereType<Map>().forEach(add);
        start += rows.length;
        if (rows.isEmpty || start >= (j['TotalRecordCount'] as int? ?? start))
          break;
      }
    } else {
      add(item);
    }
    return _card(item, [
      if (episodes.isNotEmpty) CmsLine(name: 'Emby', episodes: episodes),
    ]);
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final p = Uri.parse(episode.url).queryParameters;
    final id = p['id'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id))
      throw const FormatException('Emby 剧集编号无效');
    final wanted = p['source'] ?? id;
    final info = await _api(
      '/Items/$id/PlaybackInfo',
      body: {
        'UserId': user,
        if (wanted != id) 'MediaSourceId': wanted,
        'IsPlayback': true,
        'AutoOpenLiveStream': false,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': true,
        'MaxStreamingBitrate': 80000000,
        'DeviceProfile': {
          'Name': 'Marco Movie',
          'MaxStreamingBitrate': 80000000,
          'DirectPlayProfiles': [
            {
              'Type': 'Video',
              'Container': 'mp4,m4v,mkv,mov,ts,m2ts,webm,avi,flv',
              'VideoCodec': 'h264,hevc,h265,vp9,av1,mpeg4,mpeg2video,vc1',
              'AudioCodec': 'aac,mp3,ac3,eac3,dts,truehd,flac,opus,vorbis,pcm,alac',
            },
          ],
          'TranscodingProfiles': [
            {
              'Type': 'Video',
              'Container': 'ts',
              'Protocol': 'hls',
              'VideoCodec': 'h264',
              'AudioCodec': 'aac',
              'Context': 'Streaming',
              'MaxAudioChannels': '2',
              'MinSegments': 1,
            },
          ],
        },
      },
    );
    if ((info['ErrorCode']?.toString() ?? '').isNotEmpty) {
      throw StateError('Emby 无法为当前账号或设备提供播放方案');
    }
    final sources = (info['MediaSources'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final matching = sources.where((s) => s['Id'] == wanted).toList();
    if (matching.isEmpty && wanted == id && sources.isNotEmpty)
      matching.add(sources.first);
    if (matching.isEmpty) throw StateError('Emby 未返回所选媒体版本');
    final source = matching.first;
    final sourceId = source['Id']?.toString() ?? '';
    if (sourceId.isEmpty) throw const FormatException('Emby 媒体版本缺失');
    if (source['RequiresOpening'] == true)
      throw StateError('当前 Emby 资源需要实时流打开协议');
    final session = info['PlaySessionId']?.toString() ?? '';
    if (session.isEmpty) throw const FormatException('Emby 播放会话缺失');
    final direct =
        source['SupportsDirectStream'] == true ||
        source['SupportsDirectPlay'] == true;
    if (!direct &&
        (source['SupportsTranscoding'] != true ||
            (source['TranscodingUrl']?.toString() ?? '').isEmpty)) {
      throw StateError('Emby 没有可用的直连或转码方案');
    }
    final parameters = {
      'MediaSourceId': sourceId,
      'PlaySessionId': session,
      'DeviceId': device,
    };
    Uri stream;
    if (direct) {
      stream = _url('/Videos/$id/stream', {...parameters, 'Static': 'true'});
    } else {
      final raw = source['TranscodingUrl'].toString();
      stream = Uri.parse('${base.toString()}/').resolve(raw);
      if (stream.origin != base.origin ||
          stream.userInfo.isNotEmpty ||
          !stream.path.startsWith('${base.path}/Videos/')) {
        throw const FormatException('Emby 转码地址与服务器不匹配');
      }
      final query = Map<String, String>.from(stream.queryParameters)
        ..removeWhere(
          (k, _) => ['api_key', 'x-emby-token'].contains(k.toLowerCase()),
        );
      stream = stream.replace(
        queryParameters: {...query, ...parameters},
        fragment: '',
      );
    }
    return CmsEpisode(
      name: episode.name,
      url: stream.toString(),
      headers: {'X-Emby-Token': token},
      playbackSession: {
        'ItemId': id,
        'MediaSourceId': sourceId,
        'PlaySessionId': session,
        'PlayMethod': direct ? 'DirectStream' : 'Transcode',
        'CanSeek': true,
      },
      sourceSeasonNumber: episode.sourceSeasonNumber,
      sourceEpisodeNumber: episode.sourceEpisodeNumber,
      sourceItemId: episode.sourceItemId.isNotEmpty ? episode.sourceItemId : id,
      originalFileName: episode.originalFileName,
      directoryPath: episode.directoryPath,
      containerTags: episode.containerTags,
    );
  }

  EmbyPlaybackSession track(CmsEpisode episode) =>
      EmbyPlaybackSession._(this, episode.playbackSession);
}

/// At most one HTTP check-in in flight and one latest pending state per playback.
/// Reporting failures must not interrupt video; a subsequent update retries start.
class EmbyPlaybackSession {
  final EmbyLibrary _library;
  final Map<String, dynamic> _info;
  EmbyPlaybackSession._(this._library, Map<String, dynamic> info)
    : _info = Map.unmodifiable(info);
  bool _started = false, _stopped = false;
  int _lastSentMs = -10000, _positionMs = 0;
  bool _paused = false;
  Map<String, dynamic>? _pending;
  Future<void>? _work;
  final Stopwatch _clock = Stopwatch()..start();

  Future<void> update(
    int positionMs,
    bool paused, {
    String event = 'TimeUpdate',
    bool force = false,
  }) {
    if (_stopped || _info.isEmpty) return Future.value();
    _positionMs = max(0, positionMs);
    final changed = paused != _paused;
    _paused = paused;
    final now = _clock.elapsedMilliseconds;
    if (!force && !changed && now - _lastSentMs < 10000)
      return _work ?? Future.value();
    _lastSentMs = now;
    return _enqueue({
      ..._info,
      'PositionTicks': _positionMs * 10000,
      'IsPaused': paused,
      'EventName': changed ? (paused ? 'Pause' : 'Unpause') : event,
    });
  }

  Future<void> stop([int? positionMs]) {
    if (_stopped || _info.isEmpty) return _work ?? Future.value();
    _stopped = true;
    _positionMs = max(0, positionMs ?? _positionMs);
    return _enqueue({
      ..._info,
      'PositionTicks': _positionMs * 10000,
      'IsPaused': _paused,
      '_stop': true,
    });
  }

  Future<void> _enqueue(Map<String, dynamic> state) {
    _pending = state;
    return _work ??= _drain().whenComplete(() => _work = null);
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final state = _pending!;
      _pending = null;
      final stopping = state.remove('_stop') == true;
      final path = stopping
          ? '/Sessions/Playing/Stopped'
          : (_started ? '/Sessions/Playing/Progress' : '/Sessions/Playing');
      try {
        await _library._api(path, body: state);
        if (!stopping) _started = true;
      } catch (_) {
        /* Optional server reporting cannot stop local playback. */
      }
    }
  }
}

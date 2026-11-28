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

  static ({bool useHttps, String host, String port, String subpath})
  splitServerUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return (useHttps: false, host: '', port: '8096', subpath: '');
    }
    final hasScheme = trimmed.contains('://');
    final u = Uri.tryParse(hasScheme ? trimmed : 'http://$trimmed');
    if (u == null || u.host.isEmpty) {
      return (useHttps: false, host: trimmed, port: '8096', subpath: '');
    }
    final scheme = u.scheme.toLowerCase();
    final portNum = u.hasPort ? u.port : 0;
    final useHttps =
        scheme == 'https' || portNum == 443 || portNum == 8920;
    var host = u.host;
    if (host.contains(':') && !host.startsWith('[')) {
      host = '[$host]';
    }
    var path = u.path.replaceFirst(RegExp(r'/+$'), '');
    final lower = path.toLowerCase();
    final webIdx = lower.indexOf('/web/');
    if (webIdx >= 0) {
      path = path.substring(0, webIdx).replaceFirst(RegExp(r'/+$'), '');
    } else if (lower.endsWith('/web')) {
      path = path.substring(0, path.length - 4).replaceFirst(RegExp(r'/+$'), '');
    }
    final portStr = portNum > 0 ? '$portNum' : (useHttps ? '443' : '8096');
    return (useHttps: useHttps, host: host, port: portStr, subpath: path);
  }

  static Uri resolveServerUrl({
    required String hostOrUrl,
    bool useHttps = false,
    String port = '',
    String subpath = '',
  }) {
    var rawHost = hostOrUrl.trim();
    if (rawHost.isEmpty) {
      throw const FormatException('请填写 Emby 服务器地址');
    }
    var rawSub = subpath.trim();
    var rawPort = port.trim();
    var effectiveHttps = useHttps;
    if (rawHost.contains('://')) {
      final split = splitServerUrl(rawHost);
      final parsed = Uri.tryParse(rawHost);
      if (parsed == null ||
          !['http', 'https'].contains(parsed.scheme.toLowerCase()) ||
          parsed.host.isEmpty ||
          parsed.userInfo.isNotEmpty) {
        throw const FormatException('请输入含 HTTP 或 HTTPS 的 Emby 服务器根地址');
      }
      effectiveHttps = parsed.scheme.toLowerCase() == 'https';
      rawHost = split.host;
      if (rawSub.isEmpty) rawSub = split.subpath;
      if (rawPort.isEmpty && parsed.hasPort) rawPort = '${parsed.port}';
    } else {
      final slash = rawHost.indexOf('/');
      if (slash >= 0) {
        if (rawSub.isEmpty) rawSub = rawHost.substring(slash);
        rawHost = rawHost.substring(0, slash).trim();
      }
      if (!rawHost.startsWith('[')) {
        final colon = rawHost.lastIndexOf(':');
        if (colon > 0 && colon == rawHost.indexOf(':')) {
          final inlinePort = rawHost.substring(colon + 1).trim();
          if (rawPort.isEmpty && RegExp(r'^\d+$').hasMatch(inlinePort)) {
            rawPort = inlinePort;
          }
          rawHost = rawHost.substring(0, colon).trim();
        }
      }
    }
    if (rawHost.isEmpty) {
      throw const FormatException('请输入有效的服务器地址');
    }
    final cleanHost = rawHost.startsWith('[') && rawHost.endsWith(']')
        ? rawHost.substring(1, rawHost.length - 1)
        : rawHost;
    int? parsedPort;
    if (rawPort.isNotEmpty) {
      parsedPort = int.tryParse(rawPort);
      if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
        throw FormatException('端口号无效：$rawPort');
      }
      if ((effectiveHttps && parsedPort == 443) ||
          (!effectiveHttps && parsedPort == 80)) {
        parsedPort = null;
      }
    }
    var cleanPath = rawSub.replaceFirst(RegExp(r'/+$'), '');
    if (cleanPath.isNotEmpty && !cleanPath.startsWith('/')) {
      cleanPath = '/$cleanPath';
    }
    return _normalizeRoot(
      Uri(
        scheme: effectiveHttps ? 'https' : 'http',
        host: cleanHost,
        port: parsedPort,
        path: cleanPath,
      ).toString(),
    );
  }

  static Uri _normalizeRoot(String address) {
    var trimmed = address.trim();
    final hash = trimmed.indexOf('#');
    if (hash >= 0 && trimmed.toLowerCase().contains('/web/')) {
      trimmed = trimmed.substring(0, hash);
    }
    final u = Uri.tryParse(trimmed);
    if (u == null ||
        !['http', 'https'].contains(u.scheme.toLowerCase()) ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment) {
      throw const FormatException('请输入含 HTTP 或 HTTPS 的 Emby 服务器根地址');
    }
    var path = u.path.replaceFirst(RegExp(r'/+$'), '');
    final lower = path.toLowerCase();
    final webIdx = lower.indexOf('/web/');
    if (webIdx >= 0) {
      path = path.substring(0, webIdx).replaceFirst(RegExp(r'/+$'), '');
    } else if (lower.endsWith('/web')) {
      path = path.substring(0, path.length - 4).replaceFirst(RegExp(r'/+$'), '');
    }
    return u.replace(path: path);
  }

  static Future<Map<String, dynamic>?> readAccountConfig(String subId) async {
    if (!subId.startsWith('emby_')) return null;
    final key = subId.substring('emby_'.length);
    final raw =
        (await SharedPreferences.getInstance()).getString('emby.account.$key');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<SubscriptionEntry> updateAccountMeta({
    required SubscriptionEntry existing,
    required String label,
    required String group,
    required bool isPrivate,
    required bool allowCloudSync,
    required bool useHttps,
    required String rawHost,
    required String rawPort,
    required String rawSubpath,
  }) async {
    final key = existing.id.substring('emby_'.length);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('emby.account.$key');
    if (raw == null) throw StateError('请重新验证媒体库凭据');
    final saved = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final cleanLabel = label.trim();
    final fallbackUser = saved['username']?.toString().trim() ?? '';
    final display = cleanLabel.isNotEmpty
        ? cleanLabel
        : (fallbackUser.isNotEmpty ? fallbackUser : 'Emby');
    final name = display.startsWith('Emby') ? display : 'Emby · $display';
    final api = '$prefix$key';
    saved['label'] = cleanLabel;
    saved['allowCloudSync'] = allowCloudSync;
    saved['rawHttps'] = useHttps;
    saved['rawHost'] = rawHost.trim();
    saved['rawPort'] = rawPort.trim();
    saved['rawSubpath'] = rawSubpath.trim();
    await prefs.setString('emby.account.$key', jsonEncode(saved));
    return SubscriptionEntry(
      id: existing.id,
      name: name,
      group: group,
      isPrivate: isPrivate,
      format: 'Emby',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': existing.id, 'name': name, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  static Future<SubscriptionEntry> login(
    String address,
    String username,
    String password, {
    required String group,
    required bool isPrivate,
    String label = '',
    bool allowCloudSync = true,
  }) async {
    final bareRoot = _normalizeRoot(address);
    final userSpecifiedEmby = bareRoot.path.toLowerCase().endsWith('/emby');
    var base = userSpecifiedEmby
        ? bareRoot
        : bareRoot.replace(path: '${bareRoot.path}/emby');
    final prefs = await SharedPreferences.getInstance();
    final device = prefs.getString('emby.device') ?? _nonce();
    if (!await prefs.setString('emby.device', device))
      throw StateError('无法保存设备标识');
    final cleanUser = username.trim();
    final authBody = {'Username': cleanUser, 'Pw': password};
    Map<String, dynamic> json;
    try {
      json = await EmbyLibrary._(base, '', '', device)._api(
        '/Users/AuthenticateByName',
        body: authBody,
      );
    } on HttpException catch (err) {
      if (!userSpecifiedEmby &&
          (err.message.contains('404') || err.message.contains('405'))) {
        base = bareRoot;
        json = await EmbyLibrary._(base, '', '', device)._api(
          '/Users/AuthenticateByName',
          body: authBody,
        );
      } else {
        rethrow;
      }
    } on FormatException {
      if (!userSpecifiedEmby) {
        base = bareRoot;
        json = await EmbyLibrary._(base, '', '', device)._api(
          '/Users/AuthenticateByName',
          body: authBody,
        );
      } else {
        rethrow;
      }
    }
    final user = json['User']?['Id'];
    final token = json['AccessToken'];
    if (user is! String || user.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('Emby 没有返回有效账户');
    }
    // Verify the authenticated user can actually read media library views before
    // persisting the library entry (catches 403/disabled/unauthorized accounts).
    final authed = EmbyLibrary._(base, user, token, device);
    final views = await authed._api('/Users/$user/Views');
    if (views['Items'] is! List) {
      throw StateError('Emby 未返回有效媒体库目录，请检查当前账号的媒体库访问权限');
    }
    final key = sha256.convert(utf8.encode('$base\n$user')).toString();
    final cleanLabel = label.trim();
    final display = cleanLabel.isNotEmpty ? cleanLabel : cleanUser;
    final name = display.startsWith('Emby') ? display : 'Emby · $display';
    final api = '$prefix$key';
    final split = splitServerUrl(bareRoot.toString());
    if (!await prefs.setString(
      'emby.account.$key',
      jsonEncode({
        'base': base.toString(),
        'user': user,
        'token': token,
        'device': device,
        'label': cleanLabel,
        'username': cleanUser,
        'allowCloudSync': allowCloudSync,
        'rawHttps': split.useHttps,
        'rawHost': split.host,
        'rawPort': split.port,
        'rawSubpath': split.subpath.toLowerCase() == '/emby' ? '' : split.subpath,
      }),
    ))
      throw StateError('无法保存 Emby 登录状态');
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
      _normalizeRoot(s['base'].toString()),
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline = Timer(
      const Duration(seconds: 15),
      () => client.close(force: true),
    );
    try {
      var target = _url(path, params);
      final method = body == null ? 'GET' : 'POST';
      final authHeader =
          'Emby Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="1"${token.isNotEmpty ? ', Token="$token"' : ''}';
      HttpClientResponse? response;
      for (var hop = 0; hop < 6; hop++) {
        final r = await client.openUrl(method, target);
        r.followRedirects = false;
        r.headers.set('Authorization', authHeader);
        r.headers.set('X-Emby-Authorization', authHeader);
        r.headers.set('User-Agent', 'MarcoMovie/1.0');
        r.headers.set('Accept', 'application/json');
        if (token.isNotEmpty) r.headers.set('X-Emby-Token', token);
        if (body != null) {
          r.headers.contentType = ContentType.json;
          r.write(jsonEncode(body));
        }
        final resp = await r.close();
        if (const {301, 302, 303, 307, 308}.contains(resp.statusCode)) {
          await resp.drain<void>();
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          if (loc == null || loc.trim().isEmpty) {
            throw HttpException('Emby 重定向地址缺失（HTTP ${resp.statusCode}）');
          }
          final next = target.resolve(loc.trim());
          if (!['http', 'https'].contains(next.scheme.toLowerCase()) ||
              next.origin != base.origin ||
              next.userInfo.isNotEmpty) {
            throw const FormatException('Emby 拒绝跨源重定向以保护账号凭据');
          }
          target = next;
          continue;
        }
        response = resp;
        break;
      }
      if (response == null) {
        throw const FormatException('Emby 重定向次数过多');
      }
      if (response.statusCode == 401 || response.statusCode == 403)
        throw StateError('Emby 拒绝访问，请检查账号或重新登录');
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw HttpException('Emby HTTP ${response.statusCode}');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024)
          throw const FormatException('Emby 响应过大');
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const FormatException('Emby 响应格式无效');
      }
      return Map<String, dynamic>.from(decoded);
    } on HandshakeException catch (e) {
      throw HandshakeException(
        'SSL 握手失败（若服务器使用 8096 等 HTTP 端口，请关闭 HTTPS 开关或改用 http:// 地址）：${e.message}',
      );
    } on TlsException catch (e) {
      throw TlsException(
        'TLS 连接失败（若服务器使用 8096 等 HTTP 端口，请关闭 HTTPS 开关或改用 http:// 地址）：${e.message}',
      );
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
    if (groups.isEmpty) {
      groups.add(const CmsCategory(id: '', name: '全部媒体'));
    }
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
              'Container': 'mp4,m4v,mkv,mov,ts,webm',
              'VideoCodec': 'h264,hevc,h265,vp9,av1',
              'AudioCodec': 'aac,mp3,ac3,eac3,dts,truehd,flac,opus',
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
    final rawPath = (source['Path']?.toString() ?? '').trim();
    if (source['SupportsDirectPlay'] == true &&
        (rawPath.toLowerCase().startsWith('http://') ||
            rawPath.toLowerCase().startsWith('https://'))) {
      final pathUri = Uri.tryParse(rawPath);
      final outHeaders = <String, String>{};
      final reqHeaders = source['RequiredHttpHeaders'];
      if (reqHeaders is Map) {
        reqHeaders.forEach((k, v) {
          final ks = k?.toString() ?? '';
          final vs = v?.toString() ?? '';
          if (ks.isNotEmpty && vs.isNotEmpty) outHeaders[ks] = vs;
        });
      }
      if (pathUri != null && pathUri.origin == base.origin) {
        outHeaders['X-Emby-Token'] = token;
      }
      return CmsEpisode(
        name: episode.name,
        url: rawPath,
        headers: outHeaders,
        playbackSession: {
          'ItemId': id,
          'MediaSourceId': sourceId,
          'PlaySessionId': session,
          'PlayMethod': 'DirectPlay',
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

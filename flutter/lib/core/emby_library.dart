import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Parsed components of an Emby server endpoint for structured form editing.
class EmbyConnectionSpec {
  final bool useHttps;
  final String host;
  final String path;
  final int? port;

  const EmbyConnectionSpec({
    required this.useHttps,
    required this.host,
    this.path = '',
    this.port,
  });

  String get portText =>
      port != null ? '$port' : (useHttps ? '443' : '8096');
}

/// Persisted metadata returned for pre-filling the "编辑 Emby" sheet.
class EmbySavedAccountMeta {
  final String key;
  final String label;
  final bool allowCloudSync;
  final bool useHttps;
  final String host;
  final String path;
  final int? port;
  final String username;
  final bool allowInvalidCert;

  const EmbySavedAccountMeta({
    required this.key,
    required this.label,
    required this.allowCloudSync,
    required this.useHttps,
    required this.host,
    required this.path,
    required this.port,
    required this.username,
    required this.allowInvalidCert,
  });
}

class EmbyLibrary {
  final Uri base;
  final String user, token, device;
  final bool allowInvalidCert;
  const EmbyLibrary._(
    this.base,
    this.user,
    this.token,
    this.device, {
    this.allowInvalidCert = false,
  });
  static const prefix = 'emby://account/';
  static const String _userAgent = 'MarcoMovie/0.7.12 (iOS; Apple)';

  static String _nonce() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static int _effectivePort(Uri uri) =>
      uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);

  static String _cleanPath(String rawPath) {
    var clean = rawPath.trim();
    if (clean.isEmpty || clean == '/') return '';
    if (!clean.startsWith('/')) clean = '/$clean';
    clean = clean.replaceFirst(RegExp(r'/+$'), '');
    final lower = clean.toLowerCase();
    final webIdx = lower.indexOf('/web/');
    if (webIdx > 0) {
      clean = clean.substring(0, webIdx).replaceFirst(RegExp(r'/+$'), '');
    } else if (lower == '/web' || lower.endsWith('/web')) {
      clean = clean.substring(0, clean.length - 4).replaceFirst(RegExp(r'/+$'), '');
    }
    return clean;
  }

  /// Parses either a bare host/IP (`emby.example.com`) or full URL into structured fields.
  static EmbyConnectionSpec parseAddressToSpec(
    String raw, {
    bool defaultHttps = false,
  }) {
    var cleaned = raw.trim();
    if (cleaned.isEmpty) {
      return EmbyConnectionSpec(
        useHttps: defaultHttps,
        host: '',
        path: '',
        port: defaultHttps ? 443 : 8096,
      );
    }
    final hashIdx = cleaned.indexOf('#');
    if (hashIdx >= 0 && cleaned.toLowerCase().contains('/web/')) {
      cleaned = cleaned.substring(0, hashIdx);
    }
    final hasScheme = RegExp(r'^https?://', caseSensitive: false).hasMatch(cleaned);
    final scheme = defaultHttps ? 'https' : 'http';
    final uri = Uri.tryParse(hasScheme ? cleaned : '$scheme://$cleaned');
    if (uri == null || uri.host.isEmpty) {
      return EmbyConnectionSpec(
        useHttps: defaultHttps,
        host: cleaned,
        path: '',
        port: defaultHttps ? 443 : 8096,
      );
    }
    final useHttps = hasScheme ? uri.scheme.toLowerCase() == 'https' : defaultHttps;
    final cleanPath = _cleanPath(uri.path);
    final port = uri.hasPort
        ? uri.port
        : (hasScheme ? (useHttps ? 443 : 80) : (useHttps ? 443 : 8096));
    return EmbyConnectionSpec(
      useHttps: useHttps,
      host: uri.host,
      path: cleanPath,
      port: port,
    );
  }

  /// Composes a normalized root URL from structured Emby form inputs.
  static String composeAddress({
    required bool useHttps,
    required String host,
    String path = '',
    String portText = '',
  }) {
    var trimmedHost = host.trim();
    if (trimmedHost.isEmpty) {
      throw const FormatException('请输入 Emby 服务器地址');
    }
    final hashIdx = trimmedHost.indexOf('#');
    if (hashIdx >= 0 && trimmedHost.toLowerCase().contains('/web/')) {
      trimmedHost = trimmedHost.substring(0, hashIdx);
    }
    final hasScheme =
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmedHost);
    final defaultScheme = useHttps ? 'https' : 'http';
    final parsedHostUri =
        Uri.tryParse(hasScheme ? trimmedHost : '$defaultScheme://$trimmedHost');
    if (parsedHostUri == null ||
        parsedHostUri.host.isEmpty ||
        parsedHostUri.userInfo.isNotEmpty ||
        parsedHostUri.hasQuery ||
        parsedHostUri.hasFragment) {
      throw const FormatException('服务器地址格式无效，请填写域名或 IP（如 emby.example.com）');
    }
    if (hasScheme &&
        !['http', 'https'].contains(parsedHostUri.scheme.toLowerCase())) {
      throw const FormatException('仅支持 HTTP 或 HTTPS 协议的 Emby 服务器');
    }

    int? resolvedPort;
    final trimmedPort = portText.trim();
    if (trimmedPort.isNotEmpty) {
      resolvedPort = int.tryParse(trimmedPort);
      if (resolvedPort == null || resolvedPort < 1 || resolvedPort > 65535) {
        throw const FormatException('端口号需为 1–65535 之间的数字');
      }
    } else if (parsedHostUri.hasPort) {
      resolvedPort = parsedHostUri.port;
    }

    final mergedPath =
        path.trim().isNotEmpty ? _cleanPath(path) : _cleanPath(parsedHostUri.path);
    final finalScheme = useHttps ? 'https' : 'http';
    final omitPort =
        resolvedPort == null ||
        (useHttps && resolvedPort == 443) ||
        (!useHttps && resolvedPort == 80);

    return Uri(
      scheme: finalScheme,
      host: parsedHostUri.host,
      port: omitPort ? null : resolvedPort,
      path: mergedPath,
    ).toString();
  }

  static Uri _normalizeRoot(String address) {
    var cleaned = address.trim();
    final hashIdx = cleaned.indexOf('#');
    if (hashIdx >= 0 && cleaned.toLowerCase().contains('/web/')) {
      cleaned = cleaned.substring(0, hashIdx);
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
    final cleanPath = _cleanPath(u.path);
    return u.replace(
      scheme: u.scheme.toLowerCase(),
      path: cleanPath,
      query: null,
      fragment: null,
    );
  }

  static Uri _validatedSavedBase(String address) {
    final u = _normalizeRoot(address);
    return u;
  }

  static List<Uri> _loginBaseCandidates(Uri root) {
    final lower = root.path.toLowerCase();
    if (lower.endsWith('/emby')) {
      final stripped = root.path.substring(0, root.path.length - 5);
      return <Uri>[root, root.replace(path: stripped)];
    }
    return <Uri>[
      root.replace(path: '${root.path}/emby'),
      root,
    ];
  }

  static bool _shouldRetryAlternateBase(Object error) {
    if (error is HttpException) {
      return error.message.contains('HTTP 404') ||
          error.message.contains('HTTP 405');
    }
    return error is FormatException;
  }

  static Future<SubscriptionEntry> login(
    String address,
    String username,
    String password, {
    required String group,
    required bool isPrivate,
    String label = '',
    bool allowCloudSync = true,
    bool allowInvalidCert = false,
  }) async {
    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty) {
      throw const FormatException('请输入 Emby 用户名');
    }
    final root = _normalizeRoot(address);
    final candidates = _loginBaseCandidates(root);
    final prefs = await SharedPreferences.getInstance();
    final device = prefs.getString('emby.device') ?? _nonce();
    if (!await prefs.setString('emby.device', device)) {
      throw StateError('无法保存设备标识');
    }

    Uri effectiveBase = candidates.first;
    Map<String, dynamic>? authJson;
    Object? lastError;
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final loginClient = EmbyLibrary._(
        candidate,
        '',
        '',
        device,
        allowInvalidCert: allowInvalidCert,
      );
      try {
        authJson = await loginClient._api(
          '/Users/AuthenticateByName',
          body: {'Username': trimmedUser, 'Pw': password},
        );
        effectiveBase = candidate;
        lastError = null;
        break;
      } on StateError {
        rethrow;
      } catch (e) {
        lastError = e;
        if (i + 1 < candidates.length && _shouldRetryAlternateBase(e)) {
          continue;
        }
        rethrow;
      }
    }
    if (authJson == null) {
      if (lastError != null) throw lastError;
      throw StateError('Emby 登录失败');
    }

    final user = authJson['User']?['Id'];
    final token = authJson['AccessToken'];
    if (user is! String || user.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('Emby 没有返回有效账户');
    }
    // Verify the authenticated user can actually read media library views before
    // persisting the library entry (catches 403/disabled/unauthorized accounts).
    final authed = EmbyLibrary._(
      effectiveBase,
      user,
      token,
      device,
      allowInvalidCert: allowInvalidCert,
    );
    final views = await authed._api('/Users/$user/Views');
    if (views['Items'] is! List) {
      throw StateError('Emby 未返回有效媒体库目录，请检查当前账号的媒体库访问权限');
    }
    final key = sha256.convert(utf8.encode('$effectiveBase\n$user')).toString();
    final trimmedLabel = label.trim();
    final displayName =
        trimmedLabel.isNotEmpty ? trimmedLabel : 'Emby · $trimmedUser';
    final api = '$prefix$key';
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (!await prefs.setString(
      'emby.account.$key',
      jsonEncode({
        'base': effectiveBase.toString(),
        'rawRoot': root.toString(),
        'user': user,
        'username': trimmedUser,
        'token': token,
        'device': device,
        'name': displayName,
        'allowCloudSync': allowCloudSync,
        'allowInvalidCert': allowInvalidCert,
        'updatedAt': updatedAt,
      }),
    )) {
      throw StateError('无法保存 Emby 登录状态');
    }
    return SubscriptionEntry(
      id: 'emby_$key',
      name: displayName,
      group: group,
      isPrivate: isPrivate,
      format: 'Emby',
      siteCount: 1,
      updatedAt: updatedAt,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'emby_$key', 'name': displayName, 'type': 1, 'api': api},
        ],
      }),
    );
  }

  /// Loads stored UI-editable metadata for an existing Emby subscription.
  static Future<EmbySavedAccountMeta?> loadSavedAccountMeta(
    String subscriptionId,
  ) async {
    final key = subscriptionId.startsWith('emby_')
        ? subscriptionId.substring(5)
        : (subscriptionId.startsWith(prefix)
            ? subscriptionId.substring(prefix.length)
            : subscriptionId);
    if (key.isEmpty) return null;
    final raw =
        (await SharedPreferences.getInstance()).getString('emby.account.$key');
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final rawRoot = (decoded['rawRoot'] ?? '').toString().trim();
      final baseStr = (decoded['base'] ?? '').toString().trim();
      final displayRoot = rawRoot.isNotEmpty
          ? rawRoot
          : (baseStr.toLowerCase().endsWith('/emby')
              ? baseStr.substring(0, baseStr.length - 5)
              : baseStr);
      final spec = parseAddressToSpec(
        displayRoot,
        defaultHttps: displayRoot.toLowerCase().startsWith('https://'),
      );
      return EmbySavedAccountMeta(
        key: key,
        label: (decoded['name'] ?? '').toString(),
        allowCloudSync: decoded['allowCloudSync'] != false,
        useHttps: spec.useHttps,
        host: spec.host,
        path: spec.path,
        port: spec.port,
        username: (decoded['username'] ?? '').toString(),
        allowInvalidCert: decoded['allowInvalidCert'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Refreshes metadata and re-verifies the existing session token when editing
  /// without re-entering the password (only when endpoint & username are unchanged).
  static Future<SubscriptionEntry?> updateExistingMetaIfValid({
    required SubscriptionEntry existing,
    required String address,
    required String username,
    required String label,
    required bool allowCloudSync,
    required bool allowInvalidCert,
    required String group,
    required bool isPrivate,
  }) async {
    final key = existing.id.startsWith('emby_') ? existing.id.substring(5) : '';
    if (key.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('emby.account.$key');
    if (raw == null || raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final storedRoot = (decoded['rawRoot'] ?? decoded['base'] ?? '').toString();
    final nextRoot = _normalizeRoot(address);
    final storedNormRoot =
        storedRoot.isEmpty ? null : _normalizeRoot(storedRoot);
    final baseNoEmby = storedNormRoot != null &&
            storedNormRoot.path.toLowerCase().endsWith('/emby')
        ? storedNormRoot.replace(
            path: storedNormRoot.path.substring(
              0,
              storedNormRoot.path.length - 5,
            ),
          )
        : storedNormRoot;
    final sameEndpoint =
        storedNormRoot == nextRoot ||
        (baseNoEmby != null && baseNoEmby == nextRoot);
    final storedUserName = (decoded['username'] ?? '').toString().trim();
    if (!sameEndpoint ||
        (storedUserName.isNotEmpty && storedUserName != username.trim())) {
      return null;
    }

    final effectiveBase = _validatedSavedBase(decoded['base'].toString());
    final user = decoded['user'].toString();
    final token = decoded['token'].toString();
    final device = decoded['device'].toString();
    final authed = EmbyLibrary._(
      effectiveBase,
      user,
      token,
      device,
      allowInvalidCert: allowInvalidCert,
    );
    final views = await authed._api('/Users/$user/Views');
    if (views['Items'] is! List) {
      throw StateError('Emby 未返回有效媒体库目录，请检查当前账号的媒体库访问权限');
    }

    final trimmedLabel = label.trim();
    final trimmedUser = username.trim();
    final displayName = trimmedLabel.isNotEmpty
        ? trimmedLabel
        : (trimmedUser.isNotEmpty ? 'Emby · $trimmedUser' : existing.name);
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    final nextMap = Map<String, dynamic>.from(decoded);
    nextMap['rawRoot'] = nextRoot.toString();
    nextMap['username'] = trimmedUser.isNotEmpty ? trimmedUser : storedUserName;
    nextMap['name'] = displayName;
    nextMap['allowCloudSync'] = allowCloudSync;
    nextMap['allowInvalidCert'] = allowInvalidCert;
    nextMap['updatedAt'] = updatedAt;
    if (!await prefs.setString('emby.account.$key', jsonEncode(nextMap))) {
      throw StateError('无法保存 Emby 登录状态');
    }
    final api = '$prefix$key';
    return existing.copyWith(
      name: displayName,
      group: group,
      isPrivate: isPrivate,
      format: 'Emby',
      siteCount: 1,
      updatedAt: updatedAt,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'emby_$key', 'name': displayName, 'type': 1, 'api': api},
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
      _validatedSavedBase(s['base'].toString()),
      s['user'].toString(),
      s['token'].toString(),
      s['device'].toString(),
      allowInvalidCert: s['allowInvalidCert'] == true,
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

  static bool _isSameHost(Uri a, Uri b) =>
      ['http', 'https'].contains(a.scheme.toLowerCase()) &&
      ['http', 'https'].contains(b.scheme.toLowerCase()) &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      _effectivePort(a) == _effectivePort(b);

  Future<Map<String, dynamic>> _api(
    String path, {
    Map<String, String>? params,
    Map? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = _userAgent;
    if (allowInvalidCert) {
      client.badCertificateCallback = (cert, host, port) =>
          host.toLowerCase() == base.host.toLowerCase() &&
          port == _effectivePort(base);
    }
    final deadline = Timer(
      const Duration(seconds: 15),
      () => client.close(force: true),
    );
    try {
      var currentUrl = _url(path, params);
      var method = body == null ? 'GET' : 'POST';
      Map? currentBody = body;
      HttpClientResponse? response;
      for (var hop = 0; hop < 6; hop++) {
        final r = await client.openUrl(method, currentUrl);
        r.followRedirects = false;
        final authHeader =
            'MediaBrowser Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="0.7.12"${token.isNotEmpty ? ', Token="$token"' : ''}';
        r.headers.set('X-Emby-Authorization', authHeader);
        r.headers.set(
          'Authorization',
          'Emby Client="Marco Movie", Device="${Platform.operatingSystem}", DeviceId="$device", Version="0.7.12"',
        );
        r.headers.set('Accept', 'application/json');
        if (token.isNotEmpty) r.headers.set('X-Emby-Token', token);
        if (currentBody != null) {
          r.headers.contentType = ContentType.json;
          r.write(jsonEncode(currentBody));
        }
        final candidateResp = await r.close();
        final status = candidateResp.statusCode;
        if (status == 301 ||
            status == 302 ||
            status == 303 ||
            status == 307 ||
            status == 308) {
          await candidateResp.drain<void>();
          final loc = candidateResp.headers.value(HttpHeaders.locationHeader);
          if (loc == null || loc.trim().isEmpty) {
            throw HttpException('Emby 重定向地址缺失（HTTP $status）');
          }
          final nextUrl = currentUrl.resolve(loc.trim());
          if (!_isSameHost(currentUrl, nextUrl)) {
            throw const FormatException('Emby 拒绝跨主机重定向以保护账号凭据');
          }
          if (status == 303) {
            method = 'GET';
            currentBody = null;
          }
          currentUrl = nextUrl;
          continue;
        }
        response = candidateResp;
        break;
      }
      if (response == null) {
        throw const FormatException('Emby 重定向次数过多');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        await response.drain<void>();
        throw StateError('Emby 拒绝访问，请检查账号或重新登录');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException('Emby HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const FormatException('Emby 响应过大');
        }
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const FormatException('Emby 未返回有效 JSON 响应');
      }
      return Map<String, dynamic>.from(decoded);
    } on HandshakeException {
      throw StateError(
        'TLS 握手失败：该服务器端口可能使用的是 HTTP 协议而非 HTTPS，请关闭「HTTPS」开关并确认端口号（如 8096）后重试；若为自签名 HTTPS 证书可开启「忽略证书校验」',
      );
    } on TlsException {
      throw StateError(
        'HTTPS 安全连接失败：请确认服务器端口是否启用 HTTPS，或开启「忽略证书校验」后重试',
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
                    'mm-emby=${sha256.convert(utf8.encode('$base\n$user'))}',
              )
              .toString(),
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
        (j['TotalRecordCount'] as num?)?.toInt() ??
        (page - 1) * limit + cards.length;
    return CmsListing(
      page: page,
      pageCount: max(page, (total / limit).ceil()),
      videos: cards,
    );
  }

  Future<CmsVideo> detail(String id) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Emby 媒体编号无效');
    }
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
        if (rows.isEmpty || start >= (j['TotalRecordCount'] as int? ?? start)) {
          break;
        }
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
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Emby 剧集编号无效');
    }
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
        'MaxStreamingBitrate': 120000000,
        'DeviceProfile': {
          'Name': 'Marco Movie',
          'MaxStreamingBitrate': 120000000,
          'DirectPlayProfiles': [
            {
              'Type': 'Video',
              'Container': 'mp4,m4v,mkv,mov,ts,m2ts,webm,avi,flv',
              'VideoCodec': 'h264,hevc,h265,vp9,av1,mpeg4,mpeg2video,vc1',
              'AudioCodec': 'aac,mp3,ac3,eac3,dts,truehd,flac,alac,opus,pcm,vorbis',
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
    if (matching.isEmpty && wanted == id && sources.isNotEmpty) {
      matching.add(sources.first);
    }
    if (matching.isEmpty) throw StateError('Emby 未返回所选媒体版本');
    final source = matching.first;
    final sourceId = source['Id']?.toString() ?? '';
    if (sourceId.isEmpty) throw const FormatException('Emby 媒体版本缺失');
    if (source['RequiresOpening'] == true) {
      throw StateError('当前 Emby 资源需要实时流打开协议');
    }
    final session = info['PlaySessionId']?.toString() ?? '';
    if (session.isEmpty) throw const FormatException('Emby 播放会话缺失');
    final direct =
        source['SupportsDirectStream'] == true ||
        source['SupportsDirectPlay'] == true;
    final sourceProtocol =
        (source['Protocol']?.toString() ?? '').trim().toLowerCase();
    final rawSourcePath = (source['Path']?.toString() ?? '').trim();
    if (direct && sourceProtocol == 'http' && rawSourcePath.isNotEmpty) {
      final externalUri = Uri.tryParse(rawSourcePath);
      if (externalUri != null &&
          ['http', 'https'].contains(externalUri.scheme.toLowerCase()) &&
          externalUri.host.isNotEmpty &&
          externalUri.origin != base.origin) {
        return CmsEpisode(
          name: episode.name,
          url: externalUri.toString(),
          headers: const <String, String>{},
          playbackSession: {
            'ItemId': id,
            'MediaSourceId': sourceId,
            'PlaySessionId': session,
            'PlayMethod': 'DirectPlay',
            'CanSeek': true,
          },
          sourceSeasonNumber: episode.sourceSeasonNumber,
          sourceEpisodeNumber: episode.sourceEpisodeNumber,
          sourceItemId:
              episode.sourceItemId.isNotEmpty ? episode.sourceItemId : id,
          originalFileName: episode.originalFileName,
          directoryPath: episode.directoryPath,
          containerTags: episode.containerTags,
        );
      }
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
      final raw = source['TranscodingUrl'].toString().trim();
      if (raw.startsWith('http://') || raw.startsWith('https://')) {
        stream = Uri.parse(raw);
      } else if (base.path.isNotEmpty &&
          raw.startsWith('/') &&
          !raw.startsWith('${base.path}/')) {
        stream = Uri.parse('${base.toString()}/').resolve(raw.substring(1));
      } else if (raw.startsWith('/')) {
        stream = base.resolve(raw);
      } else {
        stream = Uri.parse('${base.toString()}/').resolve(raw);
      }
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
    if (!force && !changed && now - _lastSentMs < 10000) {
      return _work ?? Future.value();
    }
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

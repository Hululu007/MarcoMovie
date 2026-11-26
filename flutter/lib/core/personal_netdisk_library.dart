import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_media_proxy.dart';
import 'media_library_connectors.dart';
import 'models.dart';
import 'quark_account.dart';
import 'quark_drive.dart';
import 'resilient_http_client.dart';
import 'storage_service.dart';

enum PersonalCloudProvider {
  quark(
    key: 'quark',
    displayName: '夸克网盘',
    shortName: '夸克',
    rootFolderId: '0',
    rootLabel: '夸克网盘根目录',
  ),
  uc(
    key: 'uc',
    displayName: 'UC 网盘',
    shortName: 'UC',
    rootFolderId: '0',
    rootLabel: 'UC 网盘根目录',
  ),
  baidu(
    key: 'baidu',
    displayName: '百度网盘',
    shortName: '百度',
    rootFolderId: '/',
    rootLabel: '百度网盘根目录',
  ),
  ali(
    key: 'ali',
    displayName: '阿里云盘',
    shortName: '阿里',
    rootFolderId: 'root',
    rootLabel: '阿里云盘根目录',
  );

  final String key;
  final String displayName;
  final String shortName;
  final String rootFolderId;
  final String rootLabel;

  const PersonalCloudProvider({
    required this.key,
    required this.displayName,
    required this.shortName,
    required this.rootFolderId,
    required this.rootLabel,
  });

  static PersonalCloudProvider? fromKey(String raw) {
    final k = raw.trim().toLowerCase();
    for (final p in values) {
      if (p.key == k) return p;
    }
    return null;
  }
}

class PersonalCloudException implements Exception {
  final String code;
  final String message;
  final bool requiresReauth;

  const PersonalCloudException(
    this.code,
    this.message, {
    this.requiresReauth = false,
  });

  @override
  String toString() => message;
}

class PersonalCloudItem {
  final PersonalCloudProvider provider;
  final String id;
  final String name;
  final bool isDir;
  final int size;
  final String thumbnail;
  final String driveId;
  final String path;
  final String rawRef;

  const PersonalCloudItem({
    required this.provider,
    required this.id,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.thumbnail = '',
    this.driveId = '',
    this.path = '',
    this.rawRef = '',
  });
}

class PersonalCloudPage {
  final PersonalCloudProvider provider;
  final String folderId;
  final List<PersonalCloudItem> items;
  final int page;
  final int pageCount;
  final bool hasMore;
  final String nextMarker;
  final String driveId;
  final String accountId;
  final String cookieAccountId;
  final String legacyAccountId;

  const PersonalCloudPage({
    required this.provider,
    required this.folderId,
    required this.items,
    required this.page,
    required this.pageCount,
    required this.hasMore,
    this.nextMarker = '',
    this.driveId = '',
    this.accountId = '',
    this.cookieAccountId = '',
    this.legacyAccountId = '',
  });
}

/// Unified personal file API client for all 4 cloud drives (Quark, UC, Baidu,
/// Ali). Reads user-owned directories, supports multi-level browsing,
/// pagination, auth-expiry detection, and playback resolution without touching
/// share-link playback flows.
class PersonalCloudDriveClient {
  PersonalCloudDriveClient({
    required Future<String> Function(String provider) credentialReader,
    Future<void> Function(String provider, String value)? credentialWriter,
    QuarkAccountProvider? quarkAccounts,
    QuarkDriveClient? quarkClient,
    http.Client? httpClient,
    http.Client Function()? mediaClientFactory,
    bool Function()? isCancelled,
  })  : _readCredential = credentialReader,
        _writeCredential = credentialWriter,
        _quarkAccounts = quarkAccounts,
        _externalQuarkClient = quarkClient,
        _http = httpClient ?? ResilientHttpClient(),
        _ownsHttp = httpClient == null,
        _mediaClientFactory =
            mediaClientFactory ?? CloudMediaLease.createDefaultMediaClient,
        _isCancelled = isCancelled ?? (() => false);

  factory PersonalCloudDriveClient.fromStorage(
    StorageService storage, {
    http.Client? httpClient,
    http.Client Function()? mediaClientFactory,
    bool Function()? isCancelled,
  }) {
    return PersonalCloudDriveClient(
      credentialReader: (provider) async => storage.getNetdiskCred(provider),
      credentialWriter: (provider, value) =>
          storage.setNetdiskCredential(provider, value),
      quarkAccounts: storage.quarkAccounts,
      httpClient: httpClient,
      mediaClientFactory: mediaClientFactory,
      isCancelled: isCancelled,
    );
  }

  final Future<String> Function(String provider) _readCredential;
  final Future<void> Function(String provider, String value)? _writeCredential;
  final QuarkAccountProvider? _quarkAccounts;
  final QuarkDriveClient? _externalQuarkClient;
  final http.Client _http;
  final bool _ownsHttp;
  final http.Client Function() _mediaClientFactory;
  final bool Function() _isCancelled;

  static const _timeout = Duration(seconds: 20);
  static const _maxBytes = 4 * 1024 * 1024;
  static const _ucApiHost = 'pc-api.uc.cn';
  static const _ucUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Safari/537.36';
  static const _baiduWebUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _baiduMediaUa = 'netdisk;P2SP;2.2.91.136;android-android';
  static const _aliApi = 'https://api.aliyundrive.com';
  static const _aliMediaHeaders = <String, String>{
    'Referer': 'https://www.aliyundrive.com/',
    'User-Agent': 'Mozilla/5.0',
  };

  _AliPersonalSession? _aliSession;
  String _aliSessionCredential = '';
  final Map<String, String> _verifiedOwnerByCookieId = <String, String>{};

  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<PersonalCloudPage> listFolder(
    PersonalCloudProvider provider, {
    String folderId = '',
    int page = 1,
    String marker = '',
    String driveId = '',
  }) async {
    final effectiveFolder =
        folderId.trim().isEmpty ? provider.rootFolderId : folderId.trim();
    return switch (provider) {
      PersonalCloudProvider.quark =>
        _listQuark(folderId: effectiveFolder, page: page),
      PersonalCloudProvider.uc =>
        _listUc(folderId: effectiveFolder, page: page),
      PersonalCloudProvider.baidu =>
        _listBaidu(folderPath: effectiveFolder, page: page),
      PersonalCloudProvider.ali => _listAli(
          folderId: effectiveFolder,
          page: page,
          marker: marker,
          driveId: driveId,
        ),
    };
  }

  Future<CmsEpisode> resolveFile({
    required PersonalCloudProvider provider,
    required String fileId,
    required String name,
    String driveId = '',
    String path = '',
    String rawRef = '',
    String expectedAccountId = '',
    String expectedCookieAccountId = '',
  }) async {
    return switch (provider) {
      PersonalCloudProvider.quark => _resolveQuark(
          fileId: fileId,
          name: name,
          rawRef: rawRef,
          expectedAccountId: expectedAccountId,
        ),
      PersonalCloudProvider.uc => _resolveUc(
          fileId: fileId,
          name: name,
          expectedAccountId: expectedAccountId,
          expectedCookieAccountId: expectedCookieAccountId,
        ),
      PersonalCloudProvider.baidu => _resolveBaidu(
          fsId: fileId,
          path: path,
          name: name,
          expectedAccountId: expectedAccountId,
          expectedCookieAccountId: expectedCookieAccountId,
        ),
      PersonalCloudProvider.ali => _resolveAli(
          fileId: fileId,
          driveId: driveId,
          name: name,
          expectedAccountId: expectedAccountId,
        ),
    };
  }

  static bool _isProviderOwnerId(String id) =>
      id.startsWith('uc:uid:') || id.startsWith('baidu:uk:');

  static bool _isCookieAccountId(String id) =>
      id.startsWith('uc:v2:') || id.startsWith('baidu:v2:');

  static void assertAccountMatches({
    required PersonalCloudProvider provider,
    required String expectedAccountId,
    required String observedAccountId,
    String expectedCookieAccountId = '',
    String observedCookieAccountId = '',
    String legacyObservedAccountId = '',
  }) {
    final expected = expectedAccountId.trim();
    final observed = observedAccountId.trim();
    final expectedCookie = expectedCookieAccountId.trim();
    final observedCookie = observedCookieAccountId.trim();
    final legacyObserved = legacyObservedAccountId.trim();
    if (expected.isEmpty || (observed.isEmpty && observedCookie.isEmpty)) return;

    // 1. Direct canonical identity match.
    if (observed.isNotEmpty && expected == observed) return;

    // 2. Legacy 16-hex raw-credential hash match (triggers in-place migration).
    if (legacyObserved.isNotEmpty && expected == legacyObserved) return;

    // 3. Verified owner <-> canonical cookie identity binding:
    //    - When an endpoint (e.g. resolve/filemetas/download) omits server
    //      uid/uk so `observed` is a cookie identity, accept iff the canonical
    //      auth cookie matches the library's bound `expectedCookieAccountId`.
    //    - When a library was created without server uid/uk (`expected` is a
    //      cookie identity) and a later call additionally observes server
    //      uid/uk on the SAME verified cookie, accept (`observedCookie == expected`).
    //    - Conflicting server owner IDs (e.g. `uc:uid:u1` vs `uc:uid:u2`) or
    //      different auth cookies (`__pus` / `BDUSS`) ALWAYS throw mismatch.
    if (observedCookie.isNotEmpty) {
      final observedHasDistinctServerOwner =
          _isProviderOwnerId(observed) && _isProviderOwnerId(expected);
      if (!observedHasDistinctServerOwner) {
        if (expectedCookie.isNotEmpty &&
            expectedCookie == observedCookie &&
            !_isProviderOwnerId(observed)) {
          return;
        }
        if (_isCookieAccountId(expected) && expected == observedCookie) {
          return;
        }
      }
    }

    throw PersonalCloudException(
      'account_mismatch',
      '当前登录的${provider.displayName}账号与该资源库绑定账号不一致，请切回原账号或重新绑定新资源库',
      requiresReauth: true,
    );
  }

  // ── 1. Quark Personal Drive (reusing QuarkDriveClient) ────────────────────

  Future<QuarkDriveClient> _openQuarkClient() async {
    if (_externalQuarkClient != null) return _externalQuarkClient;
    final accounts =
        _quarkAccounts ?? (await StorageService.init()).quarkAccounts;
    return QuarkDriveClient(
      accounts: accounts,
      httpClient: _http,
      mediaClientFactory: _mediaClientFactory,
      isCancelled: _isCancelled,
    );
  }

  Future<PersonalCloudPage> _listQuark({
    required String folderId,
    required int page,
  }) async {
    final cred = (await _readCredential('quark')).trim();
    if (cred.isEmpty) {
      throw const PersonalCloudException(
        'auth_required',
        '请先授权登录夸克网盘账号',
        requiresReauth: true,
      );
    }
    final client = await _openQuarkClient();
    final owns = !identical(client, _externalQuarkClient);
    try {
      final listing = await client.listOwned(folder: folderId, page: page);
      final items = <PersonalCloudItem>[];
      var accountId = '';
      for (final v in listing.videos) {
        final uri = Uri.tryParse(v.id);
        final fid = uri?.queryParameters['fid'] ?? v.id;
        final acc = uri?.queryParameters['account'] ?? '';
        if (accountId.isEmpty && acc.isNotEmpty) accountId = acc;
        final isDir = v.tag == 'quark-folder';
        items.add(
          PersonalCloudItem(
            provider: PersonalCloudProvider.quark,
            id: fid,
            name: v.title,
            isDir: isDir,
            thumbnail: v.poster,
            rawRef: v.id,
          ),
        );
      }
      return PersonalCloudPage(
        provider: PersonalCloudProvider.quark,
        folderId: folderId,
        items: items,
        page: listing.page,
        pageCount: listing.pageCount,
        hasMore: listing.page < listing.pageCount,
        accountId: accountId.isNotEmpty ? accountId : _credAccountHash('quark', cred),
      );
    } on QuarkAccountException catch (e) {
      throw PersonalCloudException(
        'auth_expired',
        e.message,
        requiresReauth: true,
      );
    } on QuarkDriveException catch (e) {
      final expired = e.code == 'unauthenticated' ||
          e.code == 'auth_expired' ||
          e.code == 'session_changed' ||
          e.message.contains('登录') ||
          e.message.contains('失效');
      throw PersonalCloudException(
        expired ? 'auth_expired' : e.code,
        e.message,
        requiresReauth: expired,
      );
    } finally {
      if (owns) client.close();
    }
  }

  Future<CmsEpisode> _resolveQuark({
    required String fileId,
    required String name,
    required String rawRef,
    String expectedAccountId = '',
  }) async {
    final client = await _openQuarkClient();
    final owns = !identical(client, _externalQuarkClient);
    try {
      final accounts =
          _quarkAccounts ?? (await StorageService.init()).quarkAccounts;
      final session = await accounts.requireSession();
      assertAccountMatches(
        provider: PersonalCloudProvider.quark,
        expectedAccountId: expectedAccountId,
        observedAccountId: session.accountId,
      );
      var targetUrl = rawRef;
      if (!targetUrl.startsWith('mmquark://owned?')) {
        targetUrl = Uri(
          scheme: 'mmquark',
          host: 'owned',
          queryParameters: {'account': session.accountId, 'fid': fileId},
        ).toString();
      } else if (expectedAccountId.trim().isNotEmpty) {
        final refAcc = Uri.tryParse(targetUrl)?.queryParameters['account'] ?? '';
        assertAccountMatches(
          provider: PersonalCloudProvider.quark,
          expectedAccountId: expectedAccountId,
          observedAccountId: refAcc,
        );
      }
      return await client.resolve(CmsEpisode(name: name, url: targetUrl));
    } on QuarkAccountException catch (e) {
      throw PersonalCloudException(
        'auth_expired',
        e.message,
        requiresReauth: true,
      );
    } on QuarkDriveException catch (e) {
      final expired = e.code == 'unauthenticated' ||
          e.code == 'auth_expired' ||
          e.message.contains('登录') ||
          e.message.contains('失效');
      throw PersonalCloudException(
        expired ? 'auth_expired' : e.code,
        e.message,
        requiresReauth: expired,
      );
    } finally {
      if (owns) client.close();
    }
  }

  // ── 2. UC Personal Drive ──────────────────────────────────────────────────

  Map<String, String> _parseCookieMap(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, String>{};
    var cookieText = trimmed;
    if (trimmed.startsWith('{')) {
      try {
        final map = jsonDecode(trimmed);
        if (map is Map) {
          if (map['cookie'] is String) {
            cookieText = map['cookie'] as String;
          } else if (map['cookies'] is Map) {
            final out = <String, String>{};
            (map['cookies'] as Map).forEach((k, v) {
              if (k != null && v != null && '$v'.trim().isNotEmpty) {
                out['$k'.trim()] = '$v'.trim();
              }
            });
            return out;
          } else if (map['cookies'] is List) {
            final out = <String, String>{};
            for (final item in map['cookies'] as List) {
              if (item is Map) {
                final k = '${item['name'] ?? ''}'.trim();
                final v = '${item['value'] ?? ''}'.trim();
                if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
              }
            }
            return out;
          }
        }
      } catch (_) {}
    }
    final out = <String, String>{};
    for (final part in cookieText.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).trim();
      final val = part.substring(idx + 1).trim();
      if (key.isEmpty || val.isEmpty) continue;
      const attrs = {
        'path',
        'domain',
        'expires',
        'max-age',
        'samesite',
        'secure',
        'httponly',
      };
      if (attrs.contains(key.toLowerCase())) continue;
      out[key] = val;
    }
    return out;
  }

  String _formatCookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _absorbSetCookie(http.BaseResponse response, Map<String, String> jar) {
    final rawHeader = response.headers['set-cookie'];
    if (rawHeader == null || rawHeader.isEmpty) return;
    final matches = RegExp(r'(?:^|,)\s*([A-Za-z0-9_.-]+)=([^;,\r\n]+)')
        .allMatches(rawHeader);
    const attrs = {
      'path',
      'domain',
      'expires',
      'max-age',
      'samesite',
      'secure',
      'httponly',
    };
    for (final m in matches) {
      final k = m.group(1)?.trim() ?? '';
      final v = m.group(2)?.trim() ?? '';
      if (k.isEmpty || attrs.contains(k.toLowerCase())) continue;
      jar[k] = v;
    }
  }

  Future<(Map<String, String>, Map<String, String>, String, Map<String, dynamic>)>
      _prepareUcSession() async {
    final cred = (await _readCredential('uc')).trim();
    final rawCookies = _parseCookieMap(cred);
    final cookies = Map<String, String>.from(rawCookies);
    if (cookies.isEmpty) {
      throw const PersonalCloudException(
        'auth_required',
        '请先授权登录 UC 网盘账号',
        requiresReauth: true,
      );
    }
    if (cookies.containsKey('__pus')) cookies.remove('__puus');
    final cfg = await _ucRequest(
      '/1/clouddrive/config',
      cookies: cookies,
      query: const {'pr': 'UCBrowser', 'fr': 'pc'},
    );
    _assertUcPayloadOk(cfg);
    return (cookies, rawCookies, cred, cfg);
  }

  void _assertUcPayloadOk(Map<String, dynamic> payload) {
    final status = _intVal(payload['status']);
    final code = _intVal(payload['code']);
    final msg = '${payload['message'] ?? ''}'.trim();
    if (status == 401 ||
        status == 403 ||
        code == 31001 ||
        code == 40100 ||
        code == 41001 ||
        msg.contains('未登录') ||
        msg.contains('登录失效') ||
        msg.contains('token')) {
      throw const PersonalCloudException(
        'auth_expired',
        'UC 网盘登录已失效，请重新授权',
        requiresReauth: true,
      );
    }
    if ((payload.containsKey('code') && code != 0) ||
        (payload.containsKey('status') && status != 0 && status != 200)) {
      throw PersonalCloudException(
        'uc_error',
        msg.isEmpty ? 'UC 网盘请求失败（code=$code）' : 'UC 网盘请求失败：$msg',
      );
    }
  }

  Future<Map<String, dynamic>> _ucRequest(
    String path, {
    required Map<String, String> cookies,
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    _checkActive();
    final uri = Uri.https(_ucApiHost, path, query);
    final req = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Cookie': _formatCookieHeader(cookies),
        'User-Agent': _ucUa,
        'Referer': 'https://drive.uc.cn/',
        'Origin': 'https://drive.uc.cn',
        'Accept': 'application/json, text/plain, */*',
        if (body != null) 'Content-Type': 'application/json',
      });
    if (body != null) req.body = jsonEncode(body);
    try {
      final resp = await _http.send(req).timeout(_timeout);
      _absorbSetCookie(resp, cookies);
      final bytes = await _readBoundedBytes(resp.stream);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw const PersonalCloudException(
          'auth_expired',
          'UC 网盘登录已失效，请重新授权',
          requiresReauth: true,
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw PersonalCloudException(
          'http_${resp.statusCode}',
          'UC 网盘服务异常（HTTP ${resp.statusCode}）',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const PersonalCloudException('invalid_response', 'UC 网盘未返回有效目录数据');
      }
      return Map<String, dynamic>.from(decoded);
    } on PersonalCloudException {
      rethrow;
    } on TimeoutException {
      throw const PersonalCloudException('timeout', 'UC 网盘连接超时，请稍后重试');
    } catch (e) {
      throw PersonalCloudException('network', 'UC 网盘请求失败：$e');
    }
  }

  Future<PersonalCloudPage> _listUc({
    required String folderId,
    required int page,
  }) async {
    const pageSize = 50;
    final (cookies, rawCookies, cred, cfg) = await _prepareUcSession();
    final payload = await _ucRequest(
      '/1/clouddrive/file/sort',
      cookies: cookies,
      query: {
        'pr': 'UCBrowser',
        'fr': 'pc',
        'pdir_fid': folderId,
        '_page': '$page',
        '_size': '$pageSize',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,file_name:asc',
      },
    );
    _assertUcPayloadOk(payload);
    final data = payload['data'];
    final rows = data is Map ? data['list'] : null;
    if (rows is! List) {
      throw const PersonalCloudException('invalid_response', 'UC 网盘未返回有效目录');
    }
    final items = <PersonalCloudItem>[];
    for (final row in rows.whereType<Map>()) {
      final fid = '${row['fid'] ?? ''}'.trim();
      final name = '${row['file_name'] ?? ''}'.trim();
      if (fid.isEmpty || name.isEmpty) continue;
      final isDir = row['dir'] == true || _intVal(row['file_type']) == 0;
      if (!isDir &&
          _intVal(row['category']) != 1 &&
          !ExternalMediaLibrary.isVideoFileName(name)) {
        continue;
      }
      items.add(
        PersonalCloudItem(
          provider: PersonalCloudProvider.uc,
          id: fid,
          name: name,
          isDir: isDir,
          size: _intVal(row['size']),
          thumbnail: _httpUrl(row['thumbnail'] ?? row['thumbnail_url']),
        ),
      );
    }
    final metadata = payload['metadata'];
    final total = metadata is Map ? _intVal(metadata['_total']) : 0;
    final pageCount = total > 0
        ? ((total + pageSize - 1) ~/ pageSize).clamp(1, 10000)
        : (rows.length >= pageSize ? page + 1 : page);
    final cookieAccountId = _ucCookieAccountId(rawCookies);
    final resolvedAccountId = _ucAccountId(rawCookies, cfg: cfg, payload: payload);
    if (_isProviderOwnerId(resolvedAccountId)) {
      _verifiedOwnerByCookieId[cookieAccountId] = resolvedAccountId;
    }
    return PersonalCloudPage(
      provider: PersonalCloudProvider.uc,
      folderId: folderId,
      items: items,
      page: page,
      pageCount: pageCount,
      hasMore: page < pageCount,
      accountId: resolvedAccountId,
      cookieAccountId: cookieAccountId,
      legacyAccountId: _credAccountHash('uc', cred),
    );
  }

  Future<CmsEpisode> _resolveUc({
    required String fileId,
    required String name,
    String expectedAccountId = '',
    String expectedCookieAccountId = '',
  }) async {
    final (cookies, rawCookies, cred, cfg) = await _prepareUcSession();
    final cookieAccountId = _ucCookieAccountId(rawCookies);
    final directAccountId = _ucAccountId(rawCookies, cfg: cfg);
    if (_isProviderOwnerId(directAccountId)) {
      _verifiedOwnerByCookieId[cookieAccountId] = directAccountId;
    }
    final observedAccountId = _isProviderOwnerId(directAccountId)
        ? directAccountId
        : (_verifiedOwnerByCookieId[cookieAccountId] ?? cookieAccountId);
    final legacyAccountId = _credAccountHash('uc', cred);
    assertAccountMatches(
      provider: PersonalCloudProvider.uc,
      expectedAccountId: expectedAccountId,
      observedAccountId: observedAccountId,
      expectedCookieAccountId: expectedCookieAccountId,
      observedCookieAccountId: cookieAccountId,
      legacyObservedAccountId: legacyAccountId,
    );
    final variants = <CmsEpisode>[];
    try {
      final dl = await _ucRequest(
        '/1/clouddrive/file/download',
        cookies: cookies,
        query: const {'pr': 'UCBrowser', 'fr': 'pc'},
        body: {
          'fids': [fileId],
        },
      );
      _assertUcPayloadOk(dl);
      final list = dl['data'];
      if (list is List) {
        for (final row in list.whereType<Map>()) {
          if (row['fid'] != null && '${row['fid']}' != fileId) continue;
          final url = _httpsUrl(row['download_url']);
          if (url.isNotEmpty) {
            variants.add(CmsEpisode(name: '原画', url: url));
          }
        }
      }
    } on PersonalCloudException catch (e) {
      if (e.requiresReauth) rethrow;
    }

    try {
      final play = await _ucRequest(
        '/1/clouddrive/file/v2/play',
        cookies: cookies,
        query: const {'pr': 'UCBrowser', 'fr': 'pc'},
        body: {
          'fid': fileId,
          'resolutions': 'normal,low,high,super,2k,4k',
          'supports': 'fmp4,m3u8',
        },
      );
      _assertUcPayloadOk(play);
      final data = play['data'];
      final list = data is Map ? data['video_list'] : null;
      if (list is List) {
        const rankMap = {'4k': 6, '2k': 5, 'super': 4, 'high': 3, 'low': 2, 'normal': 1};
        final ranked = <({int rank, String label, String url})>[];
        for (final row in list.whereType<Map>()) {
          final info = row['video_info'];
          if (info is! Map || row['available'] == false || info['available'] == false) {
            continue;
          }
          final url = _httpsUrl(info['url']);
          if (url.isEmpty) continue;
          final res = '${row['resolution'] ?? ''}'.toLowerCase();
          final height = _intVal(info['height']);
          final label = const {
                '4k': '4K',
                '2k': '2K',
                'super': '超清',
                'high': '高清',
                'low': '标清',
                'normal': '流畅',
              }[res] ??
              (height > 0 ? '${height}P' : '转码');
          ranked.add((rank: rankMap[res] ?? (height ~/ 360), label: label, url: url));
        }
        ranked.sort((a, b) => b.rank.compareTo(a.rank));
        for (final r in ranked) {
          variants.add(CmsEpisode(name: r.label, url: r.url));
        }
      }
    } on PersonalCloudException catch (e) {
      if (e.requiresReauth) rethrow;
    }

    if (variants.isEmpty) {
      throw const PersonalCloudException('unavailable', 'UC 网盘未返回可用的播放地址');
    }

    final accountCookie = cookies.entries
        .where((e) => e.key == '__pus' || e.key == '__puus')
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
    CloudMediaLease? lease;
    final leasedVariants = <CmsEpisode>[];
    try {
      for (final v in variants) {
        final target = Uri.parse(v.url);
        var playUrl = v.url;
        if (CloudMediaLease.isTrustedUcMedia(target)) {
          lease ??= await CloudMediaLease.open(
            target: target,
            provider: CloudMediaProvider.uc,
            headers: {
              'Cookie': accountCookie.isNotEmpty
                  ? accountCookie
                  : _formatCookieHeader(cookies),
              'User-Agent': _ucUa,
              'Referer': 'https://drive.uc.cn/',
              'Origin': 'https://drive.uc.cn',
            },
            isCancelled: _isCancelled,
            isCurrent: () async {
              final cur = (await _readCredential('uc')).trim();
              if (cur.isEmpty) return false;
              if (cur == cred) return true;
              final curCookies = _parseCookieMap(cur);
              if (curCookies.isEmpty) return false;
              return _ucAccountId(curCookies) == _ucAccountId(rawCookies);
            },
            client: _mediaClientFactory(),
          );
          playUrl = lease.urlFor(target).toString();
        }
        leasedVariants.add(
          CmsEpisode(
            name: v.name,
            url: playUrl,
            headers: const {'User-Agent': _ucUa, 'Referer': 'https://drive.uc.cn/'},
            playbackSession: {if (lease != null) 'cloudMediaLease': lease},
          ),
        );
      }
      return CmsEpisode(
        name: name,
        url: leasedVariants.first.url,
        headers: leasedVariants.first.headers,
        playbackSession: {if (lease != null) 'cloudMediaLease': lease},
        variants: leasedVariants,
      );
    } catch (_) {
      await lease?.close();
      rethrow;
    }
  }

  // ── 3. Baidu Personal Drive ───────────────────────────────────────────────

  Future<(Map<String, String>, String)> _requireBaiduCookies() async {
    final cred = (await _readCredential('baidu')).trim();
    final cookies = _parseCookieMap(cred);
    if (cookies.isEmpty && cred.isNotEmpty && !cred.contains('=')) {
      cookies['BDUSS'] = cred;
    }
    if ((cookies['BDUSS'] ?? '').isEmpty) {
      throw const PersonalCloudException(
        'auth_required',
        '请先授权登录百度网盘账号',
        requiresReauth: true,
      );
    }
    return (cookies, cred);
  }

  Future<Map<String, dynamic>> _baiduGet(
    Uri uri, {
    required Map<String, String> cookies,
    String userAgent = _baiduWebUa,
  }) async {
    _checkActive();
    final req = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Cookie': _formatCookieHeader(cookies),
        'User-Agent': userAgent,
        'Referer': 'https://pan.baidu.com/',
        'Accept': 'application/json, text/plain, */*',
      });
    try {
      final resp = await _http.send(req).timeout(_timeout);
      _absorbSetCookie(resp, cookies);
      final bytes = await _readBoundedBytes(resp.stream);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw const PersonalCloudException(
          'auth_expired',
          '百度网盘登录已失效，请重新授权',
          requiresReauth: true,
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw PersonalCloudException(
          'http_${resp.statusCode}',
          '百度网盘服务异常（HTTP ${resp.statusCode}）',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const PersonalCloudException('invalid_response', '百度网盘未返回有效目录数据');
      }
      final map = Map<String, dynamic>.from(decoded);
      final errno = _intVal(map['errno']);
      if (errno == -6 || errno == 110 || errno == 111 || errno == -3) {
        throw const PersonalCloudException(
          'auth_expired',
          '百度网盘登录已失效，请重新授权',
          requiresReauth: true,
        );
      }
      if (map.containsKey('errno') && errno != 0) {
        throw PersonalCloudException(
          'baidu_$errno',
          '百度网盘请求失败（errno=$errno）',
        );
      }
      return map;
    } on PersonalCloudException {
      rethrow;
    } on TimeoutException {
      throw const PersonalCloudException('timeout', '百度网盘连接超时，请稍后重试');
    } catch (e) {
      throw PersonalCloudException('network', '百度网盘请求失败：$e');
    }
  }

  Future<PersonalCloudPage> _listBaidu({
    required String folderPath,
    required int page,
  }) async {
    const pageSize = 100;
    final (cookies, cred) = await _requireBaiduCookies();
    final dir = folderPath.startsWith('/') ? folderPath : '/$folderPath';
    final start = (page - 1) * pageSize;
    final payload = await _baiduGet(
      Uri.https('pan.baidu.com', '/api/list', {
        'dir': dir,
        'order': 'name',
        'desc': '0',
        'start': '$start',
        'limit': '$pageSize',
        'web': '1',
        'showempty': '0',
      }),
      cookies: cookies,
    );
    final rows = payload['list'];
    if (rows is! List) {
      throw const PersonalCloudException('invalid_response', '百度网盘未返回有效目录');
    }
    final items = <PersonalCloudItem>[];
    for (final row in rows.whereType<Map>()) {
      final path = '${row['path'] ?? ''}'.trim();
      final name = '${row['server_filename'] ?? ''}'.trim();
      final fsId = '${row['fs_id'] ?? ''}'.trim();
      if (name.isEmpty || (path.isEmpty && fsId.isEmpty)) continue;
      final isDir = _intVal(row['isdir']) == 1;
      if (!isDir &&
          _intVal(row['category']) != 1 &&
          !ExternalMediaLibrary.isVideoFileName(name)) {
        continue;
      }
      final thumbs = row['thumbs'];
      final thumb = thumbs is Map
          ? _httpUrl(thumbs['url3'] ?? thumbs['url2'] ?? thumbs['url1'])
          : '';
      items.add(
        PersonalCloudItem(
          provider: PersonalCloudProvider.baidu,
          id: isDir ? path : (fsId.isNotEmpty ? fsId : path),
          name: name,
          isDir: isDir,
          size: _intVal(row['size']),
          thumbnail: thumb,
          path: path,
        ),
      );
    }
    final hasMore = payload['has_more'] == 1 || rows.length >= pageSize;
    final cookieAccountId = _baiduCookieAccountId(cookies);
    final resolvedAccountId = _baiduAccountId(cookies, payload: payload);
    if (_isProviderOwnerId(resolvedAccountId)) {
      _verifiedOwnerByCookieId[cookieAccountId] = resolvedAccountId;
    }
    return PersonalCloudPage(
      provider: PersonalCloudProvider.baidu,
      folderId: dir,
      items: items,
      page: page,
      pageCount: hasMore ? page + 1 : page,
      hasMore: hasMore,
      accountId: resolvedAccountId,
      cookieAccountId: cookieAccountId,
      legacyAccountId: _credAccountHash('baidu', cred),
    );
  }

  Future<CmsEpisode> _resolveBaidu({
    required String fsId,
    required String path,
    required String name,
    String expectedAccountId = '',
    String expectedCookieAccountId = '',
  }) async {
    final (cookies, cred) = await _requireBaiduCookies();
    final cookieAccountId = _baiduCookieAccountId(cookies);
    final observedAccountId =
        _verifiedOwnerByCookieId[cookieAccountId] ?? cookieAccountId;
    final legacyAccountId = _credAccountHash('baidu', cred);
    assertAccountMatches(
      provider: PersonalCloudProvider.baidu,
      expectedAccountId: expectedAccountId,
      observedAccountId: observedAccountId,
      expectedCookieAccountId: expectedCookieAccountId,
      observedCookieAccountId: cookieAccountId,
      legacyObservedAccountId: legacyAccountId,
    );
    final variants = <CmsEpisode>[];

    if (fsId.isNotEmpty && RegExp(r'^\d+$').hasMatch(fsId)) {
      try {
        final metas = await _baiduGet(
          Uri.https('pan.baidu.com', '/api/filemetas', {
            'dlink': '1',
            'fsids': '[$fsId]',
          }),
          cookies: cookies,
          userAgent: _baiduMediaUa,
        );
        final list = metas['info'] ?? metas['list'];
        if (list is List) {
          for (final row in list.whereType<Map>()) {
            final dlink = _httpsUrl(row['dlink']);
            if (dlink.isNotEmpty) {
              variants.add(CmsEpisode(name: '原画', url: dlink));
              break;
            }
          }
        }
      } on PersonalCloudException catch (e) {
        if (e.requiresReauth) rethrow;
      }
    }

    if (variants.isEmpty && path.isNotEmpty) {
      try {
        final loc = await _baiduGet(
          Uri.https('d.pcs.baidu.com', '/rest/2.0/pcs/file', {
            'method': 'locatedownload',
            'app_id': '250528',
            'ver': '4.0',
            'path': path,
          }),
          cookies: cookies,
          userAgent: _baiduMediaUa,
        );
        final urls = loc['urls'];
        if (urls is List) {
          for (final row in urls.whereType<Map>()) {
            final u = _httpsUrl(row['url']);
            if (u.isNotEmpty) {
              variants.add(CmsEpisode(name: '原画', url: u));
              break;
            }
          }
        }
      } on PersonalCloudException catch (e) {
        if (e.requiresReauth) rethrow;
      }
    }

    if (path.isNotEmpty) {
      final hlsUri = Uri.https('pan.baidu.com', '/api/streaming', {
        'path': path,
        'app_id': '250528',
        'clienttype': '0',
        'type': 'M3U8_AUTO_1080',
        'vip': '2',
      });
      variants.add(CmsEpisode(name: '流畅转码', url: hlsUri.toString()));
    }

    if (variants.isEmpty) {
      throw const PersonalCloudException('unavailable', '百度网盘未返回可用的播放地址');
    }

    final cookieHeader = _formatCookieHeader(cookies);
    CloudMediaLease? lease;
    final leased = <CmsEpisode>[];
    try {
      for (final v in variants) {
        final target = Uri.parse(v.url);
        var playUrl = v.url;
        if (CloudMediaLease.isTrustedBaiduMedia(target)) {
          lease ??= await CloudMediaLease.open(
            target: target,
            provider: CloudMediaProvider.baidu,
            headers: {
              'Cookie': cookieHeader,
              'User-Agent': _baiduMediaUa,
              'Referer': 'https://pan.baidu.com/',
            },
            isCancelled: _isCancelled,
            isCurrent: () async {
              final cur = (await _readCredential('baidu')).trim();
              if (cur.isEmpty) return false;
              if (cur == cred) return true;
              final curCookies = _parseCookieMap(cur);
              if (curCookies.isEmpty && !cur.contains('=')) {
                curCookies['BDUSS'] = cur;
              }
              if ((curCookies['BDUSS'] ?? '').isEmpty) return false;
              return _baiduCookieAccountId(curCookies) == cookieAccountId;
            },
            client: _mediaClientFactory(),
          );
          playUrl = lease.urlFor(target).toString();
        }
        leased.add(
          CmsEpisode(
            name: v.name,
            url: playUrl,
            headers: const {
              'User-Agent': _baiduMediaUa,
              'Referer': 'https://pan.baidu.com/',
            },
            playbackSession: {if (lease != null) 'cloudMediaLease': lease},
          ),
        );
      }
      return CmsEpisode(
        name: name,
        url: leased.first.url,
        headers: leased.first.headers,
        playbackSession: {if (lease != null) 'cloudMediaLease': lease},
        variants: leased,
      );
    } catch (_) {
      await lease?.close();
      rethrow;
    }
  }

  // ── 4. Ali Personal Drive ─────────────────────────────────────────────────

  Future<_AliPersonalSession> _requireAliSession() async {
    final cred = (await _readCredential('ali')).trim();
    var refresh = cred;
    if (refresh.startsWith('ali_token=')) {
      refresh = refresh.substring(10).trim();
    }
    if (refresh.startsWith('{')) {
      try {
        refresh = '${(jsonDecode(refresh) as Map)['refresh_token'] ?? ''}'.trim();
      } catch (_) {
        refresh = '';
      }
    }
    if (refresh.isEmpty) {
      throw const PersonalCloudException(
        'auth_required',
        '请先授权登录阿里云盘账号',
        requiresReauth: true,
      );
    }
    final existing = _aliSession;
    if (_aliSessionCredential == cred &&
        existing != null &&
        existing.expires.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return existing;
    }
    final data = await _aliPost(
      'https://auth.aliyundrive.com/v2/account/token',
      {'refresh_token': refresh, 'grant_type': 'refresh_token'},
    );
    final access = '${data['access_token'] ?? ''}'.trim();
    final userId = '${data['user_id'] ?? ''}'.trim();
    var driveId = '${data['resource_drive_id'] ?? ''}'.trim();
    if (driveId.isEmpty || driveId == 'NO_ID') {
      driveId = '${data['default_drive_id'] ?? ''}'.trim();
    }
    if (driveId.isEmpty) {
      driveId = '${data['backup_drive_id'] ?? ''}'.trim();
    }
    if (access.isEmpty || driveId.isEmpty) {
      throw const PersonalCloudException(
        'auth_expired',
        '阿里云盘登录已失效，请重新授权',
        requiresReauth: true,
      );
    }
    var stored = cred;
    final rotated = '${data['refresh_token'] ?? ''}'.trim();
    if (_writeCredential != null && rotated.isNotEmpty && rotated != refresh) {
      stored = 'ali_token=$rotated';
      await _writeCredential('ali', stored);
    }
    final expiresSec = _intVal(data['expires_in']);
    final session = _AliPersonalSession(
      accessToken: access,
      accountId: userId.isNotEmpty ? userId : _credAccountHash('ali', stored),
      driveId: driveId,
      deviceId: '${data['device_id'] ?? ''}'.trim(),
      expires: DateTime.now().add(Duration(seconds: expiresSec > 0 ? expiresSec : 3600)),
    );
    _aliSession = session;
    _aliSessionCredential = stored;
    return session;
  }

  Future<Map<String, dynamic>> _aliPost(
    String url,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) async {
    _checkActive();
    final req = http.Request('POST', Uri.parse(url))
      ..followRedirects = false
      ..headers.addAll({
        ..._aliMediaHeaders,
        'Content-Type': 'application/json',
        'X-Canary': 'client=Android,app=adrive,version=v4.1.4',
        ...headers,
      })
      ..body = jsonEncode(body);
    try {
      final resp = await _http.send(req).timeout(_timeout);
      final bytes = await _readBoundedBytes(resp.stream);
      if (resp.statusCode == 401) {
        _aliSession = null;
        throw const PersonalCloudException(
          'auth_expired',
          '阿里云盘登录已失效，请重新授权',
          requiresReauth: true,
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const PersonalCloudException('invalid_response', '阿里云盘未返回有效数据');
      }
      final map = Map<String, dynamic>.from(decoded);
      final code = '${map['code'] ?? ''}'.trim();
      if (code.toLowerCase().contains('token') ||
          code.toLowerCase().contains('unauthorized') ||
          code == 'InvalidParameter.RefreshToken') {
        _aliSession = null;
        throw const PersonalCloudException(
          'auth_expired',
          '阿里云盘登录已失效，请重新授权',
          requiresReauth: true,
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300 || (code.isNotEmpty && code != '0')) {
        final msg = '${map['message'] ?? ''}'.trim();
        throw PersonalCloudException(
          code.isEmpty ? 'http_${resp.statusCode}' : code,
          msg.isEmpty ? '阿里云盘请求失败（HTTP ${resp.statusCode}）' : '阿里云盘请求失败：$msg',
        );
      }
      return map;
    } on PersonalCloudException {
      rethrow;
    } on TimeoutException {
      throw const PersonalCloudException('timeout', '阿里云盘连接超时，请稍后重试');
    } catch (e) {
      throw PersonalCloudException('network', '阿里云盘请求失败：$e');
    }
  }

  Future<PersonalCloudPage> _listAli({
    required String folderId,
    required int page,
    required String marker,
    required String driveId,
  }) async {
    final session = await _requireAliSession();
    final activeDrive = driveId.isNotEmpty ? driveId : session.driveId;
    var cursor = marker;
    // Support indexed page requests (e.g., Library pagination page=2, 3...) by
    // stepping cursor pages when no explicit marker was supplied.
    Map<String, dynamic>? payload;
    final steps = cursor.isNotEmpty ? 1 : math.max(1, page);
    for (var i = 0; i < steps; i++) {
      payload = await _aliPost(
        '$_aliApi/adrive/v3/file/list',
        {
          'drive_id': activeDrive,
          'parent_file_id': folderId,
          'limit': 100,
          'order_by': 'name',
          'order_direction': 'ASC',
          if (cursor.isNotEmpty) 'marker': cursor,
        },
        headers: session.headers,
      );
      cursor = '${payload['next_marker'] ?? ''}'.trim();
      if (i + 1 < steps && cursor.isEmpty) {
        return PersonalCloudPage(
          provider: PersonalCloudProvider.ali,
          folderId: folderId,
          items: const <PersonalCloudItem>[],
          page: page,
          pageCount: i + 1,
          hasMore: false,
          driveId: activeDrive,
          accountId: session.accountId,
        );
      }
    }
    final rows = payload?['items'];
    if (rows is! List) {
      throw const PersonalCloudException('invalid_response', '阿里云盘未返回有效目录');
    }
    final items = <PersonalCloudItem>[];
    for (final row in rows.whereType<Map>()) {
      final fid = '${row['file_id'] ?? ''}'.trim();
      final name = '${row['name'] ?? ''}'.trim();
      if (fid.isEmpty || name.isEmpty) continue;
      final isDir = row['type'] == 'folder';
      if (!isDir &&
          row['category'] != 'video' &&
          !ExternalMediaLibrary.isVideoFileName(name)) {
        continue;
      }
      items.add(
        PersonalCloudItem(
          provider: PersonalCloudProvider.ali,
          id: fid,
          name: name,
          isDir: isDir,
          size: _intVal(row['size']),
          thumbnail: _httpUrl(row['thumbnail']),
          driveId: activeDrive,
        ),
      );
    }
    final hasMore = cursor.isNotEmpty;
    return PersonalCloudPage(
      provider: PersonalCloudProvider.ali,
      folderId: folderId,
      items: items,
      page: page,
      pageCount: hasMore ? page + 1 : page,
      hasMore: hasMore,
      nextMarker: cursor,
      driveId: activeDrive,
      accountId: session.accountId,
    );
  }

  Future<CmsEpisode> _resolveAli({
    required String fileId,
    required String driveId,
    required String name,
    String expectedAccountId = '',
  }) async {
    final session = await _requireAliSession();
    assertAccountMatches(
      provider: PersonalCloudProvider.ali,
      expectedAccountId: expectedAccountId,
      observedAccountId: session.accountId,
    );
    final activeDrive = driveId.isNotEmpty ? driveId : session.driveId;
    final variants = <CmsEpisode>[];
    PersonalCloudException? lastErr;

    try {
      final dl = await _aliPost(
        'https://bj29.api.aliyunpds.com/v2/file/get_download_url',
        {'drive_id': activeDrive, 'file_id': fileId, 'expire_sec': 14400},
        headers: session.headers,
      );
      final url = _httpsUrl(dl['url']);
      if (url.isNotEmpty) {
        variants.add(
          CmsEpisode(name: '原画', url: url, headers: _aliMediaHeaders),
        );
      }
    } on PersonalCloudException catch (e) {
      if (e.requiresReauth) rethrow;
      lastErr = e;
    }

    try {
      final preview = await _aliPost(
        '$_aliApi/v2/file/get_video_preview_play_info',
        {
          'drive_id': activeDrive,
          'file_id': fileId,
          'category': 'live_transcoding',
          'get_subtitle_info': true,
          'url_expire_sec': 14400,
        },
        headers: session.headers,
      );
      final info = preview['video_preview_play_info'];
      final tasks = info is Map ? info['live_transcoding_task_list'] : null;
      if (tasks is List) {
        final ready = tasks
            .whereType<Map>()
            .where((t) =>
                (t['status'] == null || t['status'] == 'finished') &&
                _httpsUrl(t['url']).isNotEmpty)
            .toList()
          ..sort((a, b) =>
              _intVal(b['template_height']).compareTo(_intVal(a['template_height'])));
        for (final t in ready) {
          final url = _httpsUrl(t['url']);
          if (variants.any((v) => v.url == url)) continue;
          final h = _intVal(t['template_height']);
          variants.add(
            CmsEpisode(
              name: h > 0 ? '${h}P' : '转码',
              url: url,
              headers: _aliMediaHeaders,
            ),
          );
        }
      }
    } on PersonalCloudException catch (e) {
      if (e.requiresReauth) rethrow;
      lastErr ??= e;
    }

    if (variants.isEmpty) {
      throw lastErr ??
          const PersonalCloudException('unavailable', '阿里云盘未返回可用播放地址');
    }
    return CmsEpisode(
      name: name,
      url: variants.first.url,
      headers: variants.first.headers,
      variants: variants,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _checkActive() {
    if (_isCancelled()) {
      throw const PersonalCloudException('cancelled', '已取消网盘请求');
    }
  }

  Future<List<int>> _readBoundedBytes(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream.timeout(_timeout)) {
      if (bytes.length + chunk.length > _maxBytes) {
        throw const PersonalCloudException('response_too_large', '网盘响应过大');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static int _intVal(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  static String _httpUrl(Object? v) {
    final s = v is String ? v.trim() : '';
    final u = Uri.tryParse(s);
    if (u == null || !const ['http', 'https'].contains(u.scheme.toLowerCase())) {
      return '';
    }
    return s;
  }

  static String _httpsUrl(Object? v) {
    final s = v is String ? v.trim() : '';
    final u = Uri.tryParse(s);
    if (u == null || u.scheme.toLowerCase() != 'https' || u.host.isEmpty) {
      return '';
    }
    return s;
  }

  static String _credAccountHash(String provider, String cred) =>
      sha256.convert(utf8.encode('$provider|$cred')).toString().substring(0, 16);

  static const Set<String> _nonIdentityCookieKeys = <String>{
    'theme',
    'lang',
    'locale',
    'language',
    'timezone',
    'tz',
    'abtest',
    'gray',
    'csrf',
    '_csrf',
    'xsrf-token',
    '_ga',
    '_gid',
    '_gat',
    'baiduid',
    'baiduid_bfess',
    'stoken',
    'sboxt',
    'pan_login_way',
    'ndut_fmt',
  };

  static String _extractProviderId(
    Map<String, dynamic>? payload,
    List<String> candidateKeys,
  ) {
    if (payload == null || payload.isEmpty) return '';
    String pickFrom(Map<Object?, Object?> map) {
      for (final key in candidateKeys) {
        final raw = map[key];
        if (raw == null) continue;
        final text = '$raw'.trim();
        if (text.isNotEmpty && text != '0' && text.toLowerCase() != 'null') {
          return text;
        }
      }
      return '';
    }

    final direct = pickFrom(payload);
    if (direct.isNotEmpty) return direct;
    for (final nestedKey in const ['data', 'user', 'account', 'member', 'metadata']) {
      final sub = payload[nestedKey];
      if (sub is Map) {
        final nested = pickFrom(sub);
        if (nested.isNotEmpty) return nested;
      }
    }
    return '';
  }

  static String _canonicalCookieHash(
    String provider,
    Map<String, String> cookies, {
    required List<String> primaryKeys,
  }) {
    final normalized = <String, String>{};
    cookies.forEach((k, v) {
      final ck = k.trim();
      final cv = v.trim();
      if (ck.isNotEmpty && cv.isNotEmpty) {
        normalized[ck] = cv;
      }
    });
    for (final key in primaryKeys) {
      final exact = normalized[key];
      if (exact != null && exact.isNotEmpty) {
        final digest = sha256
            .convert(utf8.encode('$provider|$key=$exact'))
            .toString()
            .substring(0, 16);
        return '$provider:v2:$digest';
      }
      final lowerTarget = key.toLowerCase();
      for (final entry in normalized.entries) {
        if (entry.key.toLowerCase() == lowerTarget && entry.value.isNotEmpty) {
          final digest = sha256
              .convert(utf8.encode('$provider|$key=${entry.value}'))
              .toString()
              .substring(0, 16);
          return '$provider:v2:$digest';
        }
      }
    }
    final filteredEntries = normalized.entries
        .where((e) => !_nonIdentityCookieKeys.contains(e.key.toLowerCase()))
        .toList();
    final chosen = filteredEntries.isNotEmpty
        ? filteredEntries
        : normalized.entries.toList();
    chosen.sort((a, b) => a.key.compareTo(b.key));
    final canonical = chosen.map((e) => '${e.key}=${e.value}').join(';');
    final digest = sha256
        .convert(utf8.encode('$provider|$canonical'))
        .toString()
        .substring(0, 16);
    return '$provider:v2:$digest';
  }

  static String _ucCookieAccountId(Map<String, String> cookies) =>
      _canonicalCookieHash(
        'uc',
        cookies,
        primaryKeys: const <String>['__pus', '__puus', 'uid', 'member_id'],
      );

  static String _ucAccountId(
    Map<String, String> cookies, {
    Map<String, dynamic>? cfg,
    Map<String, dynamic>? payload,
  }) {
    const idKeys = <String>['uid', 'member_id', 'user_id', 'account_id'];
    final cfgUid = _extractProviderId(cfg, idKeys);
    final serverUid = cfgUid.isNotEmpty
        ? cfgUid
        : _extractProviderId(payload, idKeys);
    if (serverUid.isNotEmpty) return 'uc:uid:$serverUid';
    return _ucCookieAccountId(cookies);
  }

  static String _baiduCookieAccountId(Map<String, String> cookies) =>
      _canonicalCookieHash(
        'baidu',
        cookies,
        primaryKeys: const <String>['BDUSS', 'BDUSS_BFESS'],
      );

  static String _baiduAccountId(
    Map<String, String> cookies, {
    Map<String, dynamic>? payload,
  }) {
    const idKeys = <String>['uk', 'user_id', 'uid'];
    final serverUk = _extractProviderId(payload, idKeys);
    if (serverUk.isNotEmpty) return 'baidu:uk:$serverUk';
    return _baiduCookieAccountId(cookies);
  }
}

class _AliPersonalSession {
  const _AliPersonalSession({
    required this.accessToken,
    required this.accountId,
    required this.driveId,
    required this.deviceId,
    required this.expires,
  });

  final String accessToken;
  final String accountId;
  final String driveId;
  final String deviceId;
  final DateTime expires;

  Map<String, String> get headers => {
        'Authorization': 'Bearer $accessToken',
        if (deviceId.isNotEmpty) 'x-device-id': deviceId,
      };
}

/// Saved personal cloud-drive folder resource library (`cloudlib://account/<key>`).
///
/// Supports adding any user-owned directory from Quark, UC, Baidu, or Ali as a
/// persistent resource library with deduplication, multi-level folder browsing,
/// pagination, refresh, and playback resolution.
class PersonalCloudLibrary {
  static const String prefix = 'cloudlib://account/';
  static const String playScheme = 'mmcloudlib';
  static const String folderTag = 'media-folder';

  final String key;
  final PersonalCloudProvider provider;
  final String folderId;
  final String folderName;
  final String driveId;
  String _accountId;
  String _cookieAccountId;
  String _legacyAccountId;
  final Set<String> _verifiedCookieAccountIds;
  final PersonalCloudDriveClient _client;
  final bool _ownsClient;

  static const int _maxVerifiedCookieAliases = 32;

  String get accountId => _accountId;
  String get cookieAccountId => _cookieAccountId;

  PersonalCloudLibrary._({
    required this.key,
    required this.provider,
    required this.folderId,
    required this.folderName,
    required this.driveId,
    required String accountId,
    String cookieAccountId = '',
    String legacyAccountId = '',
    Iterable<String> verifiedCookieAccountIds = const <String>[],
    required PersonalCloudDriveClient client,
    required bool ownsClient,
  })  : _accountId = accountId,
        _cookieAccountId = cookieAccountId,
        _legacyAccountId = legacyAccountId,
        _verifiedCookieAccountIds = <String>{
          for (final id in verifiedCookieAccountIds)
            if (id.trim().isNotEmpty) id.trim(),
        },
        _client = client,
        _ownsClient = ownsClient;

  static List<String> _readVerifiedCookieAliases(Map rawMap) {
    final raw = rawMap['verifiedCookieAccountIds'];
    if (raw is! List) return const <String>[];
    final out = <String>[];
    for (final entry in raw) {
      final id = '$entry'.trim();
      if (id.isNotEmpty &&
          PersonalCloudDriveClient._isCookieAccountId(id) &&
          !out.contains(id)) {
        out.add(id);
      }
    }
    return out;
  }

  static List<String> _collectVerifiedCookieAliases({
    required String ownerAccountId,
    Iterable<String> existing = const <String>[],
    Iterable<String> candidates = const <String>[],
  }) {
    if (!PersonalCloudDriveClient._isProviderOwnerId(ownerAccountId)) {
      return const <String>[];
    }
    final ordered = <String>[];
    void addIfCookie(String raw) {
      final id = raw.trim();
      if (id.isEmpty || !PersonalCloudDriveClient._isCookieAccountId(id)) {
        return;
      }
      if (!ordered.contains(id)) {
        ordered.add(id);
      }
    }

    for (final id in existing) {
      addIfCookie(id);
    }
    for (final id in candidates) {
      addIfCookie(id);
    }
    if (ordered.length > _maxVerifiedCookieAliases) {
      // Keep the earliest pre-migration alias alongside the most recent cookies.
      return <String>[
        ordered.first,
        ...ordered.sublist(ordered.length - (_maxVerifiedCookieAliases - 1)),
      ];
    }
    return ordered;
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  static bool isSupportedSite(CmsSite site) => site.api.startsWith(prefix);
  static bool isPlayableScheme(String url) => url.startsWith('$playScheme://play?');

  static String deterministicKey({
    required PersonalCloudProvider provider,
    required String accountId,
    required String driveId,
    required String folderId,
  }) =>
      sha256
          .convert(
            utf8.encode(
              'cloudlib|${provider.key}|${accountId.trim()}|${driveId.trim()}|${folderId.trim()}',
            ),
          )
          .toString();

  /// Validates the target folder against the provider's personal file API and
  /// saves it as a deduplicated [SubscriptionEntry]. Never saves an empty or
  /// unverified library if listing or auth fails.
  static Future<({SubscriptionEntry entry, bool updatedExisting})> create({
    required PersonalCloudDriveClient client,
    required PersonalCloudProvider provider,
    required String folderId,
    required String folderName,
    String driveId = '',
    required String group,
    required bool isPrivate,
  }) async {
    final effectiveFolderId =
        folderId.trim().isEmpty ? provider.rootFolderId : folderId.trim();
    // Actively verify folder accessibility before creating the library.
    final page = await client.listFolder(
      provider,
      folderId: effectiveFolderId,
      page: 1,
      driveId: driveId,
    );
    final resolvedDriveId =
        page.driveId.isNotEmpty ? page.driveId : driveId.trim();
    final resolvedAccountId = page.accountId.trim();
    final resolvedCookieAccountId = page.cookieAccountId.trim();
    final resolvedLegacyAccountId = page.legacyAccountId.trim();
    final cleanFolderName =
        folderName.trim().isEmpty ? provider.rootLabel : folderName.trim();
    final title = '${provider.shortName} · $cleanFolderName';
    final prefs = await SharedPreferences.getInstance();

    // Unified identity-merge helper shared by BOTH direct deterministic-key
    // hits and legacy/cookie-key lookup scans:
    //  1. Two explicitly distinct provider owner IDs (`uc:uid:A` vs `uc:uid:B`,
    //     or `baidu:uk:777` vs `baidu:uk:888`) NEVER merge onto the same
    //     subscription key, even when sharing a cookie identity.
    //  2. Omitting the optional owner ID on re-add NEVER downgrades a
    //     previously verified provider owner ID stored on that key.
    ({
      bool canMerge,
      String accountId,
      String cookieAccountId,
      String legacyAccountId,
      List<String> verifiedCookieAccountIds,
    })
        evaluateExistingLibraryIdentity(Map existingMap) {
      final storedAcc = '${existingMap['accountId'] ?? ''}'.trim();
      final storedCookie = '${existingMap['cookieAccountId'] ?? ''}'.trim();
      final storedLegacy = '${existingMap['legacyAccountId'] ?? ''}'.trim();
      final storedVerifiedCookies = _readVerifiedCookieAliases(existingMap);
      final hasConflictingExplicitOwners =
          PersonalCloudDriveClient._isProviderOwnerId(storedAcc) &&
          PersonalCloudDriveClient._isProviderOwnerId(resolvedAccountId) &&
          storedAcc != resolvedAccountId;
      if (hasConflictingExplicitOwners) {
        return (
          canMerge: false,
          accountId: storedAcc,
          cookieAccountId: storedCookie,
          legacyAccountId: storedLegacy,
          verifiedCookieAccountIds: storedVerifiedCookies,
        );
      }
      final candidateIds = <String>{
        if (resolvedAccountId.isNotEmpty) resolvedAccountId,
        if (resolvedCookieAccountId.isNotEmpty) resolvedCookieAccountId,
        if (resolvedLegacyAccountId.isNotEmpty) resolvedLegacyAccountId,
      };
      final matches =
          (storedAcc.isNotEmpty && candidateIds.contains(storedAcc)) ||
          (storedCookie.isNotEmpty && candidateIds.contains(storedCookie)) ||
          (storedLegacy.isNotEmpty && candidateIds.contains(storedLegacy));
      if (!matches) {
        return (
          canMerge: false,
          accountId: storedAcc,
          cookieAccountId: storedCookie,
          legacyAccountId: storedLegacy,
          verifiedCookieAccountIds: storedVerifiedCookies,
        );
      }
      final preserveStoredOwner =
          PersonalCloudDriveClient._isProviderOwnerId(storedAcc) &&
          !PersonalCloudDriveClient._isProviderOwnerId(resolvedAccountId);
      final mergedAccountId = preserveStoredOwner
          ? storedAcc
          : (resolvedAccountId.isNotEmpty ? resolvedAccountId : storedAcc);
      final mergedCookieId = resolvedCookieAccountId.isNotEmpty
          ? resolvedCookieAccountId
          : storedCookie;
      final mergedLegacyId = storedLegacy.isNotEmpty
          ? storedLegacy
          : ((resolvedLegacyAccountId.isNotEmpty &&
                    storedAcc == resolvedLegacyAccountId)
                ? storedAcc
                : '');
      final mergedVerifiedCookies = _collectVerifiedCookieAliases(
        ownerAccountId: mergedAccountId,
        existing: storedVerifiedCookies,
        candidates: [
          storedAcc,
          storedCookie,
          resolvedCookieAccountId,
        ],
      );
      return (
        canMerge: true,
        accountId: mergedAccountId,
        cookieAccountId: mergedCookieId,
        legacyAccountId: mergedLegacyId,
        verifiedCookieAccountIds: mergedVerifiedCookies,
      );
    }

    var key = deterministicKey(
      provider: provider,
      accountId: resolvedAccountId,
      driveId: resolvedDriveId,
      folderId: effectiveFolderId,
    );
    var prefKey = 'cloudlib.account.$key';
    var existed = false;
    var persistedAccountId = resolvedAccountId;
    var persistedCookieAccountId = resolvedCookieAccountId;
    var preservedLegacyId = '';
    var persistedVerifiedCookies = _collectVerifiedCookieAliases(
      ownerAccountId: resolvedAccountId,
      candidates: [resolvedCookieAccountId],
    );

    final directRaw = prefs.getString(prefKey);
    if (directRaw != null && directRaw.isNotEmpty) {
      try {
        final directMap = jsonDecode(directRaw);
        if (directMap is Map &&
            '${directMap['provider'] ?? ''}'.trim() == provider.key &&
            '${directMap['folderId'] ?? ''}'.trim() == effectiveFolderId &&
            '${directMap['driveId'] ?? ''}'.trim() == resolvedDriveId) {
          final merged = evaluateExistingLibraryIdentity(directMap);
          if (merged.canMerge) {
            existed = true;
            persistedAccountId = merged.accountId;
            persistedCookieAccountId = merged.cookieAccountId;
            preservedLegacyId = merged.legacyAccountId;
            persistedVerifiedCookies = merged.verifiedCookieAccountIds;
          } else {
            throw PersonalCloudException(
              'account_mismatch',
              '当前登录的${provider.displayName}账号与已保存资源库绑定账号冲突，请切回原账号或重新绑定',
              requiresReauth: true,
            );
          }
        }
      } catch (_) {}
    }

    if (!existed) {
      const keyPrefix = 'cloudlib.account.';
      for (final existingPrefKey in prefs.getKeys()) {
        if (!existingPrefKey.startsWith(keyPrefix)) continue;
        final existingRaw = prefs.getString(existingPrefKey);
        if (existingRaw == null || existingRaw.isEmpty) continue;
        try {
          final existingMap = jsonDecode(existingRaw);
          if (existingMap is! Map) continue;
          if ('${existingMap['provider'] ?? ''}'.trim() != provider.key) {
            continue;
          }
          if ('${existingMap['folderId'] ?? ''}'.trim() != effectiveFolderId) {
            continue;
          }
          if ('${existingMap['driveId'] ?? ''}'.trim() != resolvedDriveId) {
            continue;
          }
          final merged = evaluateExistingLibraryIdentity(existingMap);
          if (merged.canMerge) {
            key = existingPrefKey.substring(keyPrefix.length);
            prefKey = existingPrefKey;
            existed = true;
            persistedAccountId = merged.accountId;
            persistedCookieAccountId = merged.cookieAccountId;
            preservedLegacyId = merged.legacyAccountId;
            persistedVerifiedCookies = merged.verifiedCookieAccountIds;
            break;
          }
        } catch (_) {}
      }
    }

    await prefs.setString(
      prefKey,
      jsonEncode({
        'provider': provider.key,
        'folderId': effectiveFolderId,
        'folderName': cleanFolderName,
        'driveId': resolvedDriveId,
        'accountId': persistedAccountId,
        if (persistedCookieAccountId.isNotEmpty)
          'cookieAccountId': persistedCookieAccountId,
        if (preservedLegacyId.isNotEmpty) 'legacyAccountId': preservedLegacyId,
        if (persistedVerifiedCookies.isNotEmpty)
          'verifiedCookieAccountIds': persistedVerifiedCookies,
      }),
    );
    final api = '$prefix$key';
    final entry = SubscriptionEntry(
      id: 'cloudlib_$key',
      name: title,
      group: group,
      isPrivate: isPrivate,
      format: 'CloudDrive',
      siteCount: 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      rawContent: jsonEncode({
        'sites': [
          {'key': 'cloudlib_$key', 'name': title, 'type': 1, 'api': api},
        ],
      }),
    );
    return (entry: entry, updatedExisting: existed);
  }

  static Future<PersonalCloudLibrary> open(
    CmsSite site, {
    PersonalCloudDriveClient? client,
  }) async {
    final key = site.api.substring(prefix.length);
    final raw = (await SharedPreferences.getInstance())
        .getString('cloudlib.account.$key');
    if (raw == null) {
      throw const PersonalCloudException(
        'missing_config',
        '该个人网盘资源库配置已丢失，请重新添加',
      );
    }
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final provider = PersonalCloudProvider.fromKey('${map['provider'] ?? ''}');
    if (provider == null) {
      throw const PersonalCloudException('invalid_config', '未知的网盘服务商配置');
    }
    final owns = client == null;
    final activeClient = client ??
        PersonalCloudDriveClient.fromStorage(await StorageService.init());
    return PersonalCloudLibrary._(
      key: key,
      provider: provider,
      folderId: '${map['folderId'] ?? provider.rootFolderId}',
      folderName: '${map['folderName'] ?? provider.rootLabel}',
      driveId: '${map['driveId'] ?? ''}',
      accountId: '${map['accountId'] ?? ''}',
      cookieAccountId: '${map['cookieAccountId'] ?? ''}',
      legacyAccountId: '${map['legacyAccountId'] ?? ''}',
      verifiedCookieAccountIds: _readVerifiedCookieAliases(map),
      client: activeClient,
      ownsClient: owns,
    );
  }

  static String encodeFolderCardId(String folderId) =>
      Uri(scheme: 'mmfolder', host: 'open', queryParameters: {'id': folderId})
          .toString();

  static String decodeFolderTarget(String rawId) {
    final u = Uri.tryParse(rawId);
    if (u != null && u.scheme == 'mmfolder') {
      return u.queryParameters['id'] ?? '';
    }
    return rawId;
  }

  CmsVideo _toVideoCard(PersonalCloudItem item) {
    if (item.isDir) {
      return CmsVideo(
        id: encodeFolderCardId(item.id),
        title: item.name,
        remarks: '文件夹',
        tag: folderTag,
      );
    }
    final playUrl = Uri(
      scheme: playScheme,
      host: 'play',
      queryParameters: {
        'provider': provider.key,
        'fid': item.id,
        'name': item.name,
        if (accountId.trim().isNotEmpty) 'account': accountId.trim(),
        if (item.driveId.isNotEmpty) 'drive': item.driveId,
        if (item.path.isNotEmpty) 'path': item.path,
        if (item.rawRef.isNotEmpty) 'ref': item.rawRef,
      },
    ).toString();
    return CmsVideo(
      id: playUrl,
      title: ExternalMediaLibrary.cleanMediaTitle(item.name),
      poster: item.thumbnail,
      remarks: item.size > 0 ? formatFileSize(item.size) : provider.displayName,
      tag: 'cloudlib-video',
      lines: [
        CmsLine(
          name: provider.displayName,
          episodes: [CmsEpisode(name: item.name, url: playUrl)],
        ),
      ],
    );
  }

  Future<void> _verifyAndMigrateAccountOwnership(PersonalCloudPage page) async {
    final observed = page.accountId.trim();
    final observedCookie = page.cookieAccountId.trim();
    final legacyObserved = page.legacyAccountId.trim();
    PersonalCloudDriveClient.assertAccountMatches(
      provider: provider,
      expectedAccountId: _accountId,
      observedAccountId: observed,
      expectedCookieAccountId: _cookieAccountId,
      observedCookieAccountId: observedCookie,
      legacyObservedAccountId: legacyObserved,
    );
    // Never downgrade an already-verified server owner ID (`uc:uid:*` /
    // `baidu:uk:*`) to a weaker cookie identity when a paginated or partial API
    // response omits the optional owner field. Conflicting server owner IDs or
    // switched cookies have already been rejected by `assertAccountMatches`.
    final isDowngradeFromOwner =
        PersonalCloudDriveClient._isProviderOwnerId(_accountId) &&
        !PersonalCloudDriveClient._isProviderOwnerId(observed);
    final nextAccountId =
        (observed.isNotEmpty && !isDowngradeFromOwner) ? observed : _accountId;
    final nextVerifiedCookies = _collectVerifiedCookieAliases(
      ownerAccountId: nextAccountId,
      existing: _verifiedCookieAccountIds,
      candidates: [_accountId, _cookieAccountId, observedCookie],
    );
    final verifiedCookiesChanged =
        nextVerifiedCookies.length != _verifiedCookieAccountIds.length ||
        nextVerifiedCookies.any((id) => !_verifiedCookieAccountIds.contains(id));
    final needsMigration =
        (nextAccountId.isNotEmpty && _accountId != nextAccountId) ||
        (observedCookie.isNotEmpty && _cookieAccountId != observedCookie) ||
        verifiedCookiesChanged;
    if (!needsMigration) return;

    final prevAcc = _accountId.trim();
    if (_legacyAccountId.isEmpty &&
        legacyObserved.isNotEmpty &&
        prevAcc == legacyObserved) {
      _legacyAccountId = prevAcc;
    }
    if (nextAccountId.isNotEmpty) {
      _accountId = nextAccountId;
    }
    if (observedCookie.isNotEmpty) {
      _cookieAccountId = observedCookie;
    }
    if (verifiedCookiesChanged) {
      _verifiedCookieAccountIds
        ..clear()
        ..addAll(nextVerifiedCookies);
    }
    final prefs = await SharedPreferences.getInstance();
    final prefKey = 'cloudlib.account.$key';
    if (prefs.getString(prefKey) != null) {
      await prefs.setString(
        prefKey,
        jsonEncode({
          'provider': provider.key,
          'folderId': folderId,
          'folderName': folderName,
          'driveId': driveId,
          'accountId': _accountId,
          if (_cookieAccountId.isNotEmpty) 'cookieAccountId': _cookieAccountId,
          if (_legacyAccountId.isNotEmpty) 'legacyAccountId': _legacyAccountId,
          if (_verifiedCookieAccountIds.isNotEmpty)
            'verifiedCookieAccountIds': _verifiedCookieAccountIds.toList(),
        }),
      );
    }
  }

  Future<(List<CmsCategory>, CmsListing)> home() async {
    final page = await _client.listFolder(
      provider,
      folderId: folderId,
      page: 1,
      driveId: driveId,
    );
    await _verifyAndMigrateAccountOwnership(page);
    final cats = <CmsCategory>[
      CmsCategory(id: folderId, name: folderName),
      for (final item in page.items.where((i) => i.isDir))
        CmsCategory(id: item.id, name: item.name),
    ];
    final cards = page.items.map(_toVideoCard).toList();
    return (
      cats,
      CmsListing(
        page: page.page,
        pageCount: page.pageCount,
        videos: cards,
      ),
    );
  }

  Future<CmsListing> list(String categoryId, String query, int page) async {
    final targetFolder = categoryId.trim().isEmpty
        ? folderId
        : decodeFolderTarget(categoryId.trim());
    final res = await _client.listFolder(
      provider,
      folderId: targetFolder,
      page: page,
      driveId: driveId,
    );
    await _verifyAndMigrateAccountOwnership(res);
    final q = query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? res.items
        : res.items
            .where((i) => i.name.toLowerCase().contains(q))
            .toList();
    return CmsListing(
      page: res.page,
      pageCount: res.pageCount,
      videos: filtered.map(_toVideoCard).toList(),
    );
  }

  Future<CmsVideo> detail(CmsVideo fallback) async {
    if (fallback.lines.isNotEmpty) return fallback;
    final playUrl = fallback.id.startsWith('$playScheme://play?')
        ? fallback.id
        : Uri(
            scheme: playScheme,
            host: 'play',
            queryParameters: {
              'provider': provider.key,
              'fid': fallback.id,
              'name': fallback.title,
              if (accountId.trim().isNotEmpty) 'account': accountId.trim(),
              if (driveId.isNotEmpty) 'drive': driveId,
            },
          ).toString();
    return CmsVideo(
      id: fallback.id,
      title: fallback.title,
      poster: fallback.poster,
      remarks: provider.displayName,
      lines: [
        CmsLine(
          name: provider.displayName,
          episodes: [CmsEpisode(name: fallback.title, url: playUrl)],
        ),
      ],
    );
  }

  Future<CmsEpisode> resolve(CmsEpisode episode) async {
    final uri = Uri.tryParse(episode.url);
    if (uri == null || uri.scheme != playScheme) {
      throw const PersonalCloudException('invalid_episode', '个人网盘播放引用无效');
    }
    final p = uri.queryParameters;
    final targetProvider =
        PersonalCloudProvider.fromKey(p['provider'] ?? '') ?? provider;
    final urlAccount = (p['account'] ?? '').trim();
    var expectedAccount =
        urlAccount.isNotEmpty ? urlAccount : _accountId.trim();
    if (_accountId.trim().isNotEmpty && urlAccount.isNotEmpty) {
      final matchesMigratedLegacy =
          _legacyAccountId.isNotEmpty && urlAccount == _legacyAccountId;
      final matchesVerifiedOwnerCookie =
          PersonalCloudDriveClient._isProviderOwnerId(_accountId) &&
          PersonalCloudDriveClient._isCookieAccountId(urlAccount) &&
          _verifiedCookieAccountIds.contains(urlAccount);
      if (matchesMigratedLegacy || matchesVerifiedOwnerCookie) {
        expectedAccount = _accountId.trim();
      } else {
        PersonalCloudDriveClient.assertAccountMatches(
          provider: provider,
          expectedAccountId: _accountId,
          observedAccountId: urlAccount,
          expectedCookieAccountId: _cookieAccountId,
          observedCookieAccountId:
              PersonalCloudDriveClient._isCookieAccountId(urlAccount)
                  ? urlAccount
                  : '',
          legacyObservedAccountId: _legacyAccountId,
        );
        if (PersonalCloudDriveClient._isProviderOwnerId(_accountId) &&
            PersonalCloudDriveClient._isCookieAccountId(urlAccount)) {
          expectedAccount = _accountId.trim();
        }
      }
    }
    Future<CmsEpisode> resolveWithCurrentBinding() => _client.resolveFile(
          provider: targetProvider,
          fileId: p['fid'] ?? '',
          name: (p['name']?.isNotEmpty ?? false) ? p['name']! : episode.name,
          driveId: (p['drive']?.isNotEmpty ?? false) ? p['drive']! : driveId,
          path: p['path'] ?? '',
          rawRef: p['ref'] ?? '',
          expectedAccountId: expectedAccount,
          expectedCookieAccountId: _cookieAccountId.trim(),
        );

    try {
      return await resolveWithCurrentBinding();
    } on PersonalCloudException catch (e) {
      // When the library is already bound to a verified provider owner ID
      // (`uc:uid:*` / `baidu:uk:*`) and the user re-authenticated with a fresh
      // cookie without first browsing the library, verify server ownership on
      // demand. Only if the server confirms the EXACT SAME owner do we update
      // the cookie binding and retry; a different owner or unverified session
      // continues to reject with `account_mismatch`.
      final canVerifyOnDemand =
          e.code == 'account_mismatch' &&
          PersonalCloudDriveClient._isProviderOwnerId(_accountId.trim()) &&
          (targetProvider == PersonalCloudProvider.uc ||
              targetProvider == PersonalCloudProvider.baidu);
      if (!canVerifyOnDemand) rethrow;

      PersonalCloudPage verifyPage;
      try {
        verifyPage = await _client.listFolder(
          targetProvider,
          folderId: folderId,
          page: 1,
          driveId: driveId,
        );
      } on PersonalCloudException catch (verifyErr) {
        if (verifyErr.code == 'account_mismatch') {
          throw e;
        }
        // Preserve both expired-session errors (`requiresReauth: true`, e.g.
        // 401) and transient service outages (`requiresReauth: false`, e.g.
        // HTTP 503 / timeout / network) so callers stop playback cleanly
        // without misclassifying temporary outages as an account switch.
        rethrow;
      } catch (_) {
        throw const PersonalCloudException(
          'verify_unavailable',
          '校验网盘账号归属失败，请稍后重试',
          requiresReauth: false,
        );
      }

      final observedOwner = verifyPage.accountId.trim();
      if (!PersonalCloudDriveClient._isProviderOwnerId(observedOwner) ||
          observedOwner != _accountId.trim()) {
        throw e;
      }
      await _verifyAndMigrateAccountOwnership(verifyPage);
      return resolveWithCurrentBinding();
    }
  }

  static String formatFileSize(int bytes) {
    if (bytes <= 0) return '';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

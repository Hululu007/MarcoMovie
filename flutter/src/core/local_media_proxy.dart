import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

enum _TargetKind { auto, playlist, tsSegment, raw }

class _RegisteredTarget {
  final Uri uri;
  final _TargetKind kind;
  const _RegisteredTarget(this.uri, this.kind);
}

class _StoredCookie {
  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final DateTime? expiresAt;

  const _StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    this.expiresAt,
  });

  bool matches(Uri uri, DateTime now) {
    if (expiresAt != null && !expiresAt!.isAfter(now)) return false;
    final reqHost = uri.host.toLowerCase();
    if (hostOnly) {
      if (reqHost != domain) return false;
    } else {
      if (reqHost != domain && !reqHost.endsWith('.$domain')) return false;
    }
    final reqPath = uri.path.isEmpty ? '/' : uri.path;
    if (path == '/' || reqPath == path) return true;
    if (reqPath.startsWith(path)) {
      return path.endsWith('/') || reqPath.codeUnitAt(path.length) == 0x2F;
    }
    return false;
  }
}

class _SessionCookieJar {
  final Map<String, _StoredCookie> _cookies = {};

  static List<String> splitSetCookieHeader(String raw) {
    final result = <String>[];
    var start = 0;
    var inExpires = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw.codeUnitAt(i);
      if (ch == 0x3B /* ; */) {
        inExpires = false;
      } else if (!inExpires &&
          i + 8 <= raw.length &&
          raw.substring(i, i + 8).toLowerCase() == 'expires=') {
        inExpires = true;
      } else if (ch == 0x2C /* , */) {
        if (inExpires) {
          inExpires = false;
          continue;
        }
        final rest = raw.substring(i + 1).trimLeft();
        final semi = rest.indexOf(';');
        final eq = rest.indexOf('=');
        if (eq > 0 && (semi < 0 || eq < semi)) {
          final piece = raw.substring(start, i).trim();
          if (piece.isNotEmpty) result.add(piece);
          start = i + 1;
        }
      }
    }
    final tail = raw.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }

  void storeFromHeaders(
      Map<String, String> responseHeaders, Uri requestUri, DateTime now) {
    String? rawSetCookie;
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        rawSetCookie = entry.value;
        break;
      }
    }
    if (rawSetCookie == null || rawSetCookie.trim().isEmpty) return;
    for (final header in splitSetCookieHeader(rawSetCookie)) {
      final parts = header.split(';');
      if (parts.isEmpty) continue;
      final nv = parts.first.trim();
      final eq = nv.indexOf('=');
      if (eq <= 0) continue;
      final name = nv.substring(0, eq).trim();
      final value = nv.substring(eq + 1).trim();
      if (name.isEmpty) continue;

      final reqHost = requestUri.host.toLowerCase();
      var domain = reqHost;
      var hostOnly = true;
      var path = _defaultCookiePath(requestUri.path);
      DateTime? expiresAt;

      for (final rawAttr in parts.skip(1)) {
        final attr = rawAttr.trim();
        if (attr.isEmpty) continue;
        final aEq = attr.indexOf('=');
        final aKey =
            (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase();
        final aVal = aEq < 0 ? '' : attr.substring(aEq + 1).trim();
        if (aKey == 'domain' && aVal.isNotEmpty) {
          final clean = aVal.replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
          if (clean.contains('.') &&
              InternetAddress.tryParse(clean) == null &&
              (reqHost == clean || reqHost.endsWith('.$clean'))) {
            domain = clean;
            hostOnly = false;
          }
        } else if (aKey == 'path' && aVal.startsWith('/')) {
          path = aVal;
        } else if (aKey == 'max-age') {
          final secs = int.tryParse(aVal);
          if (secs != null) {
            expiresAt = secs <= 0
                ? now.subtract(const Duration(seconds: 1))
                : now.add(Duration(seconds: secs));
          }
        } else if (aKey == 'expires' && expiresAt == null && aVal.isNotEmpty) {
          try {
            expiresAt = HttpDate.parse(aVal);
          } catch (_) {}
        }
      }

      final storageKey = '$domain|$hostOnly|$path|$name';
      if (value.isEmpty || (expiresAt != null && !expiresAt.isAfter(now))) {
        _cookies.remove(storageKey);
      } else if (_cookies.length < 256 || _cookies.containsKey(storageKey)) {
        _cookies[storageKey] = _StoredCookie(
          name: name,
          value: value,
          domain: domain,
          hostOnly: hostOnly,
          path: path,
          expiresAt: expiresAt,
        );
      }
    }
  }

  Map<String, String> matchingCookies(Uri uri, DateTime now) {
    final out = <String, String>{};
    final matched = _cookies.values.where((c) => c.matches(uri, now)).toList()
      ..sort((a, b) => a.path.length.compareTo(b.path.length));
    for (final c in matched) {
      out[c.name] = c.value;
    }
    return out;
  }

  void clear() => _cookies.clear();

  static String _defaultCookiePath(String reqPath) {
    if (reqPath.isEmpty || !reqPath.startsWith('/')) return '/';
    final lastSlash = reqPath.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : reqPath.substring(0, lastSlash);
  }
}

/// Session-scoped loopback media gateway (`http://127.0.0.1:<port>/<capability>/...`).
///
/// Handles anti-leech `Referer`/`User-Agent`/`Origin`, dynamic `Set-Cookie` jars,
/// cross-domain CDN redirects with strict credential-origin boundaries, extensionless
/// HLS `.m3u8` manifest rewriting, and fake PNG/JPG/GIF header stripping on MPEG-TS
/// segments so `libmpv` receives a clean local stream.
class LocalMediaLease {
  LocalMediaLease._(
    this._server,
    this._client,
    this._ownsClient,
    Uri initialTarget,
    this._headers,
    this._isCancelled,
    this._capability,
    this._clock,
  )   : _initialOrigin = _originOf(initialTarget),
        _created = _clock() {
    _initialUrl = _register(initialTarget, _inferInitialKind(initialTarget));
    _server.listen(_serve);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sweep());
  }

  static const int _maxConcurrentRequests = 16;
  static const int _flushThresholdBytes = 256 * 1024;
  static const int _maxPlaylistBytes = 4 * 1024 * 1024;
  static const int _sniffPrefixBytes = 4096;
  static const String _defaultBrowserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Set<String> _originBoundHeaderNames = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'cookie2',
    'x-api-key',
    'x-emby-token',
    'x-plex-token',
  };

  static const Set<String> _hopByHopHeaderNames = {
    'host',
    'connection',
    'keep-alive',
    'proxy-connection',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
    'content-length',
  };

  final HttpServer _server;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _initialOrigin;
  final Map<String, String> _headers;
  final bool Function() _isCancelled;
  final String _capability;
  final DateTime Function() _clock;
  final DateTime _created;
  final _cookieJar = _SessionCookieJar();
  final _targets = <String, _RegisteredTarget>{};
  final _paths = <String, String>{};
  final _requests = <HttpRequest>{};
  final _upstreams = <StreamSubscription<List<int>>>{};
  late final Uri _initialUrl;
  http.Client? _directOnlyClient;
  Timer? _timer;
  bool _closed = false;

  Uri get url => _initialUrl;
  bool get isClosed => _closed;

  /// Registers a companion stream (e.g. separate DASH `.m4s` audio track) onto
  /// this session's loopback gateway so it receives the same anti-leech headers.
  Uri? tryRegisterCompanionMedia(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !shouldProxy(parsed) || !_canRegisterTarget(parsed)) {
      return null;
    }
    try {
      return _register(parsed, _inferInitialKind(parsed));
    } catch (_) {
      return null;
    }
  }

  static bool isLoopbackHost(String host) {
    final bare = host.trim().toLowerCase();
    if (bare.isEmpty) return false;
    return bare == '127.0.0.1' ||
        bare == 'localhost' ||
        bare == '::1' ||
        bare == '[::1]' ||
        bare.startsWith('127.');
  }

  static bool shouldProxy(Uri? uri) =>
      uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !isLoopbackHost(uri.host);

  static bool isPrivateOrReservedTarget(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return true;
    if (isLoopbackHost(host) || host.endsWith('.localhost')) return true;
    final cleanHost = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    final ip = InternetAddress.tryParse(cleanHost);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
    final raw = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0], b = raw[1];
      if (a == 0 || a == 10 || a == 127) return true;
      if (a == 169 && b == 254) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 100 && b >= 64 && b <= 127) return true;
      return false;
    }
    if (ip.type == InternetAddressType.IPv6 && raw.length == 16) {
      final allZero = raw.every((b) => b == 0);
      if (allZero) return true;
      // Unique local fc00::/7
      if ((raw[0] & 0xFE) == 0xFC) return true;
      // IPv4-mapped ::ffff:a.b.c.d
      final v4Mapped = raw.take(10).every((b) => b == 0) &&
          raw[10] == 0xFF &&
          raw[11] == 0xFF;
      if (v4Mapped) {
        final v4 = '${raw[12]}.${raw[13]}.${raw[14]}.${raw[15]}';
        return isPrivateOrReservedTarget(Uri(scheme: 'http', host: v4));
      }
    }
    return false;
  }

  /// Detects a fake image/padding prefix (e.g. PNG/JPG/GIF/BMP header) prepended
  /// before an unencrypted 188-byte MPEG-TS packet stream and returns its byte offset.
  /// Returns `0` when the buffer is already standard media or no TS sync lock exists.
  static int findDisguisedTsOffset(Uint8List prefix) {
    if (prefix.length < 189 || prefix[0] == 0x47) return 0;
    // Standard elementary / container signatures that must never be stripped:
    // ID3 (packed audio HLS), #EXTM3U, WEBVTT, FLV, EBML (MKV/WebM), MP4/fMP4 boxes.
    if (prefix.length >= 3 &&
        prefix[0] == 0x49 &&
        prefix[1] == 0x44 &&
        prefix[2] == 0x33) {
      return 0;
    }
    if (prefix.length >= 7) {
      var s = 0;
      if (prefix[0] == 0xEF && prefix[1] == 0xBB && prefix[2] == 0xBF) s = 3;
      while (s < prefix.length &&
          (prefix[s] == 0x20 ||
              prefix[s] == 0x09 ||
              prefix[s] == 0x0D ||
              prefix[s] == 0x0A)) {
        s++;
      }
      if (s + 7 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 7)) == '#EXTM3U') {
        return 0;
      }
      if (s + 6 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 6)) == 'WEBVTT') {
        return 0;
      }
    }
    if (prefix.length >= 4 &&
        ((prefix[0] == 0x46 && prefix[1] == 0x4C && prefix[2] == 0x56) ||
            (prefix[0] == 0x1A &&
                prefix[1] == 0x45 &&
                prefix[2] == 0xDF &&
                prefix[3] == 0xA3))) {
      return 0;
    }
    if (prefix.length >= 8) {
      final box = latin1.decode(prefix.sublist(4, 8));
      if (const {'ftyp', 'styp', 'moof', 'moov', 'mdat', 'sidx', 'free', 'wide'}
          .contains(box)) {
        return 0;
      }
    }

    final maxOffset = math.min(prefix.length - 189, 3072);
    for (var i = 1; i <= maxOffset; i++) {
      if (prefix[i] != 0x47) continue;
      if (prefix.length >= i + 377) {
        if (prefix[i + 188] == 0x47 && prefix[i + 376] == 0x47) {
          return i;
        }
      } else if (prefix[i + 188] == 0x47) {
        return i;
      }
    }
    return 0;
  }

  static Future<LocalMediaLease> open({
    required Uri target,
    Map<String, String> headers = const {},
    required bool Function() isCancelled,
    DateTime Function()? clock,
    http.Client? client,
  }) async {
    if (!shouldProxy(target)) {
      throw const FormatException('本地媒体代理仅接受远程 HTTP/HTTPS 流地址');
    }
    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty ||
          key.contains('\r') ||
          key.contains('\n') ||
          value.contains('\r') ||
          value.contains('\n')) {
        continue;
      }
      if (_hopByHopHeaderNames.contains(key.toLowerCase())) continue;
      sanitized[key] = value;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = math.Random.secure();
    final capability = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final ownsClient = client == null;
    final transport = client ?? _createDirectFallbackHttpClient();
    return LocalMediaLease._(
      server,
      transport,
      ownsClient,
      target,
      sanitized,
      isCancelled,
      capability,
      clock ?? DateTime.now,
    );
  }

  static http.Client _createDirectFallbackHttpClient({bool directOnly = false}) {
    final io = HttpClient()
      ..autoUncompress = true
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    if (directOnly) {
      io.findProxy = (_) => 'DIRECT';
    }
    return IOClient(io);
  }

  static bool _isDeadLocalProxyError(Uri targetUri, Object error) {
    if (isLoopbackHost(targetUri.host)) return false;
    if (error is SocketException) {
      final host = error.address?.host ?? '';
      if (error.address?.isLoopback == true || isLoopbackHost(host)) {
        return true;
      }
    }
    if (error is http.ClientException || error is SocketException) {
      final msg = error.toString();
      final hitsLoopback = msg.contains('address = 127.0.0.1') ||
          msg.contains('address = ::1') ||
          msg.contains('address = localhost');
      final refused = msg.contains('Connection refused') ||
          msg.contains('errno = 61') ||
          msg.contains('errno = 111') ||
          msg.contains('errno = 10061');
      return hitsLoopback && refused;
    }
    return false;
  }

  static Uri _originOf(Uri uri) => Uri(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        port: uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80),
      );

  static bool _sameOrigin(Uri a, Uri b) =>
      _originOf(a).scheme == _originOf(b).scheme &&
      _originOf(a).host == _originOf(b).host &&
      _originOf(a).port == _originOf(b).port;

  static _TargetKind _inferInitialKind(Uri uri) {
    final lower = '${uri.path}?${uri.query}'.toLowerCase();
    if (lower.contains('.m3u8')) return _TargetKind.playlist;
    return _TargetKind.auto;
  }

  bool _canRegisterTarget(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
    if (_sameOrigin(uri, _initialOrigin)) return true;
    if (isPrivateOrReservedTarget(uri)) return false;
    return uri.host.contains('.') || InternetAddress.tryParse(uri.host) != null;
  }

  Uri _register(Uri target, _TargetKind kind) {
    if (_closed || !_canRegisterTarget(target) || _targets.length >= 65536) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    final key = '${kind.name}|$target';
    final path = _paths.putIfAbsent(key, () {
      String suffix;
      if (_targets.isEmpty) {
        final lowerPath = target.path.toLowerCase();
        if (lowerPath.endsWith('.m3u8') || kind == _TargetKind.playlist) {
          suffix = 'stream.m3u8';
        } else if (lowerPath.endsWith('.mp4')) {
          suffix = 'stream.mp4';
        } else if (lowerPath.endsWith('.mkv')) {
          suffix = 'stream.mkv';
        } else if (lowerPath.endsWith('.flv')) {
          suffix = 'stream.flv';
        } else {
          suffix = 'stream';
        }
      } else {
        String ext;
        if (kind == _TargetKind.playlist) {
          ext = '.m3u8';
        } else if (kind == _TargetKind.tsSegment) {
          ext = '.ts';
        } else {
          final lowerPath = target.path.toLowerCase();
          const safeExts = [
            '.m4s',
            '.mp4',
            '.ts',
            '.key',
            '.aac',
            '.vtt',
            '.mkv',
            '.flv',
          ];
          ext = safeExts.firstWhere(
            (candidate) => lowerPath.endsWith(candidate),
            orElse: () => '',
          );
        }
        suffix = 'part-${_targets.length}$ext';
      }
      final p = '/$_capability/$suffix';
      _targets[p] = _RegisteredTarget(target, kind);
      return p;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  Future<void> _sweep() async {
    if (_closed) return;
    if (_isCancelled() ||
        _clock().difference(_created) > const Duration(hours: 12)) {
      await close();
    }
  }

  bool _isAllowedLocalRequest(HttpRequest request) {
    final hostHeader = request.headers.value(HttpHeaders.hostHeader);
    if (hostHeader != null && hostHeader.isNotEmpty) {
      final hostOnly = hostHeader.startsWith('[')
          ? hostHeader.substring(0, hostHeader.indexOf(']') + 1)
          : hostHeader.split(':').first;
      if (!isLoopbackHost(hostOnly)) return false;
    }
    final origin = request.headers.value('origin');
    if (origin != null && origin.isNotEmpty) return false;
    final secFetch = request.headers.value('sec-fetch-site')?.trim().toLowerCase();
    if (secFetch != null &&
        secFetch.isNotEmpty &&
        secFetch != 'none' &&
        secFetch != 'same-origin') {
      return false;
    }
    return true;
  }

  Map<String, String> _buildUpstreamHeaders(
    Uri target, {
    String? range,
    String? ifRange,
    required bool allowRange,
  }) {
    final sameOrigin = _sameOrigin(target, _initialOrigin);
    final out = <String, String>{};
    var hasUa = false;
    String? initialCookie;

    for (final entry in _headers.entries) {
      final lower = entry.key.toLowerCase();
      if (_hopByHopHeaderNames.contains(lower)) continue;
      if (!sameOrigin && _originBoundHeaderNames.contains(lower)) continue;
      if (lower == 'user-agent') hasUa = true;
      if (lower == 'cookie') {
        initialCookie = entry.value;
        continue;
      }
      out[entry.key] = entry.value;
    }
    if (!hasUa) {
      out['User-Agent'] = _defaultBrowserUa;
    }

    final mergedCookies = <String, String>{};
    if (initialCookie != null && initialCookie.isNotEmpty) {
      for (final pair in initialCookie.split(';')) {
        final trimmed = pair.trim();
        final eq = trimmed.indexOf('=');
        if (eq > 0) {
          mergedCookies[trimmed.substring(0, eq).trim()] =
              trimmed.substring(eq + 1).trim();
        }
      }
    }
    mergedCookies.addAll(_cookieJar.matchingCookies(target, _clock()));
    if (mergedCookies.isNotEmpty) {
      out['Cookie'] =
          mergedCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    if (allowRange && range != null && range.isNotEmpty) {
      out['Accept-Encoding'] = 'identity';
      out['Range'] = range;
      if (ifRange != null && ifRange.isNotEmpty) {
        out['If-Range'] = ifRange;
      }
    }
    return out;
  }

  Future<(http.StreamedResponse, Uri)> _sendWithRedirects(
    Uri initialTarget, {
    required String method,
    String? range,
    String? ifRange,
    required bool allowRange,
  }) async {
    var current = initialTarget;
    for (var redirects = 0;; redirects++) {
      http.Request makeReq() => http.Request(method, current)
        ..followRedirects = false
        ..headers.addAll(_buildUpstreamHeaders(
          current,
          range: range,
          ifRange: ifRange,
          allowRange: allowRange,
        ));
      http.StreamedResponse response;
      try {
        final activeTransport = _directOnlyClient ?? _client;
        response = await activeTransport
            .send(makeReq())
            .timeout(const Duration(seconds: 25));
      } catch (error) {
        if (_ownsClient &&
            _directOnlyClient == null &&
            !_closed &&
            !_isCancelled() &&
            _isDeadLocalProxyError(current, error)) {
          _directOnlyClient = _createDirectFallbackHttpClient(directOnly: true);
          response = await _directOnlyClient!
              .send(makeReq())
              .timeout(const Duration(seconds: 25));
        } else {
          rethrow;
        }
      }
      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('cancelled');
      }
      _cookieJar.storeFromHeaders(response.headers, current, _clock());

      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return (response, current);
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      if (location == null || location.trim().isEmpty || redirects >= 6) {
        throw const FormatException('媒体重定向次数过多或地址缺失');
      }
      final next = current.resolve(location.trim()).removeFragment();
      if (!_canRegisterTarget(next)) {
        throw const FormatException('媒体重定向目标不受信任');
      }
      current = next;
    }
  }

  static bool _startsWithM3u8Magic(List<int> bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0D ||
            bytes[i] == 0x0A)) {
      i++;
    }
    if (bytes.length - i < 7) return false;
    return latin1.decode(bytes.sublist(i, i + 7)) == '#EXTM3U';
  }

  static bool _hasNonZeroRangeStart(String? range) {
    if (range == null || range.isEmpty) return false;
    final match = RegExp(r'^bytes=(\d+)-').firstMatch(range.trim());
    if (match == null) return true;
    return (int.tryParse(match.group(1)!) ?? 0) > 0;
  }

  Future<void> _serve(HttpRequest request) async {
    if (_closed || _isCancelled()) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    if (!_isAllowedLocalRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final registered = _targets[request.uri.path];
    if (registered == null) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (_requests.length >= _maxConcurrentRequests) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    _requests.add(request);
    try {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final isExplicitPlaylist = registered.kind == _TargetKind.playlist ||
          registered.uri.path.toLowerCase().endsWith('.m3u8');
      final (response, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: request.method,
        range: range,
        ifRange: ifRange,
        allowRange: !isExplicitPlaylist,
      );

      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = response.statusCode;
        return;
      }

      final mime = (response.headers['content-type'] ?? '').toLowerCase();
      final knownPlaylist = isExplicitPlaylist ||
          mime.contains('mpegurl') ||
          finalTarget.path.toLowerCase().endsWith('.m3u8');

      if (request.method == 'HEAD') {
        _copyResponseHeaders(response, request.response);
        if (knownPlaylist) {
          request.response.headers
              .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
        }
        await response.stream.listen((_) {}).cancel();
        return;
      }

      if (knownPlaylist) {
        final body = await _readBoundedBody(response.stream, _maxPlaylistBytes);
        final text = utf8.decode(body, allowMalformed: true);
        if (_startsWithM3u8Magic(body)) {
          await _respondPlaylist(request.response, text, finalTarget);
          return;
        }
        _copyResponseHeaders(response, request.response);
        request.response.contentLength = body.length;
        request.response.add(body);
        return;
      }

      // Sniff prefix for extensionless #EXTM3U playlists or disguised TS segments.
      final shouldSniffPrefix = !_hasNonZeroRangeStart(range) &&
          (registered.kind == _TargetKind.tsSegment ||
              (registered.kind == _TargetKind.auto &&
                  (mime.isEmpty ||
                      mime.contains('text/plain') ||
                      mime.contains('octet-stream'))));

      if (shouldSniffPrefix) {
        await _serveWithPrefixInspection(
          response,
          finalTarget,
          registered.kind,
          request.response,
        );
        return;
      }

      _copyResponseHeaders(response, request.response);
      request.response.statusCode = response.statusCode;
      await _pipeMediaStream(response.stream, request.response);
    } on StateError {
      try {
        request.response.statusCode = HttpStatus.gone;
      } catch (_) {}
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      _requests.remove(request);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _copyResponseHeaders(
      http.StreamedResponse upstream, HttpResponse downstream) {
    downstream.statusCode = upstream.statusCode;
    for (final key in const [
      'content-type',
      'content-length',
      'content-range',
      'accept-ranges',
      'etag',
      'last-modified',
    ]) {
      final value = upstream.headers[key];
      if (value != null && value.isNotEmpty) {
        downstream.headers.set(key, value);
      }
    }
    downstream.headers.set('cache-control', 'no-store');
  }

  Future<Uint8List> _readBoundedBody(
      Stream<List<int>> stream, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (_closed || _isCancelled()) throw StateError('cancelled');
      if (builder.length + chunk.length > maxBytes) {
        throw const FormatException('媒体播放列表体积超出安全上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _respondPlaylist(
      HttpResponse downstream, String playlistText, Uri playlistOrigin) async {
    final rewritten = _rewritePlaylist(playlistText, playlistOrigin);
    final encoded = utf8.encode(rewritten);
    downstream.statusCode = HttpStatus.ok;
    downstream.headers.removeAll('content-range');
    downstream.headers
        .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
    downstream.headers.set('cache-control', 'no-store');
    downstream.contentLength = encoded.length;
    downstream.add(encoded);
  }

  Future<void> _serveWithPrefixInspection(
    http.StreamedResponse upstream,
    Uri finalTarget,
    _TargetKind kind,
    HttpResponse downstream,
  ) async {
    final iterator = StreamIterator<List<int>>(upstream.stream);
    final prefixBuilder = BytesBuilder(copy: false);
    var streamEnded = false;
    try {
      while (prefixBuilder.length < _sniffPrefixBytes) {
        final hasMore =
            await iterator.moveNext().timeout(const Duration(seconds: 25));
        if (!hasMore) {
          streamEnded = true;
          break;
        }
        if (_closed || _isCancelled()) throw StateError('cancelled');
        prefixBuilder.add(iterator.current);
        if (_startsWithM3u8Magic(prefixBuilder.toBytes()) &&
            prefixBuilder.length >= 7) {
          break;
        }
      }

      final prefix = prefixBuilder.takeBytes();
      if (_startsWithM3u8Magic(prefix)) {
        final fullBuilder = BytesBuilder(copy: false)..add(prefix);
        if (!streamEnded) {
          while (await iterator
              .moveNext()
              .timeout(const Duration(seconds: 30))) {
            if (_closed || _isCancelled()) throw StateError('cancelled');
            if (fullBuilder.length + iterator.current.length >
                _maxPlaylistBytes) {
              throw const FormatException('媒体播放列表体积超出安全上限');
            }
            fullBuilder.add(iterator.current);
          }
        }
        final text = utf8.decode(fullBuilder.takeBytes(), allowMalformed: true);
        await _respondPlaylist(downstream, text, finalTarget);
        return;
      }

      final skip =
          kind == _TargetKind.tsSegment ? findDisguisedTsOffset(prefix) : 0;
      _copyResponseHeaders(upstream, downstream);
      if (skip > 0) {
        downstream.statusCode = HttpStatus.ok;
        downstream.headers.removeAll('content-range');
        downstream.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
        final rawLen = int.tryParse(upstream.headers['content-length'] ?? '');
        if (rawLen != null && rawLen >= skip) {
          downstream.contentLength = rawLen - skip;
        } else {
          downstream.headers.removeAll(HttpHeaders.contentLengthHeader);
        }
      }

      final initialSlice = skip > 0 ? prefix.sublist(skip) : prefix;
      if (initialSlice.isNotEmpty) {
        downstream.add(initialSlice);
      }
      if (streamEnded) return;

      Stream<List<int>> remaining() async* {
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      }

      await _pipeMediaStream(remaining(), downstream);
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {}
    }
  }

  Future<void> _pipeMediaStream(
    Stream<List<int>> source,
    HttpResponse sink,
  ) async {
    final done = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var finished = false;
    var pendingBytes = 0;

    Future<void> finish([Object? error, StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      final sub = subscription;
      if (sub != null) {
        _upstreams.remove(sub);
        try {
          await sub.cancel();
        } catch (_) {}
      }
      if (!done.isCompleted) {
        if (error != null) {
          done.completeError(error, stackTrace);
        } else {
          done.complete();
        }
      }
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 30), () {
        unawaited(finish(TimeoutException('upstream media idle')));
      });
    }

    unawaited(sink.done.then((_) => finish(), onError: (_) => finish()));
    resetIdleTimer();
    subscription = source.listen(
      (chunk) {
        if (finished || _closed || _isCancelled()) {
          unawaited(finish());
          return;
        }
        resetIdleTimer();
        try {
          sink.add(chunk);
        } catch (_) {
          unawaited(finish());
          return;
        }
        pendingBytes += chunk.length;
        if (pendingBytes >= _flushThresholdBytes) {
          pendingBytes = 0;
          subscription?.pause(
            sink
                .flush()
                .timeout(const Duration(seconds: 30))
                .catchError((_) => finish()),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(finish(error, stackTrace));
      },
      onDone: () {
        unawaited(finish());
      },
      cancelOnError: true,
    );
    _upstreams.add(subscription);
    await done.future;
    if (!_closed && !_isCancelled() && pendingBytes > 0) {
      try {
        await sink.flush().timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
  }

  String _rewritePlaylist(String text, Uri origin) {
    var encrypted = false;
    var hasInitMap = false;
    var expectVariant = false;

    String rewriteUri(String rawUri, _TargetKind kind) {
      final cleaned = rawUri.trim();
      if (cleaned.isEmpty || cleaned.startsWith('data:')) return rawUri;
      final resolved = origin.resolve(cleaned);
      if (!_canRegisterTarget(resolved)) {
        throw const FormatException('播放列表包含不受信任的分片地址');
      }
      return _register(resolved, kind).toString();
    }

    final out = <String>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
          expectVariant = true;
          out.add(line);
          continue;
        }
        if (trimmed.startsWith('#EXT-X-KEY:')) {
          final methodMatch =
              RegExp(r'METHOD=([^,\s]+)', caseSensitive: false).firstMatch(trimmed);
          final method = methodMatch?.group(1)?.trim().toUpperCase() ?? 'NONE';
          encrypted = method != 'NONE';
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.raw)}"',
          ));
          continue;
        }
        if (trimmed.startsWith('#EXT-X-MAP:')) {
          hasInitMap = true;
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.raw)}"',
          ));
          continue;
        }
        if (trimmed.startsWith('#EXT-X-MEDIA:') ||
            trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.playlist)}"',
          ));
          continue;
        }
        out.add(line);
        continue;
      }

      final resolved = origin.resolve(trimmed);
      final looksPlaylist = expectVariant ||
          resolved.path.toLowerCase().endsWith('.m3u8');
      expectVariant = false;
      final kind = looksPlaylist
          ? _TargetKind.playlist
          : ((!encrypted && !hasInitMap)
              ? _TargetKind.tsSegment
              : _TargetKind.raw);
      out.add(rewriteUri(trimmed, kind));
    }
    return out.join('\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _headers.clear();
    _cookieJar.clear();
    _targets.clear();
    _paths.clear();
    final activeUpstreams = _upstreams.toList();
    _upstreams.clear();
    for (final sub in activeUpstreams) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    if (_ownsClient) {
      _client.close();
      _directOnlyClient?.close();
      _directOnlyClient = null;
    }
    await _server.close(force: true);
  }
}

/// Owns the active episode's local `127.0.0.1` gateway lease in `PlayerScreen`.
class PlayerLocalMediaSession {
  LocalMediaLease? _current;
  LocalMediaLease? get current => _current;

  bool owns(LocalMediaLease? lease) =>
      lease != null && identical(lease, _current);

  void adopt(LocalMediaLease? lease) => _current = lease;

  LocalMediaLease? detach() {
    final previous = _current;
    _current = null;
    return previous;
  }

  Future<void> releaseUnless(LocalMediaLease? keep) async {
    if (!owns(keep)) await detach()?.close();
  }

  Future<void> discard(LocalMediaLease? lease) async {
    if (lease != null && !owns(lease)) await lease.close();
  }
}

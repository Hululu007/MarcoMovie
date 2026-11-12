import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP client wrapper that falls back to a direct socket (`DIRECT`) when the
/// operating system's configured local proxy port is closed (`Connection refused`).
class ResilientHttpClient extends http.BaseClient {
  ResilientHttpClient({
    this.autoUncompress = true,
    this.maxConnectionsPerHost = 8,
    this.connectionTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 25),
  }) : _useOverrides = HttpOverrides.current != null {
    _primary = _useOverrides ? http.Client() : _buildIoClient(direct: false);
  }

  final bool autoUncompress;
  final int maxConnectionsPerHost;
  final Duration connectionTimeout;
  final Duration idleTimeout;
  final bool _useOverrides;

  late final http.Client _primary;
  http.Client? _direct;
  bool _preferDirect = false;
  bool _closed = false;

  http.Client _buildIoClient({required bool direct}) {
    final io = HttpClient()
      ..autoUncompress = autoUncompress
      ..maxConnectionsPerHost = maxConnectionsPerHost
      ..connectionTimeout = connectionTimeout
      ..idleTimeout = idleTimeout;
    if (direct) {
      io.findProxy = (_) => 'DIRECT';
    }
    return IOClient(io);
  }

  static bool isLoopbackHost(String host) {
    final clean = host.trim().toLowerCase();
    if (clean.isEmpty) return false;
    if (clean == 'localhost' || clean.endsWith('.localhost')) return true;
    final stripped = clean.startsWith('[') && clean.endsWith(']')
        ? clean.substring(1, clean.length - 1)
        : clean;
    return InternetAddress.tryParse(stripped)?.isLoopback == true;
  }

  /// Detects when a desktop/mobile system HTTP proxy points to a closed local
  /// tunnel while dialing a non-loopback target host.
  static bool isDeadLocalSystemProxyError(Uri targetUri, Object error) {
    if (isLoopbackHost(targetUri.host)) return false;
    if (error is SocketException) {
      final addr = error.address;
      if (addr != null && (addr.isLoopback || isLoopbackHost(addr.host))) {
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

  static http.Request? _cloneRequest(http.BaseRequest original) {
    if (original is! http.Request) return null;
    final copy = http.Request(original.method, original.url)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection
      ..headers.addAll(original.headers)
      ..bodyBytes = original.bodyBytes;
    return copy;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('HTTP client is closed', request.url);
    }
    if (_useOverrides || isLoopbackHost(request.url.host)) {
      return _primary.send(request);
    }
    if (_preferDirect) {
      final direct = _direct ??= _buildIoClient(direct: true);
      return direct.send(request);
    }
    final backup = _cloneRequest(request);
    try {
      return await _primary.send(request);
    } catch (error) {
      if (!_closed &&
          backup != null &&
          isDeadLocalSystemProxyError(request.url, error)) {
        _preferDirect = true;
        final direct = _direct ??= _buildIoClient(direct: true);
        return direct.send(backup);
      }
      rethrow;
    }
  }

  @override
  void close() {
    _closed = true;
    _primary.close();
    _direct?.close();
    _direct = null;
  }

  static String? cloudProviderForHost(String rawHost) {
    final host = rawHost.trim().toLowerCase();
    if (host == 'pan.quark.cn') return 'quark';
    if (host == 'drive.uc.cn' || host == 'fast.uc.cn') return 'uc';
    if (host == 'pan.baidu.com') return 'baidu';
    if (const {
      'www.alipan.com',
      'alipan.com',
      'www.aliyundrive.com',
      'aliyundrive.com',
    }.contains(host)) {
      return 'ali';
    }
    return null;
  }

  static String? cloudProviderForShare(String raw) {
    final normalized = normalizeCloudShareUrl(raw);
    if (normalized == null) return null;
    final uri = Uri.tryParse(normalized);
    return uri == null ? null : cloudProviderForHost(uri.host);
  }

  /// Extracts and normalizes a supported netdisk share URL (with optional
  /// passcode such as `提取码: xxxx` or `#pwd=xxxx`).
  ///
  /// When [strictClipboard] is true, ambiguous multi-link or conflicting
  /// passcode strings throw [FormatException] instead of returning `null`.
  static String? normalizeCloudShareUrl(
    String raw, {
    bool strictClipboard = false,
  }) {
    if (raw.length > 16 * 1024) {
      if (strictClipboard) throw const FormatException('分享信息过长');
      return null;
    }
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!strictClipboard) {
      if (text.startsWith('mmshare://')) {
        text = text.substring('mmshare://'.length).trim();
      } else if (text.toLowerCase().startsWith('push://')) {
        text = text.substring('push://'.length).trim();
        if (text.toLowerCase().startsWith('http%3a') ||
            text.toLowerCase().startsWith('https%3a')) {
          try {
            text = Uri.decodeComponent(text).trim();
          } catch (_) {}
        }
      }
    }

    final schemeMatches =
        RegExp(r'https?://', caseSensitive: false).allMatches(text).toList();
    if (schemeMatches.isEmpty) return null;
    if (strictClipboard && schemeMatches.length != 1) {
      throw const FormatException('分享链接不明确');
    }

    final urlMatch = RegExp(
      r'https?://[^\s<>"\x27\u4e00-\u9fff，。；！？（）【】]+',
      caseSensitive: false,
    ).firstMatch(text);
    final candidateLink = urlMatch?.group(0)?.replaceAll(RegExp(r'[,;.|]+$'), '');
    if (candidateLink == null || candidateLink.isEmpty) {
      if (strictClipboard) throw const FormatException('分享地址或提取码不明确');
      return null;
    }

    final uri = Uri.tryParse(candidateLink);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 80 && uri.port != 443)) {
      if (strictClipboard) throw const FormatException('分享地址或提取码不明确');
      return null;
    }

    final provider = cloudProviderForHost(uri.host);
    if (provider == null) {
      return strictClipboard ? raw : null;
    }

    final hasCodeLabel = text.contains('提取码') ||
        RegExp(r'(?:^|[\s,;|])(?:pwd|passcode|password)\s*[:：=]',
                caseSensitive: false)
            .hasMatch(text.substring(urlMatch!.end));
    final codeMatches = RegExp(
      r'(?:提取码|(?:^|[\s,;|])(?:pwd|passcode|password))\s*[:：=]?\s*([A-Za-z0-9]{4})(?![A-Za-z0-9])',
      caseSensitive: false,
    ).allMatches(text).toList();

    if (strictClipboard && text.contains('提取码') && codeMatches.length != 1) {
      throw const FormatException('分享地址或提取码不明确');
    }
    if (strictClipboard && (uri.queryParametersAll['pwd']?.length ?? 0) > 1) {
      throw const FormatException('分享地址或提取码不明确');
    }

    String? extraPwd = codeMatches.length == 1 ? codeMatches.single.group(1) : null;
    if (extraPwd == null && uri.fragment.isNotEmpty) {
      final fragPwd = RegExp(
        r'(?:^|[?&#])(?:pwd|passcode|password)=([A-Za-z0-9]{4})(?:&|$)',
        caseSensitive: false,
      ).firstMatch(uri.fragment);
      if (fragPwd != null) extraPwd = fragPwd.group(1);
    }

    var normalizedUri = uri;
    if (provider == 'baidu' && uri.path == '/share/init') {
      final surl = (uri.queryParameters['surl'] ?? '').trim();
      if (!RegExp(r'^[A-Za-z0-9_-]{3,80}$').hasMatch(surl)) {
        if (strictClipboard) throw const FormatException('分享地址或提取码不明确');
        return null;
      }
      final fullId = surl.startsWith('1') ? surl : '1$surl';
      final nextQuery = Map<String, List<String>>.from(uri.queryParametersAll)
        ..remove('surl');
      normalizedUri = uri.replace(
        path: '/s/$fullId',
        queryParameters: nextQuery.isEmpty ? null : nextQuery,
      );
    } else if (provider == 'ali') {
      final segs = uri.pathSegments;
      final validAliPath = segs.length >= 2 &&
          segs[0] == 's' &&
          RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(segs[1]) &&
          (segs.length == 2 ||
              (segs.length == 4 &&
                  segs[2] == 'folder' &&
                  RegExp(r'^[A-Za-z0-9_-]{1,160}$').hasMatch(segs[3])));
      if (!validAliPath) {
        if (strictClipboard) throw const FormatException('分享地址或提取码不明确');
        return null;
      }
    } else {
      if (!RegExp(r'^/s/[A-Za-z0-9_-]{1,128}/?$').hasMatch(uri.path)) {
        if (strictClipboard) throw const FormatException('分享地址或提取码不明确');
        return null;
      }
    }

    final existingPwd = normalizedUri.queryParameters['pwd'] ??
        normalizedUri.queryParameters['passcode'] ??
        normalizedUri.queryParameters['password'];
    if (extraPwd != null && extraPwd.isNotEmpty) {
      if (existingPwd != null &&
          existingPwd.isNotEmpty &&
          existingPwd != extraPwd) {
        if (strictClipboard) throw const FormatException('分享提取码不一致');
        return null;
      }
      if (existingPwd == null || existingPwd.isEmpty) {
        normalizedUri = normalizedUri.replace(queryParameters: {
          ...normalizedUri.queryParametersAll,
          'pwd': [extraPwd],
        });
      }
    } else if (hasCodeLabel && strictClipboard && (existingPwd ?? '').isEmpty) {
      throw const FormatException('分享地址或提取码不明确');
    }

    // Preserve plain URL byte-for-byte when no normalization was required.
    if (candidateLink == raw.trim() &&
        extraPwd == null &&
        normalizedUri.path == uri.path) {
      return candidateLink;
    }
    return normalizedUri.removeFragment().toString();
  }
}

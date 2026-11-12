import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'storage_service.dart';

typedef LanSyncAppliedCallback = void Function({
  required int historyCount,
  required int favoriteCount,
  required int subscriptionCount,
  required bool changed,
  required bool subscriptionsChanged,
});

/// Short-lived, token-scoped LAN HTTP receiver compatible with Android's
/// `ConfigTransferServer` (`/configure/<token>` and `/configure/<token>/sync`).
class LanSyncServer {
  final StorageService storage;
  final LanSyncAppliedCallback? onSynced;
  final HttpServer _server;
  final String tokenPath;
  final DateTime expiresAt;
  bool _closed = false;
  bool _busy = false;

  LanSyncServer._({
    required this.storage,
    required HttpServer server,
    required this.tokenPath,
    required this.expiresAt,
    this.onSynced,
  }) : _server = server {
    _server.listen(
      _handleRequest,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  int get port => _server.port;
  bool get isClosed => _closed;
  bool get isExpired => _closed || DateTime.now().isAfter(expiresAt);

  static const String _httpPrefix = 'http://';

  String addressForHost(String host) => '$_httpPrefix$host:$port$tokenPath';
  String syncEndpointForHost(String host) => '${addressForHost(host)}/sync';

  static Future<LanSyncServer> start(
    StorageService storage, {
    Duration ttl = const Duration(minutes: 5),
    InternetAddress? bindAddress,
    int port = 0,
    LanSyncAppliedCallback? onSynced,
  }) async {
    final rng = Random.secure();
    final tokenBytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final token = tokenBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
    );
    server.idleTimeout = const Duration(seconds: 15);
    return LanSyncServer._(
      storage: storage,
      server: server,
      tokenPath: '/configure/$token',
      expiresAt: DateTime.now().add(ttl),
      onSynced: onSynced,
    );
  }

  static bool isAllowedPeerAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final raw = address.rawAddress;
    if (raw.length == 4) {
      final b0 = raw[0];
      final b1 = raw[1];
      if (b0 == 10) return true;
      if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
      if (b0 == 192 && b1 == 168) return true;
      if (b0 == 169 && b1 == 254) return true;
      if (b0 == 100 && b1 >= 64 && b1 <= 127) return true;
      return false;
    }
    if (raw.length == 16) {
      // IPv4-mapped IPv6 ::ffff:a.b.c.d
      var v4Mapped = true;
      for (var i = 0; i < 10; i++) {
        if (raw[i] != 0) {
          v4Mapped = false;
          break;
        }
      }
      if (v4Mapped && raw[10] == 0xff && raw[11] == 0xff) {
        final b0 = raw[12];
        final b1 = raw[13];
        if (b0 == 127 || b0 == 10) return true;
        if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
        if (b0 == 192 && b1 == 168) return true;
        if (b0 == 169 && b1 == 254) return true;
        if (b0 == 100 && b1 >= 64 && b1 <= 127) return true;
      }
      // Unique local fc00::/7
      if ((raw[0] & 0xfe) == 0xfc) return true;
    }
    return false;
  }

  /// Discovers active non-loopback LAN IPv4 addresses sorted with physical Wi-Fi /
  /// Ethernet interfaces ahead of virtual bridge interfaces.
  static Future<List<String>> discoverLanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final candidates = <({String ip, int score})>[];
      for (final iface in interfaces) {
        final lowerName = iface.name.toLowerCase();
        final isVirtual = lowerName.contains('vethernet') ||
            lowerName.contains('wsl') ||
            lowerName.contains('vmware') ||
            lowerName.contains('vbox') ||
            lowerName.contains('virtual') ||
            lowerName.contains('docker') ||
            lowerName.contains('utun') ||
            lowerName.startsWith('tun') ||
            lowerName.startsWith('tap');
        for (final addr in iface.addresses) {
          if (!isAllowedPeerAddress(addr) || addr.isLoopback) continue;
          final raw = addr.rawAddress;
          if (raw.length != 4) continue;
          if (raw[0] == 169 && raw[1] == 254) continue;
          var score = isVirtual ? 10 : 100;
          if (raw[0] == 192 && raw[1] == 168) {
            score += 30;
          } else if (raw[0] == 10) {
            score += 20;
          } else if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) {
            score += 15;
          }
          if (lowerName.contains('wi-fi') ||
              lowerName.contains('wlan') ||
              lowerName == 'en0' ||
              lowerName.contains('eth')) {
            score += 10;
          }
          candidates.add((ip: addr.address, score: score));
        }
      }
      candidates.sort((a, b) => b.score.compareTo(a.score));
      final seen = <String>{};
      return [
        for (final c in candidates)
          if (seen.add(c.ip)) c.ip,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    try {
      final conn = req.connectionInfo;
      final peer = conn?.remoteAddress;
      if (peer == null || !isAllowedPeerAddress(peer)) {
        await _sendText(res, HttpStatus.forbidden, '仅允许局域网设备访问');
        return;
      }
      final reqPath = req.uri.path;
      final syncPath = '$tokenPath/sync';
      if (reqPath != tokenPath && reqPath != syncPath) {
        await _sendText(res, HttpStatus.notFound, '页面不存在');
        return;
      }
      if (isExpired) {
        await _sendText(res, HttpStatus.gone, '局域网同步会话已过期，请重新打开接收码');
        return;
      }
      final origin = req.headers.value('origin');
      if (origin != null && origin.isNotEmpty) {
        final hostHeader = req.headers.value(HttpHeaders.hostHeader) ?? '';
        if (origin != '$_httpPrefix$hostHeader') {
          await _sendText(res, HttpStatus.forbidden, '来源校验未通过');
          return;
        }
      }

      if (reqPath == tokenPath) {
        if (req.method == 'GET') {
          final hostHeader = req.headers.value(HttpHeaders.hostHeader) ??
              '127.0.0.1:$port';
          final fullUrl = '$_httpPrefix$hostHeader$tokenPath';
          await _sendHtml(res, HttpStatus.ok, _buildInfoHtml(fullUrl));
          return;
        }
        await _sendText(res, HttpStatus.methodNotAllowed, '请求方式不支持');
        return;
      }

      // /configure/<token>/sync
      if (req.method == 'GET') {
        final payload = storage.exportSyncPayload();
        await _sendJson(res, HttpStatus.ok, payload);
        return;
      }
      if (req.method != 'POST') {
        await _sendText(res, HttpStatus.methodNotAllowed, '请求方式不支持');
        return;
      }
      if (_busy) {
        await _sendText(res, HttpStatus.conflict, '正在处理上一次同步，请稍候重试');
        return;
      }
      _busy = true;
      try {
        final bytes = await _readBoundedBody(
          req,
          StorageService.maxSyncPayloadBytes,
        );
        final bodyText = utf8.decode(bytes);
        final now = DateTime.now().millisecondsSinceEpoch;
        final merged = await storage.mergeSyncPayload(bodyText, nowMs: now);
        onSynced?.call(
          historyCount: merged.historyCount,
          favoriteCount: merged.favoriteCount,
          subscriptionCount: merged.subscriptionCount,
          changed: merged.changed,
          subscriptionsChanged: merged.subscriptionsChanged,
        );
        await _sendJson(res, HttpStatus.ok, merged.payloadJson);
      } on _PayloadTooLargeException {
        await _sendText(res, HttpStatus.requestEntityTooLarge, '同步数据超过 8 MB 限制');
      } on FormatException catch (e) {
        await _sendText(res, HttpStatus.badRequest, e.message);
      } finally {
        _busy = false;
      }
    } catch (_) {
      try {
        await _sendText(res, HttpStatus.internalServerError, '局域网同步处理失败');
      } catch (_) {}
    }
  }

  static Future<List<int>> _readBoundedBody(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxBytes) {
        throw const _PayloadTooLargeException();
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<void> _sendText(
    HttpResponse res,
    int status,
    String text,
  ) async {
    res.statusCode = status;
    res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
    res.add(utf8.encode(text));
    await res.close();
  }

  static Future<void> _sendJson(
    HttpResponse res,
    int status,
    String jsonText,
  ) async {
    res.statusCode = status;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.add(utf8.encode(jsonText));
    await res.close();
  }

  static Future<void> _sendHtml(
    HttpResponse res,
    int status,
    String htmlText,
  ) async {
    res.statusCode = status;
    res.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
    res.add(utf8.encode(htmlText));
    await res.close();
  }

  static String _escapeHtml(String s) => const HtmlEscape().convert(s);

  static String _buildInfoHtml(String fullUrl) {
    final safe = _escapeHtml(fullUrl);
    return '<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Marco Movie 局域网同步</title>'
        '<style>body{margin:0;background:#101013;color:#f5f5f7;font:16px system-ui;padding:28px}'
        'main{max-width:520px;margin:8vh auto}h1{font-size:26px;margin-bottom:10px}'
        'p{line-height:1.65;color:#bfbfc7}code{display:block;background:#1c1c20;'
        'padding:14px 16px;border-radius:14px;color:#64d2ff;word-break:break-all;margin:14px 0}</style>'
        '<main><h1>Marco Movie 局域网双向同步</h1>'
        '<p>请在另一台设备的 <b>Marco Movie → 设置 → 多端网络同步</b> 中粘贴下方局域网地址，点击「立即双向同步」即可合并观看进度、收藏与公开订阅源：</p>'
        '<code>$safe</code>'
        '<p>本次接收会话有效期 5 分钟，关闭同步页面后自动失效。</p></main></html>';
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _server.close(force: true);
    } catch (_) {}
  }
}

class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
}

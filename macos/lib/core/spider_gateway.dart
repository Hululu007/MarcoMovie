import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'models.dart';
import 'spider_plugin_registry.dart';

/// Health report returned by a user-owned BYO Spider Gateway (`GET /marco-gateway/v1/health`).
class SpiderGatewayHealth {
  final bool ok;
  final String protocol;
  final String deviceName;
  final String engine;
  final bool supportsNativeSo;
  final int latencyMs;
  final String message;

  const SpiderGatewayHealth({
    required this.ok,
    this.protocol = '',
    this.deviceName = '',
    this.engine = '',
    this.supportsNativeSo = false,
    this.latencyMs = 0,
    this.message = '',
  });
}

/// Discovered LAN Spider Gateway advertised by a user's own Android device or
/// local Docker/NAS container over UDP broadcast (`port 41978`).
///
/// Discovery payloads NEVER include the Bearer token; the user pairs using the
/// token displayed on their Android device or self-hosted container.
class DiscoveredSpiderGateway {
  final String baseUrl;
  final String deviceName;
  final String engine;
  final bool supportsNativeSo;
  final bool requiresToken;

  const DiscoveredSpiderGateway({
    required this.baseUrl,
    required this.deviceName,
    this.engine = 'android-csp',
    this.supportsNativeSo = true,
    this.requiresToken = true,
  });
}

/// Client for the open `marco-spider-gateway-v1` BYO protocol.
///
/// Marco Movie does NOT host or bundle any central spider gateway. This client
/// ONLY communicates with a user-configured LAN Android companion device or a
/// user's own self-hosted Docker/NAS gateway, and ONLY handles lightweight JSON
/// metadata (`home / category / search / detail / play`). Actual video streams
/// are played directly by the local client.
class SpiderGatewayClient {
  static const String protocolId = 'marco-spider-gateway-v1';
  static const int discoveryUdpPort = 41978;
  static const String discoveryProbePayload = 'MARCO_SPIDER_GATEWAY_PROBE_V1';
  static const int maxResponseBytes = 8 * 1024 * 1024;

  static http.Client _createDirectClient() {
    final ioHttp = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'DIRECT';
    return IOClient(ioHttp);
  }

  static Map<String, String> _headersFor(
    SpiderGatewayConfig config, {
    bool jsonBody = false,
  }) {
    final h = <String, String>{
      'Accept': 'application/json',
      'X-Marco-Gateway-Protocol': protocolId,
      if (jsonBody) 'Content-Type': 'application/json; charset=utf-8',
    };
    final tok = config.token.trim();
    if (tok.isNotEmpty) {
      h['Authorization'] = 'Bearer $tok';
    }
    return h;
  }

  static Uri _endpointUri(SpiderGatewayConfig config, String path) {
    final base = config.normalizedBaseUrl;
    if (base.isEmpty) {
      throw const FormatException('请先填写有效的蜘蛛网关地址（http:// 或 https://）');
    }
    return Uri.parse('$base$path');
  }

  static String _sanitizeError(Object error) {
    final raw = error.toString().trim();
    final cleaned = raw
        .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer ***')
        .replaceFirst(
          RegExp(
            r'^(?:FormatException|HttpException|SocketException|TimeoutException|ClientException):\s*',
          ),
          '',
        )
        .trim();
    return cleaned.isEmpty ? '网关连接失败' : cleaned;
  }

  /// Checks reachability, authentication, and `.so` capability of a user's BYO gateway.
  static Future<SpiderGatewayHealth> checkHealth(
    SpiderGatewayConfig config, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = _endpointUri(config, '/marco-gateway/v1/health');
    final ownClient = client == null;
    final transport = client ?? _createDirectClient();
    final sw = Stopwatch()..start();
    try {
      final resp = await transport
          .get(uri, headers: _headersFor(config))
          .timeout(timeout);
      sw.stop();
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return SpiderGatewayHealth(
          ok: false,
          latencyMs: sw.elapsedMilliseconds,
          message: '鉴权失败（HTTP ${resp.statusCode}），请核对网关访问令牌（Token）',
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return SpiderGatewayHealth(
          ok: false,
          latencyMs: sw.elapsedMilliseconds,
          message: '网关返回异常状态码 HTTP ${resp.statusCode}',
        );
      }
      if (resp.bodyBytes.length > maxResponseBytes) {
        return SpiderGatewayHealth(
          ok: false,
          latencyMs: sw.elapsedMilliseconds,
          message: '网关响应体积超出安全上限',
        );
      }
      final doc = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (doc is! Map) {
        return SpiderGatewayHealth(
          ok: false,
          latencyMs: sw.elapsedMilliseconds,
          message: '目标地址未返回合法的 Marco 蜘蛛网关健康信息',
        );
      }
      final ok = doc['ok'] != false;
      final deviceName = (doc['deviceName'] ?? doc['name'] ?? '').toString().trim();
      final engine = (doc['engine'] ?? 'spider-gateway').toString().trim();
      final supportsSo = doc['supportsNativeSo'] == true;
      final protocol = (doc['protocol'] ?? protocolId).toString().trim();
      return SpiderGatewayHealth(
        ok: ok,
        protocol: protocol,
        deviceName: deviceName,
        engine: engine,
        supportsNativeSo: supportsSo,
        latencyMs: sw.elapsedMilliseconds,
        message: ok
            ? '已连接${deviceName.isNotEmpty ? '「$deviceName」' : ''}（${sw.elapsedMilliseconds}ms${supportsSo ? ' · 支持 .so' : ''}）'
            : (doc['error'] ?? '网关状态不可用').toString(),
      );
    } on TimeoutException {
      return const SpiderGatewayHealth(
        ok: false,
        message: '连接网关超时，请确认设备在同一局域网或服务已启动',
      );
    } catch (e) {
      return SpiderGatewayHealth(
        ok: false,
        message: _sanitizeError(e),
      );
    } finally {
      if (ownClient) transport.close();
    }
  }

  /// Invokes a spider method (`home` / `homeVod` / `category` / `search` / `detail` / `play`)
  /// on the user's BYO Spider Gateway and returns CMS-shaped JSON text.
  static Future<String> invoke(
    SpiderGatewayConfig config, {
    required CmsSite site,
    required String action,
    Map<String, dynamic> params = const <String, dynamic>{},
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!config.isActive) {
      throw const FormatException('蜘蛛网关未启用，请在「设置 → 蜘蛛扩展与网关」中配置');
    }
    final uri = _endpointUri(config, '/marco-gateway/v1/invoke');
    final ownClient = client == null;
    final transport = client ?? _createDirectClient();
    final payload = <String, dynamic>{
      'protocol': protocolId,
      'action': action,
      'site': <String, dynamic>{
        'key': site.sourceKey,
        'name': site.name,
        'api': site.sourceApi,
        'type': site.type,
        'ext': site.rawExtension ?? site.ext,
        'jar': site.jar,
        'spider': site.spider,
        'playUrl': site.playUrl,
      },
      'params': params,
    };
    try {
      final resp = await transport
          .post(
            uri,
            headers: _headersFor(config, jsonBody: true),
            body: utf8.encode(jsonEncode(payload)),
          )
          .timeout(timeout);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw FormatException('蜘蛛网关鉴权失败（HTTP ${resp.statusCode}），请检查访问令牌');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        String detail = 'HTTP ${resp.statusCode}';
        try {
          final errDoc = jsonDecode(
            utf8.decode(resp.bodyBytes, allowMalformed: true),
          );
          if (errDoc is Map && (errDoc['error'] ?? '').toString().trim().isNotEmpty) {
            detail = errDoc['error'].toString().trim();
          }
        } catch (_) {}
        throw FormatException('蜘蛛网关执行失败：$detail');
      }
      if (resp.bodyBytes.length > maxResponseBytes) {
        throw const FormatException('蜘蛛网关返回数据超过 8 MB 上限');
      }
      final rawText = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
      if (rawText.isEmpty) {
        throw const FormatException('蜘蛛网关返回了空响应');
      }
      final decoded = jsonDecode(rawText);
      if (decoded is Map) {
        if (decoded['ok'] == false) {
          final err = (decoded['error'] ?? '网关解析失败').toString().trim();
          throw FormatException('蜘蛛网关返回错误：$err');
        }
        if (decoded.containsKey('data')) {
          final data = decoded['data'];
          if (data is String) return data;
          return jsonEncode(data ?? const <String, dynamic>{});
        }
      }
      return rawText;
    } on TimeoutException {
      throw const FormatException('蜘蛛网关请求超时，请检查局域网 Android 端或自建服务状态');
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('蜘蛛网关通信失败：${_sanitizeError(e)}');
    } finally {
      if (ownClient) transport.close();
    }
  }

  /// Sends a lightweight UDP broadcast probe on the local network to discover
  /// any user-owned Android Marco Movie devices with LAN Spider Gateway enabled.
  static Future<List<DiscoveredSpiderGateway>> discoverLanGateways({
    Duration timeout = const Duration(milliseconds: 1400),
  }) async {
    if (kIsWeb) return const <DiscoveredSpiderGateway>[];
    final found = <String, DiscoveredSpiderGateway>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket?.receive();
        if (dg == null) return;
        try {
          final text = utf8.decode(dg.data, allowMalformed: true).trim();
          final doc = jsonDecode(text);
          if (doc is! Map) return;
          if ((doc['protocol'] ?? '').toString() != protocolId) return;
          final port = (doc['port'] as num?)?.toInt() ?? 0;
          if (port <= 0 || port > 65535) return;
          final host = dg.address.address;
          final url = Uri(scheme: 'http', host: host, port: port).toString();
          final deviceName = (doc['deviceName'] ?? host).toString().trim();
          found[url] = DiscoveredSpiderGateway(
            baseUrl: url,
            deviceName: deviceName.isEmpty ? host : deviceName,
            engine: (doc['engine'] ?? 'android-csp').toString(),
            supportsNativeSo: doc['supportsNativeSo'] != false,
            requiresToken: doc['requiresToken'] != false,
          );
        } catch (_) {}
      });

      final probeBytes = utf8.encode(discoveryProbePayload);
      try {
        socket.send(
          probeBytes,
          InternetAddress('255.255.255.255'),
          discoveryUdpPort,
        );
      } catch (_) {}
      await Future<void>.delayed(timeout);
      await sub.cancel();
    } catch (_) {
      // LAN broadcast may be denied by OS permission or headless test sandbox.
    } finally {
      socket?.close();
    }
    return found.values.toList(growable: false);
  }
}

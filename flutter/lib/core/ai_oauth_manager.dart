// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ui/official_channel_notice.dart' show launchExternalOfficialUrl;
import 'ai_provider_profiles.dart';
import 'ai_service.dart';

/// Cooperative cancellation token for interactive OAuth / Device Code flows.
class AiOAuthCancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get onCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Result returned after completing OpenRouter's official PKCE OAuth exchange.
@immutable
class OpenRouterOAuthResult {
  final String apiKey;
  final String accountLabel;

  const OpenRouterOAuthResult({
    required this.apiKey,
    this.accountLabel = 'OpenRouter OAuth',
  });
}

/// Official OpenRouter PKCE OAuth manager modeled on OpenMinis's ephemeral
/// loopback callback server (`OAuthCallbackServer` + `OpenRouterOAuthManager`).
///
/// Flow:
/// 1. Bind ephemeral `127.0.0.1:0` HTTP server with random single-use callback
///    path nonce.
/// 2. Generate RFC 7636 `code_verifier` + SHA-256 `code_challenge` (`S256`).
/// 3. Launch `https://openrouter.ai/auth?callback_url=...&code_challenge=...&code_challenge_method=S256`
///    in the user's system browser.
/// 4. Receive `code` on localhost, close the server immediately, and exchange
///    at `POST https://openrouter.ai/api/v1/auth/keys`.
class OpenRouterPkceManager {
  static const String authBaseUrl = 'https://openrouter.ai/auth';
  static const String keyExchangeUrl = 'https://openrouter.ai/api/v1/auth/keys';
  static const String defaultApiBaseUrl = 'https://openrouter.ai/api/v1';

  static String generateCodeVerifier([Random? rng]) {
    final random = rng ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String computeS256Challenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  static Future<OpenRouterOAuthResult> authorize({
    AiOAuthCancelToken? cancelToken,
    Future<bool> Function(Uri uri)? urlOpener,
    void Function(Uri authorizeUri, Uri callbackUri)? onAuthorizeUriReady,
    http.Client? httpClient,
    Duration timeout = const Duration(minutes: 3),
    Random? random,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '已取消 OpenRouter 授权',
      );
    }

    final verifier = generateCodeVerifier(random);
    final challenge = computeS256Challenge(verifier);
    final pathNonce = generateCodeVerifier(random).substring(0, 16);
    final callbackPath = '/openrouter-cb-$pathNonce';

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final codeCompleter = Completer<String>();
    StreamSubscription<HttpRequest>? sub;

    try {
      final callbackUri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: callbackPath,
      );
      final authorizeUri = Uri.parse(authBaseUrl).replace(
        queryParameters: <String, String>{
          'callback_url': callbackUri.toString(),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
        },
      );

      sub = server.listen((request) async {
        try {
          if (request.uri.path != callbackPath) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          final err = (request.uri.queryParameters['error'] ?? '').trim();
          final code = (request.uri.queryParameters['code'] ?? '').trim();
          request.response.headers.contentType = ContentType.html;
          if (err.isNotEmpty || code.isEmpty) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write(
              '<!doctype html><html><head><meta charset="utf-8"><title>Marco Movie</title></head>'
              '<body style="font-family:sans-serif;padding:32px"><h3>授权未完成</h3>'
              '<p>请返回 Marco Movie 重试。</p></body></html>',
            );
            await request.response.close();
            if (!codeCompleter.isCompleted) {
              codeCompleter.completeError(
                AiServiceException(
                  AiErrorCode.unauthorized,
                  err.isNotEmpty ? 'OpenRouter 授权被拒绝（$err）' : '未收到 OpenRouter 授权码',
                ),
              );
            }
            return;
          }

          request.response.statusCode = HttpStatus.ok;
          request.response.write(
            '<!doctype html><html><head><meta charset="utf-8"><title>Marco Movie</title></head>'
            '<body style="font-family:sans-serif;padding:32px;background:#0f141c;color:#eef3fa">'
            '<h2>OpenRouter 授权成功</h2>'
            '<p>你可以关闭此标签页并返回 Marco Movie。</p></body></html>',
          );
          await request.response.close();
          if (!codeCompleter.isCompleted) {
            codeCompleter.complete(code);
          }
        } catch (_) {}
      });

      onAuthorizeUriReady?.call(authorizeUri, callbackUri);
      final opener = urlOpener ?? launchExternalOfficialUrl;
      unawaited(opener(authorizeUri));

      final waiters = <Future<String>>[
        codeCompleter.future,
        if (cancelToken != null)
          cancelToken.onCancelled.then<String>(
            (_) => throw const AiServiceException(
              AiErrorCode.unauthorized,
              '已取消 OpenRouter 授权',
            ),
          ),
      ];
      final code = await Future.any<String>(waiters).timeout(
        timeout,
        onTimeout: () => throw const AiServiceException(
          AiErrorCode.timeout,
          '等待浏览器授权超时，请重新点击授权',
        ),
      );

      final key = await exchangeCodeForKey(
        code: code,
        codeVerifier: verifier,
        httpClient: httpClient,
      );
      return OpenRouterOAuthResult(apiKey: key);
    } finally {
      await sub?.cancel();
      await server.close(force: true);
    }
  }

  /// Exchanges a PKCE authorization [code] + [codeVerifier] for an OpenRouter
  /// API key via `POST https://openrouter.ai/api/v1/auth/keys`.
  static Future<String> exchangeCodeForKey({
    required String code,
    required String codeVerifier,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final ephemeral = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse(keyExchangeUrl),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, String>{
              'code': code,
              'code_verifier': codeVerifier,
              'code_challenge_method': 'S256',
            }),
          )
          .timeout(timeout);
      final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AiServiceException(
          AiErrorCode.unauthorized,
          'OpenRouter 换取密钥失败（HTTP ${resp.statusCode}）',
          statusCode: resp.statusCode,
        );
      }
      final decoded = jsonDecode(raw);
      final key = decoded is Map ? (decoded['key'] ?? '').toString().trim() : '';
      if (key.isEmpty) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          'OpenRouter 未返回有效 API 密钥',
        );
      }
      return key;
    } on AiServiceException {
      rethrow;
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        'OpenRouter 换取密钥超时，请检查网络',
      );
    } catch (e) {
      throw AiServiceException(
        AiErrorCode.networkError,
        'OpenRouter 换取密钥失败：${redactAiSecret(e.toString())}',
      );
    } finally {
      if (ephemeral) client.close();
    }
  }
}

/// Device-code verification prompt returned by GitHub's RFC 8628 endpoint.
@immutable
class CopilotDeviceCodePrompt {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresInSeconds;
  final int intervalSeconds;

  const CopilotDeviceCodePrompt({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresInSeconds,
    required this.intervalSeconds,
  });
}

/// Short-lived Copilot API bearer token exchanged from the user's GitHub OAuth
/// token via `GET https://api.github.com/copilot_internal/v2/token`.
@immutable
class CopilotSessionToken {
  final String token;
  final int expiresAtEpochSec;
  final String apiBaseUrl;

  const CopilotSessionToken({
    required this.token,
    required this.expiresAtEpochSec,
    this.apiBaseUrl = 'https://api.githubcopilot.com',
  });

  bool isValidAt(DateTime now) {
    if (token.trim().isEmpty) return false;
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    return nowSec < (expiresAtEpochSec - 60);
  }
}

/// Official RFC 8628 GitHub Copilot Device Code Flow + short-lived session
/// token exchanger modeled on OpenMinis's `CopilotDeviceFlow`.
class GitHubCopilotDeviceFlow {
  static const String defaultClientId = 'Iv1.b507a08c87ecfe98';
  static const String deviceCodeUrl = 'https://github.com/login/device/code';
  static const String accessTokenUrl =
      'https://github.com/login/oauth/access_token';
  static const String copilotTokenUrl =
      'https://api.github.com/copilot_internal/v2/token';
  static const String defaultApiBaseUrl = 'https://api.githubcopilot.com';

  static const Map<String, String> standardCopilotHeaders = <String, String>{
    'Editor-Version': 'MarcoMovie/0.7.3',
    'Editor-Plugin-Version': 'MarcoMovie/0.7.3',
    'Copilot-Integration-Id': 'vscode-chat',
  };

  final Map<String, CopilotSessionToken> _sessionCache =
      <String, CopilotSessionToken>{};

  static final GitHubCopilotDeviceFlow instance = GitHubCopilotDeviceFlow();

  void clearSessionCache() {
    _sessionCache.clear();
  }

  /// Step 1: Requests a device code & 8-character user verification code.
  Future<CopilotDeviceCodePrompt> requestDeviceCode({
    String clientId = defaultClientId,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final ephemeral = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse(deviceCodeUrl),
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: 'client_id=${Uri.encodeQueryComponent(clientId)}&scope=read%3Auser',
          )
          .timeout(timeout);
      final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AiServiceException(
          AiErrorCode.networkError,
          '请求 GitHub 设备码失败（HTTP ${resp.statusCode}）',
          statusCode: resp.statusCode,
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          'GitHub 设备码接口返回格式无效',
        );
      }
      final deviceCode = (decoded['device_code'] ?? '').toString().trim();
      final userCode = (decoded['user_code'] ?? '').toString().trim();
      final verificationUri = (decoded['verification_uri'] ??
              'https://github.com/login/device')
          .toString()
          .trim();
      final expiresIn = (decoded['expires_in'] as num?)?.toInt() ?? 900;
      final interval = (decoded['interval'] as num?)?.toInt() ?? 5;
      if (deviceCode.isEmpty || userCode.isEmpty) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          'GitHub 未返回有效的设备验证码',
        );
      }
      return CopilotDeviceCodePrompt(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri,
        expiresInSeconds: expiresIn.clamp(60, 3600),
        intervalSeconds: interval.clamp(1, 30),
      );
    } on AiServiceException {
      rethrow;
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        '请求 GitHub 设备码超时，请检查网络连接',
      );
    } catch (e) {
      throw AiServiceException(
        AiErrorCode.networkError,
        '请求 GitHub 设备码失败：${redactAiSecret(e.toString())}',
      );
    } finally {
      if (ephemeral) client.close();
    }
  }

  /// Step 2: Polls GitHub's RFC 8628 token endpoint until the user confirms
  /// the code in their browser, cancels, or the code expires.
  Future<String> pollAccessToken(
    CopilotDeviceCodePrompt prompt, {
    String clientId = defaultClientId,
    AiOAuthCancelToken? cancelToken,
    http.Client? httpClient,
    Future<void> Function(Duration duration)? sleeper,
    DateTime Function()? clock,
    Duration requestTimeout = const Duration(seconds: 20),
  }) async {
    final nowFn = clock ?? DateTime.now;
    final sleepFn = sleeper ?? Future<void>.delayed;
    final deadline = nowFn().add(Duration(seconds: prompt.expiresInSeconds));
    var intervalSec = prompt.intervalSeconds;

    final ephemeral = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      while (true) {
        if (cancelToken?.isCancelled == true) {
          throw const AiServiceException(
            AiErrorCode.unauthorized,
            '已取消 GitHub Copilot 登录',
          );
        }
        if (!nowFn().isBefore(deadline)) {
          throw const AiServiceException(
            AiErrorCode.timeout,
            'GitHub 设备码已过期，请重新获取',
          );
        }

        // Wait `intervalSec` cooperatively with cancelToken.
        final sleepFuture = sleepFn(Duration(seconds: intervalSec));
        if (cancelToken != null) {
          await Future.any<void>(<Future<void>>[
            sleepFuture,
            cancelToken.onCancelled,
          ]);
        } else {
          await sleepFuture;
        }
        if (cancelToken?.isCancelled == true) {
          throw const AiServiceException(
            AiErrorCode.unauthorized,
            '已取消 GitHub Copilot 登录',
          );
        }

        final resp = await client
            .post(
              Uri.parse(accessTokenUrl),
              headers: const <String, String>{
                'Accept': 'application/json',
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: 'client_id=${Uri.encodeQueryComponent(clientId)}'
                  '&device_code=${Uri.encodeQueryComponent(prompt.deviceCode)}'
                  '&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code',
            )
            .timeout(requestTimeout);
        final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw const AiServiceException(
            AiErrorCode.malformedResponse,
            'GitHub 授权轮询返回格式无效',
          );
        }
        final accessToken = (decoded['access_token'] ?? '').toString().trim();
        if (accessToken.isNotEmpty) {
          return accessToken;
        }
        final err = (decoded['error'] ?? '').toString().trim();
        if (err == 'authorization_pending') {
          continue;
        }
        if (err == 'slow_down') {
          final serverInterval = (decoded['interval'] as num?)?.toInt();
          intervalSec = serverInterval != null && serverInterval > intervalSec
              ? serverInterval
              : intervalSec + 5;
          continue;
        }
        if (err == 'expired_token') {
          throw const AiServiceException(
            AiErrorCode.timeout,
            'GitHub 设备码已过期，请重新登录',
          );
        }
        if (err == 'access_denied') {
          throw const AiServiceException(
            AiErrorCode.unauthorized,
            'GitHub 授权已被拒绝',
          );
        }
        throw AiServiceException(
          AiErrorCode.unauthorized,
          'GitHub Copilot 登录失败${err.isNotEmpty ? "（$err）" : ""}',
        );
      }
    } on AiServiceException {
      rethrow;
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        'GitHub 授权请求超时，请检查网络连接',
      );
    } catch (e) {
      throw AiServiceException(
        AiErrorCode.networkError,
        'GitHub Copilot 登录失败：${redactAiSecret(e.toString())}',
      );
    } finally {
      if (ephemeral) client.close();
    }
  }

  /// Step 3: Exchanges a long-lived GitHub OAuth token for a short-lived
  /// Copilot bearer token and caches it in memory until 60s before expiry.
  Future<CopilotSessionToken> getOrRefreshSessionToken(
    String githubAccessToken, {
    bool forceRefresh = false,
    http.Client? httpClient,
    DateTime Function()? clock,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final trimmed = githubAccessToken.trim();
    if (trimmed.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请先完成 GitHub Copilot 登录授权',
      );
    }
    final now = (clock ?? DateTime.now)();
    if (!forceRefresh) {
      final cached = _sessionCache[trimmed];
      if (cached != null && cached.isValidAt(now)) {
        return cached;
      }
    }

    final ephemeral = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final resp = await client
          .get(
            Uri.parse(copilotTokenUrl),
            headers: <String, String>{
              'Authorization': 'token $trimmed',
              'Accept': 'application/json',
              'User-Agent': 'MarcoMovie/0.7.3',
              ...standardCopilotHeaders,
            },
          )
          .timeout(timeout);
      final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        _sessionCache.remove(trimmed);
        throw AiServiceException(
          AiErrorCode.unauthorized,
          'GitHub Copilot 令牌无效或当前账号未开通 Copilot 订阅（HTTP ${resp.statusCode}）',
          statusCode: resp.statusCode,
        );
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw AiServiceException(
          AiErrorCode.networkError,
          '换取 Copilot 会话令牌失败（HTTP ${resp.statusCode}）',
          statusCode: resp.statusCode,
        );
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          'Copilot 会话接口返回格式无效',
        );
      }
      final token = (decoded['token'] ?? '').toString().trim();
      final expiresAt = (decoded['expires_at'] as num?)?.toInt() ??
          ((now.millisecondsSinceEpoch ~/ 1000) + 1500);
      var apiBase = defaultApiBaseUrl;
      final endpoints = decoded['endpoints'];
      if (endpoints is Map && endpoints['api'] is String) {
        final candidate = (endpoints['api'] as String).trim();
        if (candidate.startsWith('https://')) {
          apiBase = candidate;
        }
      }
      if (token.isEmpty) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          'Copilot 会话接口未返回有效令牌',
        );
      }
      final session = CopilotSessionToken(
        token: token,
        expiresAtEpochSec: expiresAt,
        apiBaseUrl: apiBase,
      );
      _sessionCache[trimmed] = session;
      return session;
    } on AiServiceException {
      rethrow;
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        '换取 Copilot 会话令牌超时，请检查网络连接',
      );
    } catch (e) {
      throw AiServiceException(
        AiErrorCode.networkError,
        '换取 Copilot 会话令牌失败：${redactAiSecret(e.toString())}',
      );
    } finally {
      if (ephemeral) client.close();
    }
  }
}

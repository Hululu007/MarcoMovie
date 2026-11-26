import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ohos_runtime.dart';
import 'secure_credential_store.dart';

/// Supported Bring-Your-Own-API (BYO-API) wire protocols.
enum AiApiProtocol {
  openaiCompatible('openai_compatible', 'OpenAI 兼容接口'),
  anthropicMessages('anthropic_messages', 'Anthropic Messages'),
  geminiGenerateContent('gemini_generate_content', 'Google Gemini');

  final String id;
  final String labelZh;

  const AiApiProtocol(this.id, this.labelZh);

  static AiApiProtocol fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final p in AiApiProtocol.values) {
      if (p.id == normalized) return p;
    }
    return AiApiProtocol.openaiCompatible;
  }
}

/// Categorized error codes for [AiServiceException].
enum AiErrorCode {
  disabled,
  unconfigured,
  invalidEndpoint,
  privacySpaceBlocked,
  budgetExceeded,
  unauthorized,
  rateLimited,
  timeout,
  networkError,
  malformedResponse,
  unsafeOutputRejected,
}

/// Structured diagnostic exception raised by [AiService].
class AiServiceException implements Exception {
  final AiErrorCode code;
  final String messageZh;
  final int? statusCode;

  const AiServiceException(
    this.code,
    this.messageZh, {
    this.statusCode,
  });

  @override
  String toString() => messageZh;
}

/// Immutable non-secret AI configuration persisted in local [SharedPreferences].
///
/// Security & compliance invariants:
/// - Default [baseUrl], [model], and [fastModel] are strictly `""`.
/// - Zero built-in endpoints or keys exist in the binary.
/// - The API key is NEVER stored in [AiConfig], [SharedPreferences], or sync
///   payloads; it lives exclusively in [SecureStorageBackend] (iOS Keychain).
@immutable
class AiConfig {
  static const int minTimeoutSeconds = 5;
  static const int maxTimeoutSeconds = 120;
  static const int defaultTimeoutSeconds = 25;

  final bool enabled;
  final AiApiProtocol protocol;
  final String baseUrl;
  final String model;
  final String fastModel;
  final int timeoutSeconds;
  final int monthlyTokenBudget;
  final bool nlSearchEnabled;
  final bool titleCleanupEnabled;
  final bool firstUseConsentAccepted;

  const AiConfig({
    this.enabled = false,
    this.protocol = AiApiProtocol.openaiCompatible,
    this.baseUrl = '',
    this.model = '',
    this.fastModel = '',
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.monthlyTokenBudget = 0,
    this.nlSearchEnabled = true,
    this.titleCleanupEnabled = true,
    this.firstUseConsentAccepted = false,
  });

  /// Secondary lightweight model for batch filename cleanup; falls back to [model].
  String get effectiveFastModel {
    final fast = fastModel.trim();
    return fast.isNotEmpty ? fast : model.trim();
  }

  AiConfig copyWith({
    bool? enabled,
    AiApiProtocol? protocol,
    String? baseUrl,
    String? model,
    String? fastModel,
    int? timeoutSeconds,
    int? monthlyTokenBudget,
    bool? nlSearchEnabled,
    bool? titleCleanupEnabled,
    bool? firstUseConsentAccepted,
  }) {
    final nextTimeout = (timeoutSeconds ?? this.timeoutSeconds)
        .clamp(minTimeoutSeconds, maxTimeoutSeconds);
    final nextBudget = (monthlyTokenBudget ?? this.monthlyTokenBudget);
    return AiConfig(
      enabled: enabled ?? this.enabled,
      protocol: protocol ?? this.protocol,
      baseUrl: (baseUrl ?? this.baseUrl).trim(),
      model: (model ?? this.model).trim(),
      fastModel: (fastModel ?? this.fastModel).trim(),
      timeoutSeconds: nextTimeout,
      monthlyTokenBudget: nextBudget < 0 ? 0 : nextBudget,
      nlSearchEnabled: nlSearchEnabled ?? this.nlSearchEnabled,
      titleCleanupEnabled: titleCleanupEnabled ?? this.titleCleanupEnabled,
      firstUseConsentAccepted:
          firstUseConsentAccepted ?? this.firstUseConsentAccepted,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'protocol': protocol.id,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        'fastModel': fastModel.trim(),
        'timeoutSeconds': timeoutSeconds,
        'monthlyTokenBudget': monthlyTokenBudget,
        'nlSearchEnabled': nlSearchEnabled,
        'titleCleanupEnabled': titleCleanupEnabled,
        'firstUseConsentAccepted': firstUseConsentAccepted,
      };

  factory AiConfig.fromJson(Map<String, dynamic> json) {
    final rawTimeout = (json['timeoutSeconds'] as num?)?.toInt() ??
        AiConfig.defaultTimeoutSeconds;
    final rawBudget = (json['monthlyTokenBudget'] as num?)?.toInt() ?? 0;
    return AiConfig(
      enabled: json['enabled'] == true,
      protocol: AiApiProtocol.fromId(json['protocol']?.toString()),
      baseUrl: (json['baseUrl'] ?? '').toString().trim(),
      model: (json['model'] ?? '').toString().trim(),
      fastModel: (json['fastModel'] ?? '').toString().trim(),
      timeoutSeconds: rawTimeout.clamp(
        AiConfig.minTimeoutSeconds,
        AiConfig.maxTimeoutSeconds,
      ),
      monthlyTokenBudget: rawBudget < 0 ? 0 : rawBudget,
      nlSearchEnabled: json['nlSearchEnabled'] != false,
      titleCleanupEnabled: json['titleCleanupEnabled'] != false,
      firstUseConsentAccepted: json['firstUseConsentAccepted'] == true,
    );
  }
}

/// Token and call counter scoped to a single `YYYY-MM` calendar month.
@immutable
class AiMonthlyUsage {
  final String monthKey;
  final int promptTokens;
  final int completionTokens;
  final int requestCount;

  const AiMonthlyUsage({
    required this.monthKey,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.requestCount = 0,
  });

  int get totalTokens => promptTokens + completionTokens;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'monthKey': monthKey,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'requestCount': requestCount,
      };

  factory AiMonthlyUsage.fromJson(
    Map<String, dynamic> json, {
    required String expectedMonthKey,
  }) {
    final storedMonth = (json['monthKey'] ?? '').toString().trim();
    if (storedMonth != expectedMonthKey) {
      return AiMonthlyUsage(monthKey: expectedMonthKey);
    }
    return AiMonthlyUsage(
      monthKey: expectedMonthKey,
      promptTokens: ((json['promptTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      completionTokens:
          ((json['completionTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      requestCount: ((json['requestCount'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
    );
  }
}

/// Result returned by a single [AiService.complete] invocation.
@immutable
class AiCompletionResult {
  final String text;
  final int promptTokens;
  final int completionTokens;
  final bool fromCache;
  final int latencyMs;

  const AiCompletionResult({
    required this.text,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.fromCache = false,
    this.latencyMs = 0,
  });
}

/// Diagnostic result returned by [AiService.testConnection].
@immutable
class AiConnectionTestResult {
  final bool ok;
  final int latencyMs;
  final String modelReply;
  final String messageZh;

  const AiConnectionTestResult({
    required this.ok,
    required this.latencyMs,
    this.modelReply = '',
    required this.messageZh,
  });
}

/// Candidate work recommended by natural-language AI search before matching
/// against the user's own configured `CmsSite` sources.
@immutable
class AiMovieCandidate {
  final String title;
  final String year;
  final String reason;

  const AiMovieCandidate({
    required this.title,
    this.year = '',
    this.reason = '',
  });
}

/// Self-contained BYO-API client, Keychain credential manager, response cache,
/// monthly token budget guard, and Privacy Space hard-blocker.
class AiService extends ChangeNotifier {
  static const String prefsConfigKey = 'marco_ai_config_v1';
  static const String prefsUsageKey = 'marco_ai_usage_v1';
  static const String prefsCacheKey = 'marco_ai_cache_v1';
  static const String secureApiKeySlot = 'marco_ai_api_key_v1';
  static const int maxCacheEntries = 200;

  static final RegExp _forbiddenUrlLikeRe = RegExp(
    r'(?:https?://|ftp://|magnet:\?|ed2k://|thunder://|mms://|rtmp://|rtsp://|\bwww\.[a-z0-9-]+\.[a-z]{2,})',
    caseSensitive: false,
  );

  static final AiService instance = AiService();

  http.Client? _injectedHttpClient;
  SecureStorageBackend _secureBackend;
  DateTime Function() _clock;

  AiConfig _config = const AiConfig();
  String _apiKey = '';
  AiMonthlyUsage? _usage;
  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();
  bool _loaded = false;
  Future<void>? _loadFuture;

  AiService({
    http.Client? httpClient,
    SecureStorageBackend? secureStorage,
    DateTime Function()? clock,
  })  : _injectedHttpClient = httpClient,
        _secureBackend = secureStorage ?? const FlutterSecureStorageBackend(),
        _clock = clock ?? DateTime.now;

  AiConfig get config => _config;
  bool get isLoaded => _loaded;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;
  int get cachedEntryCount => _cache.length;

  /// True when AI Assistant is enabled and has non-empty Base URL, API key, and model.
  bool get isConfigured =>
      !OhosRuntime.isOhos &&
      _config.enabled &&
      _config.baseUrl.trim().isNotEmpty &&
      _config.model.trim().isNotEmpty &&
      _apiKey.trim().isNotEmpty;

  String get currentMonthKey {
    final now = _clock();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  AiMonthlyUsage get monthlyUsage {
    final expected = currentMonthKey;
    final current = _usage;
    if (current == null || current.monthKey != expected) {
      return AiMonthlyUsage(monthKey: expected);
    }
    return current;
  }

  /// Replaces transport/storage/clock dependencies on [AiService.instance] for
  /// deterministic widget and unit tests without touching disk or real network.
  @visibleForTesting
  void configureForTest({
    http.Client? httpClient,
    SecureStorageBackend? secureStorage,
    DateTime Function()? clock,
    bool resetState = false,
  }) {
    if (httpClient != null) _injectedHttpClient = httpClient;
    if (secureStorage != null) _secureBackend = secureStorage;
    if (clock != null) _clock = clock;
    if (resetState) {
      _config = const AiConfig();
      _apiKey = '';
      _usage = null;
      _cache.clear();
      _loaded = false;
      _loadFuture = null;
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTest() {
    _injectedHttpClient = null;
    _secureBackend = const FlutterSecureStorageBackend();
    _clock = DateTime.now;
    _config = const AiConfig();
    _apiKey = '';
    _usage = null;
    _cache.clear();
    _loaded = false;
    _loadFuture = null;
    notifyListeners();
  }

  /// Ensures local preferences, monthly token counters, cache, and Keychain API
  /// key have been loaded into memory.
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _doLoad();
  }

  Future<void> reload() {
    _loaded = false;
    _loadFuture = null;
    return ensureLoaded();
  }

  Future<void> _doLoad() async {
    if (OhosRuntime.isOhos) {
      _loaded = true;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawConfig = prefs.getString(prefsConfigKey);
      if (rawConfig != null && rawConfig.trim().isNotEmpty) {
        final decoded = jsonDecode(rawConfig);
        if (decoded is Map) {
          _config = AiConfig.fromJson(Map<String, dynamic>.from(decoded));
        }
      } else {
        _config = const AiConfig();
      }

      final expectedMonth = currentMonthKey;
      final rawUsage = prefs.getString(prefsUsageKey);
      if (rawUsage != null && rawUsage.trim().isNotEmpty) {
        final decodedUsage = jsonDecode(rawUsage);
        if (decodedUsage is Map) {
          _usage = AiMonthlyUsage.fromJson(
            Map<String, dynamic>.from(decodedUsage),
            expectedMonthKey: expectedMonth,
          );
        } else {
          _usage = AiMonthlyUsage(monthKey: expectedMonth);
        }
      } else {
        _usage = AiMonthlyUsage(monthKey: expectedMonth);
      }

      _cache.clear();
      final rawCache = prefs.getString(prefsCacheKey);
      if (rawCache != null && rawCache.trim().isNotEmpty) {
        final decodedCache = jsonDecode(rawCache);
        if (decodedCache is List) {
          for (final item in decodedCache) {
            if (item is Map && item['k'] is String && item['v'] is String) {
              _cache[item['k'] as String] = item['v'] as String;
            }
          }
          while (_cache.length > maxCacheEntries) {
            _cache.remove(_cache.keys.first);
          }
        }
      }

      final storedKey = await _secureBackend.read(secureApiKeySlot);
      _apiKey = (storedKey ?? '').trim();
    } catch (_) {
      _usage ??= AiMonthlyUsage(monthKey: currentMonthKey);
    } finally {
      _loaded = true;
      _loadFuture = null;
      notifyListeners();
    }
  }

  /// Reads the stored API key for populating the obscured settings field on iOS.
  Future<String> readApiKey() async {
    await ensureLoaded();
    return _apiKey;
  }

  /// Writes or deletes the API key strictly inside [SecureStorageBackend]
  /// (iOS Keychain) and NEVER in [SharedPreferences].
  Future<void> setApiKey(String rawKey) async {
    await ensureLoaded();
    final trimmed = rawKey.trim();
    _apiKey = trimmed;
    if (trimmed.isEmpty) {
      await _secureBackend.delete(secureApiKeySlot);
    } else {
      await _secureBackend.write(secureApiKeySlot, trimmed);
    }
    notifyListeners();
  }

  /// Persists non-secret [AiConfig] to [SharedPreferences].
  Future<void> saveConfig(AiConfig next) async {
    await ensureLoaded();
    _config = next;
    if (!OhosRuntime.isOhos) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsConfigKey, jsonEncode(_config.toJson()));
    }
    notifyListeners();
  }

  Future<void> acceptFirstUseConsent() async {
    await ensureLoaded();
    if (_config.firstUseConsentAccepted) return;
    await saveConfig(_config.copyWith(firstUseConsentAccepted: true));
  }

  /// Clears the bounded local AI response cache.
  Future<void> clearCache() async {
    await ensureLoaded();
    _cache.clear();
    if (!OhosRuntime.isOhos) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsCacheKey);
    }
    notifyListeners();
  }

  Future<void> _persistCache() async {
    if (OhosRuntime.isOhos) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final serialized = <Map<String, String>>[
        for (final entry in _cache.entries)
          <String, String>{'k': entry.key, 'v': entry.value},
      ];
      await prefs.setString(prefsCacheKey, jsonEncode(serialized));
    } catch (_) {}
  }

  Future<void> _recordUsage({
    required int promptTokens,
    required int completionTokens,
  }) async {
    final month = currentMonthKey;
    final prev = monthlyUsage;
    final updated = AiMonthlyUsage(
      monthKey: month,
      promptTokens: prev.promptTokens + (promptTokens < 0 ? 0 : promptTokens),
      completionTokens:
          prev.completionTokens + (completionTokens < 0 ? 0 : completionTokens),
      requestCount: prev.requestCount + 1,
    );
    _usage = updated;
    if (!OhosRuntime.isOhos) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsUsageKey, jsonEncode(updated.toJson()));
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Computes deterministic SHA-256 cache key over `feature + protocol + model + prompt`.
  static String computeCacheKey({
    required String feature,
    required AiApiProtocol protocol,
    required String model,
    required String systemPrompt,
    required String userPrompt,
  }) {
    final payload =
        '$feature|${protocol.id}|${model.trim()}|$systemPrompt|$userPrompt';
    return sha256.convert(utf8.encode(payload)).toString();
  }

  /// Resolves the target endpoint URI for [protocol], [baseUrl], and [model].
  static Uri resolveEndpointUri({
    required AiApiProtocol protocol,
    required String baseUrl,
    required String model,
  }) {
    var trimmed = baseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.invalidEndpoint,
        '请先填写有效的接口地址 (Base URL)',
      );
    }
    final parsedBase = Uri.tryParse(trimmed);
    if (parsedBase == null ||
        !parsedBase.hasAuthority ||
        parsedBase.host.trim().isEmpty ||
        parsedBase.userInfo.isNotEmpty ||
        (parsedBase.scheme != 'https' && parsedBase.scheme != 'http')) {
      throw const AiServiceException(
        AiErrorCode.invalidEndpoint,
        '接口地址格式无效，请填写以 https:// 开头的有效地址',
      );
    }

    final lower = trimmed.toLowerCase();
    final String fullUrl;
    switch (protocol) {
      case AiApiProtocol.openaiCompatible:
        if (lower.endsWith('/chat/completions')) {
          fullUrl = trimmed;
        } else {
          fullUrl = '$trimmed/chat/completions';
        }
      case AiApiProtocol.anthropicMessages:
        if (lower.endsWith('/messages')) {
          fullUrl = trimmed;
        } else if (parsedBase.path.isEmpty || parsedBase.path == '/') {
          fullUrl = '$trimmed/v1/messages';
        } else {
          fullUrl = '$trimmed/messages';
        }
      case AiApiProtocol.geminiGenerateContent:
        if (lower.endsWith(':generatecontent')) {
          fullUrl = trimmed;
        } else {
          final encodedModel = Uri.encodeComponent(model.trim());
          if (lower.endsWith('/models')) {
            fullUrl = '$trimmed/$encodedModel:generateContent';
          } else {
            fullUrl = '$trimmed/models/$encodedModel:generateContent';
          }
        }
    }
    return Uri.parse(fullUrl);
  }

  static bool containsForbiddenUrl(String value) {
    if (value.isEmpty) return false;
    return _forbiddenUrlLikeRe.hasMatch(value);
  }

  /// Core text/JSON completion entry point supporting OpenAI-compatible,
  /// Anthropic Messages, and Google Gemini protocols.
  Future<AiCompletionResult> complete({
    required String feature,
    required String userPrompt,
    String systemPrompt = '',
    String? modelOverride,
    double temperature = 0.2,
    int maxTokens = 1024,
    bool useCache = true,
    bool isPrivateSession = false,
    AiConfig? configOverride,
    String? apiKeyOverride,
    bool ignoreEnabledFlag = false,
  }) async {
    if (isPrivateSession) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已硬性禁用所有外部 AI 网络请求',
      );
    }
    if (OhosRuntime.isOhos) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '当前平台暂不支持 AI 助手',
      );
    }
    await ensureLoaded();

    final cfg = configOverride ?? _config;
    final key = (apiKeyOverride ?? _apiKey).trim();
    if (!ignoreEnabledFlag && !cfg.enabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        'AI 助手尚未启用',
      );
    }
    final effectiveModel = (modelOverride != null && modelOverride.trim().isNotEmpty)
        ? modelOverride.trim()
        : cfg.model.trim();
    if (cfg.baseUrl.trim().isEmpty || key.isEmpty || effectiveModel.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请先填写完整的接口地址、API 密钥与主模型名称',
      );
    }

    final uri = resolveEndpointUri(
      protocol: cfg.protocol,
      baseUrl: cfg.baseUrl,
      model: effectiveModel,
    );

    final cacheKey = computeCacheKey(
      feature: feature,
      protocol: cfg.protocol,
      model: effectiveModel,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
    );
    if (useCache) {
      final cached = _cache.remove(cacheKey);
      if (cached != null) {
        // Refresh LRU order and return at 0 token cost.
        _cache[cacheKey] = cached;
        return AiCompletionResult(
          text: cached,
          fromCache: true,
        );
      }
    }

    final usage = monthlyUsage;
    if (cfg.monthlyTokenBudget > 0 &&
        usage.totalTokens >= cfg.monthlyTokenBudget) {
      throw AiServiceException(
        AiErrorCode.budgetExceeded,
        '已超出本月 Token 预算上限（已用 ${usage.totalTokens} / 限额 ${cfg.monthlyTokenBudget}）',
      );
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final Map<String, dynamic> body;

    switch (cfg.protocol) {
      case AiApiProtocol.openaiCompatible:
        headers['Authorization'] = 'Bearer $key';
        body = <String, dynamic>{
          'model': effectiveModel,
          'messages': <Map<String, String>>[
            if (systemPrompt.trim().isNotEmpty)
              <String, String>{'role': 'system', 'content': systemPrompt},
            <String, String>{'role': 'user', 'content': userPrompt},
          ],
          'temperature': temperature,
          'max_tokens': maxTokens,
        };
      case AiApiProtocol.anthropicMessages:
        headers['x-api-key'] = key;
        headers['anthropic-version'] = '2023-06-01';
        body = <String, dynamic>{
          'model': effectiveModel,
          'max_tokens': maxTokens,
          if (systemPrompt.trim().isNotEmpty) 'system': systemPrompt,
          'messages': <Map<String, String>>[
            <String, String>{'role': 'user', 'content': userPrompt},
          ],
          'temperature': temperature,
        };
      case AiApiProtocol.geminiGenerateContent:
        headers['x-goog-api-key'] = key;
        body = <String, dynamic>{
          if (systemPrompt.trim().isNotEmpty)
            'systemInstruction': <String, dynamic>{
              'parts': <Map<String, String>>[
                <String, String>{'text': systemPrompt},
              ],
            },
          'contents': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'parts': <Map<String, String>>[
                <String, String>{'text': userPrompt},
              ],
            },
          ],
          'generationConfig': <String, dynamic>{
            'temperature': temperature,
            'maxOutputTokens': maxTokens,
          },
        };
    }

    final sw = Stopwatch()..start();
    final ephemeralClient = _injectedHttpClient == null;
    final client = _injectedHttpClient ?? http.Client();
    http.Response response;
    try {
      response = await client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: cfg.timeoutSeconds));
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        'AI 接口响应超时，请检查网络或调大超时时间',
      );
    } catch (_) {
      throw const AiServiceException(
        AiErrorCode.networkError,
        '无法连接到 AI 接口，请检查接口地址与网络状态',
      );
    } finally {
      sw.stop();
      if (ephemeralClient) {
        client.close();
      }
    }

    final status = response.statusCode;
    final rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (status < 200 || status >= 300) {
      throw _buildHttpError(status, rawBody);
    }

    final parsed = _parseProtocolResponse(
      protocol: cfg.protocol,
      rawBody: rawBody,
      fallbackPromptChars: systemPrompt.length + userPrompt.length,
    );

    await _recordUsage(
      promptTokens: parsed.promptTokens,
      completionTokens: parsed.completionTokens,
    );

    if (useCache && parsed.text.trim().isNotEmpty) {
      _cache.remove(cacheKey);
      if (_cache.length >= maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
      _cache[cacheKey] = parsed.text;
      unawaited(_persistCache());
    }

    return AiCompletionResult(
      text: parsed.text,
      promptTokens: parsed.promptTokens,
      completionTokens: parsed.completionTokens,
      fromCache: false,
      latencyMs: sw.elapsedMilliseconds,
    );
  }

  static AiServiceException _buildHttpError(int status, String rawBody) {
    String detail = '';
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] is String) {
          detail = (err['message'] as String).trim();
        } else if (err is String) {
          detail = err.trim();
        } else if (decoded['message'] is String) {
          detail = (decoded['message'] as String).trim();
        }
      }
    } catch (_) {}
    // Strip any URL from upstream error details to keep UI diagnostics clean.
    if (detail.isNotEmpty && containsForbiddenUrl(detail)) {
      detail = '';
    }
    if (detail.length > 80) {
      detail = '${detail.substring(0, 80)}…';
    }
    final suffix = detail.isNotEmpty ? '（$detail）' : '';

    if (status == 401 || status == 403) {
      return AiServiceException(
        AiErrorCode.unauthorized,
        '鉴权失败（HTTP $status）：请检查 API 密钥是否正确$suffix',
        statusCode: status,
      );
    }
    if (status == 404) {
      return AiServiceException(
        AiErrorCode.invalidEndpoint,
        '接口路径或模型不存在（HTTP 404）：请检查 Base URL 与模型名称$suffix',
        statusCode: status,
      );
    }
    if (status == 429) {
      return AiServiceException(
        AiErrorCode.rateLimited,
        '请求频率受限或账户额度不足（HTTP 429）$suffix',
        statusCode: status,
      );
    }
    return AiServiceException(
      AiErrorCode.networkError,
      '模型服务返回异常（HTTP $status）$suffix',
      statusCode: status,
    );
  }

  static ({String text, int promptTokens, int completionTokens})
      _parseProtocolResponse({
    required AiApiProtocol protocol,
    required String rawBody,
    required int fallbackPromptChars,
  }) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawBody);
    } catch (_) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型接口返回了非 JSON 响应',
      );
    }
    if (decoded is! Map) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型接口响应结构无效',
      );
    }

    String contentText = '';
    int? promptTok;
    int? completionTok;

    switch (protocol) {
      case AiApiProtocol.openaiCompatible:
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final first = choices.first as Map;
          final msg = first['message'];
          if (msg is Map) {
            final rawContent = msg['content'];
            if (rawContent is String) {
              contentText = rawContent.trim();
            } else if (rawContent is List) {
              final buf = StringBuffer();
              for (final part in rawContent) {
                if (part is Map && part['text'] is String) {
                  buf.write(part['text']);
                }
              }
              contentText = buf.toString().trim();
            }
          } else if (first['text'] is String) {
            contentText = (first['text'] as String).trim();
          }
        }
        final usage = decoded['usage'];
        if (usage is Map) {
          promptTok = (usage['prompt_tokens'] as num?)?.toInt() ??
              (usage['input_tokens'] as num?)?.toInt();
          completionTok = (usage['completion_tokens'] as num?)?.toInt() ??
              (usage['output_tokens'] as num?)?.toInt();
        }

      case AiApiProtocol.anthropicMessages:
        final content = decoded['content'];
        if (content is List) {
          final buf = StringBuffer();
          for (final block in content) {
            if (block is Map &&
                (block['type'] == null || block['type'] == 'text') &&
                block['text'] is String) {
              buf.write(block['text']);
            }
          }
          contentText = buf.toString().trim();
        } else if (content is String) {
          contentText = content.trim();
        }
        final usage = decoded['usage'];
        if (usage is Map) {
          promptTok = (usage['input_tokens'] as num?)?.toInt();
          completionTok = (usage['output_tokens'] as num?)?.toInt();
        }

      case AiApiProtocol.geminiGenerateContent:
        final candidates = decoded['candidates'];
        if (candidates is List &&
            candidates.isNotEmpty &&
            candidates.first is Map) {
          final candContent = (candidates.first as Map)['content'];
          if (candContent is Map && candContent['parts'] is List) {
            final buf = StringBuffer();
            for (final part in candContent['parts'] as List) {
              if (part is Map && part['text'] is String) {
                buf.write(part['text']);
              }
            }
            contentText = buf.toString().trim();
          }
        }
        final usageMeta = decoded['usageMetadata'];
        if (usageMeta is Map) {
          promptTok = (usageMeta['promptTokenCount'] as num?)?.toInt();
          completionTok = (usageMeta['candidatesTokenCount'] as num?)?.toInt();
        }
    }

    if (contentText.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型接口未返回有效文本内容',
      );
    }

    final resolvedPromptTokens =
        promptTok ?? ((fallbackPromptChars / 3).ceil().clamp(1, 100000));
    final resolvedCompletionTokens =
        completionTok ?? ((contentText.length / 3).ceil().clamp(1, 100000));

    return (
      text: contentText,
      promptTokens: resolvedPromptTokens,
      completionTokens: resolvedCompletionTokens,
    );
  }

  /// Sends a minimal ping (`Reply with OK`) to verify endpoint connectivity,
  /// authentication, and model availability.
  Future<AiConnectionTestResult> testConnection({
    AiConfig? configOverride,
    String? apiKeyOverride,
    bool isPrivateSession = false,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final res = await complete(
        feature: 'ping',
        systemPrompt:
            'You are a connectivity check endpoint. Reply concisely with OK only. Never output URLs or links.',
        userPrompt: 'Reply with OK',
        temperature: 0.0,
        maxTokens: 16,
        useCache: false,
        isPrivateSession: isPrivateSession,
        configOverride: configOverride,
        apiKeyOverride: apiKeyOverride,
        ignoreEnabledFlag: true,
      );
      sw.stop();
      final ms = res.latencyMs > 0 ? res.latencyMs : sw.elapsedMilliseconds;
      var preview = res.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (containsForbiddenUrl(preview)) {
        preview = 'OK';
      } else if (preview.length > 24) {
        preview = '${preview.substring(0, 24)}…';
      }
      return AiConnectionTestResult(
        ok: true,
        latencyMs: ms,
        modelReply: preview,
        messageZh: '连接成功（${ms}ms）· 响应：$preview',
      );
    } on AiServiceException catch (e) {
      sw.stop();
      return AiConnectionTestResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        messageZh: e.messageZh,
      );
    } catch (_) {
      sw.stop();
      return AiConnectionTestResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        messageZh: '连接测试失败，请检查接口配置与网络状态',
      );
    }
  }

  static const String _nlSearchSystemPrompt =
      '你是本地影视检索助手。请根据用户的自然语言找片描述，推荐 5 到 8 部高度契合的真实影视作品候选。\n'
      '严格只输出纯 JSON 数组，格式为：'
      '[{"title":"标准中文片名","year":"2014","reason":"一句话推荐理由（24字以内）"}]。\n'
      '安全与合规硬性约束：只允许输出结构化影视元数据（title、year、reason）；'
      '严禁生成或返回任何网址、URL、域名、网盘分享链接、磁力链接或流媒体播放地址；'
      '严禁输出 Markdown 代码块或任何额外解释文字。';

  /// Translates a natural-language description into 5–8 structured movie/series
  /// candidates (`title`, `year`, `reason`) to be matched against the user's
  /// own configured `CmsSite` sources.
  Future<List<AiMovieCandidate>> suggestSearchCandidates(
    String naturalQuery, {
    bool isPrivateSession = false,
  }) async {
    final trimmed = naturalQuery.trim();
    if (trimmed.isEmpty) return const <AiMovieCandidate>[];
    if (isPrivateSession) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已硬性禁用所有外部 AI 网络请求',
      );
    }
    await ensureLoaded();
    if (!_config.nlSearchEnabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '自然语言找片开关未开启',
      );
    }

    final completion = await complete(
      feature: 'nl_search_v1',
      systemPrompt: _nlSearchSystemPrompt,
      userPrompt: trimmed,
      temperature: 0.3,
      maxTokens: 768,
      useCache: true,
      isPrivateSession: isPrivateSession,
    );
    return parseSearchCandidatesJson(completion.text);
  }

  /// Extracts and validates the JSON array of [AiMovieCandidate]s, stripping
  /// optional markdown fences and rejecting any item carrying URLs/links.
  static List<AiMovieCandidate> parseSearchCandidatesJson(String rawText) {
    final jsonSlice = extractJsonArraySlice(rawText);
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonSlice);
    } catch (_) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型返回的推荐列表不是合法的 JSON 格式',
      );
    }
    if (decoded is! List) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型返回的推荐列表格式无效',
      );
    }

    final results = <AiMovieCandidate>[];
    final seenTitles = <String>{};
    var rejectedForUrl = 0;

    for (final entry in decoded) {
      if (entry is! Map) continue;
      if (_mapContainsAnyUrl(entry)) {
        rejectedForUrl++;
        continue;
      }
      final rawTitle = (entry['title'] ?? entry['name'] ?? '').toString().trim();
      if (rawTitle.isEmpty || rawTitle.length > 80) continue;
      if (containsForbiddenUrl(rawTitle)) {
        rejectedForUrl++;
        continue;
      }
      final normTitle = rawTitle.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (!seenTitles.add(normTitle)) continue;

      final rawYear = (entry['year'] ?? '').toString().trim();
      final yearMatch = RegExp(r'^(?:19|20)\d{2}$').firstMatch(rawYear);
      final cleanYear = yearMatch != null ? rawYear : '';

      var cleanReason = (entry['reason'] ?? '').toString().trim();
      cleanReason = cleanReason.replaceAll(RegExp(r'\s+'), ' ');
      if (containsForbiddenUrl(cleanReason)) {
        rejectedForUrl++;
        continue;
      }
      if (cleanReason.length > 64) {
        cleanReason = '${cleanReason.substring(0, 64)}…';
      }

      results.add(
        AiMovieCandidate(
          title: rawTitle,
          year: cleanYear,
          reason: cleanReason,
        ),
      );
      if (results.length >= 8) break;
    }

    if (results.isEmpty && rejectedForUrl > 0) {
      throw const AiServiceException(
        AiErrorCode.unsafeOutputRejected,
        '模型返回内容包含不允许的链接字段，已安全拦截',
      );
    }
    return List<AiMovieCandidate>.unmodifiable(results);
  }

  /// Strips optional Markdown code fences and extracts the outermost `[...]` JSON array.
  static String extractJsonArraySlice(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      s = s
          .replaceFirst(RegExp(r'^```(?:json|JSON)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '')
          .trim();
    }
    final start = s.indexOf('[');
    final end = s.lastIndexOf(']');
    if (start < 0 || end <= start) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型未返回有效的 JSON 数组',
      );
    }
    return s.substring(start, end + 1);
  }

  static bool _mapContainsAnyUrl(Map<dynamic, dynamic> map) {
    for (final entry in map.entries) {
      final k = entry.key.toString().trim().toLowerCase();
      if (k == 'url' ||
          k == 'play_url' ||
          k == 'playurl' ||
          k == 'stream' ||
          k == 'link' ||
          k == 'href') {
        final v = (entry.value ?? '').toString().trim();
        if (v.isNotEmpty) return true;
      }
      final val = entry.value;
      if (val is String && containsForbiddenUrl(val)) return true;
      if (val is Map && _mapContainsAnyUrl(val)) return true;
      if (val is List) {
        for (final sub in val) {
          if (sub is String && containsForbiddenUrl(sub)) return true;
          if (sub is Map && _mapContainsAnyUrl(sub)) return true;
        }
      }
    }
    return false;
  }
}

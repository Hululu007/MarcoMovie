import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_lab_gate.dart';
import 'ohos_runtime.dart';
import 'secure_credential_store.dart';

/// Authentication mode for the AI Assistant.
enum AiAuthMode {
  apiKey('api_key', 'API 密钥'),
  codexOAuth('codex_oauth', 'GPT 订阅账号');

  final String id;
  final String labelZh;

  const AiAuthMode(this.id, this.labelZh);

  static AiAuthMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in AiAuthMode.values) {
      if (mode.id == normalized) return mode;
    }
    return AiAuthMode.apiKey;
  }
}

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

/// Discovered model entry from `/models` or Codex subscription catalog.
@immutable
class AiModelOption {
  final String id;
  final String displayName;
  final String description;
  final int priority;

  const AiModelOption({
    required this.id,
    String? displayName,
    this.description = '',
    this.priority = 1000,
  }) : displayName = (displayName == null || displayName == '') ? id : displayName;

  bool get hasDistinctDisplayName =>
      displayName.trim().isNotEmpty &&
      displayName.trim().toLowerCase() != id.trim().toLowerCase();
}

/// OAuth 2.0 PKCE session credentials for ChatGPT Plus / Pro / Team subscription
/// access. Persisted exclusively inside [SecureStorageBackend] (iOS Keychain)
/// and NEVER written to [SharedPreferences] or WebDAV sync backups.
@immutable
class AiOAuthSession {
  final String accessToken;
  final String refreshToken;
  final int expiresAtEpochMs;
  final String accountId;
  final String planType;
  final String email;

  const AiOAuthSession({
    required this.accessToken,
    this.refreshToken = '',
    this.expiresAtEpochMs = 0,
    this.accountId = '',
    this.planType = '',
    this.email = '',
  });

  bool get isValid => accessToken.trim().isNotEmpty;

  bool isExpiringSoon(DateTime now) {
    if (expiresAtEpochMs <= 0) return false;
    return now.millisecondsSinceEpoch >= (expiresAtEpochMs - 60000);
  }

  String get planBadgeLabel {
    final p = planType.trim().toLowerCase();
    if (p.isEmpty) return 'ChatGPT 订阅';
    return switch (p) {
      'pro' => 'ChatGPT Pro',
      'plus' => 'ChatGPT Plus',
      'team' => 'ChatGPT Team',
      'enterprise' => 'ChatGPT Enterprise',
      'edu' => 'ChatGPT Edu',
      'free' => 'ChatGPT Free',
      _ => 'ChatGPT ${p[0].toUpperCase()}${p.substring(1)}',
    };
  }

  String get maskedIdentity {
    final e = email.trim();
    if (e.contains('@')) {
      final parts = e.split('@');
      final local = parts.first;
      final domain = parts.sublist(1).join('@');
      if (local.length <= 2) {
        return '${local.isEmpty ? '*' : local[0]}***@$domain';
      }
      return '${local.substring(0, 2)}***@$domain';
    }
    final acc = accountId.trim();
    if (acc.length > 8) {
      return '账号 ${acc.substring(0, 6)}…';
    }
    return acc.isNotEmpty ? '账号 $acc' : '已授权订阅账号';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAtEpochMs': expiresAtEpochMs,
        'accountId': accountId,
        'planType': planType,
        'email': email,
      };

  factory AiOAuthSession.fromJson(Map<String, dynamic> json) {
    return AiOAuthSession(
      accessToken: (json['accessToken'] ?? '').toString().trim(),
      refreshToken: (json['refreshToken'] ?? '').toString().trim(),
      expiresAtEpochMs: (json['expiresAtEpochMs'] as num?)?.toInt() ?? 0,
      accountId: (json['accountId'] ?? '').toString().trim(),
      planType: (json['planType'] ?? '').toString().trim(),
      email: (json['email'] ?? '').toString().trim(),
    );
  }
}

/// PKCE S256 authorization request state for ChatGPT subscription sign-in.
@immutable
class AiPkceAuthRequest {
  final Uri authorizeUri;
  final String state;
  final String codeVerifier;
  final String redirectUri;

  const AiPkceAuthRequest({
    required this.authorizeUri,
    required this.state,
    required this.codeVerifier,
    required this.redirectUri,
  });
}

/// Active loopback OAuth login session listening on `localhost:1455` while also
/// allowing manual callback URL / token JSON paste if a VPN intercepts loopback.
class AiPendingOAuthLogin {
  final AiPkceAuthRequest request;
  final Future<AiOAuthSession> future;
  final Future<void> Function() cancel;

  const AiPendingOAuthLogin({
    required this.request,
    required this.future,
    required this.cancel,
  });
}

/// Immutable non-secret AI configuration persisted in local [SharedPreferences].
///
/// Security & compliance invariants:
/// - Default [baseUrl], [model], and [fastModel] are strictly `""`.
/// - Zero built-in keys exist in the binary.
/// - API keys and OAuth tokens are NEVER stored in [AiConfig],
///   [SharedPreferences], or sync payloads; they live exclusively in
///   [SecureStorageBackend] (iOS Keychain).
@immutable
class AiConfig {
  static const int minTimeoutSeconds = 5;
  static const int maxTimeoutSeconds = 120;
  static const int defaultTimeoutSeconds = 25;

  final bool enabled;
  final AiAuthMode authMode;
  final AiApiProtocol protocol;
  final String baseUrl;
  final String model;
  final String fastModel;
  final int timeoutSeconds;
  final int monthlyTokenBudget;
  final bool nlSearchEnabled;
  final bool titleCleanupEnabled;
  final bool subtitleTranslateEnabled;
  final bool spoilerFreeRecapEnabled;
  final bool moodCurationEnabled;
  final bool smartDiagnosticsEnabled;
  final List<AiCustomSkill> customSkills;
  final bool firstUseConsentAccepted;

  const AiConfig({
    this.enabled = false,
    this.authMode = AiAuthMode.apiKey,
    this.protocol = AiApiProtocol.openaiCompatible,
    this.baseUrl = '',
    this.model = '',
    this.fastModel = '',
    this.timeoutSeconds = defaultTimeoutSeconds,
    this.monthlyTokenBudget = 0,
    this.nlSearchEnabled = true,
    this.titleCleanupEnabled = true,
    this.subtitleTranslateEnabled = true,
    this.spoilerFreeRecapEnabled = true,
    this.moodCurationEnabled = true,
    this.smartDiagnosticsEnabled = true,
    this.customSkills = const <AiCustomSkill>[],
    this.firstUseConsentAccepted = false,
  });

  List<AiCustomSkill> get effectiveSkills => <AiCustomSkill>[
        ...AiCustomSkill.defaultBuiltInSkills,
        ...customSkills,
      ];

  /// Secondary lightweight model for batch filename cleanup; falls back to [model].
  String get effectiveFastModel {
    final fast = fastModel.trim();
    return fast.isNotEmpty ? fast : model.trim();
  }

  AiConfig copyWith({
    bool? enabled,
    AiAuthMode? authMode,
    AiApiProtocol? protocol,
    String? baseUrl,
    String? model,
    String? fastModel,
    int? timeoutSeconds,
    int? monthlyTokenBudget,
    bool? nlSearchEnabled,
    bool? titleCleanupEnabled,
    bool? subtitleTranslateEnabled,
    bool? spoilerFreeRecapEnabled,
    bool? moodCurationEnabled,
    bool? smartDiagnosticsEnabled,
    List<AiCustomSkill>? customSkills,
    bool? firstUseConsentAccepted,
  }) {
    final nextTimeout = (timeoutSeconds ?? this.timeoutSeconds)
        .clamp(minTimeoutSeconds, maxTimeoutSeconds);
    final nextBudget = (monthlyTokenBudget ?? this.monthlyTokenBudget);
    return AiConfig(
      enabled: enabled ?? this.enabled,
      authMode: authMode ?? this.authMode,
      protocol: protocol ?? this.protocol,
      baseUrl: (baseUrl ?? this.baseUrl).trim(),
      model: (model ?? this.model).trim(),
      fastModel: (fastModel ?? this.fastModel).trim(),
      timeoutSeconds: nextTimeout,
      monthlyTokenBudget: nextBudget < 0 ? 0 : nextBudget,
      nlSearchEnabled: nlSearchEnabled ?? this.nlSearchEnabled,
      titleCleanupEnabled: titleCleanupEnabled ?? this.titleCleanupEnabled,
      subtitleTranslateEnabled:
          subtitleTranslateEnabled ?? this.subtitleTranslateEnabled,
      spoilerFreeRecapEnabled:
          spoilerFreeRecapEnabled ?? this.spoilerFreeRecapEnabled,
      moodCurationEnabled: moodCurationEnabled ?? this.moodCurationEnabled,
      smartDiagnosticsEnabled:
          smartDiagnosticsEnabled ?? this.smartDiagnosticsEnabled,
      customSkills: customSkills ?? this.customSkills,
      firstUseConsentAccepted:
          firstUseConsentAccepted ?? this.firstUseConsentAccepted,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'authMode': authMode.id,
        'protocol': protocol.id,
        'baseUrl': baseUrl.trim(),
        'model': model.trim(),
        'fastModel': fastModel.trim(),
        'timeoutSeconds': timeoutSeconds,
        'monthlyTokenBudget': monthlyTokenBudget,
        'nlSearchEnabled': nlSearchEnabled,
        'titleCleanupEnabled': titleCleanupEnabled,
        'subtitleTranslateEnabled': subtitleTranslateEnabled,
        'spoilerFreeRecapEnabled': spoilerFreeRecapEnabled,
        'moodCurationEnabled': moodCurationEnabled,
        'smartDiagnosticsEnabled': smartDiagnosticsEnabled,
        if (customSkills.isNotEmpty)
          'customSkills': customSkills.map((s) => s.toJson()).toList(),
        'firstUseConsentAccepted': firstUseConsentAccepted,
      };

  factory AiConfig.fromJson(Map<String, dynamic> json) {
    final rawTimeout = (json['timeoutSeconds'] as num?)?.toInt() ??
        AiConfig.defaultTimeoutSeconds;
    final rawBudget = (json['monthlyTokenBudget'] as num?)?.toInt() ?? 0;
    final parsedSkills = <AiCustomSkill>[];
    if (json['customSkills'] is List) {
      for (final item in json['customSkills'] as List) {
        if (item is Map) {
          final s = AiCustomSkill.fromJson(Map<String, dynamic>.from(item));
          if (s.id.isNotEmpty && s.name.isNotEmpty && s.promptTemplate.isNotEmpty) {
            parsedSkills.add(s);
          }
        }
      }
    }
    return AiConfig(
      enabled: json['enabled'] == true,
      authMode: AiAuthMode.fromId(json['authMode']?.toString()),
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
      subtitleTranslateEnabled: json['subtitleTranslateEnabled'] != false,
      spoilerFreeRecapEnabled: json['spoilerFreeRecapEnabled'] != false,
      moodCurationEnabled: json['moodCurationEnabled'] != false,
      smartDiagnosticsEnabled: json['smartDiagnosticsEnabled'] != false,
      customSkills: List<AiCustomSkill>.unmodifiable(parsedSkills),
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
      promptTokens:
          ((json['promptTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      completionTokens:
          ((json['completionTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      requestCount:
          ((json['requestCount'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
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

/// Self-contained BYO-API & Subscription OAuth client, Keychain credential
/// manager, live model catalog fetcher, response cache, monthly token budget
/// guard, and Privacy Space hard-blocker.
class AiService extends ChangeNotifier {
  static const String prefsConfigKey = 'marco_ai_config_v1';
  static const String prefsUsageKey = 'marco_ai_usage_v1';
  static const String prefsCacheKey = 'marco_ai_cache_v1';
  static const String secureApiKeySlot = 'marco_ai_api_key_v1';
  static const String secureOAuthSessionSlot = 'marco_ai_oauth_session_v1';
  static const String secureLabTokenSlot = 'marco_ai_lab_token_v1';
  static const int maxCacheEntries = 200;

  // Official public PKCE client parameters for user-initiated ChatGPT
  // subscription sign-in (aligned with OpenMinis / Codex CLI PKCE spec).
  static const String codexClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const String codexClientVersion = '0.159.0';
  static const int codexLoopbackPort = 1455;
  static const String codexRedirectUri = 'http://localhost:1455/auth/callback';
  static const String _defaultCodexAuthorizeEndpoint =
      'https://auth.openai.com/oauth/authorize';
  static const String _defaultCodexTokenEndpoint =
      'https://auth.openai.com/oauth/token';
  static const String _defaultCodexModelsEndpoint =
      'https://chatgpt.com/backend-api/codex/models';
  static const String _defaultCodexResponsesEndpoint =
      'https://chatgpt.com/backend-api/codex/responses';
  static const String _jwtAuthClaimNamespace = 'https://api.openai.com/auth';

  /// Quick fill presets offered only when the user explicitly taps a vendor
  /// chip in `IosAiSettingsPage` (default Base URL remains `""`).
  static const List<({String label, AiApiProtocol protocol, String baseUrl})>
      quickApiPresets = <({String label, AiApiProtocol protocol, String baseUrl})>[
    (
      label: 'OpenAI',
      protocol: AiApiProtocol.openaiCompatible,
      baseUrl: 'https://api.openai.com/v1',
    ),
    (
      label: 'DeepSeek',
      protocol: AiApiProtocol.openaiCompatible,
      baseUrl: 'https://api.deepseek.com/v1',
    ),
    (
      label: 'Anthropic',
      protocol: AiApiProtocol.anthropicMessages,
      baseUrl: 'https://api.anthropic.com',
    ),
    (
      label: 'Gemini',
      protocol: AiApiProtocol.geminiGenerateContent,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    ),
    (
      label: '硅基流动',
      protocol: AiApiProtocol.openaiCompatible,
      baseUrl: 'https://api.siliconflow.cn/v1',
    ),
  ];

  static const List<AiModelOption> fallbackCodexModels = <AiModelOption>[
    AiModelOption(
      id: 'gpt-5.4',
      displayName: 'GPT-5.4',
      description: '最新旗舰通用与推理模型',
      priority: 1,
    ),
    AiModelOption(
      id: 'gpt-5.3-codex',
      displayName: 'GPT-5.3 Codex',
      description: '高速结构化理解与分析模型',
      priority: 2,
    ),
    AiModelOption(
      id: 'codex-mini-latest',
      displayName: 'Codex Mini',
      description: '轻量极速低延迟模型（适合标题清洗）',
      priority: 3,
    ),
  ];

  static final RegExp _forbiddenUrlLikeRe = RegExp(
    r'(?:https?://|ftp://|magnet:\?|ed2k://|thunder://|mms://|rtmp://|rtsp://|\bwww\.[a-z0-9-]+\.[a-z]{2,})',
    caseSensitive: false,
  );

  static final AiService instance = AiService();

  http.Client? _injectedHttpClient;
  SecureStorageBackend _secureBackend;
  AiLabPasscodeStore _passcodeStore;
  DateTime Function() _clock;
  String? _codexTokenEndpointOverride;
  String? _codexModelsEndpointOverride;
  String? _codexResponsesEndpointOverride;

  AiConfig _config = const AiConfig();
  String _apiKey = '';
  AiOAuthSession? _oauthSession;
  bool? _debugLabUnlockedOverride;
  bool? _debugExperimentalOAuthOverride;
  List<AiModelOption> _discoveredModels = const <AiModelOption>[];
  AiMonthlyUsage? _usage;
  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<AiOAuthSession>? _inFlightTokenRefresh;

  AiService({
    http.Client? httpClient,
    SecureStorageBackend? secureStorage,
    AiLabPasscodeStore? passcodeStore,
    DateTime Function()? clock,
  })  : _injectedHttpClient = httpClient,
        _secureBackend = secureStorage ?? const FlutterSecureStorageBackend(),
        _passcodeStore = passcodeStore ?? AiLabPasscodeStore.instance,
        _clock = clock ?? DateTime.now {
    _passcodeStore.addListener(_onPasscodeStoreChanged);
  }

  void _onPasscodeStoreChanged() {
    notifyListeners();
  }

  AiConfig get config => _config;
  bool get isLoaded => _loaded;
  bool get hasApiKey => _apiKey.trim().isNotEmpty;
  AiOAuthSession? get oauthSession => _oauthSession;
  bool get hasOAuthSession => _oauthSession?.isValid == true;
  AiLabPasscodeStore get passcodeStore => _passcodeStore;
  AiLabPasscodePayload? get activePasscodePayload =>
      _passcodeStore.activePayloadAt(_clock());
  AiLabTokenClaims? get labTokenClaims {
    final p = activePasscodePayload;
    if (p == null) return null;
    return AiLabTokenClaims(rawToken: _passcodeStore.storedToken, payload: p);
  }
  List<AiModelOption> get discoveredModels => _discoveredModels;
  int get cachedEntryCount => _cache.length;

  /// True when the experimental AI Viewing Lab gate has been unlocked via a
  /// valid, platform-matching, non-expired Ed25519 passcode (`MMAILAB1...`).
  bool get isLabUnlocked {
    if (OhosRuntime.isOhos) return false;
    if (_debugLabUnlockedOverride != null) return _debugLabUnlockedOverride!;
    return _passcodeStore.isUnlockedAt(_clock());
  }

  /// True when the active passcode grants experimental OpenAI OAuth (`exp_oauth`).
  bool get isExperimentalOAuthAllowed {
    if (!isLabUnlocked) return false;
    if (_debugExperimentalOAuthOverride != null) {
      return _debugExperimentalOAuthOverride!;
    }
    final p = activePasscodePayload;
    if (p != null) return p.experimentalOAuth;
    return _debugLabUnlockedOverride == true;
  }

  void _ensureLabGateAuthorized({bool requireExperimentalOAuth = false}) {
    if (!isLabUnlocked) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        'AI 观影实验室尚未通过内测口令解锁',
      );
    }
    if (requireExperimentalOAuth && !isExperimentalOAuthAllowed) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '当前内测口令未开放实验性 OpenAI OAuth 权限，请使用个人 API 密钥或更换口令',
      );
    }
  }

  /// True when both the experimental AI Lab passcode is unlocked AND model
  /// credentials are configured.
  bool get isUnlockedAndConfigured => isLabUnlocked && isConfigured;

  /// True when AI Assistant is enabled and has valid credentials + model for
  /// the active [AiConfig.authMode].
  bool get isConfigured {
    if (OhosRuntime.isOhos || !isLabUnlocked || !_config.enabled) return false;
    if (_config.model.trim().isEmpty) return false;
    return switch (_config.authMode) {
      AiAuthMode.codexOAuth => isExperimentalOAuthAllowed && hasOAuthSession,
      AiAuthMode.apiKey =>
        _config.baseUrl.trim().isNotEmpty && _apiKey.trim().isNotEmpty,
    };
  }

  String get statusSummaryZh {
    if (!isLabUnlocked) {
      return '内测中 · 输入口令开启';
    }
    if (!isConfigured) {
      return _config.authMode == AiAuthMode.codexOAuth &&
              isExperimentalOAuthAllowed
          ? '未登录订阅账号'
          : '未配置';
    }
    if (_config.authMode == AiAuthMode.codexOAuth &&
        isExperimentalOAuthAllowed) {
      return '${_oauthSession!.planBadgeLabel} · ${_config.model}';
    }
    return '${_config.protocol.labelZh} · ${_config.model}';
  }

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
    AiLabPasscodeStore? passcodeStore,
    DateTime Function()? clock,
    String? codexTokenEndpoint,
    String? codexModelsEndpoint,
    String? codexResponsesEndpoint,
    bool? labUnlockedForTest = true,
    bool? experimentalOAuthForTest,
    bool resetState = false,
  }) {
    if (httpClient != null) _injectedHttpClient = httpClient;
    if (secureStorage != null) _secureBackend = secureStorage;
    if (passcodeStore != null && !identical(passcodeStore, _passcodeStore)) {
      _passcodeStore.removeListener(_onPasscodeStoreChanged);
      _passcodeStore = passcodeStore;
      _passcodeStore.addListener(_onPasscodeStoreChanged);
    }
    if (clock != null) _clock = clock;
    if (codexTokenEndpoint != null) {
      _codexTokenEndpointOverride = codexTokenEndpoint;
    }
    if (codexModelsEndpoint != null) {
      _codexModelsEndpointOverride = codexModelsEndpoint;
    }
    if (codexResponsesEndpoint != null) {
      _codexResponsesEndpointOverride = codexResponsesEndpoint;
    }
    if (resetState) {
      _config = const AiConfig();
      _apiKey = '';
      _oauthSession = null;
      _discoveredModels = const <AiModelOption>[];
      _usage = null;
      _cache.clear();
      _loaded = false;
      _loadFuture = null;
      _inFlightTokenRefresh = null;
    }
    _debugLabUnlockedOverride = labUnlockedForTest;
    _debugExperimentalOAuthOverride = experimentalOAuthForTest;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _injectedHttpClient = null;
    _secureBackend = const FlutterSecureStorageBackend();
    if (!identical(_passcodeStore, AiLabPasscodeStore.instance)) {
      _passcodeStore.removeListener(_onPasscodeStoreChanged);
      _passcodeStore = AiLabPasscodeStore.instance;
      _passcodeStore.addListener(_onPasscodeStoreChanged);
    }
    _clock = DateTime.now;
    _codexTokenEndpointOverride = null;
    _codexModelsEndpointOverride = null;
    _codexResponsesEndpointOverride = null;
    _config = const AiConfig();
    _apiKey = '';
    _oauthSession = null;
    _debugLabUnlockedOverride = null;
    _debugExperimentalOAuthOverride = null;
    _discoveredModels = const <AiModelOption>[];
    _usage = null;
    _cache.clear();
    _loaded = false;
    _loadFuture = null;
    _inFlightTokenRefresh = null;
    notifyListeners();
  }

  /// Ensures local preferences, monthly token counters, cache, and Keychain
  /// credentials have been loaded into memory.
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

      await _passcodeStore.ensureLoaded();

      try {
        final storedKey = await _secureBackend.read(secureApiKeySlot);
        _apiKey = (storedKey ?? '').trim();
      } catch (_) {
        _apiKey = '';
      }

      try {
        final storedOAuth = await _secureBackend.read(secureOAuthSessionSlot);
        if (storedOAuth != null && storedOAuth.trim().isNotEmpty) {
          final parsedOAuth = jsonDecode(storedOAuth);
          if (parsedOAuth is Map) {
            final session =
                AiOAuthSession.fromJson(Map<String, dynamic>.from(parsedOAuth));
            _oauthSession = session.isValid ? session : null;
          }
        } else {
          _oauthSession = null;
        }
      } catch (_) {
        _oauthSession = null;
      }

      if (!_passcodeStore.isUnlockedAt(_clock())) {
        // One-time migration if an earlier build saved a token in Keychain only.
        if (_secureBackend is! FlutterSecureStorageBackend) {
          try {
            final storedLabTok = await _secureBackend.read(secureLabTokenSlot);
            if (storedLabTok != null && storedLabTok.trim().isNotEmpty) {
              await _passcodeStore.unlockWithPasscode(
                storedLabTok,
                nowOverride: _clock(),
              );
            }
          } catch (_) {}
        }
      }
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

  /// Verifies an offline Ed25519-signed AI Lab passcode (`MMAILAB1...`) via
  /// [AiLabPasscodeStore], persists the signed token, and unlocks AI Lab.
  Future<AiLabTokenClaims> unlockAiLab(String rawPasscode) async {
    final res = await _passcodeStore.unlockWithPasscode(
      rawPasscode,
      nowOverride: _clock(),
    );
    if (!res.isValid || res.payload == null) {
      throw FormatException(res.messageZh);
    }
    notifyListeners();
    return AiLabTokenClaims(
      rawToken: res.canonicalToken,
      payload: res.payload!,
    );
  }

  /// Non-throwing passcode activation returning the rich [AiLabPasscodeVerifyResult].
  Future<AiLabPasscodeVerifyResult> verifyAndUnlockAiLab(
    String rawPasscode,
  ) async {
    final res = await _passcodeStore.unlockWithPasscode(
      rawPasscode,
      nowOverride: _clock(),
    );
    notifyListeners();
    return res;
  }

  /// Clears the stored AI Lab passcode and returns AI Lab to locked state.
  Future<void> lockAiLab() async {
    _debugLabUnlockedOverride = null;
    _debugExperimentalOAuthOverride = null;
    await _passcodeStore.lock();
    notifyListeners();
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

  /// Saves or clears the OAuth subscription session strictly inside Keychain.
  Future<void> setOAuthSession(AiOAuthSession? session) async {
    await ensureLoaded();
    if (session == null || !session.isValid) {
      _oauthSession = null;
      await _secureBackend.delete(secureOAuthSessionSlot);
    } else {
      _oauthSession = session;
      await _secureBackend.write(
        secureOAuthSessionSlot,
        jsonEncode(session.toJson()),
      );
    }
    notifyListeners();
  }

  /// Signs out of the current OAuth subscription account and clears Keychain.
  Future<void> signOutOAuth() async {
    await setOAuthSession(null);
    _discoveredModels = const <AiModelOption>[];
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

  // ---------------------------------------------------------------------------
  // ChatGPT Subscription PKCE OAuth 2.0 & Codex Token Management
  // ---------------------------------------------------------------------------

  static String _randomBase64Url(int byteLength) {
    final rng = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Builds a fresh S256 PKCE authorization request matching Codex CLI / OpenMinis.
  static AiPkceAuthRequest createCodexPkceRequest({
    String redirectUri = codexRedirectUri,
  }) {
    final verifier = _randomBase64Url(32);
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final state = _randomBase64Url(24);
    final authorizeUri = Uri.parse(_defaultCodexAuthorizeEndpoint).replace(
      queryParameters: <String, String>{
        'response_type': 'code',
        'client_id': codexClientId,
        'redirect_uri': redirectUri,
        'scope': 'openid profile email offline_access',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'codex_cli_simplified_flow': 'true',
        'originator': 'codex_cli_rs',
        'id_token_add_organizations': 'true',
      },
    );
    return AiPkceAuthRequest(
      authorizeUri: authorizeUri,
      state: state,
      codeVerifier: verifier,
      redirectUri: redirectUri,
    );
  }

  /// Extracts `chatgpt_account_id`, `chatgpt_plan_type`, and `email` from JWT
  /// payload claims without logging or exposing raw tokens.
  static ({String accountId, String planType, String email})
      extractCodexJwtClaims({
    String? idToken,
    String? accessToken,
  }) {
    Map<String, dynamic>? decodePayload(String? jwt) {
      if (jwt == null || jwt.isEmpty) return null;
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      try {
        var b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
        while (b64.length % 4 != 0) {
          b64 += '=';
        }
        final jsonStr = utf8.decode(base64Decode(b64), allowMalformed: true);
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return null;
    }

    String accountId = '';
    String planType = '';
    String email = '';

    for (final claims in <Map<String, dynamic>?>[
      decodePayload(idToken),
      decodePayload(accessToken),
    ]) {
      if (claims == null) continue;
      if (email.isEmpty && claims['email'] is String) {
        email = (claims['email'] as String).trim();
      }
      final authObj = claims[_jwtAuthClaimNamespace];
      if (authObj is Map) {
        if (accountId.isEmpty && authObj['chatgpt_account_id'] is String) {
          accountId = (authObj['chatgpt_account_id'] as String).trim();
        }
        if (planType.isEmpty && authObj['chatgpt_plan_type'] is String) {
          planType = (authObj['chatgpt_plan_type'] as String).trim();
        }
      }
      if (accountId.isEmpty && claims['chatgpt_account_id'] is String) {
        accountId = (claims['chatgpt_account_id'] as String).trim();
      }
      if (planType.isEmpty && claims['chatgpt_plan_type'] is String) {
        planType = (claims['chatgpt_plan_type'] as String).trim();
      }
    }
    return (accountId: accountId, planType: planType, email: email);
  }

  /// Starts dual-stack (`127.0.0.1` + `::1`) loopback callback servers on port
  /// `1455` and awaits the OAuth redirect from Safari / `SFSafariViewController`.
  Future<AiPendingOAuthLogin> startInteractiveCodexLogin() async {
    await ensureLoaded();
    _ensureLabGateAuthorized(requireExperimentalOAuth: true);
    final pkce = createCodexPkceRequest();
    final servers = <HttpServer>[];
    final completer = Completer<AiOAuthSession>();

    Future<void> closeServers() async {
      final copy = List<HttpServer>.of(servers);
      servers.clear();
      for (final srv in copy) {
        try {
          await srv.close(force: true);
        } catch (_) {}
      }
    }

    void handleHttpRequest(HttpRequest req) async {
      final uri = req.uri;
      if (uri.path != '/auth/callback') {
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
        await req.response.close();
        return;
      }

      final errorParam = (uri.queryParameters['error'] ?? '').trim();
      final code = (uri.queryParameters['code'] ?? '').trim();
      final returnedState = (uri.queryParameters['state'] ?? '').trim();

      final okHtml = errorParam.isEmpty &&
          code.isNotEmpty &&
          (returnedState.isEmpty || returnedState == pkce.state);

      req.response.statusCode = okHtml ? HttpStatus.ok : HttpStatus.badRequest;
      req.response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      req.response.write(
        okHtml
            ? '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>授权成功</title></head><body style="font-family:-apple-system,sans-serif;'
                'background:#0c0c0e;color:#fff;display:flex;align-items:center;justify-content:center;'
                'height:90vh;margin:0;text-align:center;"><div><h2 style="margin-bottom:8px;">已成功连接订阅账号</h2>'
                '<p style="color:#9ea4b0;font-size:14px;">正在自动返回 Marco Movie…</p>'
                '<script>setTimeout(function(){window.close();},400);</script></div></body></html>'
            : '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>授权未完成</title></head><body style="font-family:-apple-system,sans-serif;'
                'background:#0c0c0e;color:#fff;padding:32px;text-align:center;">'
                '<h3>授权未完成，请返回应用重试</h3></body></html>',
      );
      await req.response.close();
      await closeServers();

      if (completer.isCompleted) return;
      if (!okHtml) {
        completer.completeError(
          AiServiceException(
            AiErrorCode.unauthorized,
            errorParam.isNotEmpty ? '授权已取消或被拒绝（$errorParam）' : '回调参数校验未通过，请重新发起登录',
          ),
        );
        return;
      }

      try {
        final session = await exchangeCodexAuthorizationCode(
          code: code,
          codeVerifier: pkce.codeVerifier,
          redirectUri: pkce.redirectUri,
        );
        if (!completer.isCompleted) {
          completer.complete(session);
        }
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      }
    }

    try {
      final v4 = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        codexLoopbackPort,
        shared: true,
      );
      servers.add(v4);
      v4.listen(handleHttpRequest, onError: (_) {});
    } catch (_) {}

    try {
      final v6 = await HttpServer.bind(
        InternetAddress.loopbackIPv6,
        codexLoopbackPort,
        v6Only: true,
        shared: true,
      );
      servers.add(v6);
      v6.listen(handleHttpRequest, onError: (_) {});
    } catch (_) {}

    Future<void> cancel() async {
      await closeServers();
      if (!completer.isCompleted) {
        completer.completeError(
          const AiServiceException(AiErrorCode.unauthorized, '已取消订阅账号登录'),
        );
      }
    }

    return AiPendingOAuthLogin(
      request: pkce,
      future: completer.future,
      cancel: cancel,
    );
  }

  /// Completes login from a manually pasted `http://localhost:1455/auth/callback?code=...`
  /// URL or a Codex CLI `auth.json` token payload (useful when VPN/TUN intercepts `localhost`).
  Future<AiOAuthSession> completeManualOAuthInput(
    String rawInput, {
    AiPkceAuthRequest? pendingRequest,
  }) async {
    await ensureLoaded();
    _ensureLabGateAuthorized(requireExperimentalOAuth: true);
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请粘贴授权回调链接（含 code= 参数）或 Token JSON',
      );
    }

    // Case 1: JSON token payload (`{"tokens":{"access_token":...}}` or flat).
    if (trimmed.startsWith('{')) {
      final dynamic decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          '粘贴的 JSON 格式无效',
        );
      }
      if (decoded is Map) {
        final tokensMap =
            decoded['tokens'] is Map ? decoded['tokens'] as Map : decoded;
        final access = (tokensMap['access_token'] ??
                tokensMap['accessToken'] ??
                '')
            .toString()
            .trim();
        final refresh = (tokensMap['refresh_token'] ??
                tokensMap['refreshToken'] ??
                '')
            .toString()
            .trim();
        final idTok =
            (tokensMap['id_token'] ?? tokensMap['idToken'] ?? '').toString().trim();
        if (access.isEmpty) {
          throw const AiServiceException(
            AiErrorCode.unconfigured,
            'JSON 中缺少有效的 access_token 字段',
          );
        }
        final claims =
            extractCodexJwtClaims(idToken: idTok, accessToken: access);
        final explicitAccount =
            (tokensMap['account_id'] ?? decoded['account_id'] ?? '')
                .toString()
                .trim();
        final session = AiOAuthSession(
          accessToken: access,
          refreshToken: refresh,
          expiresAtEpochMs: 0,
          accountId:
              explicitAccount.isNotEmpty ? explicitAccount : claims.accountId,
          planType: claims.planType,
          email: claims.email,
        );
        await _activateOAuthSession(session);
        return session;
      }
    }

    // Case 2: Callback URL or bare query string containing `code=...`.
    Uri? parsedUri;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      parsedUri = Uri.tryParse(trimmed);
    } else if (trimmed.contains('code=')) {
      final q = trimmed.startsWith('?') ? trimmed.substring(1) : trimmed;
      parsedUri = Uri.tryParse('$codexRedirectUri?$q');
    }

    final code = parsedUri?.queryParameters['code']?.trim() ?? '';
    if (code.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '未识别到授权码（code=），请粘贴浏览器地址栏完整的 localhost:1455 回调链接',
      );
    }
    if (pendingRequest == null) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '授权会话已过期，请先点击「浏览器登录」后再粘贴回调链接',
      );
    }
    final returnedState = parsedUri?.queryParameters['state']?.trim() ?? '';
    if (returnedState.isNotEmpty && returnedState != pendingRequest.state) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '回调 state 与当前登录请求不匹配，请使用最新打开的登录页面回调链接',
      );
    }
    return exchangeCodexAuthorizationCode(
      code: code,
      codeVerifier: pendingRequest.codeVerifier,
      redirectUri: pendingRequest.redirectUri,
    );
  }

  /// Exchanges an authorization `code` + PKCE `codeVerifier` for OAuth tokens.
  Future<AiOAuthSession> exchangeCodexAuthorizationCode({
    required String code,
    required String codeVerifier,
    String redirectUri = codexRedirectUri,
  }) async {
    final tokenUri =
        Uri.parse(_codexTokenEndpointOverride ?? _defaultCodexTokenEndpoint);
    final payload = <String, String>{
      'grant_type': 'authorization_code',
      'client_id': codexClientId,
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': codeVerifier,
    };
    final resp = await _postBareJson(
      tokenUri,
      headers: const <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      bodyJson: jsonEncode(payload),
      timeout: const Duration(seconds: 25),
    );
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _buildHttpError(resp.statusCode, raw);
    }
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        'OAuth 令牌接口返回格式异常',
      );
    }
    final accessToken = (decoded['access_token'] ?? '').toString().trim();
    if (accessToken.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '未获取到有效的订阅访问令牌',
      );
    }
    final refreshToken = (decoded['refresh_token'] ?? '').toString().trim();
    final idToken = (decoded['id_token'] ?? '').toString().trim();
    final expiresInSec = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    final expiresAt = _clock().millisecondsSinceEpoch + expiresInSec * 1000;
    final claims =
        extractCodexJwtClaims(idToken: idToken, accessToken: accessToken);
    final session = AiOAuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAtEpochMs: expiresAt,
      accountId: claims.accountId,
      planType: claims.planType,
      email: claims.email,
    );
    await _activateOAuthSession(session);
    return session;
  }

  Future<void> _activateOAuthSession(AiOAuthSession session) async {
    await setOAuthSession(session);
    List<AiModelOption> models = const <AiModelOption>[];
    try {
      models = await fetchAvailableModels(
        configOverride: _config.copyWith(authMode: AiAuthMode.codexOAuth),
      );
    } catch (_) {
      models = fallbackCodexModels;
      _discoveredModels = models;
    }
    final currentModel = _config.model.trim();
    final modelValid = currentModel.isNotEmpty &&
        models.any((m) => m.id.toLowerCase() == currentModel.toLowerCase());
    final selectedModel = modelValid
        ? models
            .firstWhere((m) => m.id.toLowerCase() == currentModel.toLowerCase())
            .id
        : (models.isNotEmpty ? models.first.id : fallbackCodexModels.first.id);
    await saveConfig(
      _config.copyWith(
        enabled: true,
        authMode: AiAuthMode.codexOAuth,
        model: selectedModel,
      ),
    );
  }

  /// Returns a valid [AiOAuthSession], refreshing via `refresh_token` if needed.
  Future<AiOAuthSession> ensureFreshOAuthSession({bool forceRefresh = false}) async {
    await ensureLoaded();
    final current = _oauthSession;
    if (current == null || !current.isValid) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请先登录 GPT 订阅账号',
      );
    }
    if (!forceRefresh && !current.isExpiringSoon(_clock())) {
      return current;
    }
    if (current.refreshToken.trim().isEmpty) {
      if (forceRefresh) {
        throw const AiServiceException(
          AiErrorCode.unauthorized,
          '订阅登录凭证已过期，请重新点击登录',
        );
      }
      return current;
    }
    if (_inFlightTokenRefresh != null) {
      return _inFlightTokenRefresh!;
    }
    final fut = _doRefreshOAuthToken(current);
    _inFlightTokenRefresh = fut;
    try {
      return await fut;
    } finally {
      if (identical(_inFlightTokenRefresh, fut)) {
        _inFlightTokenRefresh = null;
      }
    }
  }

  Future<AiOAuthSession> _doRefreshOAuthToken(AiOAuthSession current) async {
    final tokenUri =
        Uri.parse(_codexTokenEndpointOverride ?? _defaultCodexTokenEndpoint);
    final resp = await _postBareJson(
      tokenUri,
      headers: const <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      bodyJson: jsonEncode(<String, String>{
        'grant_type': 'refresh_token',
        'client_id': codexClientId,
        'refresh_token': current.refreshToken,
      }),
      timeout: const Duration(seconds: 20),
    );
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '订阅登录状态已过期，请重新登录账号',
      );
    }
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '刷新订阅令牌响应无效',
      );
    }
    final newAccess = (decoded['access_token'] ?? '').toString().trim();
    if (newAccess.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '刷新订阅令牌失败，请重新登录',
      );
    }
    final newRefresh = (decoded['refresh_token'] ?? '').toString().trim();
    final idToken = (decoded['id_token'] ?? '').toString().trim();
    final expiresInSec = (decoded['expires_in'] as num?)?.toInt() ?? 3600;
    final claims =
        extractCodexJwtClaims(idToken: idToken, accessToken: newAccess);
    final updated = AiOAuthSession(
      accessToken: newAccess,
      refreshToken: newRefresh.isNotEmpty ? newRefresh : current.refreshToken,
      expiresAtEpochMs: _clock().millisecondsSinceEpoch + expiresInSec * 1000,
      accountId:
          claims.accountId.isNotEmpty ? claims.accountId : current.accountId,
      planType: claims.planType.isNotEmpty ? claims.planType : current.planType,
      email: claims.email.isNotEmpty ? claims.email : current.email,
    );
    await setOAuthSession(updated);
    return updated;
  }

  // ---------------------------------------------------------------------------
  // Live Model Catalog Discovery (Codex Subscription & BYO-API)
  // ---------------------------------------------------------------------------

  /// Resolves the `/models` discovery endpoint for API-key providers.
  static Uri resolveModelsUri({
    required AiApiProtocol protocol,
    required String baseUrl,
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
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.trim().isEmpty ||
        parsed.userInfo.isNotEmpty ||
        (parsed.scheme != 'https' && parsed.scheme != 'http')) {
      throw const AiServiceException(
        AiErrorCode.invalidEndpoint,
        '接口地址格式无效，请填写以 https:// 开头的有效地址',
      );
    }
    final lower = trimmed.toLowerCase();
    for (final suffix in const <String>[
      '/chat/completions',
      '/responses',
      '/messages',
    ]) {
      if (lower.endsWith(suffix)) {
        trimmed = trimmed.substring(0, trimmed.length - suffix.length);
        break;
      }
    }
    final cleanLower = trimmed.toLowerCase();
    if (cleanLower.endsWith('/models')) {
      return Uri.parse(trimmed);
    }
    if (protocol == AiApiProtocol.anthropicMessages &&
        (parsed.path.isEmpty || parsed.path == '/')) {
      return Uri.parse('$trimmed/v1/models');
    }
    if (protocol == AiApiProtocol.openaiCompatible &&
        (parsed.path.isEmpty || parsed.path == '/')) {
      return Uri.parse('$trimmed/v1/models');
    }
    return Uri.parse('$trimmed/models');
  }

  /// Fetches live available models for either ChatGPT Subscription OAuth or
  /// the configured API-key provider.
  Future<List<AiModelOption>> fetchAvailableModels({
    AiConfig? configOverride,
    String? apiKeyOverride,
    bool isPrivateSession = false,
  }) async {
    if (isPrivateSession) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已硬性禁用所有外部 AI 网络请求',
      );
    }
    await ensureLoaded();
    final cfg = configOverride ?? _config;
    _ensureLabGateAuthorized(
      requireExperimentalOAuth: cfg.authMode == AiAuthMode.codexOAuth,
    );

    if (cfg.authMode == AiAuthMode.codexOAuth) {
      final session = await ensureFreshOAuthSession();
      final baseModelsUrl =
          _codexModelsEndpointOverride ?? _defaultCodexModelsEndpoint;
      final uri = Uri.parse(baseModelsUrl).replace(
        queryParameters: <String, String>{
          'client_version': codexClientVersion,
        },
      );
      final headers = <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer ${session.accessToken}',
        'Originator': 'codex_cli_rs',
        'User-Agent': 'codex_cli_rs/$codexClientVersion (iOS; arm64)',
        if (session.accountId.isNotEmpty)
          'Chatgpt-Account-Id': session.accountId,
      };
      final resp = await _getWithTimeout(
        uri,
        headers: headers,
        timeout: Duration(seconds: cfg.timeoutSeconds),
      );
      final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 401 && session.refreshToken.isNotEmpty) {
        final refreshed = await ensureFreshOAuthSession(forceRefresh: true);
        final retryResp = await _getWithTimeout(
          uri,
          headers: <String, String>{
            ...headers,
            'Authorization': 'Bearer ${refreshed.accessToken}',
          },
          timeout: Duration(seconds: cfg.timeoutSeconds),
        );
        final retryRaw = utf8.decode(retryResp.bodyBytes, allowMalformed: true);
        if (retryResp.statusCode < 200 || retryResp.statusCode >= 300) {
          throw _buildHttpError(retryResp.statusCode, retryRaw);
        }
        final models = parseModelsResponse(retryRaw, isCodex: true);
        _discoveredModels = models.isNotEmpty ? models : fallbackCodexModels;
        notifyListeners();
        return _discoveredModels;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _buildHttpError(resp.statusCode, raw);
      }
      final models = parseModelsResponse(raw, isCodex: true);
      _discoveredModels = models.isNotEmpty ? models : fallbackCodexModels;
      notifyListeners();
      return _discoveredModels;
    }

    final key = (apiKeyOverride ?? _apiKey).trim();
    if (cfg.baseUrl.trim().isEmpty || key.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请先填写接口地址 (Base URL) 与 API 密钥后再拉取模型列表',
      );
    }
    final uri = resolveModelsUri(
      protocol: cfg.protocol,
      baseUrl: cfg.baseUrl,
    );
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    switch (cfg.protocol) {
      case AiApiProtocol.openaiCompatible:
        headers['Authorization'] = 'Bearer $key';
      case AiApiProtocol.anthropicMessages:
        headers['x-api-key'] = key;
        headers['anthropic-version'] = '2023-06-01';
      case AiApiProtocol.geminiGenerateContent:
        headers['x-goog-api-key'] = key;
    }
    final resp = await _getWithTimeout(
      uri,
      headers: headers,
      timeout: Duration(seconds: cfg.timeoutSeconds),
    );
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _buildHttpError(resp.statusCode, raw);
    }
    final models = parseModelsResponse(
      raw,
      protocol: cfg.protocol,
    );
    if (models.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '接口未返回可选模型列表，请手动输入模型 ID',
      );
    }
    _discoveredModels = models;
    notifyListeners();
    return models;
  }

  /// Parses `/models` payloads across Codex, OpenAI, Anthropic, and Gemini.
  static List<AiModelOption> parseModelsResponse(
    String rawBody, {
    AiApiProtocol protocol = AiApiProtocol.openaiCompatible,
    bool isCodex = false,
  }) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawBody);
    } catch (_) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型列表接口返回了非 JSON 响应',
      );
    }

    List<dynamic> rawItems = const <dynamic>[];
    if (decoded is List) {
      rawItems = decoded;
    } else if (decoded is Map) {
      if (decoded['models'] is List) {
        rawItems = decoded['models'] as List;
      } else if (decoded['data'] is List) {
        rawItems = decoded['data'] as List;
      }
    }

    final seen = <String>{};
    final out = <AiModelOption>[];
    for (var i = 0; i < rawItems.length; i++) {
      final entry = rawItems[i];
      if (entry is String) {
        final id = entry.trim();
        if (id.isNotEmpty && seen.add(id.toLowerCase())) {
          out.add(AiModelOption(id: id, priority: 100 + i));
        }
        continue;
      }
      if (entry is! Map) continue;
      if (isCodex) {
        final vis = (entry['visibility'] ?? '').toString().trim().toLowerCase();
        if (const <String>{'hide', 'hidden', 'internal', 'none'}
            .contains(vis)) {
          continue;
        }
      }
      if (protocol == AiApiProtocol.geminiGenerateContent &&
          entry['supportedGenerationMethods'] is List) {
        final methods = (entry['supportedGenerationMethods'] as List)
            .map((e) => e.toString())
            .toList();
        if (methods.isNotEmpty && !methods.contains('generateContent')) {
          continue;
        }
      }

      var rawId = (entry['slug'] ?? entry['id'] ?? entry['name'] ?? '')
          .toString()
          .trim();
      if (protocol == AiApiProtocol.geminiGenerateContent &&
          rawId.startsWith('models/')) {
        rawId = rawId.substring('models/'.length);
      }
      if (rawId.isEmpty) continue;
      final lowerId = rawId.toLowerCase();
      // Filter non-text embedding / moderation / audio-only utility models on OpenAI.
      if (!isCodex &&
          protocol == AiApiProtocol.openaiCompatible &&
          (lowerId.startsWith('text-embedding') ||
              lowerId.startsWith('omni-moderation') ||
              lowerId.startsWith('tts-') ||
              lowerId.startsWith('whisper-') ||
              lowerId.startsWith('dall-e'))) {
        continue;
      }
      if (!seen.add(lowerId)) continue;

      final disp = (entry['display_name'] ??
              entry['displayName'] ??
              entry['title'] ??
              '')
          .toString()
          .trim();
      final desc = (entry['description'] ?? '').toString().trim();
      final prio = (entry['priority'] as num?)?.toInt() ?? (100 + i);
      out.add(
        AiModelOption(
          id: rawId,
          displayName: disp.isNotEmpty ? disp : rawId,
          description: desc,
          priority: prio,
        ),
      );
    }

    out.sort((a, b) {
      final cmp = a.priority.compareTo(b.priority);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    return List<AiModelOption>.unmodifiable(out);
  }

  /// Resolves user-typed display names (e.g. `GPT 6.1 Terra` -> `gpt-6.1-terra`
  /// when present in discovered catalog, or slugified on Codex OAuth) so human
  /// model labels don't unnecessarily trigger `invalid model ID`.
  String resolveCanonicalModelId(String rawModel, {required bool isCodex}) {
    final trimmed = rawModel.trim();
    if (trimmed.isEmpty) return '';
    final lower = trimmed.toLowerCase();
    for (final m in <AiModelOption>[..._discoveredModels, ...fallbackCodexModels]) {
      if (m.id.toLowerCase() == lower ||
          m.displayName.trim().toLowerCase() == lower) {
        return m.id;
      }
    }
    if (isCodex && trimmed.contains(' ')) {
      return lower.replaceAll(RegExp(r'\s+'), '-');
    }
    return trimmed;
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
    AiAuthMode authMode = AiAuthMode.apiKey,
  }) {
    final modeTag =
        authMode == AiAuthMode.codexOAuth ? 'codex_oauth' : protocol.id;
    final payload =
        '$feature|$modeTag|${model.trim()}|$systemPrompt|$userPrompt';
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
        if (lower.endsWith('/chat/completions') ||
            lower.endsWith('/responses')) {
          fullUrl = trimmed;
        } else if (parsedBase.path.isEmpty || parsedBase.path == '/') {
          fullUrl = '$trimmed/v1/chat/completions';
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

  Future<http.Response> _getWithTimeout(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final ephemeral = _injectedHttpClient == null;
    final client = _injectedHttpClient ?? http.Client();
    try {
      return await client.get(uri, headers: headers).timeout(timeout);
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        'AI 接口响应超时，请检查网络状态',
      );
    } catch (_) {
      throw const AiServiceException(
        AiErrorCode.networkError,
        '无法连接到 AI 接口，请检查网络状态与地址配置',
      );
    } finally {
      if (ephemeral) client.close();
    }
  }

  /// Sends a POST request with raw UTF-8 `bodyBytes` so strict backends (such
  /// as `chatgpt.com/backend-api/codex/responses` and Responses gateways)
  /// receive bare `Content-Type: application/json` without `; charset=utf-8`.
  Future<http.Response> _postBareJson(
    Uri uri, {
    required Map<String, String> headers,
    required String bodyJson,
    required Duration timeout,
  }) async {
    final ephemeral = _injectedHttpClient == null;
    final client = _injectedHttpClient ?? http.Client();
    try {
      final req = http.Request('POST', uri)
        ..headers.addAll(headers)
        ..bodyBytes = utf8.encode(bodyJson);
      final streamed = await client.send(req).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
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
      if (ephemeral) client.close();
    }
  }

  /// Core text/JSON completion entry point supporting ChatGPT Subscription
  /// OAuth (Codex Responses SSE), OpenAI-compatible (Chat & Responses with
  /// reasoning-model auto-adaptation), Anthropic Messages, and Google Gemini.
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
    _ensureLabGateAuthorized(
      requireExperimentalOAuth: cfg.authMode == AiAuthMode.codexOAuth,
    );
    if (!ignoreEnabledFlag && !cfg.enabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        'AI 助手尚未启用',
      );
    }

    final rawModel = (modelOverride != null && modelOverride.trim().isNotEmpty)
        ? modelOverride.trim()
        : cfg.model.trim();
    final isCodexMode = cfg.authMode == AiAuthMode.codexOAuth;
    final effectiveModel = resolveCanonicalModelId(
      rawModel,
      isCodex: isCodexMode,
    );

    if (effectiveModel.isEmpty) {
      throw AiServiceException(
        AiErrorCode.unconfigured,
        isCodexMode
            ? '请先选择订阅模型（可点击「拉取模型列表」）'
            : '请先填写主模型名称（可点击「拉取模型列表」选择）',
      );
    }

    final cacheKey = computeCacheKey(
      feature: feature,
      protocol: cfg.protocol,
      model: effectiveModel,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      authMode: cfg.authMode,
    );
    if (useCache) {
      final cached = _cache.remove(cacheKey);
      if (cached != null) {
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

    if (isCodexMode) {
      return _completeViaCodexSubscription(
        cfg: cfg,
        model: effectiveModel,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        cacheKey: cacheKey,
        useCache: useCache,
      );
    }

    final key = (apiKeyOverride ?? _apiKey).trim();
    if (cfg.baseUrl.trim().isEmpty || key.isEmpty) {
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
    final isResponsesEndpoint = cfg.protocol == AiApiProtocol.openaiCompatible &&
        uri.path.toLowerCase().endsWith('/responses');
    final isReasoningStyleModel = cfg.protocol == AiApiProtocol.openaiCompatible &&
        RegExp(r'^(?:o1|o3|o4|gpt-5)', caseSensitive: false)
            .hasMatch(effectiveModel);

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': isResponsesEndpoint
          ? 'text/event-stream, application/json'
          : 'application/json',
    };
    Map<String, dynamic> body;

    switch (cfg.protocol) {
      case AiApiProtocol.openaiCompatible:
        headers['Authorization'] = 'Bearer $key';
        if (isResponsesEndpoint) {
          body = <String, dynamic>{
            'model': effectiveModel,
            'store': false,
            if (systemPrompt.trim().isNotEmpty) 'instructions': systemPrompt,
            'input': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'message',
                'role': 'user',
                'content': <Map<String, String>>[
                  <String, String>{'type': 'input_text', 'text': userPrompt},
                ],
              },
            ],
            'max_output_tokens': maxTokens,
          };
        } else {
          body = <String, dynamic>{
            'model': effectiveModel,
            'messages': <Map<String, String>>[
              if (systemPrompt.trim().isNotEmpty)
                <String, String>{'role': 'system', 'content': systemPrompt},
              <String, String>{'role': 'user', 'content': userPrompt},
            ],
            if (!isReasoningStyleModel) 'temperature': temperature,
            if (isReasoningStyleModel)
              'max_completion_tokens': maxTokens
            else
              'max_tokens': maxTokens,
          };
        }
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
    var response = await _postBareJson(
      uri,
      headers: headers,
      bodyJson: jsonEncode(body),
      timeout: Duration(seconds: cfg.timeoutSeconds),
    );
    var status = response.statusCode;
    var rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);

    // Auto-adapt if a reasoning model on a custom OpenAI-compatible gateway
    // rejects `max_tokens` or `temperature` with HTTP 400.
    if (status == 400 &&
        cfg.protocol == AiApiProtocol.openaiCompatible &&
        !isResponsesEndpoint &&
        (body.containsKey('max_tokens') || body.containsKey('temperature')) &&
        RegExp(
          r'max_tokens|max_completion_tokens|temperature|unsupported_parameter|unsupported_value',
          caseSensitive: false,
        ).hasMatch(rawBody)) {
      final retryBody = Map<String, dynamic>.of(body)
        ..remove('max_tokens')
        ..remove('temperature')
        ..['max_completion_tokens'] = maxTokens;
      response = await _postBareJson(
        uri,
        headers: headers,
        bodyJson: jsonEncode(retryBody),
        timeout: Duration(seconds: cfg.timeoutSeconds),
      );
      status = response.statusCode;
      rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);
    }
    sw.stop();

    if (status < 200 || status >= 300) {
      throw _buildHttpError(status, rawBody);
    }

    final parsed = isResponsesEndpoint
        ? parseCodexResponsesPayload(
            rawBody,
            fallbackPromptChars: systemPrompt.length + userPrompt.length,
          )
        : _parseProtocolResponse(
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

  Future<AiCompletionResult> _completeViaCodexSubscription({
    required AiConfig cfg,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required String cacheKey,
    required bool useCache,
  }) async {
    var session = await ensureFreshOAuthSession();
    final uri = Uri.parse(
      _codexResponsesEndpointOverride ?? _defaultCodexResponsesEndpoint,
    );
    final promptCacheKey = sha256
        .convert(utf8.encode('marco_codex|$model|$systemPrompt'))
        .toString()
        .substring(0, 32);

    Map<String, String> buildCodexHeaders(AiOAuthSession s) => <String, String>{
          'Authorization': 'Bearer ${s.accessToken}',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream, application/json',
          'Version': codexClientVersion,
          'Openai-Beta': 'responses=experimental',
          'Originator': 'codex_cli_rs',
          'User-Agent': 'codex_cli_rs/$codexClientVersion (iOS; arm64)',
          'x-codex-routing-hint': 'model=$model',
          if (s.accountId.isNotEmpty) 'Chatgpt-Account-Id': s.accountId,
        };

    final body = <String, dynamic>{
      'model': model,
      'stream': true,
      'store': false,
      'parallel_tool_calls': true,
      'prompt_cache_key': promptCacheKey,
      'include': const <String>['reasoning.encrypted_content'],
      'reasoning': const <String, String>{
        'effort': 'low',
        'summary': 'auto',
      },
      'instructions': systemPrompt.trim().isNotEmpty
          ? systemPrompt.trim()
          : 'You are a helpful assistant.',
      'input': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'message',
          'role': 'user',
          'content': <Map<String, String>>[
            <String, String>{
              'type': 'input_text',
              'text': userPrompt,
            },
          ],
        },
      ],
    };
    final bodyJson = jsonEncode(body);

    final sw = Stopwatch()..start();
    var resp = await _postBareJson(
      uri,
      headers: buildCodexHeaders(session),
      bodyJson: bodyJson,
      timeout: Duration(seconds: cfg.timeoutSeconds),
    );
    if (resp.statusCode == 401 && session.refreshToken.isNotEmpty) {
      session = await ensureFreshOAuthSession(forceRefresh: true);
      resp = await _postBareJson(
        uri,
        headers: buildCodexHeaders(session),
        bodyJson: bodyJson,
        timeout: Duration(seconds: cfg.timeoutSeconds),
      );
    }
    sw.stop();

    final rawBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _buildHttpError(resp.statusCode, rawBody, isCodex: true);
    }

    final parsed = parseCodexResponsesPayload(
      rawBody,
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

  /// Parses SSE (`text/event-stream`) or JSON Responses payloads returned by
  /// `chatgpt.com/backend-api/codex/responses` or OpenAI `/v1/responses`.
  static ({String text, int promptTokens, int completionTokens})
      parseCodexResponsesPayload(
    String rawBody, {
    required int fallbackPromptChars,
  }) {
    final trimmed = rawBody.trim();
    if (trimmed.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型服务返回了空响应',
      );
    }

    final deltaBuf = StringBuffer();
    String completedFallbackText = '';
    int? promptTok;
    int? completionTok;

    void extractFromResponseObj(Map<dynamic, dynamic> respObj) {
      final usage = respObj['usage'];
      if (usage is Map) {
        promptTok ??= (usage['input_tokens'] as num?)?.toInt() ??
            (usage['prompt_tokens'] as num?)?.toInt();
        completionTok ??= (usage['output_tokens'] as num?)?.toInt() ??
            (usage['completion_tokens'] as num?)?.toInt();
      }
      if (respObj['output_text'] is String &&
          (respObj['output_text'] as String).trim().isNotEmpty) {
        completedFallbackText = (respObj['output_text'] as String).trim();
      }
      final output = respObj['output'];
      if (output is List) {
        final outBuf = StringBuffer();
        for (final item in output) {
          if (item is! Map) continue;
          final content = item['content'];
          if (content is List) {
            for (final part in content) {
              if (part is Map && part['text'] is String) {
                outBuf.write(part['text']);
              }
            }
          }
        }
        if (outBuf.isNotEmpty) {
          completedFallbackText = outBuf.toString().trim();
        }
      }
    }

    if (trimmed.startsWith('{')) {
      final dynamic decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        throw const AiServiceException(
          AiErrorCode.malformedResponse,
          '模型接口返回了非标准 JSON 响应',
        );
      }
      if (decoded is Map) {
        if (decoded['error'] != null) {
          throw _buildHttpError(400, trimmed, isCodex: true);
        }
        extractFromResponseObj(decoded);
      }
    } else {
      for (final rawLine in const LineSplitter().convert(trimmed)) {
        final line = rawLine.trim();
        if (!line.startsWith('data:')) continue;
        var payload = line.substring(5);
        if (payload.startsWith(' ')) payload = payload.substring(1);
        if (payload == '[DONE]' || payload.isEmpty) continue;
        Map<dynamic, dynamic>? ev;
        try {
          final parsed = jsonDecode(payload);
          if (parsed is Map) ev = parsed;
        } catch (_) {
          continue;
        }
        if (ev == null) continue;
        final type = (ev['type'] ?? '').toString();
        if (type == 'response.output_text.delta') {
          final d = ev['delta'];
          if (d is String && d.isNotEmpty) {
            deltaBuf.write(d);
          }
        } else if (type == 'response.output_text.done' && deltaBuf.isEmpty) {
          final t = ev['text'];
          if (t is String && t.isNotEmpty) {
            completedFallbackText = t.trim();
          }
        } else if (type == 'response.completed' || type == 'response.done') {
          final respObj = ev['response'];
          if (respObj is Map) {
            extractFromResponseObj(respObj);
          }
        } else if (type == 'response.failed' || type == 'error') {
          final errObj = ev['error'] ??
              (ev['response'] is Map ? (ev['response'] as Map)['error'] : null);
          String msg = '';
          if (errObj is Map && errObj['message'] is String) {
            msg = (errObj['message'] as String).trim();
          } else if (ev['message'] is String) {
            msg = (ev['message'] as String).trim();
          }
          if (containsForbiddenUrl(msg)) msg = '';
          throw AiServiceException(
            AiErrorCode.networkError,
            msg.isNotEmpty ? '订阅模型响应异常（$msg）' : '订阅模型响应中断，请稍后重试',
          );
        }
      }
    }

    final finalText = deltaBuf.isNotEmpty
        ? deltaBuf.toString().trim()
        : completedFallbackText.trim();
    if (finalText.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型未返回有效文本内容',
      );
    }
    return (
      text: finalText,
      promptTokens:
          promptTok ?? ((fallbackPromptChars / 3).ceil().clamp(1, 100000)),
      completionTokens:
          completionTok ?? ((finalText.length / 3).ceil().clamp(1, 100000)),
    );
  }

  static AiServiceException _buildHttpError(
    int status,
    String rawBody, {
    bool isCodex = false,
  }) {
    String detail = '';
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] is String) {
          detail = (err['message'] as String).trim();
        } else if (err is String) {
          detail = err.trim();
        } else if (decoded['detail'] is String) {
          detail = (decoded['detail'] as String).trim();
        } else if (decoded['message'] is String) {
          detail = (decoded['message'] as String).trim();
        }
      }
    } catch (_) {}
    // Strip any URL from upstream error details to keep UI diagnostics clean.
    if (detail.isNotEmpty && containsForbiddenUrl(detail)) {
      detail = '';
    }
    final lowerDetail = detail.toLowerCase();
    final isInvalidModel = lowerDetail.contains('invalid model') ||
        lowerDetail.contains('model_not_found') ||
        (lowerDetail.contains('model') && lowerDetail.contains('does not exist'));

    if (detail.length > 80) {
      detail = '${detail.substring(0, 80)}…';
    }
    final suffix = detail.isNotEmpty ? '（$detail）' : '';

    if (status == 401 || status == 403) {
      return AiServiceException(
        AiErrorCode.unauthorized,
        isCodex
            ? '订阅授权无效或已过期（HTTP $status），请重新登录订阅账号$suffix'
            : '鉴权失败（HTTP $status）：请检查 API 密钥是否正确$suffix',
        statusCode: status,
      );
    }
    if (isInvalidModel) {
      return AiServiceException(
        AiErrorCode.invalidEndpoint,
        isCodex
            ? '当前订阅不支持该模型 ID，请点击「拉取模型列表」重新选择$suffix'
            : '模型 ID 不存在或为订阅专属名称，请点击「拉取模型列表」选择真实模型 ID（或切至「GPT 订阅账号」登录）$suffix',
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
        isCodex
            ? '订阅使用配额已触达窗口限制（HTTP 429），请稍后重试或切换轻量模型$suffix'
            : '请求频率受限或账户额度不足（HTTP 429）$suffix',
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
        maxTokens: 32,
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
    _ensureLabGateAuthorized();
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

  /// Extracts the outermost `{ ... }` JSON object slice from model output.
  static String? extractJsonObjectSlice(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      s = s
          .replaceFirst(RegExp(r'^```(?:json|JSON)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '')
          .trim();
    }
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
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

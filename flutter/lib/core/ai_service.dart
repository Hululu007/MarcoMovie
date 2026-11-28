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
import 'ai_oauth_manager.dart';
import 'ai_provider_profiles.dart';
import 'ohos_runtime.dart';
import 'secure_credential_store.dart';

export 'ai_provider_profiles.dart' show AiAuthMode;

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
  final bool isLocalFallback;
  final String defaultReasoningEffort;
  final List<String>? supportedReasoningEfforts;

  const AiModelOption({
    required this.id,
    String? displayName,
    this.description = '',
    this.priority = 1000,
    this.isLocalFallback = false,
    this.defaultReasoningEffort = '',
    this.supportedReasoningEfforts,
  }) : displayName = (displayName == null || displayName == '') ? id : displayName;

  bool get hasDistinctDisplayName =>
      displayName.trim().isNotEmpty &&
      displayName.trim().toLowerCase() != id.trim().toLowerCase();

  AiModelOption copyWithPriority(
    int nextPriority, {
    bool? isLocalFallback,
  }) =>
      AiModelOption(
        id: id,
        displayName: displayName,
        description: description,
        priority: nextPriority,
        isLocalFallback: isLocalFallback ?? this.isLocalFallback,
        defaultReasoningEffort: defaultReasoningEffort,
        supportedReasoningEfforts: supportedReasoningEfforts,
      );
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
  final bool danmuMatchEnabled;
  final List<AiCustomSkill> customSkills;
  final bool picksEnabled;
  final bool firstUseConsentAccepted;
  final String activeProfileId;

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
    this.danmuMatchEnabled = true,
    this.customSkills = const <AiCustomSkill>[],
    this.picksEnabled = true,
    this.firstUseConsentAccepted = false,
    this.activeProfileId = '',
  });

  List<AiCustomSkill> get effectiveSkills => <AiCustomSkill>[
        ...AiCustomSkill.defaultBuiltInSkills,
        for (final s in customSkills)
          if (!AiCustomSkill.retiredBuiltInSkillIds.contains(s.id)) s,
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
    bool? danmuMatchEnabled,
    List<AiCustomSkill>? customSkills,
    bool? picksEnabled,
    bool? firstUseConsentAccepted,
    String? activeProfileId,
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
      danmuMatchEnabled: danmuMatchEnabled ?? this.danmuMatchEnabled,
      customSkills: customSkills ?? this.customSkills,
      picksEnabled: picksEnabled ?? this.picksEnabled,
      firstUseConsentAccepted:
          firstUseConsentAccepted ?? this.firstUseConsentAccepted,
      activeProfileId: (activeProfileId ?? this.activeProfileId).trim(),
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
        'danmuMatchEnabled': danmuMatchEnabled,
        if (customSkills.isNotEmpty)
          'customSkills': customSkills.map((s) => s.toJson()).toList(),
        'picksEnabled': picksEnabled,
        'firstUseConsentAccepted': firstUseConsentAccepted,
        'activeProfileId': activeProfileId.trim(),
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
      danmuMatchEnabled: json['danmuMatchEnabled'] != false,
      customSkills: List<AiCustomSkill>.unmodifiable(parsedSkills),
      picksEnabled: json['picksEnabled'] != false,
      firstUseConsentAccepted: json['firstUseConsentAccepted'] == true,
      activeProfileId: (json['activeProfileId'] ?? '').toString().trim(),
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

/// Single recorded AI invocation entry for the detailed usage history view and
/// local rolling 5-hour / 7-day subscription window tracking.
@immutable
class AiUsageLogEntry {
  final int timestampMs;
  final String feature;
  final String model;
  final String authModeId;
  final int promptTokens;
  final int completionTokens;
  final int latencyMs;
  final bool fromCache;

  const AiUsageLogEntry({
    required this.timestampMs,
    required this.feature,
    required this.model,
    this.authModeId = 'api_key',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.latencyMs = 0,
    this.fromCache = false,
  });

  int get totalTokens => promptTokens + completionTokens;

  String get featureLabelZh => switch (feature) {
    'ping' => '连接测试',
    'nl_search_v1' => '自然语言找片',
    'title_clean_v1' => '标题智能清洗',
    'ai_sub_v1' => '外挂字幕精译',
    'ai_sub_live_v1' => '内封实时双语字幕',
    'ai_sub_offset_v1' => '字幕时间轴校准',
    'ai_watch_brief_v1' => '零剧透看点与设定科普',
    'ai_post_credits_v1' => '片尾彩蛋与版本提示',
    'ai_work_qa_v1' => '自由观影问答',
    'ai_sommelier_v1' => '观影口味策展',
    'ai_ep_curate_v1' => '剧集智能编排',
    'ai_diag_v1' => '播放与源智能排障',
    'ai_danmu_match_v1' => 'AI 弹幕智能匹配',
    'ai_danmu_offset_v1' => '弹幕时间轴校准',
    _ => feature.startsWith('skill:') ? '自定义技能' : 'AI 助手调用',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': timestampMs,
        'f': feature,
        'm': model,
        'auth': authModeId,
        'in': promptTokens,
        'out': completionTokens,
        'ms': latencyMs,
        if (fromCache) 'cache': true,
      };

  factory AiUsageLogEntry.fromJson(Map<String, dynamic> json) {
    return AiUsageLogEntry(
      timestampMs: (json['ts'] as num?)?.toInt() ?? 0,
      feature: (json['f'] ?? '').toString().trim(),
      model: (json['m'] ?? '').toString().trim(),
      authModeId: (json['auth'] ?? 'api_key').toString().trim(),
      promptTokens: ((json['in'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      completionTokens: ((json['out'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
      latencyMs: ((json['ms'] as num?)?.toInt() ?? 0).clamp(0, 600000),
      fromCache: json['cache'] == true,
    );
  }
}

/// Rate-limit window state (e.g. 5-hour primary window or 7-day weekly window)
/// reported by ChatGPT Plus / Pro / Team subscription headers or `/wham/usage`.
@immutable
class AiSubscriptionQuotaWindow {
  final int windowSeconds;
  final double? usedPercent;
  final int resetAtEpochSec;

  const AiSubscriptionQuotaWindow({
    required this.windowSeconds,
    this.usedPercent,
    this.resetAtEpochSec = 0,
  });

  bool get hasServerPercent => usedPercent != null;

  double get clampedPercent => (usedPercent ?? 0.0).clamp(0.0, 100.0);

  String resetCountdownZh(DateTime now) {
    if (resetAtEpochSec <= 0) return '';
    final remSec = resetAtEpochSec - (now.millisecondsSinceEpoch ~/ 1000);
    if (remSec <= 0) return '即将重置';
    if (remSec >= 86400) {
      final days = remSec ~/ 86400;
      final hours = (remSec % 86400) ~/ 3600;
      return hours > 0 ? '$days天$hours小时后重置' : '$days天后重置';
    }
    if (remSec >= 3600) {
      final hours = remSec ~/ 3600;
      final mins = (remSec % 3600) ~/ 60;
      return mins > 0 ? '$hours小时$mins分后重置' : '$hours小时后重置';
    }
    final mins = remSec ~/ 60;
    return '${mins < 1 ? 1 : mins}分钟后重置';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'windowSeconds': windowSeconds,
        if (usedPercent != null) 'usedPercent': usedPercent,
        'resetAtEpochSec': resetAtEpochSec,
      };

  factory AiSubscriptionQuotaWindow.fromJson(Map<String, dynamic> json) {
    final rawPct = json['usedPercent'];
    return AiSubscriptionQuotaWindow(
      windowSeconds: (json['windowSeconds'] as num?)?.toInt() ?? 18000,
      usedPercent: rawPct is num ? rawPct.toDouble().clamp(0.0, 100.0) : null,
      resetAtEpochSec: (json['resetAtEpochSec'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Snapshot of ChatGPT Subscription 5-hour & 7-day weekly quota windows.
@immutable
class AiSubscriptionQuotaSnapshot {
  final String accountKey;
  final String planType;
  final AiSubscriptionQuotaWindow fiveHourWindow;
  final AiSubscriptionQuotaWindow weeklyWindow;
  final int updatedAtEpochMs;

  const AiSubscriptionQuotaSnapshot({
    this.accountKey = '',
    this.planType = '',
    this.fiveHourWindow =
        const AiSubscriptionQuotaWindow(windowSeconds: 18000),
    this.weeklyWindow = const AiSubscriptionQuotaWindow(windowSeconds: 604800),
    required this.updatedAtEpochMs,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (accountKey.isNotEmpty) 'accountKey': accountKey,
        'planType': planType,
        'fiveHourWindow': fiveHourWindow.toJson(),
        'weeklyWindow': weeklyWindow.toJson(),
        'updatedAtEpochMs': updatedAtEpochMs,
      };

  factory AiSubscriptionQuotaSnapshot.fromJson(Map<String, dynamic> json) {
    final fh = json['fiveHourWindow'];
    final wk = json['weeklyWindow'];
    return AiSubscriptionQuotaSnapshot(
      accountKey: (json['accountKey'] ?? '').toString().trim(),
      planType: (json['planType'] ?? '').toString().trim(),
      fiveHourWindow: fh is Map
          ? AiSubscriptionQuotaWindow.fromJson(Map<String, dynamic>.from(fh))
          : const AiSubscriptionQuotaWindow(windowSeconds: 18000),
      weeklyWindow: wk is Map
          ? AiSubscriptionQuotaWindow.fromJson(Map<String, dynamic>.from(wk))
          : const AiSubscriptionQuotaWindow(windowSeconds: 604800),
      updatedAtEpochMs: (json['updatedAtEpochMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Snapshot of a BYO-API provider's account balance / credit quota (e.g.
/// OpenAI/OneAPI/NewAPI billing, OpenRouter credits, DeepSeek balance,
/// Moonshot/SiliconFlow balance) when exposed by the configured endpoint.
@immutable
class AiApiBalanceSnapshot {
  final String endpointKey;
  final String accountKey;
  final bool supported;
  final bool isUnlimited;
  final String currency;
  final double? remaining;
  final double? totalGranted;
  final double? totalUsed;
  final String sourceLabel;
  final int updatedAtEpochMs;

  const AiApiBalanceSnapshot({
    required this.endpointKey,
    this.accountKey = '',
    required this.supported,
    this.isUnlimited = false,
    this.currency = '',
    this.remaining,
    this.totalGranted,
    this.totalUsed,
    this.sourceLabel = '',
    required this.updatedAtEpochMs,
  });

  bool get isUnitUnknown => currency.trim().isEmpty;

  String get currencySymbol => switch (currency.trim().toUpperCase()) {
        'CNY' || 'RMB' => '¥',
        'USD' => r'$',
        'EUR' => '€',
        'GBP' => '£',
        _ => '',
      };

  String formatAmount(double value) {
    final safe = value.isFinite ? value : 0.0;
    final neg = safe < 0;
    final absVal = safe.abs();
    final cur = currency.trim().toUpperCase();
    final isTokenUnit = cur == 'TOKENS' || cur == 'TOKEN';
    final formatted = (isTokenUnit ||
            (absVal >= 10000 && (absVal - absVal.roundToDouble()).abs() < 1e-6))
        ? absVal.round().toString()
        : ((absVal > 0 && absVal < 0.01)
            ? absVal.toStringAsFixed(4)
            : absVal.toStringAsFixed(2));
    final sign = neg ? '-' : '';
    final sym = currencySymbol;
    if (sym.isNotEmpty) {
      return '$sign$sym$formatted';
    }
    if (isTokenUnit) return '$sign$formatted tokens';
    if (cur == 'CREDITS' || cur == 'POINTS') return '$sign$formatted 积分';
    return cur.isEmpty ? '$sign$formatted' : '$sign$formatted $cur';
  }

  String get _unknownUnitSuffix => isUnitUnknown ? '（单位未知）' : '';

  double? get effectiveRemaining {
    if (remaining != null) return remaining;
    if (totalGranted != null && totalUsed != null) {
      final diff = totalGranted! - totalUsed!;
      return diff < 0 ? 0.0 : diff;
    }
    return null;
  }

  double? get usedRatio {
    if (!supported || isUnlimited) return null;
    if (totalGranted == null || totalGranted! <= 0) return null;
    final used = totalUsed ??
        (remaining != null ? (totalGranted! - remaining!) : null);
    if (used == null) return null;
    return (used / totalGranted!).clamp(0.0, 1.0);
  }

  String get headlineTextZh {
    if (!supported) return '当前接口未公开余额查询';
    if (isUnlimited) return '无限额度';
    final rem = effectiveRemaining;
    if (rem != null) return '剩余 ${formatAmount(rem)}$_unknownUnitSuffix';
    if (totalGranted != null) {
      return '额度上限 ${formatAmount(totalGranted!)}$_unknownUnitSuffix';
    }
    if (totalUsed != null) return '已用 ${formatAmount(totalUsed!)}$_unknownUnitSuffix';
    return '已获取账户状态';
  }

  String get detailSubtitleZh {
    if (!supported) {
      return '部分官方接口或自建代理未开放余额 API，不影响正常使用，可前往服务商控制台查看';
    }
    if (isUnlimited) {
      if (totalUsed != null && totalUsed! > 0) {
        return '已累计消耗 ${formatAmount(totalUsed!)}$_unknownUnitSuffix · 额度无上限';
      }
      return '该 API 密钥已配置为无限额度';
    }
    if (effectiveRemaining == null &&
        totalGranted != null &&
        totalUsed == null) {
      final unitNote = isUnitUnknown ? '，计费单位未知' : '';
      return '用量接口未返回，仅显示账户额度上限$unitNote（来源：$sourceLabel）';
    }
    final parts = <String>[];
    if (totalUsed != null) {
      parts.add('已用 ${formatAmount(totalUsed!)}');
    }
    if (totalGranted != null && totalGranted! > 0) {
      parts.add('总额 ${formatAmount(totalGranted!)}');
    }
    if (parts.isNotEmpty) {
      final suffix = isUnitUnknown ? ' · 单位未知' : '';
      return '${parts.join(' / ')}$suffix';
    }
    if (sourceLabel.isNotEmpty) {
      return isUnitUnknown ? '来源：$sourceLabel · 单位未知' : '来源：$sourceLabel';
    }
    return isUnitUnknown ? '已从当前 API 接口同步余额（单位未知）' : '已从当前 API 接口同步余额';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'endpointKey': endpointKey,
        if (accountKey.isNotEmpty) 'accountKey': accountKey,
        'supported': supported,
        'isUnlimited': isUnlimited,
        'currency': currency,
        if (remaining != null) 'remaining': remaining,
        if (totalGranted != null) 'totalGranted': totalGranted,
        if (totalUsed != null) 'totalUsed': totalUsed,
        'sourceLabel': sourceLabel,
        'updatedAtEpochMs': updatedAtEpochMs,
      };

  factory AiApiBalanceSnapshot.fromJson(Map<String, dynamic> json) {
    return AiApiBalanceSnapshot(
      endpointKey: (json['endpointKey'] ?? '').toString().trim(),
      accountKey: (json['accountKey'] ?? '').toString().trim(),
      supported: json['supported'] == true,
      isUnlimited: json['isUnlimited'] == true,
      currency: (json['currency'] ?? '').toString().trim(),
      remaining: (json['remaining'] as num?)?.toDouble(),
      totalGranted: (json['totalGranted'] as num?)?.toDouble(),
      totalUsed: (json['totalUsed'] as num?)?.toDouble(),
      sourceLabel: (json['sourceLabel'] ?? '').toString().trim(),
      updatedAtEpochMs: (json['updatedAtEpochMs'] as num?)?.toInt() ?? 0,
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
  final bool stale;

  const AiConnectionTestResult({
    required this.ok,
    required this.latencyMs,
    this.modelReply = '',
    required this.messageZh,
    this.stale = false,
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
  static const String prefsProfilesKey = 'marco_ai_profiles_v1';
  static const String prefsUsageKey = 'marco_ai_usage_v1';
  static const String prefsUsageHistoryKey = 'marco_ai_usage_history_v1';
  static const String prefsRollingUsageKey = 'marco_ai_rolling_usage_v1';
  static const String prefsSubQuotaKey = 'marco_ai_sub_quota_v1';
  static const String prefsApiBalanceKey = 'marco_ai_api_balance_v1';
  static const String prefsCacheKey = 'marco_ai_cache_v1';
  static const String secureApiKeySlot = 'marco_ai_api_key_v1';
  static const String secureOAuthSessionSlot = 'marco_ai_oauth_session_v1';
  static const String secureLabTokenSlot = 'marco_ai_lab_token_v1';
  static const String secureProfileSecretPrefix = 'marco_ai_profile_secret_';
  static const int maxCacheEntries = 200;
  static const int maxUsageHistoryEntries = 200;

  // Official public PKCE client parameters for user-initiated ChatGPT
  // subscription sign-in (aligned with OpenMinis / Codex CLI PKCE spec).
  static const String codexClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
  static const String codexClientVersion = '0.180.0';
  static const int codexLoopbackPort = 1455;
  static const String codexRedirectUri = 'http://localhost:1455/auth/callback';
  static const String _defaultCodexAuthorizeEndpoint =
      'https://auth.openai.com/oauth/authorize';
  static const String _defaultCodexTokenEndpoint =
      'https://auth.openai.com/oauth/token';
  static const String _defaultCodexModelsEndpoint =
      'https://chatgpt.com/backend-api/codex/models';
  static const String _defaultCodexUsageEndpoint =
      'https://chatgpt.com/backend-api/wham/usage';
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
      id: 'gpt-6.2-sol',
      displayName: 'GPT-6.2 Sol',
      description: '最新旗舰通用与深度推理订阅模型',
      priority: 1,
    ),
    AiModelOption(
      id: 'gpt-6.1-sol',
      displayName: 'GPT-6.1 Sol',
      description: '高速均衡通用对话与推理订阅模型',
      priority: 2,
    ),
    AiModelOption(
      id: 'gpt-5.4',
      displayName: 'GPT-5.4',
      description: '经典旗舰通用与深度推理模型',
      priority: 3,
    ),
    AiModelOption(
      id: 'gpt-5.3-codex',
      displayName: 'GPT-5.3 Codex',
      description: '高速结构化理解与精准分析模型',
      priority: 4,
    ),
    AiModelOption(
      id: 'gpt-5.2-codex',
      displayName: 'GPT-5.2 Codex',
      description: '指令遵循与复杂结构化输出模型',
      priority: 5,
    ),
    AiModelOption(
      id: 'gpt-5.1-codex-mini',
      displayName: 'GPT-5.1 Codex Mini',
      description: '高性价比轻量快速订阅模型',
      priority: 6,
    ),
    AiModelOption(
      id: 'codex-mini-latest',
      displayName: 'Codex Mini',
      description: '轻量极速低延迟模型（适合标题清洗）',
      priority: 7,
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
  String? _codexUsageEndpointOverride;
  String? _codexResponsesEndpointOverride;
  GitHubCopilotDeviceFlow _copilotFlow;

  AiConfig _config = const AiConfig();
  List<AiProviderProfile> _profiles = <AiProviderProfile>[];
  String _apiKey = '';
  AiOAuthSession? _oauthSession;
  bool? _debugLabUnlockedOverride;
  bool? _debugExperimentalOAuthOverride;
  List<AiModelOption> _discoveredModels = const <AiModelOption>[];
  String _discoveredModelsScopeKey = '';
  AiMonthlyUsage? _usage;
  List<AiUsageLogEntry> _usageHistory = <AiUsageLogEntry>[];
  List<({int ts, int inTok, int outTok, String auth})> _rollingUsageEvents =
      <({int ts, int inTok, int outTok, String auth})>[];
  AiSubscriptionQuotaSnapshot? _subscriptionQuota;
  AiApiBalanceSnapshot? _apiBalance;
  bool _privacySessionActive = false;
  int _outboundAuthEpoch = 0;
  int _oauthSessionGen = 0;
  int _byoCredentialGen = 0;
  int _byoEndpointGen = 0;
  Future<void>? _oauthKeychainChain;
  int _oauthKeychainTailToken = 0;
  int _oauthKeychainWriteSeq = 0;
  Future<void>? _apiKeyKeychainChain;
  int _apiKeyKeychainTailToken = 0;
  int _apiKeySlotWriteSeq = 0;
  Future<void>? _labTokenKeychainChain;
  int _labTokenKeychainTailToken = 0;
  int _labTokenKeychainWriteSeq = 0;
  final Map<String, int> _profileSecretWriteSeq = <String, int>{};
  int _balanceEpoch = 0;
  int _quotaEpoch = 0;
  final Map<String, int> _balanceBackoffUntilMs = <String, int>{};
  final Map<String, Future<AiApiBalanceSnapshot?>> _inFlightApiBalance =
      <String, Future<AiApiBalanceSnapshot?>>{};
  Future<AiSubscriptionQuotaSnapshot?>? _inFlightSubQuota;
  String _inFlightSubQuotaKey = '';
  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<AiOAuthSession>? _inFlightTokenRefresh;
  String _inFlightTokenRefreshAccountKey = '';
  int _inFlightTokenRefreshGen = -1;
  String? _codexWebModelsEndpointOverride;

  AiService({
    http.Client? httpClient,
    SecureStorageBackend? secureStorage,
    AiLabPasscodeStore? passcodeStore,
    DateTime Function()? clock,
    GitHubCopilotDeviceFlow? copilotFlow,
  })  : _injectedHttpClient = httpClient,
        _secureBackend = secureStorage ?? const FlutterSecureStorageBackend(),
        _passcodeStore = passcodeStore ?? AiLabPasscodeStore.instance,
        _clock = clock ?? DateTime.now,
        _copilotFlow = copilotFlow ?? GitHubCopilotDeviceFlow.instance {
    _passcodeStore.addListener(_onPasscodeStoreChanged);
  }

  void _onPasscodeStoreChanged() {
    _outboundAuthEpoch++;
    notifyListeners();
  }

  AiConfig get config => _config;
  List<AiProviderProfile> get profiles =>
      List<AiProviderProfile>.unmodifiable(_profiles);

  AiProviderProfile? get activeProfile {
    final targetId = _config.activeProfileId.trim();
    if (targetId.isEmpty) return null;
    for (final profile in _profiles) {
      if (profile.id == targetId) return profile;
    }
    return null;
  }

  AiAuthMode get activeAuthMode => activeProfile?.authMode ?? _config.authMode;
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
  List<AiModelOption> get discoveredModels {
    if (_discoveredModels.isEmpty) return const <AiModelOption>[];
    if (_discoveredModelsScopeKey.isNotEmpty &&
        _discoveredModelsScopeKey != _currentActiveModelCatalogScopeKey) {
      return const <AiModelOption>[];
    }
    return _discoveredModels;
  }

  /// Monotonic generation bumped whenever OAuth sign-in / sign-out / account
  /// switch changes the active subscription session.
  int get oauthSessionGen => _oauthSessionGen;

  String _computeModelCatalogScopeKey({
    required AiConfig config,
    required AiAuthMode authMode,
    required String apiKey,
    AiOAuthSession? oauthSession,
  }) {
    if (authMode == AiAuthMode.codexOAuth) {
      return 'codex|${oauthAccountKey(oauthSession ?? _oauthSession)}';
    }
    final ep = normalizeApiBalanceEndpointKey(config.baseUrl);
    final trimmedKey = apiKey.trim();
    final keyHash = trimmedKey.isEmpty
        ? ''
        : sha256.convert(utf8.encode(trimmedKey)).toString();
    return 'byo|${authMode.id}|${config.protocol.id}|$ep|$keyHash';
  }

  String get _currentActiveModelCatalogScopeKey => _computeModelCatalogScopeKey(
        config: _config,
        authMode: activeAuthMode,
        apiKey: _apiKey,
      );

  void _clearDiscoveredModels() {
    _discoveredModels = const <AiModelOption>[];
    _discoveredModelsScopeKey = '';
  }
  int get cachedEntryCount => _cache.length;

  bool get _enforcesPasscodeInService =>
      _passcodeStore.effectiveTargetPlatform == 'ios';

  bool get isPrivacySessionActive => _privacySessionActive;

  /// Hard circuit-breaker toggled by the shell whenever Privacy Space is
  /// entered or exited so no background AI/OAuth/balance request can ever fire
  /// during a private session.
  void setPrivacySessionActive(bool active) {
    if (_privacySessionActive == active) return;
    _privacySessionActive = active;
    _outboundAuthEpoch++;
    if (active) {
      _balanceEpoch++;
      _quotaEpoch++;
      _inFlightApiBalance.clear();
      _inFlightSubQuota = null;
      _inFlightSubQuotaKey = '';
      _inFlightTokenRefresh = null;
      _inFlightTokenRefreshAccountKey = '';
      _inFlightTokenRefreshGen = -1;
    }
    notifyListeners();
  }

  /// True when the experimental AI Viewing Lab gate has been unlocked via a
  /// valid, platform-matching, non-expired Ed25519 passcode (`MMAILAB1...`).
  bool get isLabUnlocked {
    if (OhosRuntime.isOhos || _privacySessionActive) return false;
    if (_debugLabUnlockedOverride != null) return _debugLabUnlockedOverride!;
    return _passcodeStore.isUnlockedAt(_clock());
  }

  /// True when the active passcode grants experimental OpenAI OAuth (`exp_oauth`).
  bool get isExperimentalOAuthAllowed {
    if (!isLabUnlocked) return false;
    if (_debugExperimentalOAuthOverride != null) {
      return _debugExperimentalOAuthOverride!;
    }
    if (_debugLabUnlockedOverride == true) return true;
    final p = activePasscodePayload;
    return p != null && p.experimentalOAuth;
  }

  void _ensureLabGateAuthorized({bool requireExperimentalOAuth = false}) {
    if (_privacySessionActive) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已硬性禁用所有外部 AI 网络请求',
      );
    }
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

  bool get _shouldEnforcePasscodeGate =>
      _enforcesPasscodeInService ||
      _passcodeStore.hasStoredToken ||
      _debugLabUnlockedOverride != null ||
      _debugExperimentalOAuthOverride != null;

  void _ensureOutboundAuthorized({
    required bool isPrivateSession,
    required bool requireExperimentalOAuth,
  }) {
    if (isPrivateSession || _privacySessionActive) {
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
    if (_shouldEnforcePasscodeGate) {
      _ensureLabGateAuthorized(
        requireExperimentalOAuth: requireExperimentalOAuth,
      );
    }
  }

  /// Re-verifies authorization session & live credentials right before any
  /// follow-up network dispatch or late state write-back.
  void _assertOutboundStillAuthorized({
    required int capturedAuthEpoch,
    required bool isPrivateSession,
    required bool requireExperimentalOAuth,
    int? capturedOAuthGen,
    String? expectedOAuthAccountKey,
  }) {
    _ensureOutboundAuthorized(
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: requireExperimentalOAuth,
    );
    if (capturedAuthEpoch != _outboundAuthEpoch) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '授权会话状态已变更，已中止后续请求与结果写回',
      );
    }
    if (capturedOAuthGen != null && capturedOAuthGen != _oauthSessionGen) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '订阅账号登录状态已变更，已中止旧会话请求',
      );
    }
    if (expectedOAuthAccountKey != null &&
        expectedOAuthAccountKey.isNotEmpty &&
        oauthAccountKey(_oauthSession) != expectedOAuthAccountKey) {
      throw const AiServiceException(
        AiErrorCode.unauthorized,
        '当前订阅账号已切换，已丢弃旧账号响应',
      );
    }
  }

  /// True when both the experimental AI Lab passcode is unlocked AND model
  /// credentials are configured.
  bool get isUnlockedAndConfigured => isLabUnlocked && isConfigured;

  /// True when AI Assistant is enabled and has valid credentials + model for
  /// the active [AiAuthMode].
  bool get isConfigured {
    if (OhosRuntime.isOhos || !_config.enabled) return false;
    if (_enforcesPasscodeInService && !isLabUnlocked) return false;
    final model = _config.model.trim();
    if (model.isEmpty) return false;
    final mode = activeAuthMode;
    if (mode == AiAuthMode.codexOAuth) {
      if (_enforcesPasscodeInService && !isExperimentalOAuthAllowed) {
        return false;
      }
      return hasOAuthSession;
    }
    final base = _config.baseUrl.trim();
    if (base.isEmpty) return false;
    final active = activeProfile;
    final noKeyRequired = mode == AiAuthMode.localNoAuth ||
        (active != null && !active.requiresApiKey) ||
        (!_enforcesPasscodeInService && isLoopbackAiBaseUrl(base));
    return noKeyRequired || _apiKey.trim().isNotEmpty;
  }

  String get statusSummaryZh {
    if (!isLabUnlocked) {
      return '内测中 · 输入口令开启';
    }
    if (!isConfigured) {
      return activeAuthMode == AiAuthMode.codexOAuth &&
              isExperimentalOAuthAllowed
          ? '未登录订阅账号'
          : '未配置';
    }
    if (activeAuthMode == AiAuthMode.codexOAuth &&
        isExperimentalOAuthAllowed &&
        _oauthSession != null) {
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

  List<AiUsageLogEntry> get usageHistory =>
      List<AiUsageLogEntry>.unmodifiable(_usageHistory);

  static String oauthAccountKey(AiOAuthSession? session) {
    if (session == null || !session.isValid) return '';
    final acc = session.accountId.trim().toLowerCase();
    final email = session.email.trim().toLowerCase();
    if (acc.isNotEmpty || email.isNotEmpty) {
      return '$acc|$email';
    }
    return sha256.convert(utf8.encode(session.accessToken.trim())).toString();
  }

  static String computeApiBalanceAccountKey(String baseUrl, String apiKey) {
    final ep = normalizeApiBalanceEndpointKey(baseUrl);
    final k = apiKey.trim();
    if (ep.isEmpty || k.isEmpty) return '';
    return sha256.convert(utf8.encode('$ep|$k')).toString();
  }

  AiSubscriptionQuotaSnapshot? get subscriptionQuota {
    final snap = _subscriptionQuota;
    if (snap == null) return null;
    final activeKey = oauthAccountKey(_oauthSession);
    if (activeKey.isEmpty) return null;
    if (snap.accountKey.isNotEmpty && snap.accountKey != activeKey) {
      return null;
    }
    return snap;
  }

  /// Latest BYO-API account balance snapshot matching the currently configured
  /// `baseUrl` (case-preserving path) AND active API key fingerprint, or `null`
  /// if not yet queried or if endpoint/key changed.
  AiApiBalanceSnapshot? get apiBalance {
    final snap = _apiBalance;
    if (snap == null) return null;
    final epKey = normalizeApiBalanceEndpointKey(_config.baseUrl);
    final acctKey = computeApiBalanceAccountKey(_config.baseUrl, _apiKey);
    if (epKey.isEmpty || acctKey.isEmpty) return null;
    if (snap.endpointKey != epKey) return null;
    if (snap.accountKey.isNotEmpty && snap.accountKey != acctKey) return null;
    return snap;
  }

  /// Computes local non-cached request count and total tokens within [window]
  /// (e.g. `Duration(hours: 5)` for 5h window and `Duration(days: 7)` for weekly)
  /// from the dedicated 7-day rolling ledger (decoupled from the 200-item UI log).
  ({int requests, int promptTokens, int completionTokens, int totalTokens})
      rollingWindowUsage(
    Duration window, {
    bool codexOAuthOnly = false,
  }) {
    final nowMs = _clock().millisecondsSinceEpoch;
    final cutoffMs = _clock().subtract(window).millisecondsSinceEpoch;
    var reqs = 0;
    var inTok = 0;
    var outTok = 0;
    for (final entry in _rollingUsageEvents) {
      if (entry.ts < cutoffMs || entry.ts > nowMs) continue;
      if (codexOAuthOnly && entry.auth != AiAuthMode.codexOAuth.id) {
        continue;
      }
      reqs++;
      inTok += entry.inTok;
      outTok += entry.outTok;
    }
    return (
      requests: reqs,
      promptTokens: inTok,
      completionTokens: outTok,
      totalTokens: inTok + outTok,
    );
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
    String? codexWebModelsEndpoint,
    String? codexUsageEndpoint,
    String? codexResponsesEndpoint,
    bool? labUnlockedForTest = true,
    bool? experimentalOAuthForTest,
    GitHubCopilotDeviceFlow? copilotFlow,
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
    if (codexWebModelsEndpoint != null) {
      _codexWebModelsEndpointOverride = codexWebModelsEndpoint;
    }
    if (codexUsageEndpoint != null) {
      _codexUsageEndpointOverride = codexUsageEndpoint;
    }
    if (codexResponsesEndpoint != null) {
      _codexResponsesEndpointOverride = codexResponsesEndpoint;
    }
    if (copilotFlow != null) _copilotFlow = copilotFlow;
    if (resetState) {
      _config = const AiConfig();
      _profiles = <AiProviderProfile>[];
      _apiKey = '';
      _oauthSession = null;
      _clearDiscoveredModels();
      _usage = null;
      _usageHistory = <AiUsageLogEntry>[];
      _rollingUsageEvents = <({int ts, int inTok, int outTok, String auth})>[];
      _subscriptionQuota = null;
      _apiBalance = null;
      _privacySessionActive = false;
      _outboundAuthEpoch++;
      _oauthSessionGen++;
      _byoCredentialGen++;
      _byoEndpointGen++;
      _oauthKeychainChain = null;
      _oauthKeychainTailToken++;
      _oauthKeychainWriteSeq = 0;
      _apiKeyKeychainChain = null;
      _apiKeyKeychainTailToken++;
      _apiKeySlotWriteSeq = 0;
      _labTokenKeychainChain = null;
      _labTokenKeychainTailToken++;
      _labTokenKeychainWriteSeq = 0;
      DefaultSecureCredentialStore.deleteTestFallbackKey(secureLabTokenSlot);
      _profileSecretWriteSeq.clear();
      _balanceEpoch++;
      _quotaEpoch++;
      _balanceBackoffUntilMs.clear();
      _inFlightApiBalance.clear();
      _inFlightSubQuota = null;
      _inFlightSubQuotaKey = '';
      _cache.clear();
      _copilotFlow.clearSessionCache();
      _loaded = false;
      _loadFuture = null;
      _inFlightTokenRefresh = null;
      _inFlightTokenRefreshAccountKey = '';
      _inFlightTokenRefreshGen = -1;
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
    _codexWebModelsEndpointOverride = null;
    _codexUsageEndpointOverride = null;
    _codexResponsesEndpointOverride = null;
    _copilotFlow = GitHubCopilotDeviceFlow.instance;
    _copilotFlow.clearSessionCache();
    _config = const AiConfig();
    _profiles = <AiProviderProfile>[];
    _apiKey = '';
    _oauthSession = null;
    _debugLabUnlockedOverride = null;
    _debugExperimentalOAuthOverride = null;
    _clearDiscoveredModels();
    _usage = null;
    _usageHistory = <AiUsageLogEntry>[];
    _rollingUsageEvents = <({int ts, int inTok, int outTok, String auth})>[];
    _subscriptionQuota = null;
    _apiBalance = null;
    _privacySessionActive = false;
    _outboundAuthEpoch++;
    _oauthSessionGen++;
    _byoCredentialGen++;
    _byoEndpointGen++;
    _oauthKeychainChain = null;
    _oauthKeychainTailToken++;
    _oauthKeychainWriteSeq = 0;
    _apiKeyKeychainChain = null;
    _apiKeyKeychainTailToken++;
    _apiKeySlotWriteSeq = 0;
    _labTokenKeychainChain = null;
    _labTokenKeychainTailToken++;
    _labTokenKeychainWriteSeq = 0;
    DefaultSecureCredentialStore.deleteTestFallbackKey(secureLabTokenSlot);
    _profileSecretWriteSeq.clear();
    _balanceEpoch++;
    _quotaEpoch++;
    _balanceBackoffUntilMs.clear();
    _inFlightApiBalance.clear();
    _inFlightSubQuota = null;
    _inFlightSubQuotaKey = '';
    _cache.clear();
    _loaded = false;
    _loadFuture = null;
    _inFlightTokenRefresh = null;
    _inFlightTokenRefreshAccountKey = '';
    _inFlightTokenRefreshGen = -1;
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
      if (_config.authMode == AiAuthMode.codexOAuth) {
        final healedModel = sanitizeCodexModelSlug(_config.model);
        final healedFast = isDisallowedCodexModelSlug(_config.fastModel)
            ? ''
            : sanitizeCodexModelSlug(_config.fastModel);
        if (healedModel != _config.model || healedFast != _config.fastModel) {
          _config = _config.copyWith(
            model: healedModel,
            fastModel: healedFast,
          );
          if (!OhosRuntime.isOhos) {
            try {
              await prefs.setString(prefsConfigKey, jsonEncode(_config.toJson()));
            } catch (_) {}
          }
        }
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

      _usageHistory = <AiUsageLogEntry>[];
      final rawHistory = prefs.getString(prefsUsageHistoryKey);
      if (rawHistory != null && rawHistory.trim().isNotEmpty) {
        try {
          final decodedHistory = jsonDecode(rawHistory);
          if (decodedHistory is List) {
            for (final item in decodedHistory) {
              if (item is Map) {
                _usageHistory.add(
                  AiUsageLogEntry.fromJson(Map<String, dynamic>.from(item)),
                );
              }
            }
          }
        } catch (_) {}
      }

      _rollingUsageEvents = <({int ts, int inTok, int outTok, String auth})>[];
      final sevenDayCutoffMs =
          _clock().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
      final rawRolling = prefs.getString(prefsRollingUsageKey);
      if (rawRolling != null && rawRolling.trim().isNotEmpty) {
        try {
          final decodedRolling = jsonDecode(rawRolling);
          if (decodedRolling is List) {
            for (final item in decodedRolling) {
              if (item is List && item.length >= 4) {
                final ts = (item[0] as num?)?.toInt() ?? 0;
                if (ts < sevenDayCutoffMs) continue;
                _rollingUsageEvents.add((
                  ts: ts,
                  inTok: ((item[1] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
                  outTok: ((item[2] as num?)?.toInt() ?? 0).clamp(0, 1 << 30),
                  auth: (item[3] ?? 'api_key').toString().trim(),
                ));
              }
            }
          }
        } catch (_) {}
      } else if (_usageHistory.isNotEmpty) {
        for (final h in _usageHistory) {
          if (!h.fromCache && h.timestampMs >= sevenDayCutoffMs) {
            _rollingUsageEvents.add((
              ts: h.timestampMs,
              inTok: h.promptTokens,
              outTok: h.completionTokens,
              auth: h.authModeId,
            ));
          }
        }
      }

      _subscriptionQuota = null;
      final rawSubQuota = prefs.getString(prefsSubQuotaKey);
      if (rawSubQuota != null && rawSubQuota.trim().isNotEmpty) {
        try {
          final decodedQuota = jsonDecode(rawSubQuota);
          if (decodedQuota is Map) {
            _subscriptionQuota = AiSubscriptionQuotaSnapshot.fromJson(
              Map<String, dynamic>.from(decodedQuota),
            );
          }
        } catch (_) {}
      }

      _apiBalance = null;
      final rawApiBalance = prefs.getString(prefsApiBalanceKey);
      if (rawApiBalance != null && rawApiBalance.trim().isNotEmpty) {
        try {
          final decodedBal = jsonDecode(rawApiBalance);
          if (decodedBal is Map) {
            _apiBalance = AiApiBalanceSnapshot.fromJson(
              Map<String, dynamic>.from(decodedBal),
            );
          }
        } catch (_) {}
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

      final rawProfiles = prefs.getString(prefsProfilesKey);
      _profiles = <AiProviderProfile>[];
      if (rawProfiles != null && rawProfiles.trim().isNotEmpty) {
        final decodedProfiles = jsonDecode(rawProfiles);
        if (decodedProfiles is List) {
          for (final item in decodedProfiles) {
            if (item is Map) {
              final profile = AiProviderProfile.fromJson(
                Map<String, dynamic>.from(item),
              );
              if (profile.id.isNotEmpty) {
                _profiles.add(profile);
              }
            }
          }
        }
      }

      try {
        final pendingApiKeychain = _apiKeyKeychainChain;
        if (pendingApiKeychain != null) {
          await pendingApiKeychain.catchError((_) {});
        }
        String? storedKey;
        final activeId = _config.activeProfileId.trim();
        if (activeId.isNotEmpty) {
          storedKey = await _secureBackend.read(
            '$secureProfileSecretPrefix$activeId',
          );
        }
        storedKey ??= await _secureBackend.read(secureApiKeySlot);
        _apiKey = (storedKey ?? '').trim();
      } catch (_) {
        _apiKey = '';
      }

      try {
        final pendingOAuthKeychain = _oauthKeychainChain;
        if (pendingOAuthKeychain != null) {
          await pendingOAuthKeychain.catchError((_) {});
        }
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
        // Restore signed passcode token from Keychain if SharedPreferences was
        // cleared or not yet hydrated (never gated by backend type on iOS).
        try {
          final pendingLabKeychain = _labTokenKeychainChain;
          if (pendingLabKeychain != null) {
            await pendingLabKeychain.catchError((_) {});
          }
          final storedLabTok = await _secureBackend.read(secureLabTokenSlot);
          if (storedLabTok != null && storedLabTok.trim().isNotEmpty) {
            await _passcodeStore.unlockWithPasscode(
              storedLabTok,
              nowOverride: _clock(),
            );
          }
        } catch (_) {}
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

  Future<void> _enqueueLabTokenKeychainOp(Future<void> Function() op) {
    final prev = _labTokenKeychainChain;
    final token = ++_labTokenKeychainTailToken;
    final run = (prev == null
            ? Future<void>.sync(op)
            : prev.catchError((_) {}).then((_) => op()))
        .whenComplete(() {
      if (_labTokenKeychainTailToken == token) {
        _labTokenKeychainChain = null;
      }
    });
    _labTokenKeychainChain = run.catchError((_) {});
    return run;
  }

  Future<void> _persistLabTokenToKeychain(String canonicalToken) async {
    final trimmed = canonicalToken.trim();
    if (trimmed.isEmpty) return;
    final mySeq = ++_labTokenKeychainWriteSeq;
    await _enqueueLabTokenKeychainOp(() async {
      if (mySeq != _labTokenKeychainWriteSeq) return;
      try {
        await _secureBackend.write(secureLabTokenSlot, trimmed);
      } catch (_) {}
    });
  }

  Future<void> _clearLabTokenFromKeychain() async {
    final mySeq = ++_labTokenKeychainWriteSeq;
    await _enqueueLabTokenKeychainOp(() async {
      if (mySeq != _labTokenKeychainWriteSeq) return;
      try {
        await _secureBackend.delete(secureLabTokenSlot);
      } catch (_) {}
    });
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
    await _persistLabTokenToKeychain(res.canonicalToken);
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
    if (res.isValid && res.payload != null) {
      await _persistLabTokenToKeychain(res.canonicalToken);
    }
    notifyListeners();
    return res;
  }

  /// Clears the stored AI Lab passcode and returns AI Lab to locked state.
  Future<void> lockAiLab() async {
    _debugLabUnlockedOverride = null;
    _debugExperimentalOAuthOverride = null;
    await _passcodeStore.lock();
    await _clearLabTokenFromKeychain();
    notifyListeners();
  }

  /// Monotonic generation bumped whenever BYO endpoint, protocol, auth mode,
  /// active profile, or API key changes.
  int get byoEndpointGen => _byoEndpointGen;

  /// Serializes writes and deletes targeting [secureApiKeySlot] and
  /// `$secureProfileSecretPrefix<id>` so rapid key edits or clears never
  /// commit out of order on a slow Keychain backend.
  Future<void> _enqueueApiKeyKeychainOp(Future<void> Function() op) {
    final prev = _apiKeyKeychainChain;
    final token = ++_apiKeyKeychainTailToken;
    final run = (prev == null
            ? Future<void>.sync(op)
            : prev.catchError((_) {}).then((_) => op()))
        .whenComplete(() {
      if (_apiKeyKeychainTailToken == token) {
        _apiKeyKeychainChain = null;
      }
    });
    _apiKeyKeychainChain = run.catchError((_) {});
    return run;
  }

  /// Waits for all queued OAuth, BYO API-key, and Lab passcode Keychain ops.
  @visibleForTesting
  Future<void> waitForPendingKeychainOpsForTest() async {
    while (_oauthKeychainChain != null ||
        _apiKeyKeychainChain != null ||
        _labTokenKeychainChain != null) {
      final pendingOAuth = _oauthKeychainChain;
      if (pendingOAuth != null) {
        await pendingOAuth.catchError((_) {});
      }
      final pendingApi = _apiKeyKeychainChain;
      if (pendingApi != null) {
        await pendingApi.catchError((_) {});
      }
      final pendingLab = _labTokenKeychainChain;
      if (pendingLab != null) {
        await pendingLab.catchError((_) {});
      }
    }
  }

  /// Writes or deletes the API key strictly inside [SecureStorageBackend]
  /// (iOS Keychain) and NEVER in [SharedPreferences], serializing writes and
  /// deletes in submission order.
  Future<void> setApiKey(String rawKey) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final trimmed = rawKey.trim();
    if (_apiKey != trimmed) {
      _byoCredentialGen++;
      _byoEndpointGen++;
      _balanceEpoch++;
      _inFlightApiBalance.clear();
      _apiBalance = null;
      _clearDiscoveredModels();
    }
    _apiKey = trimmed;
    final activeId = _config.activeProfileId.trim();
    final myApiSeq = ++_apiKeySlotWriteSeq;
    final int myProfileSeq;
    if (activeId.isNotEmpty) {
      myProfileSeq = (_profileSecretWriteSeq[activeId] ?? 0) + 1;
      _profileSecretWriteSeq[activeId] = myProfileSeq;
    } else {
      myProfileSeq = 0;
    }
    notifyListeners();
    await _enqueueApiKeyKeychainOp(() async {
      if (myApiSeq == _apiKeySlotWriteSeq) {
        if (trimmed.isEmpty) {
          await _secureBackend.delete(secureApiKeySlot);
        } else {
          await _secureBackend.write(secureApiKeySlot, trimmed);
        }
      }
      if (activeId.isNotEmpty &&
          myProfileSeq == _profileSecretWriteSeq[activeId]) {
        final profileSlot = '$secureProfileSecretPrefix$activeId';
        if (trimmed.isEmpty) {
          await _secureBackend.delete(profileSlot);
        } else {
          await _secureBackend.write(profileSlot, trimmed);
        }
      }
    });
  }

  /// Serializes writes and deletes targeting [secureOAuthSessionSlot] so an
  /// earlier slow write can never finish after a subsequent logout or account
  /// switch and resurrect a stale account on the next cold start.
  Future<void> _enqueueOAuthKeychainOp(Future<void> Function() op) {
    final prev = _oauthKeychainChain;
    final token = ++_oauthKeychainTailToken;
    final run = (prev == null
            ? Future<void>.sync(op)
            : prev.catchError((_) {}).then((_) => op()))
        .whenComplete(() {
      if (_oauthKeychainTailToken == token) {
        _oauthKeychainChain = null;
      }
    });
    _oauthKeychainChain = run.catchError((_) {});
    return run;
  }

  /// Saves or clears the OAuth subscription session strictly inside Keychain.
  /// Always advances `_oauthSessionGen`, clears any prior in-flight refresh,
  /// and serializes Keychain write/delete operations in submission order so a
  /// slow write for account A can never overwrite a later logout or account B.
  Future<void> setOAuthSession(AiOAuthSession? session) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final prevKey = oauthAccountKey(_oauthSession);
    final nextKey = oauthAccountKey(session);
    _oauthSessionGen++;
    _inFlightTokenRefresh = null;
    _inFlightTokenRefreshAccountKey = '';
    _inFlightTokenRefreshGen = -1;
    if (prevKey != nextKey) {
      _quotaEpoch++;
      _inFlightSubQuota = null;
      _inFlightSubQuotaKey = '';
      if (_subscriptionQuota != null &&
          _subscriptionQuota!.accountKey != nextKey) {
        _subscriptionQuota = null;
      }
      _clearDiscoveredModels();
    }
    final nextSession =
        (session == null || !session.isValid) ? null : session;
    _oauthSession = nextSession;
    final mySeq = ++_oauthKeychainWriteSeq;
    notifyListeners();
    await _enqueueOAuthKeychainOp(() async {
      if (mySeq != _oauthKeychainWriteSeq) return;
      if (nextSession == null) {
        await _secureBackend.delete(secureOAuthSessionSlot);
      } else {
        await _secureBackend.write(
          secureOAuthSessionSlot,
          jsonEncode(nextSession.toJson()),
        );
      }
    });
  }

  /// Writes a refreshed OAuth session strictly for the same account & generation
  /// without resetting `_oauthSessionGen` or `_quotaEpoch`, serialized through
  /// the same Keychain slot queue as [setOAuthSession].
  Future<void> _persistRefreshedOAuthSession(
    AiOAuthSession updated, {
    required int expectedAuthEpoch,
    required int expectedOAuthGen,
    required String expectedAccountKey,
  }) async {
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: expectedAuthEpoch,
      isPrivateSession: false,
      requireExperimentalOAuth: true,
      capturedOAuthGen: expectedOAuthGen,
      expectedOAuthAccountKey: expectedAccountKey,
    );
    final mySeq = ++_oauthKeychainWriteSeq;
    await _enqueueOAuthKeychainOp(() async {
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: expectedAuthEpoch,
        isPrivateSession: false,
        requireExperimentalOAuth: true,
        capturedOAuthGen: expectedOAuthGen,
        expectedOAuthAccountKey: expectedAccountKey,
      );
      if (mySeq != _oauthKeychainWriteSeq) return;
      _oauthSession = updated;
      await _secureBackend.write(
        secureOAuthSessionSlot,
        jsonEncode(updated.toJson()),
      );
    });
    notifyListeners();
  }

  /// Signs out of the current OAuth subscription account and clears Keychain.
  Future<void> signOutOAuth() async {
    await setOAuthSession(null);
    _subscriptionQuota = null;
    _clearDiscoveredModels();
    if (!OhosRuntime.isOhos) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(prefsSubQuotaKey);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Reads the stored secret for a specific [profileId] from [SecureStorageBackend].
  Future<String> readProfileSecret(String profileId) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final id = profileId.trim();
    if (id.isEmpty) return '';
    final pendingApiKeychain = _apiKeyKeychainChain;
    if (pendingApiKeychain != null) {
      await pendingApiKeychain.catchError((_) {});
    }
    final secret = await _secureBackend.read('$secureProfileSecretPrefix$id');
    return (secret ?? '').trim();
  }

  /// Persists or clears the secret for [profileId] in [SecureStorageBackend].
  Future<void> setProfileSecret(String profileId, String rawSecret) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final id = profileId.trim();
    if (id.isEmpty) return;
    final trimmed = rawSecret.trim();
    final slot = '$secureProfileSecretPrefix$id';
    final myProfileSeq = (_profileSecretWriteSeq[id] ?? 0) + 1;
    _profileSecretWriteSeq[id] = myProfileSeq;
    final isActive = _config.activeProfileId.trim() == id;
    int? myApiSeq;
    if (isActive) {
      final changed = _apiKey != trimmed;
      _apiKey = trimmed;
      if (changed) {
        _byoCredentialGen++;
        _byoEndpointGen++;
        _balanceEpoch++;
        _inFlightApiBalance.clear();
        _apiBalance = null;
        _clearDiscoveredModels();
      }
      myApiSeq = ++_apiKeySlotWriteSeq;
    }
    notifyListeners();
    await _enqueueApiKeyKeychainOp(() async {
      if (myProfileSeq == _profileSecretWriteSeq[id]) {
        if (trimmed.isEmpty) {
          await _secureBackend.delete(slot);
        } else {
          await _secureBackend.write(slot, trimmed);
        }
      }
      if (myApiSeq != null && myApiSeq == _apiKeySlotWriteSeq) {
        if (trimmed.isEmpty) {
          await _secureBackend.delete(secureApiKeySlot);
        } else {
          await _secureBackend.write(secureApiKeySlot, trimmed);
        }
      }
    });
  }

  Future<void> _persistProfiles() async {
    if (OhosRuntime.isOhos) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsProfilesKey,
      jsonEncode(<Map<String, dynamic>>[
        for (final p in _profiles) p.toJson(),
      ]),
    );
  }

  /// Creates or updates a provider profile. When [activate] is true (or when
  /// updating the currently active profile), transparently mirrors its
  /// connection parameters into [config] and active credential slot.
  Future<AiProviderProfile> saveProfile(
    AiProviderProfile profile, {
    String? secret,
    bool activate = false,
    bool enableAiWhenActivating = false,
  }) async {
    await ensureLoaded();
    final nowMs = _clock().millisecondsSinceEpoch;
    final id = profile.id.trim().isNotEmpty
        ? profile.id.trim()
        : 'profile_$nowMs';
    final normalized = profile.copyWith(
      id: id,
      name: profile.name.trim().isNotEmpty ? profile.name.trim() : '未命名服务商',
      createdAtMs: profile.createdAtMs > 0 ? profile.createdAtMs : nowMs,
      updatedAtMs: nowMs,
    );
    final idx = _profiles.indexWhere((p) => p.id == id);
    if (idx >= 0) {
      _profiles[idx] = normalized;
    } else {
      _profiles.add(normalized);
    }
    await _persistProfiles();

    if (secret != null) {
      final trimmed = secret.trim();
      final slot = '$secureProfileSecretPrefix$id';
      final myProfileSeq = (_profileSecretWriteSeq[id] ?? 0) + 1;
      _profileSecretWriteSeq[id] = myProfileSeq;
      await _enqueueApiKeyKeychainOp(() async {
        if (myProfileSeq != _profileSecretWriteSeq[id]) return;
        if (trimmed.isEmpty) {
          await _secureBackend.delete(slot);
        } else {
          await _secureBackend.write(slot, trimmed);
        }
      });
    }

    if (activate || _config.activeProfileId.trim() == id) {
      final effectiveSecret = secret != null
          ? secret.trim()
          : await readProfileSecret(id);
      _apiKey = effectiveSecret;
      _byoCredentialGen++;
      _byoEndpointGen++;
      _balanceEpoch++;
      _inFlightApiBalance.clear();
      _apiBalance = null;
      _clearDiscoveredModels();
      final myApiSeq = ++_apiKeySlotWriteSeq;
      await _enqueueApiKeyKeychainOp(() async {
        if (myApiSeq != _apiKeySlotWriteSeq) return;
        if (effectiveSecret.isEmpty) {
          await _secureBackend.delete(secureApiKeySlot);
        } else {
          await _secureBackend.write(secureApiKeySlot, effectiveSecret);
        }
      });
      _config = _config.copyWith(
        enabled: enableAiWhenActivating ? true : _config.enabled,
        protocol: normalized.protocol,
        baseUrl: normalized.baseUrl,
        model: normalized.model,
        fastModel: normalized.fastModel,
        activeProfileId: normalized.id,
      );
      if (!OhosRuntime.isOhos) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsConfigKey, jsonEncode(_config.toJson()));
      }
    }
    notifyListeners();
    return normalized;
  }

  /// Switches the active provider instance and loads its credentials from
  /// [SecureStorageBackend].
  Future<void> activateProfile(
    String profileId, {
    bool enableAi = false,
  }) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final id = profileId.trim();
    final target = _profiles.where((p) => p.id == id).firstOrNull;
    if (target == null) return;
    final stored = await readProfileSecret(id);
    _apiKey = stored;
    _byoCredentialGen++;
    _byoEndpointGen++;
    _balanceEpoch++;
    _inFlightApiBalance.clear();
    _apiBalance = null;
    _clearDiscoveredModels();
    final myApiSeq = ++_apiKeySlotWriteSeq;
    await _enqueueApiKeyKeychainOp(() async {
      if (myApiSeq != _apiKeySlotWriteSeq) return;
      if (stored.isEmpty) {
        await _secureBackend.delete(secureApiKeySlot);
      } else {
        await _secureBackend.write(secureApiKeySlot, stored);
      }
    });
    _config = _config.copyWith(
      enabled: enableAi ? true : _config.enabled,
      protocol: target.protocol,
      baseUrl: target.baseUrl,
      model: target.model,
      fastModel: target.fastModel,
      activeProfileId: target.id,
    );
    if (!OhosRuntime.isOhos) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsConfigKey, jsonEncode(_config.toJson()));
    }
    notifyListeners();
  }

  /// Deletes a saved provider profile and scrubs its secret from
  /// [SecureStorageBackend].
  Future<void> deleteProfile(String profileId) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final id = profileId.trim();
    if (id.isEmpty) return;
    _profiles.removeWhere((p) => p.id == id);
    final myProfileSeq = (_profileSecretWriteSeq[id] ?? 0) + 1;
    _profileSecretWriteSeq[id] = myProfileSeq;
    await _enqueueApiKeyKeychainOp(() async {
      if (myProfileSeq != _profileSecretWriteSeq[id]) return;
      await _secureBackend.delete('$secureProfileSecretPrefix$id');
    });
    await _persistProfiles();

    if (_config.activeProfileId.trim() == id) {
      if (_profiles.isNotEmpty) {
        await activateProfile(_profiles.first.id);
        return;
      }
      _apiKey = '';
      _byoCredentialGen++;
      _byoEndpointGen++;
      _clearDiscoveredModels();
      final myApiSeq = ++_apiKeySlotWriteSeq;
      await _enqueueApiKeyKeychainOp(() async {
        if (myApiSeq != _apiKeySlotWriteSeq) return;
        await _secureBackend.delete(secureApiKeySlot);
      });
      _config = _config.copyWith(
        activeProfileId: '',
        baseUrl: '',
        model: '',
        fastModel: '',
      );
      if (!OhosRuntime.isOhos) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsConfigKey, jsonEncode(_config.toJson()));
      }
    }
    notifyListeners();
  }

  /// Fetches available model IDs for the active (or overridden) provider.
  Future<List<String>> fetchAvailableModels({
    AiConfig? configOverride,
    String? apiKeyOverride,
    AiAuthMode? authModeOverride,
    bool isPrivateSession = false,
  }) async {
    await ensureLoaded();
    final cfg = configOverride ?? _config;
    final mode = authModeOverride ??
        (configOverride != null ? cfg.authMode : activeAuthMode);
    _ensureOutboundAuthorized(
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: mode == AiAuthMode.codexOAuth,
    );
    final authEpoch = _outboundAuthEpoch;
    if (mode == AiAuthMode.codexOAuth) {
      final opts = await fetchAvailableModelOptions(
        configOverride: cfg.copyWith(authMode: AiAuthMode.codexOAuth),
        apiKeyOverride: apiKeyOverride,
        isPrivateSession: isPrivateSession,
      );
      return List<String>.unmodifiable(opts.map((m) => m.id));
    }
    var key = (apiKeyOverride ?? _apiKey).trim();
    var baseUrl = cfg.baseUrl.trim();
    final extraHeaders = <String, String>{};

    if (mode == AiAuthMode.githubCopilotDeviceFlow) {
      final session = await _copilotFlow.getOrRefreshSessionToken(
        key,
        httpClient: _injectedHttpClient,
        clock: _clock,
      );
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: isPrivateSession,
        requireExperimentalOAuth: false,
      );
      key = session.token;
      baseUrl = session.apiBaseUrl;
      extraHeaders.addAll(GitHubCopilotDeviceFlow.standardCopilotHeaders);
    } else if (mode == AiAuthMode.openRouterOAuth ||
        baseUrl.toLowerCase().contains('openrouter.ai')) {
      extraHeaders['HTTP-Referer'] = 'https://marcotv.wlj9919.top';
      extraHeaders['X-Title'] = 'Marco Movie';
    }

    final models = await AiModelCatalogFetcher.fetchModels(
      protocol: cfg.protocol,
      baseUrl: baseUrl,
      apiKey: key,
      authMode: mode,
      extraHeaders: extraHeaders,
      httpClient: _injectedHttpClient,
      verifyAuthorizedBeforeHop: () => _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: isPrivateSession,
        requireExperimentalOAuth: false,
      ),
    );
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: authEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: false,
    );
    return models;
  }

  /// Persists non-secret [AiConfig] to [SharedPreferences].
  Future<void> saveConfig(AiConfig next) async {
    if (!_loaded) {
      await ensureLoaded();
    }
    final endpointOrAuthChanged =
        normalizeApiBalanceEndpointKey(_config.baseUrl) !=
            normalizeApiBalanceEndpointKey(next.baseUrl) ||
        _config.protocol != next.protocol ||
        _config.authMode != next.authMode;
    final profileChanged =
        _config.activeProfileId.trim() != next.activeProfileId.trim();
    if (endpointOrAuthChanged ||
        profileChanged ||
        _config.model.trim() != next.model.trim()) {
      _byoCredentialGen++;
    }
    if (endpointOrAuthChanged || profileChanged) {
      _byoEndpointGen++;
    }
    if (endpointOrAuthChanged) {
      _balanceEpoch++;
      _inFlightApiBalance.clear();
    }
    _config = next;
    if (_discoveredModels.isNotEmpty &&
        _discoveredModelsScopeKey != _currentActiveModelCatalogScopeKey) {
      _clearDiscoveredModels();
    }
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
    _ensureOutboundAuthorized(
      isPrivateSession: false,
      requireExperimentalOAuth: true,
    );
    final startAuthEpoch = _outboundAuthEpoch;
    final startOAuthGen = _oauthSessionGen;
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

      // Re-verify privacy space, live passcode, exp_oauth & auth session BEFORE
      // accepting the callback or dispatching the token exchange!
      AiServiceException? gateViolation;
      try {
        _assertOutboundStillAuthorized(
          capturedAuthEpoch: startAuthEpoch,
          isPrivateSession: false,
          requireExperimentalOAuth: true,
          capturedOAuthGen: startOAuthGen,
        );
      } on AiServiceException catch (e) {
        gateViolation = e;
      }

      final errorParam = (uri.queryParameters['error'] ?? '').trim();
      final code = (uri.queryParameters['code'] ?? '').trim();
      final returnedState = (uri.queryParameters['state'] ?? '').trim();

      final okHtml = gateViolation == null &&
          errorParam.isEmpty &&
          code.isNotEmpty &&
          (returnedState.isEmpty || returnedState == pkce.state);

      req.response.statusCode = gateViolation != null
          ? HttpStatus.forbidden
          : (okHtml ? HttpStatus.ok : HttpStatus.badRequest);
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
      if (gateViolation != null) {
        completer.completeError(gateViolation);
        return;
      }
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
          expectedAuthEpoch: startAuthEpoch,
          expectedOAuthGen: startOAuthGen,
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
    int? expectedAuthEpoch,
    int? expectedOAuthGen,
  }) async {
    await ensureLoaded();
    final capturedAuthEpoch = expectedAuthEpoch ?? _outboundAuthEpoch;
    final capturedOAuthGen = expectedOAuthGen ?? _oauthSessionGen;
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: capturedAuthEpoch,
      isPrivateSession: false,
      requireExperimentalOAuth: true,
      capturedOAuthGen: capturedOAuthGen,
    );
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
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: capturedAuthEpoch,
      isPrivateSession: false,
      requireExperimentalOAuth: true,
      capturedOAuthGen: capturedOAuthGen,
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
    await _activateOAuthSession(
      session,
      expectedAuthEpoch: capturedAuthEpoch,
      expectedOAuthGen: capturedOAuthGen,
    );
    return session;
  }

  Future<void> _activateOAuthSession(
    AiOAuthSession session, {
    int? expectedAuthEpoch,
    int? expectedOAuthGen,
  }) async {
    final authEpoch = expectedAuthEpoch ?? _outboundAuthEpoch;
    final preGen = expectedOAuthGen ?? _oauthSessionGen;
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: authEpoch,
      isPrivateSession: false,
      requireExperimentalOAuth: true,
      capturedOAuthGen: preGen,
    );
    await setOAuthSession(session);
    final activeGen = _oauthSessionGen;
    final activeAcct = oauthAccountKey(session);
    List<AiModelOption> models = const <AiModelOption>[];
    try {
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: false,
        requireExperimentalOAuth: true,
        capturedOAuthGen: activeGen,
        expectedOAuthAccountKey: activeAcct,
      );
      models = await fetchAvailableModelOptions(
        configOverride: _config.copyWith(authMode: AiAuthMode.codexOAuth),
      );
    } catch (_) {
      models = List<AiModelOption>.unmodifiable([
        for (final fb in fallbackCodexModels)
          fb.copyWithPriority(fb.priority, isLocalFallback: true),
      ]);
      if (authEpoch == _outboundAuthEpoch && activeGen == _oauthSessionGen) {
        _discoveredModels = models;
        _discoveredModelsScopeKey = 'codex|$activeAcct';
      }
    }
    if (authEpoch != _outboundAuthEpoch ||
        activeGen != _oauthSessionGen ||
        _privacySessionActive ||
        (_shouldEnforcePasscodeGate &&
            (!isLabUnlocked || !isExperimentalOAuthAllowed))) {
      return;
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
  /// Strictly isolates in-flight refresh by `(accountKey, _oauthSessionGen)` so
  /// signing out or switching accounts can never reuse or write back a stale
  /// account's token.
  Future<AiOAuthSession> ensureFreshOAuthSession({
    bool forceRefresh = false,
    bool isPrivateSession = false,
  }) async {
    await ensureLoaded();
    _ensureOutboundAuthorized(
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: true,
    );
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
    final acctKey = oauthAccountKey(current);
    final sessionGen = _oauthSessionGen;
    final authEpoch = _outboundAuthEpoch;
    if (_inFlightTokenRefresh != null &&
        _inFlightTokenRefreshAccountKey == acctKey &&
        _inFlightTokenRefreshGen == sessionGen) {
      return _inFlightTokenRefresh!;
    }
    final fut = _doRefreshOAuthToken(
      current,
      capturedAuthEpoch: authEpoch,
      capturedOAuthGen: sessionGen,
      expectedAccountKey: acctKey,
      isPrivateSession: isPrivateSession,
    );
    _inFlightTokenRefresh = fut;
    _inFlightTokenRefreshAccountKey = acctKey;
    _inFlightTokenRefreshGen = sessionGen;
    try {
      return await fut;
    } finally {
      if (identical(_inFlightTokenRefresh, fut)) {
        _inFlightTokenRefresh = null;
        _inFlightTokenRefreshAccountKey = '';
        _inFlightTokenRefreshGen = -1;
      }
    }
  }

  Future<AiOAuthSession> _doRefreshOAuthToken(
    AiOAuthSession current, {
    required int capturedAuthEpoch,
    required int capturedOAuthGen,
    required String expectedAccountKey,
    required bool isPrivateSession,
  }) async {
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: capturedAuthEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: true,
      capturedOAuthGen: capturedOAuthGen,
      expectedOAuthAccountKey: expectedAccountKey,
    );
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
    // Re-check auth session, privacy state, passcode & account generation BEFORE
    // persisting or returning the refreshed token.
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: capturedAuthEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: true,
      capturedOAuthGen: capturedOAuthGen,
      expectedOAuthAccountKey: expectedAccountKey,
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
    await _persistRefreshedOAuthSession(
      updated,
      expectedAuthEpoch: capturedAuthEpoch,
      expectedOAuthGen: capturedOAuthGen,
      expectedAccountKey: expectedAccountKey,
    );
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

  Future<List<AiModelOption>> _finalizeCodexModelOptions(
    String primaryRaw, {
    required Map<String, String> headers,
    required int capturedAuthEpoch,
    required int capturedOAuthGen,
    required String expectedOAuthAccountKey,
    required bool isPrivateSession,
  }) async {
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: capturedAuthEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: true,
      capturedOAuthGen: capturedOAuthGen,
      expectedOAuthAccountKey: expectedOAuthAccountKey,
    );
    final models = parseModelsResponse(primaryRaw, isCodex: true);
    final merged = <AiModelOption>[...models];
    final seenIds = <String>{
      for (final m in merged) m.id.toLowerCase(),
    };
    final webModelsEndpoint = _codexWebModelsEndpointOverride;
    if (webModelsEndpoint != null && webModelsEndpoint.isNotEmpty) {
      void verifySecondaryCatalogAuth() => _assertOutboundStillAuthorized(
            capturedAuthEpoch: capturedAuthEpoch,
            isPrivateSession: isPrivateSession,
            requireExperimentalOAuth: true,
            capturedOAuthGen: capturedOAuthGen,
            expectedOAuthAccountKey: expectedOAuthAccountKey,
          );
      // Re-verify right before dispatching the 2nd catalog request!
      verifySecondaryCatalogAuth();
      try {
        final webResp = await _getWithTimeout(
          Uri.parse(webModelsEndpoint),
          headers: headers,
          timeout: const Duration(seconds: 8),
          verifyAuthorizedBeforeHop: verifySecondaryCatalogAuth,
          allowSameOriginRedirects: true,
        );
        verifySecondaryCatalogAuth();
        if (webResp.statusCode >= 200 && webResp.statusCode < 300) {
          final webRaw = utf8.decode(webResp.bodyBytes, allowMalformed: true);
          final webModels = parseModelsResponse(webRaw, isCodex: true);
          for (final wm in webModels) {
            if (seenIds.add(wm.id.toLowerCase())) {
              merged.add(wm);
            }
          }
        }
      } on AiServiceException catch (e) {
        // Abort immediately on authorization / privacy / gate invalidation,
        // while tolerating transient network/timeout errors on the secondary
        // catalog so primary-only models remain intact.
        if (e.code == AiErrorCode.privacySpaceBlocked ||
            e.code == AiErrorCode.disabled ||
            e.code == AiErrorCode.unauthorized) {
          rethrow;
        }
      } catch (_) {}
    }
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: capturedAuthEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: true,
      capturedOAuthGen: capturedOAuthGen,
      expectedOAuthAccountKey: expectedOAuthAccountKey,
    );
    _discoveredModels = merged.isNotEmpty
        ? List<AiModelOption>.unmodifiable(merged)
        : List<AiModelOption>.unmodifiable([
            for (final fb in fallbackCodexModels)
              fb.copyWithPriority(fb.priority, isLocalFallback: true),
          ]);
    _discoveredModelsScopeKey = 'codex|$expectedOAuthAccountKey';
    if (!isPrivateSession && _config.authMode == AiAuthMode.codexOAuth) {
      await _reconcileCodexConfiguredModels(_discoveredModels);
    }
    notifyListeners();
    return _discoveredModels;
  }

  Future<void> _reconcileCodexConfiguredModels(
    List<AiModelOption> catalog,
  ) async {
    if (catalog.isEmpty || _config.authMode != AiAuthMode.codexOAuth) {
      return;
    }
    String? findCaseExactMatch(String candidate) {
      final lower = candidate.trim().toLowerCase();
      if (lower.isEmpty) return null;
      for (final opt in catalog) {
        if (opt.id.toLowerCase() == lower) return opt.id;
      }
      return null;
    }

    String resolveNextPrimary(String cur) {
      final trimmed = cur.trim();
      if (trimmed.isNotEmpty) {
        final exact = findCaseExactMatch(trimmed);
        if (exact != null && !isDisallowedCodexModelSlug(exact)) {
          return exact;
        }
        final stripped = sanitizeCodexModelSlug(trimmed);
        final strippedExact = findCaseExactMatch(stripped);
        if (strippedExact != null) return strippedExact;
        if (!isDisallowedCodexModelSlug(trimmed) &&
            !trimmed.toLowerCase().endsWith('-wm')) {
          return trimmed;
        }
      }
      return catalog.first.id;
    }

    String resolveNextFast(String cur) {
      final trimmed = cur.trim();
      if (trimmed.isEmpty) return '';
      if (!isDisallowedCodexModelSlug(trimmed)) {
        final exact = findCaseExactMatch(trimmed);
        if (exact != null) return exact;
        return trimmed;
      }
      final stripped = sanitizeCodexModelSlug(trimmed);
      final strippedExact = findCaseExactMatch(stripped);
      if (strippedExact != null) return strippedExact;
      for (final opt in catalog) {
        final l = opt.id.toLowerCase();
        if (l.contains('mini') || l.contains('spark')) {
          return opt.id;
        }
      }
      return '';
    }

    final nextModel = isDisallowedCodexModelSlug(_config.model) ||
            (_config.model.trim().isNotEmpty &&
                findCaseExactMatch(_config.model) == null &&
                _config.model.trim().toLowerCase().endsWith('-wm'))
        ? resolveNextPrimary(_config.model)
        : _config.model;
    final nextFast = isDisallowedCodexModelSlug(_config.fastModel)
        ? resolveNextFast(_config.fastModel)
        : _config.fastModel;
    if (nextModel != _config.model || nextFast != _config.fastModel) {
      _config = _config.copyWith(model: nextModel, fastModel: nextFast);
      if (!OhosRuntime.isOhos) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(prefsConfigKey, jsonEncode(_config.toJson()));
        } catch (_) {}
      }
    }
  }

  /// Fetches live available models (rich [AiModelOption] entries) for either
  /// ChatGPT Subscription OAuth or the configured API-key provider.
  Future<List<AiModelOption>> fetchAvailableModelOptions({
    AiConfig? configOverride,
    String? apiKeyOverride,
    bool isPrivateSession = false,
  }) async {
    await ensureLoaded();
    final cfg = configOverride ?? _config;
    final requireOAuth = cfg.authMode == AiAuthMode.codexOAuth;
    _ensureOutboundAuthorized(
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: requireOAuth,
    );
    final authEpoch = _outboundAuthEpoch;

    if (requireOAuth) {
      final session = await ensureFreshOAuthSession(
        isPrivateSession: isPrivateSession,
      );
      final oauthGen = _oauthSessionGen;
      final acctKey = oauthAccountKey(session);
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: isPrivateSession,
        requireExperimentalOAuth: true,
        capturedOAuthGen: oauthGen,
        expectedOAuthAccountKey: acctKey,
      );
      final baseModelsUrl =
          _codexModelsEndpointOverride ?? _defaultCodexModelsEndpoint;
      final uri = Uri.parse(baseModelsUrl).replace(
        queryParameters: <String, String>{
          'client_version': codexClientVersion,
        },
      );
      Map<String, String> buildHeaders(AiOAuthSession s) => <String, String>{
            'Accept': 'application/json',
            'Authorization': 'Bearer ${s.accessToken}',
            'Originator': 'codex_cli_rs',
            'User-Agent': 'codex_cli_rs/$codexClientVersion (iOS; arm64)',
            if (s.accountId.isNotEmpty) 'Chatgpt-Account-Id': s.accountId,
          };
      var activeHeaders = buildHeaders(session);
      void verifyCodexCatalogAuth() => _assertOutboundStillAuthorized(
            capturedAuthEpoch: authEpoch,
            isPrivateSession: isPrivateSession,
            requireExperimentalOAuth: true,
            capturedOAuthGen: oauthGen,
            expectedOAuthAccountKey: acctKey,
          );
      var resp = await _getWithTimeout(
        uri,
        headers: activeHeaders,
        timeout: Duration(seconds: cfg.timeoutSeconds),
        verifyAuthorizedBeforeHop: verifyCodexCatalogAuth,
        allowSameOriginRedirects: true,
      );
      verifyCodexCatalogAuth();
      var raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode == 401 && session.refreshToken.isNotEmpty) {
        final refreshed = await ensureFreshOAuthSession(
          forceRefresh: true,
          isPrivateSession: isPrivateSession,
        );
        verifyCodexCatalogAuth();
        activeHeaders = buildHeaders(refreshed);
        resp = await _getWithTimeout(
          uri,
          headers: activeHeaders,
          timeout: Duration(seconds: cfg.timeoutSeconds),
          verifyAuthorizedBeforeHop: verifyCodexCatalogAuth,
          allowSameOriginRedirects: true,
        );
        verifyCodexCatalogAuth();
        raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _buildHttpError(resp.statusCode, raw);
      }
      return _finalizeCodexModelOptions(
        raw,
        headers: activeHeaders,
        capturedAuthEpoch: authEpoch,
        capturedOAuthGen: oauthGen,
        expectedOAuthAccountKey: acctKey,
        isPrivateSession: isPrivateSession,
      );
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
    final capturedByoEndpointGen = _byoEndpointGen;
    void verifyByoCatalogStillCurrent() {
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: isPrivateSession,
        requireExperimentalOAuth: false,
      );
      if (_byoEndpointGen != capturedByoEndpointGen) {
        throw const AiServiceException(
          AiErrorCode.unconfigured,
          'AI 配置已变更，已放弃旧的模型列表请求',
        );
      }
    }

    final resp = await _getWithTimeout(
      uri,
      headers: headers,
      timeout: Duration(seconds: cfg.timeoutSeconds),
      verifyAuthorizedBeforeHop: verifyByoCatalogStillCurrent,
      allowSameOriginRedirects: true,
    );
    verifyByoCatalogStillCurrent();
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
    verifyByoCatalogStillCurrent();
    _discoveredModels = models;
    _discoveredModelsScopeKey = _computeModelCatalogScopeKey(
      config: cfg,
      authMode: cfg.authMode,
      apiKey: key,
    );
    notifyListeners();
    return models;
  }

  static final RegExp _datedSnapshotSuffixRe =
      RegExp(r'-\d{4}-\d{2}-\d{2}$');
  static final RegExp _codexWmSuffixRe = RegExp(r'-wm$', caseSensitive: false);

  /// Returns true when [id] is a web-only (`-wm`), internal/auto-review, or
  /// non-chat utility slug that must not be selected for Codex subscription calls.
  static bool isDisallowedCodexModelSlug(String id) {
    final s = id.trim().toLowerCase();
    if (s.isEmpty) return false;
    return s == 'codex-auto-review' ||
        s == 'auto-review' ||
        s.endsWith('-wm') ||
        s.contains('-wm-') ||
        s.contains('auto-review') ||
        s.startsWith('text-embedding') ||
        s.startsWith('omni-moderation') ||
        s.startsWith('tts-') ||
        s.startsWith('whisper-') ||
        s.startsWith('dall-e') ||
        s.startsWith('gpt-image-') ||
        s.startsWith('chatgpt-image-') ||
        s.startsWith('sora-');
  }

  /// Strips web-only `-wm` suffixes or clears internal slugs for Codex config.
  static String sanitizeCodexModelSlug(String id) {
    var s = id.trim();
    if (s.isEmpty) return '';
    if (_codexWmSuffixRe.hasMatch(s)) {
      s = s.replaceFirst(_codexWmSuffixRe, '').trim();
    }
    if (isDisallowedCodexModelSlug(s)) return '';
    return s;
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
        if (id.isEmpty) continue;
        if (isCodex && isDisallowedCodexModelSlug(id)) continue;
        if (seen.add(id.toLowerCase())) {
          out.add(AiModelOption(id: id, priority: 100 + i));
        }
        continue;
      }
      if (entry is! Map) continue;
      if (isCodex) {
        if (entry['is_deprecated'] == true || entry['deprecated'] == true) {
          continue;
        }
        final vis = (entry['visibility'] ?? '').toString().trim().toLowerCase();
        if (vis == 'internal' || vis == 'hide' || vis == 'hidden') {
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
      if (isCodex && isDisallowedCodexModelSlug(rawId)) {
        continue;
      }
      // Filter non-text embedding / moderation / audio / image / legacy utility models on OpenAI.
      if (!isCodex &&
          protocol == AiApiProtocol.openaiCompatible &&
          (lowerId.startsWith('text-embedding') ||
              lowerId.startsWith('omni-moderation') ||
              lowerId.startsWith('tts-') ||
              lowerId.startsWith('whisper-') ||
              lowerId.startsWith('dall-e') ||
              lowerId.startsWith('gpt-image-') ||
              lowerId.startsWith('chatgpt-image-') ||
              lowerId.startsWith('sora-') ||
              lowerId.startsWith('babbage-') ||
              lowerId.startsWith('davinci-') ||
              lowerId.startsWith('curie-') ||
              lowerId.startsWith('ada-') ||
              lowerId.startsWith('ft:') ||
              lowerId.contains('realtime') ||
              lowerId.contains('transcribe'))) {
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
      final defaultReasoning =
          (entry['default_reasoning_level'] ?? '').toString().trim().toLowerCase();
      List<String>? supportedReasoning;
      if (entry['supported_reasoning_levels'] is List) {
        final levels = <String>[];
        for (final lvl in entry['supported_reasoning_levels'] as List) {
          String eff = '';
          if (lvl is Map) {
            eff = (lvl['effort'] ?? lvl['id'] ?? lvl['name'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
          } else {
            eff = lvl.toString().trim().toLowerCase();
          }
          if (eff.isNotEmpty && !levels.contains(eff)) {
            levels.add(eff);
          }
        }
        supportedReasoning = List<String>.unmodifiable(levels);
      }
      out.add(
        AiModelOption(
          id: rawId,
          displayName: disp.isNotEmpty ? disp : rawId,
          description: desc,
          priority: prio,
          defaultReasoningEffort: defaultReasoning,
          supportedReasoningEfforts: supportedReasoning,
        ),
      );
    }

    out.sort((a, b) {
      final aHasExplicit = a.priority < 100;
      final bHasExplicit = b.priority < 100;
      if (aHasExplicit != bHasExplicit) {
        return aHasExplicit ? -1 : 1;
      }
      final cmp = a.priority.compareTo(b.priority);
      if (cmp != 0) return cmp;
      final aDated = _datedSnapshotSuffixRe.hasMatch(a.id.toLowerCase());
      final bDated = _datedSnapshotSuffixRe.hasMatch(b.id.toLowerCase());
      if (aDated != bDated) return aDated ? 1 : -1;
      return a.id.compareTo(b.id);
    });
    return List<AiModelOption>.unmodifiable(out);
  }

  /// Resolves user-typed display names (e.g. `GPT 6.1 Terra` -> `gpt-6.1-terra`
  /// when present in the scoped discovered catalog for the SAME service and
  /// credentials, or slugified on Codex OAuth) so human model labels don't
  /// unnecessarily trigger `invalid model ID` while never leaking another
  /// service's cached model IDs onto a different endpoint or credential set.
  String resolveCanonicalModelId(
    String rawModel, {
    required bool isCodex,
    String? catalogScopeKey,
  }) {
    final trimmed = rawModel.trim();
    if (trimmed.isEmpty) return '';
    final effective = isCodex ? sanitizeCodexModelSlug(trimmed) : trimmed;
    final lower = (effective.isNotEmpty ? effective : trimmed).toLowerCase();
    final expectedScope = catalogScopeKey ?? _currentActiveModelCatalogScopeKey;
    final hasMatchingCatalog = _discoveredModels.isNotEmpty &&
        _discoveredModelsScopeKey.isNotEmpty &&
        _discoveredModelsScopeKey == expectedScope;
    final candidates = <AiModelOption>[
      if (hasMatchingCatalog) ..._discoveredModels,
      if (isCodex) ...fallbackCodexModels,
    ];
    for (final m in candidates) {
      if (m.id.toLowerCase() == lower ||
          m.displayName.trim().toLowerCase() == lower) {
        return m.id;
      }
    }
    if (isCodex) {
      if (effective.isEmpty && candidates.isNotEmpty) {
        return candidates.first.id;
      }
      if (effective.contains(' ')) {
        return effective.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
      }
      return effective;
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
    String feature = '',
    String model = '',
    String authModeId = 'api_key',
    int latencyMs = 0,
    bool fromCache = false,
  }) async {
    final safeIn = promptTokens < 0 ? 0 : promptTokens;
    final safeOut = completionTokens < 0 ? 0 : completionTokens;
    final nowMs = _clock().millisecondsSinceEpoch;
    if (!fromCache) {
      final month = currentMonthKey;
      final prev = monthlyUsage;
      final updated = AiMonthlyUsage(
        monthKey: month,
        promptTokens: prev.promptTokens + safeIn,
        completionTokens: prev.completionTokens + safeOut,
        requestCount: prev.requestCount + 1,
      );
      _usage = updated;
      _rollingUsageEvents.add((
        ts: nowMs,
        inTok: safeIn,
        outTok: safeOut,
        auth: authModeId,
      ));
      final sevenDayCutoffMs =
          _clock().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
      _rollingUsageEvents.removeWhere((e) => e.ts < sevenDayCutoffMs);
    }
    _usageHistory.insert(
      0,
      AiUsageLogEntry(
        timestampMs: nowMs,
        feature: feature,
        model: model,
        authModeId: authModeId,
        promptTokens: safeIn,
        completionTokens: safeOut,
        latencyMs: latencyMs,
        fromCache: fromCache,
      ),
    );
    if (_usageHistory.length > maxUsageHistoryEntries) {
      _usageHistory.removeRange(maxUsageHistoryEntries, _usageHistory.length);
    }
    if (!OhosRuntime.isOhos) {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (_usage != null) {
          await prefs.setString(prefsUsageKey, jsonEncode(_usage!.toJson()));
        }
        await prefs.setString(
          prefsUsageHistoryKey,
          jsonEncode([for (final e in _usageHistory) e.toJson()]),
        );
        await prefs.setString(
          prefsRollingUsageKey,
          jsonEncode([
            for (final e in _rollingUsageEvents)
              <Object>[e.ts, e.inTok, e.outTok, e.auth],
          ]),
        );
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Clears stored usage call logs (optionally resetting current month & rolling counters).
  Future<void> clearUsageHistory({bool resetMonthlyCounters = false}) async {
    await ensureLoaded();
    _usageHistory = <AiUsageLogEntry>[];
    if (resetMonthlyCounters) {
      _usage = AiMonthlyUsage(monthKey: currentMonthKey);
      _rollingUsageEvents = <({int ts, int inTok, int outTok, String auth})>[];
    }
    if (!OhosRuntime.isOhos) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(prefsUsageHistoryKey);
        if (resetMonthlyCounters) {
          await prefs.remove(prefsRollingUsageKey);
          if (_usage != null) {
            await prefs.setString(prefsUsageKey, jsonEncode(_usage!.toJson()));
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _updateSubscriptionQuotaSnapshot(
    AiSubscriptionQuotaSnapshot next,
  ) async {
    _subscriptionQuota = next;
    if (!OhosRuntime.isOhos) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsSubQuotaKey, jsonEncode(next.toJson()));
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Extracts 5-hour (`primary`) and 7-day (`secondary`) subscription quota
  /// windows from `chatgpt.com/backend-api/codex/responses` HTTP headers.
  void _captureCodexRateLimitHeaders(
    Map<String, String> rawHeaders, {
    String fallbackPlanType = '',
    String accountKey = '',
  }) {
    if (rawHeaders.isEmpty) return;
    final activeKey = accountKey.isNotEmpty
        ? accountKey
        : oauthAccountKey(_oauthSession);
    if (activeKey.isEmpty || activeKey != oauthAccountKey(_oauthSession)) {
      return;
    }
    final lower = <String, String>{
      for (final e in rawHeaders.entries) e.key.toLowerCase(): e.value.trim(),
    };
    final pPct = double.tryParse(lower['x-codex-primary-used-percent'] ?? '');
    final sPct = double.tryParse(lower['x-codex-secondary-used-percent'] ?? '');
    if (pPct == null && sPct == null) return;
    final nowSec = _clock().millisecondsSinceEpoch ~/ 1000;
    int parseReset(String prefix) {
      final at = int.tryParse(lower['$prefix-reset-at'] ?? '');
      if (at != null && at > 0) return at;
      final after = int.tryParse(lower['$prefix-reset-after-seconds'] ?? '');
      if (after != null && after > 0) return nowSec + after;
      return 0;
    }

    final pMins = int.tryParse(lower['x-codex-primary-window-minutes'] ?? '');
    final sMins = int.tryParse(lower['x-codex-secondary-window-minutes'] ?? '');
    final prev = subscriptionQuota;
    final snap = AiSubscriptionQuotaSnapshot(
      accountKey: activeKey,
      planType: (lower['x-codex-plan-type'] ?? '').isNotEmpty
          ? lower['x-codex-plan-type']!
          : (fallbackPlanType.isNotEmpty
                ? fallbackPlanType
                : (prev?.planType ?? '')),
      fiveHourWindow: AiSubscriptionQuotaWindow(
        windowSeconds: (pMins != null && pMins > 0) ? pMins * 60 : 18000,
        usedPercent: pPct?.clamp(0.0, 100.0) ?? prev?.fiveHourWindow.usedPercent,
        resetAtEpochSec: parseReset('x-codex-primary') > 0
            ? parseReset('x-codex-primary')
            : (prev?.fiveHourWindow.resetAtEpochSec ?? 0),
      ),
      weeklyWindow: AiSubscriptionQuotaWindow(
        windowSeconds: (sMins != null && sMins > 0) ? sMins * 60 : 604800,
        usedPercent: sPct?.clamp(0.0, 100.0) ?? prev?.weeklyWindow.usedPercent,
        resetAtEpochSec: parseReset('x-codex-secondary') > 0
            ? parseReset('x-codex-secondary')
            : (prev?.weeklyWindow.resetAtEpochSec ?? 0),
      ),
      updatedAtEpochMs: _clock().millisecondsSinceEpoch,
    );
    unawaited(_updateSubscriptionQuotaSnapshot(snap));
  }

  /// Queries `https://chatgpt.com/backend-api/wham/usage` to fetch live 5-hour
  /// and 7-day weekly subscription quota windows for the signed-in OAuth account.
  /// Strictly enforces privacy space, live passcode validity, `exp_oauth`,
  /// account isolation, single-flight coalescing, and late-response discard.
  Future<AiSubscriptionQuotaSnapshot?> refreshSubscriptionQuota({
    bool isPrivateSession = false,
  }) async {
    await ensureLoaded();
    if (isPrivateSession || _privacySessionActive || OhosRuntime.isOhos) {
      return null;
    }
    if (_shouldEnforcePasscodeGate &&
        (!isLabUnlocked || !isExperimentalOAuthAllowed)) {
      return null;
    }
    final current = _oauthSession;
    if (current == null || !current.isValid) return null;
    final acctKey = oauthAccountKey(current);
    if (acctKey.isEmpty) return null;

    if (_inFlightSubQuota != null && _inFlightSubQuotaKey == acctKey) {
      return _inFlightSubQuota!;
    }
    final epoch = _quotaEpoch;
    final authEpoch = _outboundAuthEpoch;
    final oauthGen = _oauthSessionGen;
    bool quotaStillAuthorized() =>
        epoch == _quotaEpoch &&
        authEpoch == _outboundAuthEpoch &&
        oauthGen == _oauthSessionGen &&
        !_privacySessionActive &&
        oauthAccountKey(_oauthSession) == acctKey &&
        (!_shouldEnforcePasscodeGate ||
            (isLabUnlocked && isExperimentalOAuthAllowed));
    final fut = () async {
      try {
        final session = await ensureFreshOAuthSession(
          isPrivateSession: isPrivateSession,
        );
        if (!quotaStillAuthorized()) {
          return null;
        }
        final uri = Uri.parse(
          _codexUsageEndpointOverride ?? _defaultCodexUsageEndpoint,
        );
        final resp = await _getWithTimeout(
          uri,
          headers: <String, String>{
            'Accept': 'application/json',
            'Authorization': 'Bearer ${session.accessToken}',
            'Originator': 'codex_cli_rs',
            'User-Agent': 'codex_cli_rs/$codexClientVersion (iOS; arm64)',
            if (session.accountId.isNotEmpty)
              'Chatgpt-Account-Id': session.accountId,
          },
          timeout: const Duration(seconds: 12),
          verifyAuthorizedBeforeHop: () {
            if (!quotaStillAuthorized()) {
              throw const AiServiceException(
                AiErrorCode.privacySpaceBlocked,
                '当前授权状态已变更，已中止额度查询',
              );
            }
          },
          allowSameOriginRedirects: true,
        );
        if (!quotaStillAuthorized()) {
          return null;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          return subscriptionQuota;
        }
        final decoded = jsonDecode(
          utf8.decode(resp.bodyBytes, allowMalformed: true),
        );
        if (decoded is! Map) return subscriptionQuota;
        final plan =
            (decoded['plan_type'] ?? session.planType).toString().trim();
        final rl = decoded['rate_limit'];
        AiSubscriptionQuotaWindow parseWin(
          Object? rawWin,
          int defaultWindowSec,
        ) {
          if (rawWin is! Map) {
            return AiSubscriptionQuotaWindow(windowSeconds: defaultWindowSec);
          }
          final pct = (rawWin['used_percent'] as num?)?.toDouble();
          final winSec =
              (rawWin['limit_window_seconds'] as num?)?.toInt() ??
                  defaultWindowSec;
          final nowSec = _clock().millisecondsSinceEpoch ~/ 1000;
          final resetAt = (rawWin['reset_at'] as num?)?.toInt() ??
              ((rawWin['reset_after_seconds'] as num?) != null
                  ? nowSec + (rawWin['reset_after_seconds'] as num).toInt()
                  : 0);
          return AiSubscriptionQuotaWindow(
            windowSeconds: winSec,
            usedPercent: pct?.clamp(0.0, 100.0),
            resetAtEpochSec: resetAt,
          );
        }

        final primaryRaw = rl is Map ? rl['primary_window'] : null;
        final secondaryRaw = rl is Map ? rl['secondary_window'] : null;
        final snap = AiSubscriptionQuotaSnapshot(
          accountKey: acctKey,
          planType: plan,
          fiveHourWindow: parseWin(primaryRaw, 18000),
          weeklyWindow: parseWin(secondaryRaw, 604800),
          updatedAtEpochMs: _clock().millisecondsSinceEpoch,
        );
        await _updateSubscriptionQuotaSnapshot(snap);
        return snap;
      } catch (_) {
        return quotaStillAuthorized() ? subscriptionQuota : null;
      }
    }();
    _inFlightSubQuota = fut;
    _inFlightSubQuotaKey = acctKey;
    try {
      return await fut;
    } finally {
      if (identical(_inFlightSubQuota, fut)) {
        _inFlightSubQuota = null;
        _inFlightSubQuotaKey = '';
      }
    }
  }

  /// Canonical cache key (`scheme://authority/CaseSensitivePath`) scoping cached
  /// API balance snapshots strictly to the active Base URL while preserving
  /// case-sensitive tenant paths (e.g. `/TenantA/v1` vs `/tenanta/v1`).
  static String normalizeApiBalanceEndpointKey(String rawBaseUrl) {
    var trimmed = rawBaseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) return '';
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
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.trim().isEmpty ||
        parsed.userInfo.isNotEmpty ||
        (parsed.scheme != 'https' && parsed.scheme != 'http')) {
      return '';
    }
    var path = parsed.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '${parsed.scheme.toLowerCase()}://${parsed.authority.toLowerCase()}$path';
  }

  static double? _parseBalanceNum(Object? raw) {
    if (raw is num) {
      final v = raw.toDouble();
      return v.isFinite ? v : null;
    }
    if (raw is String) {
      final clean = raw.trim().replaceAll(',', '');
      if (clean.isEmpty) return null;
      final v = double.tryParse(clean);
      return (v != null && v.isFinite) ? v : null;
    }
    return null;
  }

  static double? _parseNonNegativeBalanceNum(Object? raw) {
    final v = _parseBalanceNum(raw);
    if (v == null || v < 0) return null;
    return v;
  }

  static int _parseRetryAfterSeconds(String? rawHeader, DateTime now) {
    final raw = (rawHeader ?? '').trim();
    if (raw.isEmpty) return 60;
    final secs = int.tryParse(raw);
    if (secs != null) {
      return secs.clamp(5, 600);
    }
    try {
      final dt = HttpDate.parse(raw);
      final diff = dt.difference(now).inSeconds;
      return diff.clamp(5, 600);
    } catch (_) {
      return 60;
    }
  }

  static bool _isExplicitUnlimitedPayload(Map<String, dynamic> map) {
    if (map['unlimited_quota'] == true ||
        map['is_unlimited'] == true ||
        map['unlimited'] == true) {
      return true;
    }
    final rawStatus = (map['quota_type'] ?? map['plan_quota'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return rawStatus == 'unlimited' || rawStatus == 'infinite';
  }

  static String _normalizeBillingUnit(Object? raw) {
    final s = (raw ?? '').toString().trim().toUpperCase();
    if (s.isEmpty) return '';
    return switch (s) {
      'RMB' || '￥' || '¥' || 'CNY' => 'CNY',
      r'$' || 'USD' || r'US$' => 'USD',
      'EUR' || '€' => 'EUR',
      'GBP' || '£' => 'GBP',
      'TOKEN' || 'TOKENS' => 'TOKENS',
      'CREDIT' || 'CREDITS' => 'CREDITS',
      'POINT' || 'POINTS' => 'POINTS',
      _ => s,
    };
  }

  static String _officialHostCurrencyEvidence(String endpointKey) {
    final host = Uri.tryParse(endpointKey)?.host.toLowerCase() ?? '';
    return switch (host) {
      'api.openai.com' || 'openrouter.ai' => 'USD',
      'api.deepseek.com' ||
      'api.siliconflow.cn' ||
      'api.moonshot.cn' ||
      'dashscope.aliyuncs.com' ||
      'open.bigmodel.cn' =>
        'CNY',
      _ => '',
    };
  }

  static String _resolveBillingCurrency(
    Map<String, dynamic> primary,
    Map<String, dynamic>? outer, {
    required String endpointKey,
    bool hasTokenField = false,
  }) {
    final explicit = _normalizeBillingUnit(
      primary['currency'] ??
          primary['unit'] ??
          primary['quota_unit'] ??
          outer?['currency'] ??
          outer?['unit'] ??
          outer?['quota_unit'],
    );
    if (explicit.isNotEmpty) return explicit;
    if (hasTokenField) return 'TOKENS';
    return _officialHostCurrencyEvidence(endpointKey);
  }

  /// Parses balance / credit payloads returned by common OpenAI-compatible
  /// relays & official providers (Credit Grants, Billing Subscription,
  /// OpenRouter Credits/Key, DeepSeek User Balance, Moonshot, SiliconFlow).
  /// Never guesses USD or unlimited without explicit payload or official-host
  /// evidence; returns empty `currency` so UI explicitly marks unknown units.
  @visibleForTesting
  static AiApiBalanceSnapshot? parseApiBalancePayload(
    Object? decoded, {
    required String endpointKey,
    String accountKey = '',
    required String sourceKind,
    required int nowMs,
  }) {
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    final dataObj = map['data'];
    final dataMap = dataObj is Map ? Map<String, dynamic>.from(dataObj) : null;

    switch (sourceKind) {
      case 'credit_grants':
        final unlimited = _isExplicitUnlimitedPayload(map);
        final granted = _parseNonNegativeBalanceNum(map['total_granted']) ??
            _parseNonNegativeBalanceNum(map['total_tokens']);
        final used = _parseNonNegativeBalanceNum(map['total_used']) ??
            _parseNonNegativeBalanceNum(map['used_tokens']);
        final avail = _parseBalanceNum(map['total_available']) ??
            _parseBalanceNum(map['remaining_tokens']);
        final hasTokenField = map.containsKey('total_tokens') ||
            map.containsKey('used_tokens') ||
            map.containsKey('remaining_tokens');
        if (!unlimited && granted == null && used == null && avail == null) {
          return null;
        }
        final resolvedCurrency = _resolveBillingCurrency(
          map,
          null,
          endpointKey: endpointKey,
          hasTokenField: hasTokenField,
        );
        return AiApiBalanceSnapshot(
          endpointKey: endpointKey,
          accountKey: accountKey,
          supported: true,
          isUnlimited: unlimited,
          currency: resolvedCurrency,
          remaining: unlimited ? null : avail,
          totalGranted: unlimited ? null : granted,
          totalUsed: used,
          sourceLabel: 'Credit Grants',
          updatedAtEpochMs: nowMs,
        );

      case 'billing_subscription':
        final unlimited = _isExplicitUnlimitedPayload(map);
        final hardLimit = _parseNonNegativeBalanceNum(map['hard_limit_usd']) ??
            _parseNonNegativeBalanceNum(map['system_hard_limit_usd']) ??
            _parseNonNegativeBalanceNum(map['soft_limit_usd']) ??
            _parseNonNegativeBalanceNum(map['hard_limit']) ??
            _parseNonNegativeBalanceNum(map['total_tokens']);
        final hasTokenField = map.containsKey('total_tokens') &&
            !map.containsKey('hard_limit_usd');
        if (!unlimited && hardLimit == null) return null;
        // Do NOT treat OpenAI-compatibility field names (`billing_subscription`,
        // `has_payment_method`, `hard_limit_usd`) as proof of USD on generic
        // relays (e.g. New API / One API may report RMB or relay units in those
        // fields). Require explicit payload unit or official-host evidence.
        final resolvedCurrency = _resolveBillingCurrency(
          map,
          null,
          endpointKey: endpointKey,
          hasTokenField: hasTokenField,
        );
        // Never fabricate remaining = hardLimit before `/billing/usage` succeeds
        // and never assume large finite quotas are unlimited!
        return AiApiBalanceSnapshot(
          endpointKey: endpointKey,
          accountKey: accountKey,
          supported: true,
          isUnlimited: unlimited,
          currency: resolvedCurrency,
          remaining: null,
          totalGranted: unlimited ? null : hardLimit,
          totalUsed: null,
          sourceLabel: 'Billing Subscription',
          updatedAtEpochMs: nowMs,
        );

      case 'credits':
        final target = dataMap ?? map;
        final unlimited = _isExplicitUnlimitedPayload(target) ||
            _isExplicitUnlimitedPayload(map);
        final totalCredits = _parseNonNegativeBalanceNum(target['total_credits']) ??
            _parseNonNegativeBalanceNum(target['limit']) ??
            _parseNonNegativeBalanceNum(target['total_tokens']);
        final totalUsage = _parseNonNegativeBalanceNum(target['total_usage']) ??
            _parseNonNegativeBalanceNum(target['usage']) ??
            _parseNonNegativeBalanceNum(target['used_tokens']);
        final limitRem = _parseBalanceNum(target['limit_remaining']) ??
            _parseBalanceNum(target['remaining']) ??
            _parseBalanceNum(target['remaining_tokens']);
        final hasTokenField = target.containsKey('total_tokens') ||
            target.containsKey('remaining_tokens') ||
            target.containsKey('used_tokens');
        if (!unlimited &&
            totalCredits == null &&
            totalUsage == null &&
            limitRem == null) {
          return null;
        }
        final rem = unlimited
            ? null
            : (limitRem ??
                ((totalCredits != null && totalUsage != null)
                    ? (totalCredits - totalUsage).clamp(0.0, double.infinity)
                    : null));
        return AiApiBalanceSnapshot(
          endpointKey: endpointKey,
          accountKey: accountKey,
          supported: true,
          isUnlimited: unlimited,
          currency: _resolveBillingCurrency(
            target,
            map,
            endpointKey: endpointKey,
            hasTokenField: hasTokenField,
          ),
          remaining: rem,
          totalGranted: unlimited ? null : totalCredits,
          totalUsed: totalUsage,
          sourceLabel: 'Credits API',
          updatedAtEpochMs: nowMs,
        );

      case 'user_balance':
        final infos = map['balance_infos'];
        if (infos is List && infos.isNotEmpty) {
          for (final item in infos) {
            if (item is! Map) continue;
            final itemMap = Map<String, dynamic>.from(item);
            final totalBal = _parseBalanceNum(itemMap['total_balance']) ??
                _parseBalanceNum(itemMap['available_balance']);
            if (totalBal == null) continue;
            return AiApiBalanceSnapshot(
              endpointKey: endpointKey,
              accountKey: accountKey,
              supported: true,
              currency: _resolveBillingCurrency(
                itemMap,
                map,
                endpointKey: endpointKey,
              ),
              remaining: totalBal,
              sourceLabel: 'User Balance',
              updatedAtEpochMs: nowMs,
            );
          }
        }
        final topTarget = dataMap ?? map;
        final unlimited = _isExplicitUnlimitedPayload(topTarget) ||
            _isExplicitUnlimitedPayload(map);
        final topAvail = _parseBalanceNum(topTarget['available_balance']) ??
            _parseBalanceNum(topTarget['total_balance']) ??
            _parseBalanceNum(topTarget['balance']) ??
            _parseBalanceNum(topTarget['remaining_tokens']);
        final hasTokenField = topTarget.containsKey('remaining_tokens');
        if (!unlimited && topAvail == null) return null;
        return AiApiBalanceSnapshot(
          endpointKey: endpointKey,
          accountKey: accountKey,
          supported: true,
          isUnlimited: unlimited,
          currency: _resolveBillingCurrency(
            topTarget,
            map,
            endpointKey: endpointKey,
            hasTokenField: hasTokenField,
          ),
          remaining: unlimited ? null : topAvail,
          sourceLabel: 'User Balance',
          updatedAtEpochMs: nowMs,
        );

      case 'users_me_balance':
      case 'user_info':
        final target = dataMap ?? map;
        final unlimited = _isExplicitUnlimitedPayload(target) ||
            _isExplicitUnlimitedPayload(map);
        final avail = _parseBalanceNum(target['available_balance']) ??
            _parseBalanceNum(target['totalBalance']) ??
            _parseBalanceNum(target['total_balance']) ??
            _parseBalanceNum(target['balance']) ??
            _parseBalanceNum(target['chargeBalance']) ??
            _parseBalanceNum(target['remaining_tokens']);
        final hasTokenField = target.containsKey('remaining_tokens');
        if (!unlimited && avail == null) return null;
        return AiApiBalanceSnapshot(
          endpointKey: endpointKey,
          accountKey: accountKey,
          supported: true,
          isUnlimited: unlimited,
          currency: _resolveBillingCurrency(
            target,
            map,
            endpointKey: endpointKey,
            hasTokenField: hasTokenField,
          ),
          remaining: unlimited ? null : avail,
          sourceLabel: sourceKind == 'users_me_balance'
              ? 'Account Balance'
              : 'Account Info',
          updatedAtEpochMs: nowMs,
        );
    }
    return null;
  }

  Future<({http.Response? response, bool redirected, bool networkFailed})>
      _getSameOriginNoRedirect(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final client = _injectedHttpClient ?? http.Client();
    final ownsClient = _injectedHttpClient == null;
    try {
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      final streamed = await client.send(req).timeout(timeout);
      final resp = await http.Response.fromStream(streamed).timeout(timeout);
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        return (response: null, redirected: true, networkFailed: false);
      }
      return (response: resp, redirected: false, networkFailed: false);
    } catch (_) {
      return (response: null, redirected: false, networkFailed: true);
    } finally {
      if (ownsClient) {
        client.close();
      }
    }
  }

  Future<void> _updateApiBalanceSnapshot(AiApiBalanceSnapshot next) async {
    _apiBalance = next;
    if (!OhosRuntime.isOhos) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsApiBalanceKey, jsonEncode(next.toJson()));
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Best-effort same-origin balance query for BYO-API mode (`AiAuthMode.apiKey`).
  /// Enforces privacy space, passcode gate, account/key/case-sensitive path
  /// isolation, single-flight coalescing, 429 Retry-After backoff, and
  /// late-response discard.
  Future<AiApiBalanceSnapshot?> refreshApiBalance({
    AiConfig? configOverride,
    String? apiKeyOverride,
    bool force = false,
    bool isPrivateSession = false,
  }) async {
    if (isPrivateSession || _privacySessionActive || OhosRuntime.isOhos) {
      return null;
    }
    await ensureLoaded();
    if (_shouldEnforcePasscodeGate && !isLabUnlocked) {
      return null;
    }
    final cfg = configOverride ?? _config;
    if (cfg.authMode != AiAuthMode.apiKey) return null;
    final epKey = normalizeApiBalanceEndpointKey(cfg.baseUrl);
    final effectiveKey = (apiKeyOverride ?? _apiKey).trim();
    if (epKey.isEmpty || effectiveKey.isEmpty) return null;
    final acctKey = computeApiBalanceAccountKey(cfg.baseUrl, effectiveKey);

    final now = _clock();
    final nowMs = now.millisecondsSinceEpoch;
    final backoffUntil = _balanceBackoffUntilMs[acctKey];
    if (backoffUntil != null && nowMs < backoffUntil) {
      return apiBalance;
    }

    final existingInFlight = _inFlightApiBalance[acctKey];
    if (existingInFlight != null) {
      return existingInFlight;
    }

    final cached = _apiBalance;
    if (!force &&
        cached != null &&
        cached.endpointKey == epKey &&
        cached.accountKey == acctKey &&
        (nowMs - cached.updatedAtEpochMs).abs() < 60000) {
      return cached;
    }

    final epoch = _balanceEpoch;
    final authEpoch = _outboundAuthEpoch;
    bool isStale() =>
        epoch != _balanceEpoch ||
        authEpoch != _outboundAuthEpoch ||
        _privacySessionActive ||
        (_shouldEnforcePasscodeGate && !isLabUnlocked);

    final fut = () async {
      if (cfg.protocol != AiApiProtocol.openaiCompatible) {
        final unsupported = AiApiBalanceSnapshot(
          endpointKey: epKey,
          accountKey: acctKey,
          supported: false,
          sourceLabel: cfg.protocol.labelZh,
          updatedAtEpochMs: nowMs,
        );
        if (!isStale()) await _updateApiBalanceSnapshot(unsupported);
        return isStale() ? null : unsupported;
      }

      var apiRoot = cfg.baseUrl.trim();
      while (apiRoot.endsWith('/')) {
        apiRoot = apiRoot.substring(0, apiRoot.length - 1);
      }
      final lowerRoot = apiRoot.toLowerCase();
      for (final suffix in const <String>[
        '/chat/completions',
        '/responses',
        '/messages',
      ]) {
        if (lowerRoot.endsWith(suffix)) {
          apiRoot = apiRoot.substring(0, apiRoot.length - suffix.length);
          break;
        }
      }
      final parsedRoot = Uri.tryParse(apiRoot);
      if (parsedRoot == null || !parsedRoot.hasAuthority) return null;
      final hasVersionPath = RegExp(r'/v\d+(?:beta)?$', caseSensitive: false)
          .hasMatch(parsedRoot.path);
      final versionedRoot = hasVersionPath ? apiRoot : '$apiRoot/v1';
      final noV1Root = hasVersionPath
          ? apiRoot.replaceFirst(
              RegExp(r'/v\d+(?:beta)?$', caseSensitive: false),
              '',
            )
          : apiRoot;

      final headers = <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $effectiveKey',
      };
      const probeTimeout = Duration(seconds: 4);

      final seenUris = <String>{};
      final probes = <({String kind, Uri uri})>[];
      void addProbe(String kind, String rawUrl) {
        final u = Uri.tryParse(rawUrl);
        if (u == null ||
            u.host.toLowerCase() != parsedRoot.host.toLowerCase() ||
            u.scheme.toLowerCase() != parsedRoot.scheme.toLowerCase()) {
          return;
        }
        if (seenUris.add(u.toString())) {
          probes.add((kind: kind, uri: u));
        }
      }

      addProbe('credit_grants', '$versionedRoot/dashboard/billing/credit_grants');
      addProbe(
        'billing_subscription',
        '$versionedRoot/dashboard/billing/subscription',
      );
      addProbe('credits', '$apiRoot/credits');
      addProbe('user_balance', '$noV1Root/user/balance');
      addProbe('users_me_balance', '$versionedRoot/users/me/balance');
      addProbe('user_info', '$versionedRoot/user/info');

      for (final probe in probes) {
        if (isStale()) return null;
        final res = await _getSameOriginNoRedirect(
          probe.uri,
          headers: headers,
          timeout: probeTimeout,
        );
        if (isStale()) return null;
        if (res.redirected) continue;
        if (res.networkFailed || res.response == null) {
          // Host unreachable / timed out: stop hammering remaining probes.
          return apiBalance;
        }
        final resp = res.response!;
        if (resp.statusCode == 429) {
          final retrySec = _parseRetryAfterSeconds(
            resp.headers['retry-after'],
            _clock(),
          );
          _balanceBackoffUntilMs[acctKey] =
              _clock().millisecondsSinceEpoch + retrySec * 1000;
          return apiBalance;
        }
        if (resp.statusCode == 401) {
          // Invalid API key: stop probing immediately.
          return apiBalance;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          continue;
        }
        Object? decoded;
        try {
          decoded =
              jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
        } catch (_) {
          continue;
        }
        final rawParsed = parseApiBalancePayload(
          decoded,
          endpointKey: epKey,
          accountKey: acctKey,
          sourceKind: probe.kind,
          nowMs: nowMs,
        );
        if (rawParsed == null) continue;
        var parsed = rawParsed;

        if (probe.kind == 'billing_subscription' &&
            !parsed.isUnlimited &&
            parsed.totalGranted != null) {
          final startDate =
              '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-01';
          final tomorrow = now.add(const Duration(days: 1));
          final endDate =
              '${tomorrow.year.toString().padLeft(4, '0')}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
          final usageUri = Uri.tryParse(
            '$versionedRoot/dashboard/billing/usage?start_date=$startDate&end_date=$endDate',
          );
          if (usageUri != null &&
              usageUri.host.toLowerCase() == parsedRoot.host.toLowerCase()) {
            if (isStale()) return null;
            final usageRes = await _getSameOriginNoRedirect(
              usageUri,
              headers: headers,
              timeout: probeTimeout,
            );
            if (isStale()) return null;
            final usageResp = usageRes.response;
            if (usageResp != null && usageResp.statusCode == 429) {
              final retrySec = _parseRetryAfterSeconds(
                usageResp.headers['retry-after'],
                _clock(),
              );
              _balanceBackoffUntilMs[acctKey] =
                  _clock().millisecondsSinceEpoch + retrySec * 1000;
            } else if (usageResp != null &&
                usageResp.statusCode >= 200 &&
                usageResp.statusCode < 300) {
              try {
                final usageDecoded = jsonDecode(
                  utf8.decode(usageResp.bodyBytes, allowMalformed: true),
                );
                if (usageDecoded is Map) {
                  final rawCents =
                      _parseNonNegativeBalanceNum(usageDecoded['total_usage']);
                  if (rawCents != null) {
                    final usedUsd = rawCents / 100.0;
                    final remUsd = (parsed.totalGranted! - usedUsd)
                        .clamp(0.0, double.infinity);
                    parsed = AiApiBalanceSnapshot(
                      endpointKey: epKey,
                      accountKey: acctKey,
                      supported: true,
                      isUnlimited: false,
                      currency: parsed.currency,
                      remaining: remUsd,
                      totalGranted: parsed.totalGranted,
                      totalUsed: usedUsd,
                      sourceLabel: 'Billing Subscription',
                      updatedAtEpochMs: nowMs,
                    );
                  }
                }
              } catch (_) {}
            }
          }
        }

        if (isStale()) return null;
        await _updateApiBalanceSnapshot(parsed);
        return parsed;
      }

      if (isStale()) return null;
      final unsupported = AiApiBalanceSnapshot(
        endpointKey: epKey,
        accountKey: acctKey,
        supported: false,
        sourceLabel: cfg.protocol.labelZh,
        updatedAtEpochMs: nowMs,
      );
      await _updateApiBalanceSnapshot(unsupported);
      return unsupported;
    }();

    _inFlightApiBalance[acctKey] = fut;
    try {
      return await fut;
    } finally {
      if (identical(_inFlightApiBalance[acctKey], fut)) {
        _inFlightApiBalance.remove(acctKey);
      }
    }
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

  static bool _isRedirectStatus(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static bool _isSameOriginUri(Uri a, Uri b) {
    final schemeA = a.scheme.toLowerCase();
    final schemeB = b.scheme.toLowerCase();
    if (schemeA != schemeB) return false;
    if (a.host.toLowerCase() != b.host.toLowerCase()) return false;
    final portA = a.hasPort ? a.port : (schemeA == 'https' ? 443 : 80);
    final portB = b.hasPort ? b.port : (schemeB == 'https' ? 443 : 80);
    return portA == portB && b.userInfo.isEmpty;
  }

  Future<http.Response> _getWithTimeout(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
    VoidCallback? verifyAuthorizedBeforeHop,
    bool allowSameOriginRedirects = false,
    int maxRedirects = 3,
  }) async {
    final ephemeral = _injectedHttpClient == null;
    final client = _injectedHttpClient ?? http.Client();
    final capturedAuthEpoch = _outboundAuthEpoch;
    void verifyHopAuth() {
      if (verifyAuthorizedBeforeHop != null) {
        verifyAuthorizedBeforeHop();
      } else {
        _assertOutboundStillAuthorized(
          capturedAuthEpoch: capturedAuthEpoch,
          isPrivateSession: false,
          requireExperimentalOAuth: false,
        );
      }
    }

    try {
      var currentUri = uri;
      for (var hop = 0; ; hop++) {
        verifyHopAuth();
        final req = http.Request('GET', currentUri)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(headers);
        final streamed = await client.send(req).timeout(timeout);
        final resp = await http.Response.fromStream(streamed).timeout(timeout);
        if (!allowSameOriginRedirects || !_isRedirectStatus(resp.statusCode)) {
          return resp;
        }
        // Re-verify live authorization immediately upon receiving a redirect
        // BEFORE checking or dispatching any follow-up hop.
        verifyHopAuth();
        if (hop >= maxRedirects) {
          return resp;
        }
        final location = (resp.headers['location'] ?? '').trim();
        if (location.isEmpty) {
          return resp;
        }
        final nextUri = currentUri.resolve(location);
        if (!_isSameOriginUri(currentUri, nextUri)) {
          return resp;
        }
        currentUri = nextUri;
      }
    } on AiServiceException {
      rethrow;
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
  /// Always disables automatic HTTP redirects so credentials or prompts can
  /// never follow an unverified redirect hop.
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
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll(headers)
        ..bodyBytes = utf8.encode(bodyJson);
      final streamed = await client.send(req).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on AiServiceException {
      rethrow;
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
    AiAuthMode? authModeOverride,
    bool ignoreEnabledFlag = false,
  }) async {
    await ensureLoaded();

    final cfg = configOverride ?? _config;
    final rawKey = (apiKeyOverride ?? _apiKey).trim();
    final mode = authModeOverride ??
        (configOverride != null ? cfg.authMode : activeAuthMode);
    final isCodexMode = mode == AiAuthMode.codexOAuth;
    _ensureOutboundAuthorized(
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: isCodexMode,
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
    final requestCatalogScopeKey = _computeModelCatalogScopeKey(
      config: cfg,
      authMode: mode,
      apiKey: rawKey,
    );
    final effectiveModel = resolveCanonicalModelId(
      rawModel,
      isCodex: isCodexMode,
      catalogScopeKey: requestCatalogScopeKey,
    );

    if (effectiveModel.isEmpty) {
      throw AiServiceException(
        AiErrorCode.unconfigured,
        isCodexMode
            ? '请先选择订阅模型（可点击「拉取模型列表」）'
            : '请先填写主模型名称（可点击「拉取模型列表」选择）',
      );
    }

    final allowEmptyKey = mode == AiAuthMode.localNoAuth ||
        (!_enforcesPasscodeInService && isLoopbackAiBaseUrl(cfg.baseUrl));
    if (!isCodexMode &&
        (cfg.baseUrl.trim().isEmpty || (!allowEmptyKey && rawKey.isEmpty))) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请先填写完整的接口地址、API 密钥与主模型名称',
      );
    }

    final cacheKey = computeCacheKey(
      feature: feature,
      protocol: cfg.protocol,
      model: effectiveModel,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      authMode: mode,
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
        feature: feature,
        model: effectiveModel,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        cacheKey: cacheKey,
        useCache: useCache,
      );
    }

    var effectiveBaseUrl = cfg.baseUrl.trim();
    var effectiveKey = rawKey;
    final extraHeaders = <String, String>{};
    if (mode == AiAuthMode.githubCopilotDeviceFlow) {
      final session = await _copilotFlow.getOrRefreshSessionToken(
        rawKey,
        httpClient: _injectedHttpClient,
        clock: _clock,
      );
      effectiveKey = session.token;
      effectiveBaseUrl = session.apiBaseUrl;
      extraHeaders.addAll(GitHubCopilotDeviceFlow.standardCopilotHeaders);
    } else if (mode == AiAuthMode.openRouterOAuth ||
        effectiveBaseUrl.toLowerCase().contains('openrouter.ai')) {
      extraHeaders['HTTP-Referer'] = 'https://marcotv.wlj9919.top';
      extraHeaders['X-Title'] = 'Marco Movie';
    }

    final uri = resolveEndpointUri(
      protocol: cfg.protocol,
      baseUrl: effectiveBaseUrl,
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
      ...extraHeaders,
    };
    Map<String, dynamic> body;

    switch (cfg.protocol) {
      case AiApiProtocol.openaiCompatible:
        if (effectiveKey.isNotEmpty) {
          headers['Authorization'] = 'Bearer $effectiveKey';
        }
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
        if (effectiveKey.isNotEmpty) {
          headers['x-api-key'] = effectiveKey;
        }
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
        if (effectiveKey.isNotEmpty) {
          headers['x-goog-api-key'] = effectiveKey;
        }
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

    final authEpoch = _outboundAuthEpoch;
    final byoGen = _byoCredentialGen;
    void assertByoConfigUnchanged() {
      if (byoGen != _byoCredentialGen) {
        throw const AiServiceException(
          AiErrorCode.unauthorized,
          '接口地址或凭据已变更，已中止旧配置请求',
        );
      }
    }

    final sw = Stopwatch()..start();
    var response = await _postBareJson(
      uri,
      headers: headers,
      bodyJson: jsonEncode(body),
      timeout: Duration(seconds: cfg.timeoutSeconds),
    );
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: authEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: false,
    );
    assertByoConfigUnchanged();
    var status = response.statusCode;
    var rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);

    // Auto-adapt if a reasoning model on a custom OpenAI-compatible gateway
    // rejects `max_tokens` or `temperature` with HTTP 400. Re-verify auth
    // and BYO credential generation strictly BEFORE sending the retry request!
    if (status == 400 &&
        cfg.protocol == AiApiProtocol.openaiCompatible &&
        !isResponsesEndpoint &&
        (body.containsKey('max_tokens') || body.containsKey('temperature')) &&
        RegExp(
          r'max_tokens|max_completion_tokens|temperature|unsupported_parameter|unsupported_value',
          caseSensitive: false,
        ).hasMatch(rawBody)) {
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: isPrivateSession,
        requireExperimentalOAuth: false,
      );
      assertByoConfigUnchanged();
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
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: isPrivateSession,
        requireExperimentalOAuth: false,
      );
      assertByoConfigUnchanged();
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

    _assertOutboundStillAuthorized(
      capturedAuthEpoch: authEpoch,
      isPrivateSession: isPrivateSession,
      requireExperimentalOAuth: false,
    );
    assertByoConfigUnchanged();
    await _recordUsage(
      promptTokens: parsed.promptTokens,
      completionTokens: parsed.completionTokens,
      feature: feature,
      model: effectiveModel,
      authModeId: mode.id,
      latencyMs: sw.elapsedMilliseconds,
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
    required String feature,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required String cacheKey,
    required bool useCache,
  }) async {
    final authEpoch = _outboundAuthEpoch;
    var session = await ensureFreshOAuthSession();
    final oauthGen = _oauthSessionGen;
    final acctKey = oauthAccountKey(session);
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: authEpoch,
      isPrivateSession: false,
      requireExperimentalOAuth: true,
      capturedOAuthGen: oauthGen,
      expectedOAuthAccountKey: acctKey,
    );
    final uri = Uri.parse(
      _codexResponsesEndpointOverride ?? _defaultCodexResponsesEndpoint,
    );

    Map<String, String> buildCodexHeaders(
      AiOAuthSession s,
      String targetModel,
    ) =>
        <String, String>{
          'Authorization': 'Bearer ${s.accessToken}',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream, application/json',
          'Version': codexClientVersion,
          'Openai-Beta': 'responses=experimental',
          'Originator': 'codex_cli_rs',
          'User-Agent': 'codex_cli_rs/$codexClientVersion (iOS; arm64)',
          'x-codex-routing-hint': 'model=$targetModel',
          if (s.accountId.isNotEmpty) 'Chatgpt-Account-Id': s.accountId,
        };

    String? pickCodexReasoningEffort(String targetModel) {
      final scope = 'codex|$acctKey';
      AiModelOption? match;
      if (_discoveredModelsScopeKey == scope) {
        final lower = targetModel.trim().toLowerCase();
        for (final opt in _discoveredModels) {
          if (opt.id.toLowerCase() == lower) {
            match = opt;
            break;
          }
        }
      }
      final supported = match?.supportedReasoningEfforts;
      if (supported != null) {
        if (supported.isEmpty) return null;
        if (supported.contains('low')) return 'low';
        if (match!.defaultReasoningEffort.isNotEmpty &&
            supported.contains(match.defaultReasoningEffort)) {
          return match.defaultReasoningEffort;
        }
        return supported.first;
      }
      if (match != null && match.defaultReasoningEffort.isNotEmpty) {
        return match.defaultReasoningEffort;
      }
      return 'low';
    }

    String buildCodexBody(
      String targetModel, {
      bool includeOptionalFields = true,
    }) {
      final promptCacheKey = sha256
          .convert(utf8.encode('marco_codex|$targetModel|$systemPrompt'))
          .toString()
          .substring(0, 32);
      final effort =
          includeOptionalFields ? pickCodexReasoningEffort(targetModel) : null;
      final body = <String, dynamic>{
        'model': targetModel,
        'stream': true,
        'store': false,
        if (includeOptionalFields) 'parallel_tool_calls': true,
        'prompt_cache_key': promptCacheKey,
        if (includeOptionalFields && effort != null)
          'include': const <String>['reasoning.encrypted_content'],
        if (includeOptionalFields && effort != null)
          'reasoning': <String, String>{
            'effort': effort,
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
      return jsonEncode(body);
    }

    Future<http.Response> dispatchCodexPost(
      String targetModel, {
      bool includeOptionalFields = true,
    }) async {
      final bodyJson = buildCodexBody(
        targetModel,
        includeOptionalFields: includeOptionalFields,
      );
      var resp = await _postBareJson(
        uri,
        headers: buildCodexHeaders(session, targetModel),
        bodyJson: bodyJson,
        timeout: Duration(seconds: cfg.timeoutSeconds),
      );
      _assertOutboundStillAuthorized(
        capturedAuthEpoch: authEpoch,
        isPrivateSession: false,
        requireExperimentalOAuth: true,
        capturedOAuthGen: oauthGen,
        expectedOAuthAccountKey: acctKey,
      );
      if (resp.statusCode == 401 && session.refreshToken.isNotEmpty) {
        session = await ensureFreshOAuthSession(forceRefresh: true);
        _assertOutboundStillAuthorized(
          capturedAuthEpoch: authEpoch,
          isPrivateSession: false,
          requireExperimentalOAuth: true,
          capturedOAuthGen: oauthGen,
          expectedOAuthAccountKey: acctKey,
        );
        resp = await _postBareJson(
          uri,
          headers: buildCodexHeaders(session, targetModel),
          bodyJson: bodyJson,
          timeout: Duration(seconds: cfg.timeoutSeconds),
        );
        _assertOutboundStillAuthorized(
          capturedAuthEpoch: authEpoch,
          isPrivateSession: false,
          requireExperimentalOAuth: true,
          capturedOAuthGen: oauthGen,
          expectedOAuthAccountKey: acctKey,
        );
      }
      return resp;
    }

    var activeModel = model;
    final sw = Stopwatch()..start();
    var resp = await dispatchCodexPost(activeModel);

    // Self-heal HTTP 400 caused by optional reasoning/include parameters or stale/web model slugs.
    if (resp.statusCode == 400) {
      final firstBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final lowerErr = firstBody.toLowerCase();
      final isParamError = lowerErr.contains('reasoning') ||
          lowerErr.contains('effort') ||
          lowerErr.contains('summary') ||
          lowerErr.contains('parallel_tool_calls') ||
          lowerErr.contains('unsupported parameter') ||
          lowerErr.contains("'include'");
      final isUnsupportedModel =
          lowerErr.contains('not supported when using codex') ||
              lowerErr.contains('unsupported model') ||
              lowerErr.contains('invalid model') ||
              lowerErr.contains('model_not_found') ||
              (lowerErr.contains('model') &&
                  (lowerErr.contains('does not exist') ||
                      lowerErr.contains('not supported')));
      if (isParamError && !isUnsupportedModel) {
        resp = await dispatchCodexPost(
          activeModel,
          includeOptionalFields: false,
        );
      } else if (isUnsupportedModel) {
        String? healedModel;
        final stripped = sanitizeCodexModelSlug(activeModel);
        List<AiModelOption> catalog = const <AiModelOption>[];
        try {
          catalog = await fetchAvailableModelOptions(
            configOverride: cfg.copyWith(authMode: AiAuthMode.codexOAuth),
          );
        } catch (_) {}
        _assertOutboundStillAuthorized(
          capturedAuthEpoch: authEpoch,
          isPrivateSession: false,
          requireExperimentalOAuth: true,
          capturedOAuthGen: oauthGen,
          expectedOAuthAccountKey: acctKey,
        );
        final pool = catalog.isNotEmpty ? catalog : fallbackCodexModels;
        if (stripped.isNotEmpty &&
            stripped.toLowerCase() != activeModel.trim().toLowerCase()) {
          for (final opt in pool) {
            if (opt.id.toLowerCase() == stripped.toLowerCase()) {
              healedModel = opt.id;
              break;
            }
          }
          healedModel ??= stripped;
        }
        if (healedModel == null) {
          for (final opt in pool) {
            if (opt.id.toLowerCase() != activeModel.trim().toLowerCase() &&
                !isDisallowedCodexModelSlug(opt.id)) {
              healedModel = opt.id;
              break;
            }
          }
        }
        if (healedModel != null &&
            healedModel.isNotEmpty &&
            healedModel.toLowerCase() != activeModel.trim().toLowerCase()) {
          if (_config.authMode == AiAuthMode.codexOAuth) {
            final updatePrimary =
                _config.model.trim().toLowerCase() == activeModel.trim().toLowerCase() ||
                    isDisallowedCodexModelSlug(_config.model);
            final updateFast = _config.fastModel.trim().toLowerCase() ==
                    activeModel.trim().toLowerCase() ||
                isDisallowedCodexModelSlug(_config.fastModel);
            if (updatePrimary || updateFast) {
              _config = _config.copyWith(
                model: updatePrimary ? healedModel : _config.model,
                fastModel: updateFast ? '' : _config.fastModel,
              );
              if (!OhosRuntime.isOhos) {
                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                    prefsConfigKey,
                    jsonEncode(_config.toJson()),
                  );
                } catch (_) {}
              }
              notifyListeners();
            }
          }
          activeModel = healedModel;
          resp = await dispatchCodexPost(activeModel);
        }
      }
    }
    sw.stop();
    _captureCodexRateLimitHeaders(
      resp.headers,
      fallbackPlanType: session.planType,
      accountKey: oauthAccountKey(session),
    );

    final rawBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw _buildHttpError(resp.statusCode, rawBody, isCodex: true);
    }

    final parsed = parseCodexResponsesPayload(
      rawBody,
      fallbackPromptChars: systemPrompt.length + userPrompt.length,
    );
    _assertOutboundStillAuthorized(
      capturedAuthEpoch: authEpoch,
      isPrivateSession: false,
      requireExperimentalOAuth: true,
      capturedOAuthGen: oauthGen,
      expectedOAuthAccountKey: acctKey,
    );
    await _recordUsage(
      promptTokens: parsed.promptTokens,
      completionTokens: parsed.completionTokens,
      feature: feature,
      model: activeModel,
      authModeId: AiAuthMode.codexOAuth.id,
      latencyMs: sw.elapsedMilliseconds,
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
    if (detail.isNotEmpty) {
      detail = redactAiSecret(detail);
    }
    // Strip any URL from upstream error details to keep UI diagnostics clean.
    if (detail.isNotEmpty && containsForbiddenUrl(detail)) {
      detail = '';
    }
    final lowerDetail = detail.toLowerCase();
    final isInvalidModel = lowerDetail.contains('invalid model') ||
        lowerDetail.contains('model_not_found') ||
        lowerDetail.contains('not supported when using codex') ||
        (lowerDetail.contains('model') &&
            (lowerDetail.contains('does not exist') ||
                lowerDetail.contains('not supported')));

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
    AiAuthMode? authModeOverride,
    bool isPrivateSession = false,
  }) async {
    await ensureLoaded();
    final startByoGen = _byoCredentialGen;
    final startOAuthGen = _oauthSessionGen;
    final startAuthEpoch = _outboundAuthEpoch;
    final mode = authModeOverride ??
        (configOverride != null ? configOverride.authMode : activeAuthMode);
    bool isTestStale() =>
        startAuthEpoch != _outboundAuthEpoch ||
        (mode == AiAuthMode.codexOAuth
            ? startOAuthGen != _oauthSessionGen
            : startByoGen != _byoCredentialGen);

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
        authModeOverride: authModeOverride,
        ignoreEnabledFlag: true,
      );
      sw.stop();
      if (isTestStale()) {
        return AiConnectionTestResult(
          ok: false,
          latencyMs: sw.elapsedMilliseconds,
          messageZh: '接口配置已变更，旧测试结果已丢弃',
          stale: true,
        );
      }
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
        stale: isTestStale(),
      );
    } catch (_) {
      sw.stop();
      return AiConnectionTestResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        messageZh: '连接测试失败，请检查接口配置与网络状态',
        stale: isTestStale(),
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
    if (_enforcesPasscodeInService) {
      _ensureLabGateAuthorized();
    }
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

  static const String _personalizedPicksSystemPrompt =
      '你是本地私人影单推荐助手。请结合用户近期公开看过的影片与收藏片单，以及可选的心情/偏好提示，'
      '推荐 6 到 8 部不与原片单重复、口味高度契合的高口碑真实影视作品。\n'
      '严格只输出纯 JSON 数组，格式为：'
      '[{"title":"标准中文片名","year":"2020","reason":"结合其片单的一句话推荐理由（24字以内）"}]。\n'
      '安全与合规硬性约束：只允许输出结构化影视元数据（title、year、reason）；'
      '严禁生成或返回任何网址、URL、域名、网盘链接、磁力链接或播放地址；'
      '严禁输出 Markdown 代码块或任何额外解释文字。';

  /// Generates on-demand personalized movie/series recommendations based ONLY
  /// on deduplicated public watch history and favorite titles.
  /// Hard-blocked in Privacy Space and never triggered automatically on launch.
  Future<List<AiMovieCandidate>> suggestPersonalizedRecommendations({
    required List<String> recentTitles,
    required List<String> favoriteTitles,
    String moodHint = '',
    bool isPrivateSession = false,
    bool bypassCache = false,
  }) async {
    if (isPrivateSession) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已硬性禁用所有外部 AI 网络请求',
      );
    }
    await ensureLoaded();
    if (_enforcesPasscodeInService) {
      _ensureLabGateAuthorized();
    }
    if (!_config.picksEnabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        'AI 为你挑片开关未开启',
      );
    }

    List<String> sanitizeTitles(List<String> raw, int maxCount) {
      final seen = <String>{};
      final out = <String>[];
      for (final item in raw) {
        final t = item.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isEmpty || t.length > 60 || containsForbiddenUrl(t)) continue;
        final key = t.toLowerCase();
        if (seen.add(key)) {
          out.add(t);
          if (out.length >= maxCount) break;
        }
      }
      return out;
    }

    final cleanRecent = sanitizeTitles(recentTitles, 8);
    final cleanFavs = sanitizeTitles(favoriteTitles, 8);
    final cleanMood = moodHint.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (cleanRecent.isEmpty && cleanFavs.isEmpty && cleanMood.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '请先积累少量观看记录、收藏影片，或输入此刻想看的氛围提示',
      );
    }

    final promptLines = <String>[
      if (cleanRecent.isNotEmpty) '近期观看：${cleanRecent.join("、")}',
      if (cleanFavs.isNotEmpty) '我的收藏：${cleanFavs.join("、")}',
      if (cleanMood.isNotEmpty) '此刻偏好：$cleanMood',
    ];

    final completion = await complete(
      feature: 'ai_picks_v1',
      systemPrompt: _personalizedPicksSystemPrompt,
      userPrompt: promptLines.join('\n'),
      temperature: 0.45,
      maxTokens: 900,
      useCache: !bypassCache,
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

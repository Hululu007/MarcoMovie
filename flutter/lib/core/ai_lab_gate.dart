// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';

import 'ai_lab_passcode.dart';

export 'ai_lab_passcode.dart';

/// Verified claims adapter wrapping [AiLabPasscodePayload] for iOS AI Lab UI
/// and service integration.
@immutable
class AiLabTokenClaims {
  final String rawToken;
  final AiLabPasscodePayload payload;

  const AiLabTokenClaims({
    required this.rawToken,
    required this.payload,
  });

  int get version => payload.version;
  int get issuedAtEpochSec => payload.issuedAtEpochSec;
  int get expiresAtEpochSec => payload.expiresAtEpochSec;
  String get tag => payload.tag;
  String get platform => payload.platform;
  bool get shared => payload.shared;
  bool get experimentalOAuth => payload.experimentalOAuth;
  int get minVersionCode => payload.minVersionCode;

  bool get isPermanent => payload.isPermanent;

  bool isExpiredAt(DateTime now) => payload.isExpiredAt(now);

  String get badgeLabelZh => payload.summaryBadgeZh;
}

/// Thin facade delegating all Ed25519 verification to the unified three-platform
/// [AiLabPasscodeVerifier] (`flutter/lib/core/ai_lab_passcode.dart`).
abstract final class AiLabGate {
  static const String tokenPrefix = 'MMAILAB1.';
  static const String signDomainPrefix = AiLabPasscodeVerifier.signingDomainPrefix;
  static const String defaultPublicKeyHex =
      AiLabPasscodeVerifier.defaultPublicKeyHex;

  @visibleForTesting
  static String? get debugPublicKeyHexOverride =>
      AiLabPasscodeVerifier.debugPublicKeyHexOverride;

  @visibleForTesting
  static set debugPublicKeyHexOverride(String? value) {
    AiLabPasscodeVerifier.debugPublicKeyHexOverride = value;
  }

  static String? extractCanonicalToken(String rawInput) {
    final extracted = AiLabPasscodeVerifier.extractToken(rawInput);
    if (!extracted.startsWith(tokenPrefix)) return null;
    return extracted;
  }

  static AiLabTokenClaims verifyPasscode(
    String rawInput, {
    DateTime? now,
    String? publicKeyHex,
    String? targetPlatform,
    int currentVersionCode = 0,
  }) {
    final res = AiLabPasscodeVerifier.verify(
      rawInput,
      publicKeyHex: publicKeyHex,
      targetPlatform: targetPlatform,
      currentVersionCode: currentVersionCode,
      now: now,
    );
    if (!res.isValid || res.payload == null) {
      throw FormatException(res.messageZh);
    }
    return AiLabTokenClaims(
      rawToken: res.canonicalToken,
      payload: res.payload!,
    );
  }

  static AiLabTokenClaims? tryVerifyPasscode(
    String? rawInput, {
    DateTime? now,
    String? publicKeyHex,
    String? targetPlatform,
    int currentVersionCode = 0,
  }) {
    if (rawInput == null || rawInput.trim().isEmpty) return null;
    final res = AiLabPasscodeVerifier.verify(
      rawInput,
      publicKeyHex: publicKeyHex,
      targetPlatform: targetPlatform,
      currentVersionCode: currentVersionCode,
      now: now,
    );
    if (!res.isValid || res.payload == null) return null;
    return AiLabTokenClaims(
      rawToken: res.canonicalToken,
      payload: res.payload!,
    );
  }
}

/// Mount target for extensible user-defined AI Prompt Skills (`自定义 AI 技能卡`).
enum AiSkillTarget {
  both('both', '详情页与播放器'),
  detailOnly('detail', '仅详情页'),
  playerOnly('player', '仅播放器更多菜单');

  final String id;
  final String labelZh;

  const AiSkillTarget(this.id, this.labelZh);

  static AiSkillTarget fromId(String? raw) {
    final clean = (raw ?? '').trim().toLowerCase();
    for (final t in AiSkillTarget.values) {
      if (t.id == clean) return t;
    }
    return AiSkillTarget.both;
  }

  bool get showsInDetail =>
      this == AiSkillTarget.both || this == AiSkillTarget.detailOnly;
  bool get showsInPlayer =>
      this == AiSkillTarget.both || this == AiSkillTarget.playerOnly;
}

/// User-customizable prompt skill card (`自定义 AI 技能卡`) stored inside
/// [AiConfig.customSkills] with safe local metadata placeholders.
@immutable
class AiCustomSkill {
  final String id;
  final String name;
  final String promptTemplate;
  final AiSkillTarget target;
  final bool useFastModel;

  const AiCustomSkill({
    required this.id,
    required this.name,
    required this.promptTemplate,
    this.target = AiSkillTarget.both,
    this.useFastModel = false,
  });

  static const Set<String> retiredBuiltInSkillIds = <String>{
    'builtin_quotes',
    'builtin_lang_notes',
  };

  static const List<AiCustomSkill> defaultBuiltInSkills = <AiCustomSkill>[
    AiCustomSkill(
      id: 'builtin_family_guide',
      name: '合家欢陪看分级提示',
      promptTemplate:
          '请根据《{{title}}》（{{year}}）的公开作品属性（简介：{{overview}}），客观评估是否适合与父母或青少年共同观看（暴力/恐怖/尴尬桥段预警），不剧透关键结局，控制在 120 字以内。',
      target: AiSkillTarget.detailOnly,
      useFastModel: true,
    ),
  ];

  String renderPrompt({
    required String title,
    String year = '',
    String episode = '',
    String overview = '',
    String subtitles = '',
  }) {
    return promptTemplate
        .replaceAll('{{title}}', title.trim().isEmpty ? '未知影片' : title.trim())
        .replaceAll('{{year}}', year.trim())
        .replaceAll('{{episode}}', episode.trim())
        .replaceAll(
          '{{overview}}',
          overview.trim().isEmpty ? '暂无简介' : overview.trim(),
        )
        .replaceAll(
          '{{subtitles}}',
          subtitles.trim().isEmpty ? '（当前未加载外挂台词片段，请基于本集常规语境分析）' : subtitles.trim(),
        );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name.trim(),
        'promptTemplate': promptTemplate.trim(),
        'target': target.id,
        'useFastModel': useFastModel,
      };

  factory AiCustomSkill.fromJson(Map<String, dynamic> json) {
    return AiCustomSkill(
      id: (json['id'] ?? '').toString().trim(),
      name: (json['name'] ?? '').toString().trim(),
      promptTemplate: (json['promptTemplate'] ?? '').toString().trim(),
      target: AiSkillTarget.fromId(json['target']?.toString()),
      useFastModel: json['useFastModel'] == true,
    );
  }
}

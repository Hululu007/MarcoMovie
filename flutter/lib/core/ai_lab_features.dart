// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ai_lab_gate.dart';
import 'ai_service.dart';
import 'episode_scraper.dart';
import 'models.dart';

/// Parsed subtitle cue supporting `.srt`, `.vtt`, and `.ass`/`.ssa` inputs.
@immutable
class AiSubtitleCue {
  final int index;
  final Duration start;
  final Duration end;
  final String text;
  final String translatedText;

  const AiSubtitleCue({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    this.translatedText = '',
  });

  AiSubtitleCue copyWith({String? translatedText}) => AiSubtitleCue(
        index: index,
        start: start,
        end: end,
        text: text,
        translatedText: translatedText ?? this.translatedText,
      );
}

/// Result of Scenario 1: AI Subtitle Studio translation + glossary lock.
@immutable
class AiSubtitleTranslationResult {
  final List<AiSubtitleCue> cues;
  final Map<String, String> glossary;
  final bool bilingual;
  final String srtContent;

  const AiSubtitleTranslationResult({
    required this.cues,
    required this.glossary,
    required this.bilingual,
    required this.srtContent,
  });
}

/// Character card inside Scenario 2: Zero-Spoiler Episode Companion.
@immutable
class AiCharacterNote {
  final String name;
  final String factionOrRole;
  final String summary;

  const AiCharacterNote({
    required this.name,
    required this.factionOrRole,
    required this.summary,
  });
}

/// Result of Scenario 2: Zero-Spoiler Episode Recap & Character Guide.
@immutable
class AiEpisodeCompanionResult {
  final String boundaryLabel;
  final String recap;
  final List<AiCharacterNote> characters;
  final String trivia;

  const AiEpisodeCompanionResult({
    required this.boundaryLabel,
    required this.recap,
    required this.characters,
    this.trivia = '',
  });
}

/// Result of Scenario 3: Messy Netdisk / WebDAV Episode Curating & Calibration.
@immutable
class AiEpisodeCuratePlan {
  final String canonicalTitle;
  final int seasonNumber;
  final int episodeOffset;
  final List<int> specialIndices;
  final String summaryZh;

  const AiEpisodeCuratePlan({
    required this.canonicalTitle,
    this.seasonNumber = 1,
    this.episodeOffset = 0,
    this.specialIndices = const <int>[],
    required this.summaryZh,
  });

  EpisodeScrapeOverride toScrapeOverride() => EpisodeScrapeOverride(
        enabled: true,
        customTitle: canonicalTitle.trim(),
        episodeOffset: episodeOffset,
        sortByEpisodeNumber: true,
        hideSpecials: specialIndices.isNotEmpty,
      );
}

/// Ranked cross-source candidate in Scenario 3.
@immutable
class AiRankedSourceMatch {
  final CmsSite site;
  final CmsVideo video;
  final String canonicalKey;
  final int qualityScore;
  final String badgeLabel;

  const AiRankedSourceMatch({
    required this.site,
    required this.video,
    required this.canonicalKey,
    required this.qualityScore,
    required this.badgeLabel,
  });
}

/// Curated recommendation in Scenario 4: Taste Portrait & Mood Sommelier.
@immutable
class AiCuratedPick {
  final String title;
  final String year;
  final String moodTag;
  final String reason;
  final CmsSite? matchedSite;
  final CmsVideo? matchedVideo;

  const AiCuratedPick({
    required this.title,
    this.year = '',
    this.moodTag = '',
    required this.reason,
    this.matchedSite,
    this.matchedVideo,
  });

  bool get isPlayableInLibrary => matchedSite != null && matchedVideo != null;
}

/// Result of Scenario 4: Taste Portrait & Mood Sommelier.
@immutable
class AiMoodSommelierResult {
  final String tastePortrait;
  final List<AiCuratedPick> picks;

  const AiMoodSommelierResult({
    required this.tastePortrait,
    required this.picks,
  });
}

/// Executable one-tap remediation action returned by Scenario 5: AI Diagnostics.
enum AiDiagnosticActionId {
  switchToMpv('切换至 MPV 软硬解内核'),
  switchToAvPlayer('切换至系统 AVPlayer 硬解'),
  enableVocalLoudness('开启人声响度增强'),
  switchBackupLine('切换其他可用线路'),
  openEpisodeScrape('打开集数刮削校准');

  final String labelZh;
  const AiDiagnosticActionId(this.labelZh);

  static AiDiagnosticActionId? fromCode(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'switch_to_mpv' => AiDiagnosticActionId.switchToMpv,
      'switch_to_avplayer' => AiDiagnosticActionId.switchToAvPlayer,
      'enable_vocal_loudness' => AiDiagnosticActionId.enableVocalLoudness,
      'switch_backup_line' => AiDiagnosticActionId.switchBackupLine,
      'open_episode_scrape' => AiDiagnosticActionId.openEpisodeScrape,
      _ => null,
    };
  }
}

/// Result of Scenario 5: Smart Playback / Subscription Diagnostics.
@immutable
class AiDiagnosticReport {
  final String rootCauseZh;
  final List<String> stepsZh;
  final List<AiDiagnosticActionId> suggestedActions;

  const AiDiagnosticReport({
    required this.rootCauseZh,
    required this.stepsZh,
    this.suggestedActions = const <AiDiagnosticActionId>[],
  });
}

/// Implements the 5 Core Experimental AI Lab Scenarios atop [AiService].
///
/// Strict guardrails:
/// 1. Requires `AiService.isLabUnlocked` (Ed25519 offline signed passcode) +
///    `AiService.isConfigured`.
/// 2. Hard-blocked when `isPrivateSpace == true`.
/// 3. Desensitizes all URLs, tokens, IPs, and paths before constructing prompts,
///    and rejects any model output containing URLs/magnets.
class AiLabService {
  final AiService _ai;

  const AiLabService(this._ai);

  static AiLabService get instance => AiLabService(AiService.instance);

  void _ensureReady({required bool isPrivateSpace}) {
    if (isPrivateSpace) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已物理熔断外部 AI 调用',
      );
    }
    if (!_ai.isLabUnlocked) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '请先在「设置 → AI 实验室」输入口令解锁实验性功能',
      );
    }
    if (!_ai.isConfigured) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '请先在「设置 → AI 实验室」登录订阅账号或配置 API 密钥',
      );
    }
  }

  /// Strips URLs, query tokens, IPv4/IPv6 literals, and local filesystem paths
  /// from diagnostic strings so private endpoints never leave the device.
  static String desensitizeDiagnosticText(String raw) {
    return raw
        .replaceAll(RegExp(r'https?://[^\s"<>]+', caseSensitive: false), '[URL已脱敏]')
        .replaceAll(RegExp(r'(?:webdavlib|smblib|alistlib|emby|plex|jellyfin)://[^\s"<>]+', caseSensitive: false), '[库地址已脱敏]')
        .replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b'), '[IP已脱敏]')
        .replaceAll(RegExp(r'(?:token|sig|signature|key|cookie|auth)=[^&\s]+', caseSensitive: false), '[凭据已脱敏]')
        .trim();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scenario 1: Subtitle Studio (SRT / VTT / ASS Parser, Glossary Lock & Bilingual SRT)
  // ─────────────────────────────────────────────────────────────────────────

  static List<AiSubtitleCue> parseSubtitleDocument(String rawText) {
    final normalized = rawText
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (normalized.contains('[Events]') && normalized.contains('Dialogue:')) {
      return _parseAssEvents(normalized);
    }
    return _parseSrtOrVtt(normalized);
  }

  static List<AiSubtitleCue> _parseSrtOrVtt(String text) {
    final blocks = text.split(RegExp(r'\n\s*\n'));
    final out = <AiSubtitleCue>[];
    final timeRe = RegExp(
      r'((?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[,.]\d{1,3})',
    );
    int idx = 1;
    for (final block in blocks) {
      final lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && l != 'WEBVTT')
          .toList();
      if (lines.isEmpty) continue;
      int timeLineIdx = -1;
      RegExpMatch? match;
      for (int i = 0; i < lines.length && i < 2; i++) {
        final m = timeRe.firstMatch(lines[i]);
        if (m != null) {
          timeLineIdx = i;
          match = m;
          break;
        }
      }
      if (timeLineIdx < 0 || match == null) continue;
      final bodyLines = lines
          .sublist(timeLineIdx + 1)
          .map((l) => l.replaceAll(RegExp(r'<[^>]+>|\{\\[^}]*\}'), '').trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (bodyLines.isEmpty) continue;
      out.add(
        AiSubtitleCue(
          index: idx++,
          start: _parseTimestamp(match.group(1)!),
          end: _parseTimestamp(match.group(2)!),
          text: bodyLines.join('\n'),
        ),
      );
    }
    return out;
  }

  static List<AiSubtitleCue> _parseAssEvents(String text) {
    final out = <AiSubtitleCue>[];
    int idx = 1;
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('Dialogue:')) continue;
      final parts = line.substring('Dialogue:'.length).split(',');
      if (parts.length < 10) continue;
      final start = _parseTimestamp(parts[1].trim());
      final end = _parseTimestamp(parts[2].trim());
      final rawDialogue = parts
          .sublist(9)
          .join(',')
          .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .trim();
      if (rawDialogue.isEmpty) continue;
      out.add(
        AiSubtitleCue(
          index: idx++,
          start: start,
          end: end,
          text: rawDialogue,
        ),
      );
    }
    return out;
  }

  static Duration _parseTimestamp(String raw) {
    final clean = raw.trim().replaceAll(',', '.');
    final segs = clean.split(':');
    int hours = 0;
    int mins = 0;
    double secs = 0;
    if (segs.length == 3) {
      hours = int.tryParse(segs[0]) ?? 0;
      mins = int.tryParse(segs[1]) ?? 0;
      secs = double.tryParse(segs[2]) ?? 0;
    } else if (segs.length == 2) {
      mins = int.tryParse(segs[0]) ?? 0;
      secs = double.tryParse(segs[1]) ?? 0;
    }
    final ms = ((hours * 3600 + mins * 60 + secs) * 1000).round();
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  static String formatSrtTimestamp(Duration d) {
    final totalMs = d.inMilliseconds < 0 ? 0 : d.inMilliseconds;
    final h = (totalMs ~/ 3600000).toString().padLeft(2, '0');
    final m = ((totalMs % 3600000) ~/ 60000).toString().padLeft(2, '0');
    final s = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final ms = (totalMs % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  static String serializeToSrt(
    List<AiSubtitleCue> cues, {
    bool bilingual = true,
    Duration offset = Duration.zero,
  }) {
    final sb = StringBuffer();
    for (int i = 0; i < cues.length; i++) {
      final c = cues[i];
      final shiftedStart = c.start + offset;
      final shiftedEnd = c.end + offset;
      final start = shiftedStart.isNegative ? Duration.zero : shiftedStart;
      final end = shiftedEnd <= start
          ? start + const Duration(milliseconds: 500)
          : shiftedEnd;
      sb.writeln('${i + 1}');
      sb.writeln('${formatSrtTimestamp(start)} --> ${formatSrtTimestamp(end)}');
      final zh = c.translatedText.trim();
      final orig = c.text.trim();
      if (zh.isNotEmpty && bilingual && zh != orig) {
        sb.writeln(zh);
        sb.writeln(orig);
      } else if (zh.isNotEmpty) {
        sb.writeln(zh);
      } else {
        sb.writeln(orig);
      }
      sb.writeln();
    }
    return sb.toString();
  }

  /// Translates [cues] (up to [maxCues] per batch window) with automatic
  /// character/proper-noun glossary extraction & lock so names never drift.
  Future<AiSubtitleTranslationResult> translateSubtitleCues({
    required String seriesTitle,
    String episodeLabel = '',
    required List<AiSubtitleCue> cues,
    bool bilingual = true,
    Map<String, String> existingGlossary = const <String, String>{},
    bool isPrivateSpace = false,
    int chunkSize = 28,
    int maxCues = 120,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    if (!_ai.config.subtitleTranslateEnabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '「AI 字幕精译」开关已关闭，可在 AI 实验室设置中开启',
      );
    }
    if (cues.isEmpty) {
      return const AiSubtitleTranslationResult(
        cues: <AiSubtitleCue>[],
        glossary: <String, String>{},
        bilingual: true,
        srtContent: '',
      );
    }

    final bounded = cues.take(maxCues).toList(growable: false);
    final mergedGlossary = Map<String, String>.of(existingGlossary);
    final translated = List<AiSubtitleCue>.of(bounded);

    for (int offset = 0; offset < bounded.length; offset += chunkSize) {
      final slice = bounded.skip(offset).take(chunkSize).toList();
      final glossaryHint = mergedGlossary.isEmpty
          ? '如出现人名/专有名词请在 glossary 字段建立固定译名表。'
          : '请严格沿用本剧既有译名表：${jsonEncode(mergedGlossary)}';

      final inputLines = <Map<String, Object>>[
        for (int i = 0; i < slice.length; i++)
          {'i': i, 't': slice[i].text.replaceAll('\n', ' ')},
      ];

      final res = await _ai.complete(
        feature: 'ai_sub_v1',
        systemPrompt: '你是专业影视字幕精译师。仅输出合法 JSON 对象，格式为 '
            '{"glossary":{"原文名":"译名"},"items":[{"i":0,"zh":"地道自然的简体中文台词"}]}。'
            '严禁输出任何网址、Markdown 代码块解释或多余寒暄。',
        userPrompt: '作品：《$seriesTitle》$episodeLabel\n'
            '$glossaryHint\n'
            '待译字幕 JSON：${jsonEncode(inputLines)}',
        modelOverride: _ai.config.effectiveFastModel,
        temperature: 0.2,
        maxTokens: 1600,
        isPrivateSession: isPrivateSpace,
      );

      final objSlice = AiService.extractJsonObjectSlice(res.text);
      if (objSlice != null) {
        final decoded = jsonDecode(objSlice);
        if (decoded is Map<String, dynamic>) {
          final rawG = decoded['glossary'];
          if (rawG is Map) {
            rawG.forEach((k, v) {
              final ks = k.toString().trim();
              final vs = v.toString().trim();
              if (ks.isNotEmpty &&
                  vs.isNotEmpty &&
                  !AiService.containsForbiddenUrl(vs)) {
                mergedGlossary[ks] = vs;
              }
            });
          }
          final items = decoded['items'];
          if (items is List) {
            for (final entry in items) {
              if (entry is! Map) continue;
              final localIdx = (entry['i'] as num?)?.toInt();
              final zh = (entry['zh'] ?? '').toString().trim();
              if (localIdx != null &&
                  localIdx >= 0 &&
                  localIdx < slice.length &&
                  zh.isNotEmpty &&
                  !AiService.containsForbiddenUrl(zh)) {
                translated[offset + localIdx] =
                    translated[offset + localIdx].copyWith(translatedText: zh);
              }
            }
          }
        }
      }
    }

    final srt = serializeToSrt(translated, bilingual: bilingual);
    return AiSubtitleTranslationResult(
      cues: translated,
      glossary: mergedGlossary,
      bilingual: bilingual,
      srtContent: srt,
    );
  }

  /// Suggests a subtitle timeline offset (in seconds) when external subtitles
  /// lead or lag behind intro/dialogue timing.
  Future<({double offsetSeconds, String reasonZh})> suggestSubtitleOffset({
    required String seriesTitle,
    required List<AiSubtitleCue> firstCues,
    required int skipIntroSeconds,
    String userObservation = '',
    bool isPrivateSpace = false,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    final preview = firstCues.take(6).map((c) => {
          'startSec': (c.start.inMilliseconds / 1000).toStringAsFixed(1),
          'text': c.text,
        }).toList();
    final res = await _ai.complete(
      feature: 'ai_sub_offset_v1',
      systemPrompt: '你是字幕时间轴校准助手。仅输出 JSON：{"offsetSeconds":数字,"reason":"简短中文原因"}。'
          '正数表示字幕延后，负数表示字幕提前。严禁输出任何网址。',
      userPrompt: '作品：《$seriesTitle》，已记录跳过片头时长：${skipIntroSeconds}s。'
          '用户观察：${userObservation.trim().isEmpty ? "字幕与口型对不上" : userObservation.trim()}。'
          '前几句字幕时间点：${jsonEncode(preview)}',
      modelOverride: _ai.config.effectiveFastModel,
      temperature: 0.1,
      maxTokens: 320,
      isPrivateSession: isPrivateSpace,
    );
    final slice = AiService.extractJsonObjectSlice(res.text);
    if (slice == null) {
      throw const AiServiceException(AiErrorCode.malformedResponse, '未能解析时间轴校准建议');
    }
    final map = jsonDecode(slice) as Map<String, dynamic>;
    final sec = ((map['offsetSeconds'] as num?)?.toDouble() ?? 0.0).clamp(-300.0, 300.0);
    final reason = (map['reason'] ?? '根据首句台词与片头时长估算').toString().trim();
    return (offsetSeconds: sec, reasonZh: reason);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scenario 2: Zero-Spoiler Episode Recap & Character Guide
  // ─────────────────────────────────────────────────────────────────────────

  Future<AiEpisodeCompanionResult> generateEpisodeCompanion({
    required String title,
    String year = '',
    required int currentEpisodeNumber,
    int seasonNumber = 1,
    String overview = '',
    bool includeCurrentEpisodePostWatch = false,
    bool isPrivateSpace = false,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    if (!_ai.config.spoilerFreeRecapEnabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '「防剧透观影伴侣」开关已关闭，可在 AI 实验室设置中开启',
      );
    }
    final safeEp = currentEpisodeNumber < 1 ? 1 : currentEpisodeNumber;
    final boundaryDesc = includeCurrentEpisodePostWatch
        ? '第 $seasonNumber 季 第 1 集 ～ 第 $safeEp 集（已看完本集）'
        : (safeEp <= 1
            ? '第 $seasonNumber 季开篇背景（第 1 集正片前零剧透导览）'
            : '第 $seasonNumber 季 第 1 集 ～ 第 ${safeEp - 1} 集（严禁剧透第 $safeEp 集及之后任何剧情！）');

    final res = await _ai.complete(
      feature: 'ai_companion_v1',
      systemPrompt: '你是严守防剧透纪律的资深剧集导览助手。'
          '你掌握的信息上限必须严格锁死在用户指定集数边界之内，严禁暗示或透露后续集数的反转、角色死亡或结局！'
          '仅输出合法 JSON 对象：{"recap":"150字内前情提要或开篇背景","characters":[{"name":"角色名","role":"阵营或身份","summary":"截至当前进度的关系简述"}],"trivia":"80字内世界观或幕后看点"}。'
          '严禁输出任何网址。',
      userPrompt: '作品：《$title》${year.trim().isNotEmpty ? " ($year)" : ""}\n'
          '信息边界：$boundaryDesc\n'
          '公开简介参考：${overview.trim().isEmpty ? "无" : overview.trim()}',
      temperature: 0.3,
      maxTokens: 900,
      isPrivateSession: isPrivateSpace,
    );

    final slice = AiService.extractJsonObjectSlice(res.text);
    if (slice == null) {
      throw const AiServiceException(AiErrorCode.malformedResponse, 'AI 返回的前情提要格式无法解析');
    }
    final map = jsonDecode(slice) as Map<String, dynamic>;
    final recap = (map['recap'] ?? '').toString().trim();
    final trivia = (map['trivia'] ?? '').toString().trim();
    if (AiService.containsForbiddenUrl(recap) ||
        AiService.containsForbiddenUrl(trivia)) {
      throw const AiServiceException(AiErrorCode.unsafeOutputRejected, '返回内容未通过安全过滤');
    }
    final chars = <AiCharacterNote>[];
    final rawChars = map['characters'];
    if (rawChars is List) {
      for (final c in rawChars.take(8)) {
        if (c is! Map) continue;
        final name = (c['name'] ?? '').toString().trim();
        final role = (c['role'] ?? '').toString().trim();
        final sum = (c['summary'] ?? '').toString().trim();
        if (name.isEmpty || AiService.containsForbiddenUrl(sum)) continue;
        chars.add(
          AiCharacterNote(
            name: name,
            factionOrRole: role,
            summary: sum,
          ),
        );
      }
    }
    return AiEpisodeCompanionResult(
      boundaryLabel: boundaryDesc,
      recap: recap.isEmpty ? '暂无前情提要记录。' : recap,
      characters: chars,
      trivia: trivia,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scenario 3: Cross-Source Quality Ranking & Messy Netdisk Episode Curating
  // ─────────────────────────────────────────────────────────────────────────

  Future<AiEpisodeCuratePlan> curateMessyEpisodes({
    required String rawSeriesTitle,
    String year = '',
    required List<CmsEpisode> episodes,
    bool isPrivateSpace = false,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    final sample = <Map<String, Object>>[
      for (int i = 0; i < episodes.length && i < 60; i++)
        {'idx': i, 'name': episodes[i].name},
    ];
    final res = await _ai.complete(
      feature: 'ai_ep_curate_v1',
      systemPrompt: '你是影视媒体库整理专家。请分析杂乱剧集列表（可能含 SP/OVA/花絮/预告/偏移集号），'
          '仅输出 JSON：{"canonicalTitle":"标准中文剧名","seasonNumber":1,"episodeOffset":0,"specialIndices":[花絮或SP的idx数组],"summary":"一句话整理说明"}。'
          'episodeOffset 为需要加在识别集号上的整数校准值（无需偏移填 0）。严禁输出网址。',
      userPrompt: '原始标题：$rawSeriesTitle ${year.isNotEmpty ? "($year)" : ""}\n'
          '剧集条目样本：${jsonEncode(sample)}',
      modelOverride: _ai.config.effectiveFastModel,
      temperature: 0.1,
      maxTokens: 500,
      isPrivateSession: isPrivateSpace,
    );
    final slice = AiService.extractJsonObjectSlice(res.text);
    if (slice == null) {
      throw const AiServiceException(AiErrorCode.malformedResponse, '未能解析剧集智能编排结果');
    }
    final map = jsonDecode(slice) as Map<String, dynamic>;
    final canonical = (map['canonicalTitle'] ?? '').toString().trim();
    final season = ((map['seasonNumber'] as num?)?.toInt() ?? 1).clamp(1, 99);
    final offset = ((map['episodeOffset'] as num?)?.toInt() ?? 0).clamp(-500, 500);
    final specials = <int>[];
    if (map['specialIndices'] is List) {
      for (final item in map['specialIndices'] as List) {
        final v = (item as num?)?.toInt();
        if (v != null && v >= 0 && v < episodes.length) specials.add(v);
      }
    }
    final summary = (map['summary'] ?? '已完成标准剧名与集序校准').toString().trim();
    return AiEpisodeCuratePlan(
      canonicalTitle: canonical.isEmpty ? rawSeriesTitle : canonical,
      seasonNumber: season,
      episodeOffset: offset,
      specialIndices: specials,
      summaryZh: summary,
    );
  }

  ///Deterministic + AI-assisted canonical deduplication and quality scoring for
  /// heterogeneous cross-source matches (`4K Remux / DV / HDR > 1080P > 720P`).
  static List<AiRankedSourceMatch> rankCrossSourceMatches(
    String targetTitle,
    List<(CmsSite, CmsVideo)> rawMatches,
  ) {
    int scoreQuality(CmsSite site, CmsVideo v) {
      final blob = '${site.name} ${v.title} ${v.remarks}'.toLowerCase();
      int score = 50;
      if (blob.contains('remux') || blob.contains('原盘')) score += 45;
      if (blob.contains('dolby') || blob.contains('杜比') || blob.contains('dv')) {
        score += 25;
      }
      if (blob.contains('4k') || blob.contains('2160p') || blob.contains('臻彩')) {
        score += 30;
      } else if (blob.contains('1080p') || blob.contains('超清')) {
        score += 15;
      }
      if (blob.contains('hdr')) score += 12;
      if (blob.contains('枪版') || blob.contains('tc') || blob.contains('cam')) {
        score -= 40;
      }
      if (site.isEmby || site.isExternalMediaLibrary) score += 20;
      return score;
    }

    String badgeFor(int score, CmsSite site, CmsVideo v) {
      final blob = '${v.title} ${v.remarks}'.toUpperCase();
      if (blob.contains('REMUX') || blob.contains('原盘')) return '原盘 Remux 优选';
      if (blob.contains('4K') || blob.contains('2160P')) return '4K 超清优选';
      if (site.isEmby || site.isExternalMediaLibrary) return '自有媒体库直连';
      if (score >= 65) return '高码率高清';
      return '标准线路';
    }

    String canonicalOf(String raw) {
      return raw
          .replaceAll(RegExp(r'[\[【(（].*?[\]】)）]'), '')
          .replaceAll(RegExp(r'\s+'), '')
          .toLowerCase();
    }

    final ranked = <AiRankedSourceMatch>[
      for (final (site, video) in rawMatches)
        () {
          final sc = scoreQuality(site, video);
          return AiRankedSourceMatch(
            site: site,
            video: video,
            canonicalKey: canonicalOf(video.title),
            qualityScore: sc,
            badgeLabel: badgeFor(sc, site, video),
          );
        }(),
    ]..sort((a, b) => b.qualityScore.compareTo(a.qualityScore));
    return ranked;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scenario 4: Taste Portrait & Mood / Tonight Sommelier
  // ─────────────────────────────────────────────────────────────────────────

  Future<AiMoodSommelierResult> curateMoodWatchlist({
    required List<String> recentHistoryTitles,
    required List<String> favoriteTitles,
    required List<(CmsSite, CmsVideo)> availableLibrarySnapshot,
    String moodPrompt = '',
    bool isPrivateSpace = false,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    if (!_ai.config.moodCurationEnabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '「观影口味与心情策展」开关已关闭，可在 AI 实验室设置中开启',
      );
    }

    final historySample = recentHistoryTitles.take(15).toList();
    final favSample = favoriteTitles.take(15).toList();
    final catalogTitles = <String>{};
    final lookup = <String, (CmsSite, CmsVideo)>{};
    for (final pair in availableLibrarySnapshot) {
      final clean = pair.$2.title.trim();
      if (clean.isEmpty) continue;
      if (catalogTitles.length < 80) {
        catalogTitles.add(clean);
      }
      lookup.putIfAbsent(clean.toLowerCase(), () => pair);
    }

    final effectiveMood = moodPrompt.trim().isEmpty
        ? '今晚想看一部契合我近期口味的高口碑佳作'
        : moodPrompt.trim();

    final res = await _ai.complete(
      feature: 'ai_sommelier_v1',
      systemPrompt: '你是私人电影策展师。请根据用户的观影历史、收藏与当前心情，分析其观影口味画像，'
          '并优先从「用户自有片库候选单」中挑选 3～5 部最契合的作品（若候选单为空，可推荐公认影史佳作供其在自有源检索）。'
          '仅输出合法 JSON：{"tastePortrait":"60字内温和走心的口味画像","picks":[{"title":"片名","year":"年份","moodTag":"4字氛围标签","reason":"一句定制推荐理由"}]}。'
          '严禁输出任何网址。',
      userPrompt: '近期观看：${historySample.isEmpty ? "暂无" : historySample.join("、")}\n'
          '收藏片单：${favSample.isEmpty ? "暂无" : favSample.join("、")}\n'
          '当前心情/需求：$effectiveMood\n'
          '用户自有片库候选单：${catalogTitles.isEmpty ? "（未预载候选，请给检索片名建议）" : catalogTitles.join("、")}',
      temperature: 0.45,
      maxTokens: 900,
      isPrivateSession: isPrivateSpace,
    );

    final slice = AiService.extractJsonObjectSlice(res.text);
    if (slice == null) {
      throw const AiServiceException(AiErrorCode.malformedResponse, '未能解析私人影单策展结果');
    }
    final map = jsonDecode(slice) as Map<String, dynamic>;
    final portrait = (map['tastePortrait'] ?? '').toString().trim();
    if (AiService.containsForbiddenUrl(portrait)) {
      throw const AiServiceException(AiErrorCode.unsafeOutputRejected, '输出包含不安全链接');
    }
    final picks = <AiCuratedPick>[];
    if (map['picks'] is List) {
      for (final raw in (map['picks'] as List).take(6)) {
        if (raw is! Map) continue;
        final t = (raw['title'] ?? '').toString().trim();
        final y = (raw['year'] ?? '').toString().trim();
        final tag = (raw['moodTag'] ?? '').toString().trim();
        final reason = (raw['reason'] ?? '').toString().trim();
        if (t.isEmpty || AiService.containsForbiddenUrl(reason)) continue;
        (CmsSite, CmsVideo)? hit = lookup[t.toLowerCase()];
        if (hit == null) {
          for (final entry in lookup.entries) {
            if (entry.key.contains(t.toLowerCase()) ||
                t.toLowerCase().contains(entry.key)) {
              hit = entry.value;
              break;
            }
          }
        }
        picks.add(
          AiCuratedPick(
            title: t,
            year: y,
            moodTag: tag,
            reason: reason,
            matchedSite: hit?.$1,
            matchedVideo: hit?.$2,
          ),
        );
      }
    }
    return AiMoodSommelierResult(
      tastePortrait: portrait.isEmpty ? '偏爱叙事细腻、氛围沉浸的口碑佳作。' : portrait,
      picks: picks,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scenario 5: Playback / Subscription AI Diagnostics & Custom Prompt Skills
  // ─────────────────────────────────────────────────────────────────────────

  Future<AiDiagnosticReport> diagnosePlaybackOrSourceIssue({
    required String rawErrorText,
    required String engineName,
    String mediaFormatHint = '',
    bool hasBackupLines = false,
    bool isPrivateSpace = false,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    if (!_ai.config.smartDiagnosticsEnabled) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '「AI 智能排障」开关已关闭，可在 AI 实验室设置中开启',
      );
    }
    final safeError = desensitizeDiagnosticText(rawErrorText);
    final res = await _ai.complete(
      feature: 'ai_diag_v1',
      systemPrompt: '你是 iOS 影音播放器排障专家。请根据脱敏错误摘要与播放内核给出简明诊断。'
          '仅输出 JSON：{"rootCause":"一句话根因解释","steps":["处置建议1","处置建议2"],"actions":["可选动作枚举"]}。'
          'actions 仅允许从 ["switch_to_mpv","switch_to_avplayer","enable_vocal_loudness","switch_backup_line","open_episode_scrape"] 中选择相关项。严禁输出任何网址。',
      userPrompt: '当前内核：$engineName\n'
          '容器/编码提示：${mediaFormatHint.isEmpty ? "未知" : desensitizeDiagnosticText(mediaFormatHint)}\n'
          '是否有备用线路：${hasBackupLines ? "是" : "否"}\n'
          '脱敏异常信息：$safeError',
      modelOverride: _ai.config.effectiveFastModel,
      temperature: 0.15,
      maxTokens: 520,
      isPrivateSession: isPrivateSpace,
    );
    final slice = AiService.extractJsonObjectSlice(res.text);
    if (slice == null) {
      throw const AiServiceException(AiErrorCode.malformedResponse, '未能解析排障报告');
    }
    final map = jsonDecode(slice) as Map<String, dynamic>;
    final rootCause = (map['rootCause'] ?? '流媒体连接或编码兼容性异常').toString().trim();
    final steps = <String>[];
    if (map['steps'] is List) {
      for (final s in (map['steps'] as List).take(4)) {
        final txt = s.toString().trim();
        if (txt.isNotEmpty && !AiService.containsForbiddenUrl(txt)) {
          steps.add(txt);
        }
      }
    }
    final actions = <AiDiagnosticActionId>[];
    if (map['actions'] is List) {
      for (final a in map['actions'] as List) {
        final parsed = AiDiagnosticActionId.fromCode(a?.toString());
        if (parsed != null && !actions.contains(parsed)) {
          actions.add(parsed);
        }
      }
    }
    return AiDiagnosticReport(
      rootCauseZh: rootCause,
      stepsZh: steps.isEmpty ? const ['建议尝试切换播放内核或备用线路后重试。'] : steps,
      suggestedActions: actions,
    );
  }

  /// Executes a user-defined or built-in [AiCustomSkill] safely against local
  /// metadata context.
  Future<String> runCustomSkill({
    required AiCustomSkill skill,
    required String title,
    String year = '',
    String episode = '',
    String overview = '',
    String subtitles = '',
    bool isPrivateSpace = false,
  }) async {
    _ensureReady(isPrivateSpace: isPrivateSpace);
    final rendered = skill.renderPrompt(
      title: title,
      year: year,
      episode: episode,
      overview: overview,
      subtitles: subtitles,
    );
    final res = await _ai.complete(
      feature: 'ai_skill_${skill.id}',
      systemPrompt: '你是温和博学的私人观影助手。请用清晰、优雅的简体中文回答用户的观影技能卡片请求。'
          '严禁输出任何网址、磁力链或虚构播放源。',
      userPrompt: rendered,
      modelOverride: skill.useFastModel ? _ai.config.effectiveFastModel : null,
      temperature: 0.4,
      maxTokens: 800,
      isPrivateSession: isPrivateSpace,
    );
    final clean = res.text.trim();
    if (AiService.containsForbiddenUrl(clean)) {
      throw const AiServiceException(AiErrorCode.unsafeOutputRejected, '技能返回包含不安全链接，已拦截');
    }
    return clean;
  }
}

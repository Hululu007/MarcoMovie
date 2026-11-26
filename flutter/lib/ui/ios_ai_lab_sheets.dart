// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, SelectableText;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ai_lab_features.dart';
import '../core/ai_lab_gate.dart';
import '../core/ai_service.dart';
import '../core/episode_scraper.dart';
import '../core/models.dart';
import 'apple_theme.dart';

/// Scenario 1 UI: In-Player AI Subtitle Studio (`AI 字幕精译与双语对照` + Glossary Lock + Offset Calibration).
Future<void> showIosAiSubtitleStudioSheet(
  BuildContext context, {
  required String seriesTitle,
  required String episodeLabel,
  required int skipIntroSeconds,
  List<String> currentActiveCueLines = const <String>[],
  required Future<void> Function(File generatedSrtFile, String label) onMountTranslatedSrt,
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 字幕精译工作台',
    maxWidth: 500,
    builder: (ctx) => _IosAiSubtitleStudioSheetBody(
      seriesTitle: seriesTitle,
      episodeLabel: episodeLabel,
      skipIntroSeconds: skipIntroSeconds,
      currentActiveCueLines: currentActiveCueLines,
      onMountTranslatedSrt: onMountTranslatedSrt,
    ),
  );
}

class _IosAiSubtitleStudioSheetBody extends StatefulWidget {
  final String seriesTitle;
  final String episodeLabel;
  final int skipIntroSeconds;
  final List<String> currentActiveCueLines;
  final Future<void> Function(File generatedSrtFile, String label)
      onMountTranslatedSrt;

  const _IosAiSubtitleStudioSheetBody({
    required this.seriesTitle,
    required this.episodeLabel,
    required this.skipIntroSeconds,
    required this.currentActiveCueLines,
    required this.onMountTranslatedSrt,
  });

  @override
  State<_IosAiSubtitleStudioSheetBody> createState() =>
      _IosAiSubtitleStudioSheetBodyState();
}

class _IosAiSubtitleStudioSheetBodyState
    extends State<_IosAiSubtitleStudioSheetBody> {
  bool _bilingual = true;
  bool _busy = false;
  String? _status;
  bool _isError = false;
  List<AiSubtitleCue> _loadedCues = const <AiSubtitleCue>[];
  AiSubtitleTranslationResult? _result;
  double _manualOffsetSec = 0.0;

  Future<void> _pickSubtitleFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa'],
      );
      final path = picked?.files.single.path;
      if (path == null || path.isEmpty) return;
      final raw = await File(path).readAsString();
      final cues = AiLabService.parseSubtitleDocument(raw);
      if (!mounted) return;
      setState(() {
        _loadedCues = cues;
        _result = null;
        _isError = cues.isEmpty;
        _status = cues.isEmpty
            ? '未能从所选文件中解析出有效时间轴台词'
            : '已载入 ${cues.length} 条外挂字幕，点击下方按钮开始 AI 精译';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isError = true;
        _status = '读取字幕文件失败：$e';
      });
    }
  }

  Future<void> _pasteSubtitleText() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = (clip?.text ?? '').trim();
    if (raw.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isError = true;
        _status = '剪贴板为空，可先复制 SRT / VTT 文本或选择本地字幕文件';
      });
      return;
    }
    final cues = AiLabService.parseSubtitleDocument(raw);
    if (!mounted) return;
    setState(() {
      _loadedCues = cues;
      _result = null;
      _isError = cues.isEmpty;
      _status = cues.isEmpty
          ? '剪贴板内容不是标准 SRT / VTT / ASS 格式'
          : '已从剪贴板解析 ${cues.length} 条字幕';
    });
  }

  Future<void> _runTranslate() async {
    if (_busy) return;
    var sourceCues = _loadedCues;
    if (sourceCues.isEmpty && widget.currentActiveCueLines.isNotEmpty) {
      sourceCues = <AiSubtitleCue>[
        for (int i = 0; i < widget.currentActiveCueLines.length; i++)
          AiSubtitleCue(
            index: i + 1,
            start: Duration(seconds: i * 3),
            end: Duration(seconds: i * 3 + 3),
            text: widget.currentActiveCueLines[i],
          ),
      ];
    }
    if (sourceCues.isEmpty) {
      setState(() {
        _isError = true;
        _status = '请先导入本地外挂字幕文件（.srt / .vtt / .ass）或粘贴字幕内容';
      });
      return;
    }
    setState(() {
      _busy = true;
      _isError = false;
      _status = '正在提取专有名词表并进行双语上下文精译…';
    });
    try {
      final res = await AiLabService.instance.translateSubtitleCues(
        seriesTitle: widget.seriesTitle,
        episodeLabel: widget.episodeLabel,
        cues: sourceCues,
        bilingual: _bilingual,
      );
      final dir = await getTemporaryDirectory();
      final outFile = File(
        '${dir.path}/marco_ai_sub_${DateTime.now().millisecondsSinceEpoch}.srt',
      );
      final shiftedSrt = AiLabService.serializeToSrt(
        res.cues,
        bilingual: _bilingual,
        offset: Duration(milliseconds: (_manualOffsetSec * 1000).round()),
      );
      await outFile.writeAsString(shiftedSrt, flush: true);
      await widget.onMountTranslatedSrt(
        outFile,
        _bilingual ? 'AI 中外双语精译' : 'AI 简体中文精译',
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _busy = false;
        _isError = false;
        _status = '已完成 ${res.cues.length} 条字幕精译并自动挂载到当前播放器（锁定术语 ${res.glossary.length} 项）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isError = true;
        _status = '$e';
      });
    }
  }

  Future<void> _suggestOffset() async {
    if (_busy || _loadedCues.isEmpty) return;
    setState(() {
      _busy = true;
      _isError = false;
      _status = '正在分析片头时长与首句台词密度…';
    });
    try {
      final res = await AiLabService.instance.suggestSubtitleOffset(
        seriesTitle: widget.seriesTitle,
        firstCues: _loadedCues,
        skipIntroSeconds: widget.skipIntroSeconds,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _manualOffsetSec = res.offsetSeconds;
        _status =
            '建议偏移 ${res.offsetSeconds >= 0 ? "+${res.offsetSeconds.toStringAsFixed(1)}" : res.offsetSeconds.toStringAsFixed(1)} 秒：${res.reasonZh}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _isError = true;
        _status = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg = p.isDark ? const Color(0xFF26262B) : const Color(0xFFF3F4F8);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '针对无中字原盘或生硬机翻字幕，按上下文窗口锁定角色译名并生成双语对照字幕挂载至当前播放器。',
            style: TextStyle(color: p.labelSecondary, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: CupertinoButton(
                  key: const ValueKey('ai-sub-pick-file-btn'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: cardBg,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: _busy ? null : _pickSubtitleFile,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.folder_fill, size: 16, color: p.systemBlue),
                      const SizedBox(width: 6),
                      Text(
                        '导入 .srt / .ass',
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: CupertinoButton(
                  key: const ValueKey('ai-sub-paste-btn'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: cardBg,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: _busy ? null : _pasteSubtitleText,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.doc_on_clipboard_fill,
                          size: 16, color: p.systemBlue),
                      const SizedBox(width: 6),
                      Text(
                        '从剪贴板载入',
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          CupertinoSlidingSegmentedControl<bool>(
            groupValue: _bilingual,
            children: const {
              true: Padding(
                padding: EdgeInsets.symmetric(vertical: 7),
                child: Text('中外双语对照', style: TextStyle(fontSize: 13)),
              ),
              false: Padding(
                padding: EdgeInsets.symmetric(vertical: 7),
                child: Text('仅简体中文', style: TextStyle(fontSize: 13)),
              ),
            },
            onValueChanged: (v) {
              if (v != null) setState(() => _bilingual = v);
            },
          ),
          if (_loadedCues.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '时间轴微调：${_manualOffsetSec >= 0 ? "+${_manualOffsetSec.toStringAsFixed(1)}" : _manualOffsetSec.toStringAsFixed(1)}s',
                    style: TextStyle(
                      color: p.labelPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(32, 28),
                  onPressed: _busy ? null : () => setState(() => _manualOffsetSec -= 0.5),
                  child: const Text('-0.5s', style: TextStyle(fontSize: 12.5)),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(32, 28),
                  onPressed: _busy ? null : () => setState(() => _manualOffsetSec += 0.5),
                  child: const Text('+0.5s', style: TextStyle(fontSize: 12.5)),
                ),
                CupertinoButton(
                  key: const ValueKey('ai-sub-suggest-offset-btn'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(32, 28),
                  onPressed: _busy ? null : _suggestOffset,
                  child: const Text('AI 对轴建议', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isError
                    ? AppleColors.systemRed.withValues(alpha: 0.14)
                    : p.systemBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _status!,
                style: TextStyle(
                  color: _isError ? AppleColors.systemRed : p.labelPrimary,
                  fontSize: 12.8,
                  height: 1.42,
                ),
              ),
            ),
          ],
          if (_result != null && _result!.glossary.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '本集锁定角色与专有名词表',
              style: TextStyle(
                color: p.labelSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in _result!.glossary.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${e.key} → ${e.value}',
                      style: TextStyle(color: p.labelPrimary, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 46,
            child: CupertinoButton(
              key: const ValueKey('ai-sub-translate-mount-btn'),
              color: AppleColors.systemBlue,
              borderRadius: BorderRadius.circular(14),
              onPressed: _busy ? null : _runTranslate,
              child: _busy
                  ? const CupertinoActivityIndicator(color: Colors.white)
                  : const Text(
                      '开始精译并挂载至播放器',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scenario 2 UI: Zero-Spoiler Episode Recap & Character Guide (`防剧透观影伴侣`).
Future<void> showIosAiEpisodeCompanionSheet(
  BuildContext context, {
  required String title,
  String year = '',
  required int currentEpisodeNumber,
  int seasonNumber = 1,
  String overview = '',
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 防剧透观影伴侣',
    maxWidth: 500,
    builder: (_) => _IosAiEpisodeCompanionBody(
      title: title,
      year: year,
      currentEpisodeNumber: currentEpisodeNumber,
      seasonNumber: seasonNumber,
      overview: overview,
    ),
  );
}

class _IosAiEpisodeCompanionBody extends StatefulWidget {
  final String title;
  final String year;
  final int currentEpisodeNumber;
  final int seasonNumber;
  final String overview;

  const _IosAiEpisodeCompanionBody({
    required this.title,
    required this.year,
    required this.currentEpisodeNumber,
    required this.seasonNumber,
    required this.overview,
  });

  @override
  State<_IosAiEpisodeCompanionBody> createState() =>
      _IosAiEpisodeCompanionBodyState();
}

class _IosAiEpisodeCompanionBodyState extends State<_IosAiEpisodeCompanionBody> {
  bool _postWatchMode = false;
  bool _loading = true;
  String? _error;
  AiEpisodeCompanionResult? _data;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await AiLabService.instance.generateEpisodeCompanion(
        title: widget.title,
        year: widget.year,
        currentEpisodeNumber: widget.currentEpisodeNumber,
        seasonNumber: widget.seasonNumber,
        overview: widget.overview,
        includeCurrentEpisodePostWatch: _postWatchMode,
      );
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg = p.isDark ? const Color(0xFF26262B) : const Color(0xFFF3F4F8);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoSlidingSegmentedControl<bool>(
            groupValue: _postWatchMode,
            children: {
              false: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(
                  '看前零剧透（截至第 ${widget.currentEpisodeNumber > 1 ? widget.currentEpisodeNumber - 1 : 1} 集）',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              true: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(
                  '已看完第 ${widget.currentEpisodeNumber} 集复盘',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            },
            onValueChanged: (v) {
              if (v != null && v != _postWatchMode) {
                setState(() => _postWatchMode = v);
                unawaited(_load());
              }
            },
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: CupertinoActivityIndicator(radius: 12)),
            )
          else if (_error != null)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppleColors.systemRed.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: AppleColors.systemRed, fontSize: 13),
              ),
            )
          else if (_data != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '前情提要 · ${_data!.boundaryLabel}',
                    style: TextStyle(
                      color: p.systemBlue,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _data!.recap,
                    key: const ValueKey('ai-companion-recap-text'),
                    style: TextStyle(
                      color: p.labelPrimary,
                      fontSize: 14,
                      height: 1.52,
                    ),
                  ),
                ],
              ),
            ),
            if (_data!.characters.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                '登场人物与阵营关系（无后续剧透）',
                style: TextStyle(
                  color: p.labelSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              for (final ch in _data!.characters)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              ch.name,
                              style: TextStyle(
                                color: p.labelPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (ch.factionOrRole.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: p.systemBlue.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  ch.factionOrRole,
                                  style: TextStyle(
                                    color: p.systemBlue,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ch.summary,
                          style: TextStyle(
                            color: p.labelSecondary,
                            fontSize: 12.8,
                            height: 1.42,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (_data!.trivia.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppleColors.systemPurple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  '世界观与幕后看点：${_data!.trivia}',
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 12.8,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Scenario 4 UI: Taste Portrait & Mood Sommelier (`观影口味画像与「今晚看什么」`).
Future<void> showIosAiMoodSommelierSheet(
  BuildContext context, {
  required List<String> recentHistoryTitles,
  required List<String> favoriteTitles,
  required List<(CmsSite, CmsVideo)> availableLibrarySnapshot,
  required void Function(AiCuratedPick pick) onSelectPick,
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 今晚看什么 · 私人策展',
    maxWidth: 500,
    builder: (_) => _IosAiMoodSommelierBody(
      recentHistoryTitles: recentHistoryTitles,
      favoriteTitles: favoriteTitles,
      availableLibrarySnapshot: availableLibrarySnapshot,
      onSelectPick: onSelectPick,
    ),
  );
}

class _IosAiMoodSommelierBody extends StatefulWidget {
  final List<String> recentHistoryTitles;
  final List<String> favoriteTitles;
  final List<(CmsSite, CmsVideo)> availableLibrarySnapshot;
  final void Function(AiCuratedPick pick) onSelectPick;

  const _IosAiMoodSommelierBody({
    required this.recentHistoryTitles,
    required this.favoriteTitles,
    required this.availableLibrarySnapshot,
    required this.onSelectPick,
  });

  @override
  State<_IosAiMoodSommelierBody> createState() =>
      _IosAiMoodSommelierBodyState();
}

class _IosAiMoodSommelierBodyState extends State<_IosAiMoodSommelierBody> {
  static const List<String> _moodPresets = <String>[
    '今晚契合我口味的佳作',
    '周末雨夜温暖治愈电影',
    '90分钟内紧凑悬疑反转',
    '视听震撼硬核科幻大片',
    '轻松解压下饭高分喜剧',
  ];

  final TextEditingController _moodCtrl = TextEditingController();
  bool _loading = true;
  String? _error;
  AiMoodSommelierResult? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_curate(''));
  }

  @override
  void dispose() {
    _moodCtrl.dispose();
    super.dispose();
  }

  Future<void> _curate(String mood) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await AiLabService.instance.curateMoodWatchlist(
        recentHistoryTitles: widget.recentHistoryTitles,
        favoriteTitles: widget.favoriteTitles,
        availableLibrarySnapshot: widget.availableLibrarySnapshot,
        moodPrompt: mood,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg = p.isDark ? const Color(0xFF26262B) : const Color(0xFFF3F4F8);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final preset in _moodPresets)
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _moodCtrl.text = preset;
                    unawaited(_curate(preset));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      preset,
                      style: TextStyle(
                        color: p.labelPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CupertinoTextField(
                  key: const ValueKey('ai-sommelier-mood-field'),
                  controller: _moodCtrl,
                  placeholder: '输入你想看的氛围、时长或情绪…',
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                key: const ValueKey('ai-sommelier-run-btn'),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                color: AppleColors.systemBlue,
                borderRadius: BorderRadius.circular(11),
                onPressed: _loading ? null : () => _curate(_moodCtrl.text),
                child: const Text(
                  '策展',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 34),
              child: Center(child: CupertinoActivityIndicator(radius: 12)),
            )
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: AppleColors.systemRed))
          else if (_result != null) ...[
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: AppleColors.systemPurple.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '你的观影画像：${_result!.tastePortrait}',
                key: const ValueKey('ai-sommelier-portrait-text'),
                style: TextStyle(
                  color: p.labelPrimary,
                  fontSize: 13.2,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final pick in _result!.picks)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onSelectPick(pick);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      '《${pick.title}》${pick.year.isNotEmpty ? " (${pick.year})" : ""}',
                                      style: TextStyle(
                                        color: p.labelPrimary,
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (pick.moodTag.isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: p.systemBlue.withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        pick.moodTag,
                                        style: TextStyle(
                                          color: p.systemBlue,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                pick.reason,
                                style: TextStyle(
                                  color: p.labelSecondary,
                                  fontSize: 12.8,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          pick.isPlayableInLibrary
                              ? CupertinoIcons.play_circle_fill
                              : CupertinoIcons.search,
                          color: p.systemBlue,
                          size: 22,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Scenario 5 UI: Playback & Source Smart Diagnostics + Custom Skill Runner.
Future<void> showIosAiDiagnosticsSheet(
  BuildContext context, {
  required String rawErrorText,
  required String engineName,
  String mediaFormatHint = '',
  bool hasBackupLines = false,
  required void Function(AiDiagnosticActionId action) onExecuteAction,
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 播放与源智能排障',
    maxWidth: 480,
    builder: (ctx) => FutureBuilder<AiDiagnosticReport>(
      future: AiLabService.instance.diagnosePlaybackOrSourceIssue(
        rawErrorText: rawErrorText,
        engineName: engineName,
        mediaFormatHint: mediaFormatHint,
        hasBackupLines: hasBackupLines,
      ),
      builder: (ctx, snap) {
        final p = ApplePalette.of(ctx);
        final cardBg =
            p.isDark ? const Color(0xFF26262B) : const Color(0xFFF3F4F8);
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(child: CupertinoActivityIndicator(radius: 12)),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '排障分析未完成：${snap.error}',
              style: const TextStyle(color: AppleColors.systemRed, fontSize: 13.5),
            ),
          );
        }
        final report = snap.data!;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '可能原因',
                      style: TextStyle(
                        color: p.systemBlue,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      report.rootCauseZh,
                      key: const ValueKey('ai-diag-root-cause'),
                      style: TextStyle(
                        color: p.labelPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (int i = 0; i < report.stepsZh.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${i + 1}. ${report.stepsZh[i]}',
                          style: TextStyle(
                            color: p.labelSecondary,
                            fontSize: 13,
                            height: 1.42,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (report.suggestedActions.isNotEmpty) ...[
                const SizedBox(height: 14),
                for (final act in report.suggestedActions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CupertinoButton(
                      color: AppleColors.systemBlue,
                      borderRadius: BorderRadius.circular(13),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onExecuteAction(act);
                      },
                      child: Text(
                        act.labelZh,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

/// Runs a selected [AiCustomSkill] and displays the result in a clean sheet.
Future<void> showIosAiCustomSkillOutputSheet(
  BuildContext context, {
  required AiCustomSkill skill,
  required String title,
  String year = '',
  String episode = '',
  String overview = '',
  String subtitles = '',
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: skill.name,
    maxWidth: 490,
    builder: (ctx) => FutureBuilder<String>(
      future: AiLabService.instance.runCustomSkill(
        skill: skill,
        title: title,
        year: year,
        episode: episode,
        overview: overview,
        subtitles: subtitles,
      ),
      builder: (ctx, snap) {
        final p = ApplePalette.of(ctx);
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(child: CupertinoActivityIndicator(radius: 12)),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '执行失败：${snap.error}',
              style: const TextStyle(color: AppleColors.systemRed, fontSize: 13.5),
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: SelectableText(
            snap.data ?? '',
            key: const ValueKey('ai-custom-skill-output'),
            style: TextStyle(
              color: p.labelPrimary,
              fontSize: 14.2,
              height: 1.58,
            ),
          ),
        );
      },
    ),
  );
}

/// Scenario 3 + Hub UI on DetailScreen: AI Hub offering Zero-Spoiler Companion,
/// Messy Episode Curating (`EpisodeScrapeOverride`), and Custom Skills.
Future<void> showIosDetailAiLabSheet(
  BuildContext context, {
  required String title,
  required String year,
  required String overview,
  required int currentEpisodeNumber,
  required List<CmsEpisode> currentLineEpisodes,
  required Future<void> Function(EpisodeScrapeOverride override, String summary)
      onApplyEpisodeOverride,
}) async {
  final skills = AiService.instance.config.effectiveSkills
      .where((s) => s.target.showsInDetail)
      .toList();

  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 实验室 · 影片助手',
    maxWidth: 480,
    builder: (ctx) {
      final p = ApplePalette.of(ctx);
      final cardBg = p.isDark ? const Color(0xFF26262B) : const Color(0xFFF3F4F8);
      bool curating = false;
      String? curateNotice;
      return StatefulBuilder(
        builder: (ctx, setModalState) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHubActionTile(
                p: p,
                cardBg: cardBg,
                icon: CupertinoIcons.book_fill,
                iconColor: AppleColors.systemBlue,
                title: '零剧透前情提要与人物速览',
                subtitle: '严格锁定截至第 $currentEpisodeNumber 集进度，不泄露后续反转',
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(
                    showIosAiEpisodeCompanionSheet(
                      context,
                      title: title,
                      year: year,
                      currentEpisodeNumber: currentEpisodeNumber,
                      overview: overview,
                    ),
                  );
                },
              ),
              if (currentLineEpisodes.length > 1) ...[
                const SizedBox(height: 10),
                _buildHubActionTile(
                  p: p,
                  cardBg: cardBg,
                  icon: CupertinoIcons.list_number,
                  iconColor: AppleColors.systemPurple,
                  title: curating ? '正在智能识别正片集序…' : '网盘 / 杂乱剧集智能编排校准',
                  subtitle: curateNotice ??
                      '自动识别 SP/花絮与集号偏移，一键生成刮削校准规则',
                  onTap: curating
                      ? null
                      : () async {
                          setModalState(() => curating = true);
                          try {
                            final plan =
                                await AiLabService.instance.curateMessyEpisodes(
                              rawSeriesTitle: title,
                              year: year,
                              episodes: currentLineEpisodes,
                            );
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            await onApplyEpisodeOverride(
                              plan.toScrapeOverride(),
                              plan.summaryZh,
                            );
                          } catch (e) {
                            if (ctx.mounted) {
                              setModalState(() {
                                curating = false;
                                curateNotice = '编排失败：$e';
                              });
                            }
                          }
                        },
                ),
              ],
              if (skills.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  '扩展 AI 技能卡',
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                for (final skill in skills)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildHubActionTile(
                      p: p,
                      cardBg: cardBg,
                      icon: CupertinoIcons.sparkles,
                      iconColor: AppleColors.systemOrange,
                      title: skill.name,
                      subtitle: skill.useFastModel ? '轻量极速模型' : '主力深度模型',
                      onTap: () {
                        Navigator.of(ctx).pop();
                        unawaited(
                          showIosAiCustomSkillOutputSheet(
                            context,
                            skill: skill,
                            title: title,
                            year: year,
                            episode: '第 $currentEpisodeNumber 集',
                            overview: overview,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

Widget _buildHubActionTile({
  required ApplePalette p,
  required Color cardBg,
  required IconData icon,
  required Color iconColor,
  required String title,
  required String subtitle,
  required VoidCallback? onTap,
}) {
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconColor,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 12.2,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            CupertinoIcons.chevron_right,
            color: p.labelTertiary,
            size: 15,
          ),
        ],
      ),
    ),
  );
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, SelectableText;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ai_danmu_matcher.dart';
import '../core/ai_lab_features.dart';
import '../core/ai_lab_gate.dart';
import '../core/ai_service.dart';
import '../core/danmu/danmu_prefs.dart';
import '../core/danmu/provider.dart';
import '../core/episode_scraper.dart';
import '../core/models.dart';
import 'apple_theme.dart';

/// Persisted per-film AI Subtitle Studio session state separating mounted
/// on-screen subtitle overlay state (`cues`, `overlayActive`) from unmounted
/// studio workspace drafts (`draftCues`, `draftMatchesOverlay`) so merely
/// importing a file never mutates the player screen while reopening preserves
/// cue #121+ continuation progress, locked glossary, and manual offset.
@immutable
class AiSubtitleSessionState {
  final List<AiSubtitleCue> cues;
  final Map<String, String> glossary;
  final bool bilingual;
  final Duration offset;
  final String label;
  final bool overlayActive;
  final bool liveEmbeddedTranslateEnabled;
  final List<AiSubtitleCue> draftCues;
  final Map<String, String> draftGlossary;
  final Duration draftOffset;
  final bool draftMatchesOverlay;

  const AiSubtitleSessionState({
    this.cues = const <AiSubtitleCue>[],
    this.glossary = const <String, String>{},
    this.bilingual = true,
    this.offset = Duration.zero,
    this.label = '',
    this.overlayActive = false,
    this.liveEmbeddedTranslateEnabled = false,
    this.draftCues = const <AiSubtitleCue>[],
    this.draftGlossary = const <String, String>{},
    this.draftOffset = Duration.zero,
    this.draftMatchesOverlay = false,
  });

  int get translatedCount =>
      cues.where((c) => c.translatedText.trim().isNotEmpty).length;
  int get totalCount => cues.length;
  bool get hasUntranslatedRemainder =>
      cues.isNotEmpty && translatedCount < cues.length;
  int get nextUntranslatedIndex =>
      cues.indexWhere((c) => c.translatedText.trim().isEmpty);
}

/// Scenario 1 UI: In-Player AI Subtitle Studio (`AI 实时双语字幕 & 外挂精译工作台`).
///
/// Renders translated cues directly onto `PlayerScreen`'s universal
/// `AiSubtitleOverlay` (working identically across `AVPlayer`, `MDK Metal`, and
/// `MPV` without restarting the engine), and supports one-tap live bilingual
/// translation of embedded subtitle streams.
Future<void> showIosAiSubtitleStudioSheet(
  BuildContext context, {
  required String seriesTitle,
  required String episodeLabel,
  required int skipIntroSeconds,
  Duration currentPlaybackPosition = Duration.zero,
  List<String> currentActiveCueLines = const <String>[],
  List<AiSubtitleCue> currentActiveCues = const <AiSubtitleCue>[],
  AiSubtitleSessionState? initialSession,
  ValueChanged<AiSubtitleSessionState>? onSessionChanged,
  int Function()? getOverlayMountGen,
  bool liveEmbeddedTranslateEnabled = false,
  ValueChanged<bool>? onToggleLiveEmbeddedTranslate,
  bool hasActiveSubtitleOverlay = false,
  VoidCallback? onClearSubtitleOverlay,
  Future<void> Function(
    List<AiSubtitleCue> cues, {
    required bool bilingual,
    required Duration offset,
    required String label,
  })? onApplySubtitleOverlay,
  Future<void> Function(File generatedSrtFile, String label)?
      onMountTranslatedSrt,
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 双语字幕工作台',
    maxWidth: 500,
    builder: (ctx) => _IosAiSubtitleStudioSheetBody(
      seriesTitle: seriesTitle,
      episodeLabel: episodeLabel,
      skipIntroSeconds: skipIntroSeconds,
      currentPlaybackPosition: currentPlaybackPosition,
      currentActiveCueLines: currentActiveCueLines,
      currentActiveCues: currentActiveCues,
      initialSession: initialSession,
      onSessionChanged: onSessionChanged,
      getOverlayMountGen: getOverlayMountGen,
      liveEmbeddedTranslateEnabled: liveEmbeddedTranslateEnabled,
      onToggleLiveEmbeddedTranslate: onToggleLiveEmbeddedTranslate,
      hasActiveSubtitleOverlay: hasActiveSubtitleOverlay,
      onClearSubtitleOverlay: onClearSubtitleOverlay,
      onApplySubtitleOverlay: onApplySubtitleOverlay,
      onMountTranslatedSrt: onMountTranslatedSrt,
    ),
  );
}

class _IosAiSubtitleStudioSheetBody extends StatefulWidget {
  final String seriesTitle;
  final String episodeLabel;
  final int skipIntroSeconds;
  final Duration currentPlaybackPosition;
  final List<String> currentActiveCueLines;
  final List<AiSubtitleCue> currentActiveCues;
  final AiSubtitleSessionState? initialSession;
  final ValueChanged<AiSubtitleSessionState>? onSessionChanged;
  final int Function()? getOverlayMountGen;
  final bool liveEmbeddedTranslateEnabled;
  final ValueChanged<bool>? onToggleLiveEmbeddedTranslate;
  final bool hasActiveSubtitleOverlay;
  final VoidCallback? onClearSubtitleOverlay;
  final Future<void> Function(
    List<AiSubtitleCue> cues, {
    required bool bilingual,
    required Duration offset,
    required String label,
  })? onApplySubtitleOverlay;
  final Future<void> Function(File generatedSrtFile, String label)?
      onMountTranslatedSrt;

  const _IosAiSubtitleStudioSheetBody({
    required this.seriesTitle,
    required this.episodeLabel,
    required this.skipIntroSeconds,
    required this.currentPlaybackPosition,
    required this.currentActiveCueLines,
    required this.currentActiveCues,
    required this.initialSession,
    required this.onSessionChanged,
    required this.getOverlayMountGen,
    required this.liveEmbeddedTranslateEnabled,
    required this.onToggleLiveEmbeddedTranslate,
    required this.hasActiveSubtitleOverlay,
    required this.onClearSubtitleOverlay,
    required this.onApplySubtitleOverlay,
    required this.onMountTranslatedSrt,
  });

  @override
  State<_IosAiSubtitleStudioSheetBody> createState() =>
      _IosAiSubtitleStudioSheetBodyState();
}

class _IosAiSubtitleStudioSheetBodyState
    extends State<_IosAiSubtitleStudioSheetBody> {
  bool _bilingual = true;
  late bool _liveEnabled;
  late bool _overlayActive;
  bool _draftMatchesOverlay = false;
  bool _busy = false;
  int? _busyOpGen;
  int _studioOpGen = 0;
  bool _disposed = false;
  String? _status;
  bool _isError = false;
  List<AiSubtitleCue> _loadedCues = const <AiSubtitleCue>[];
  List<AiSubtitleCue> _mountedCues = const <AiSubtitleCue>[];
  Map<String, String> _mountedGlossary = const <String, String>{};
  double _mountedOffsetSec = 0.0;
  AiSubtitleTranslationResult? _result;
  double _manualOffsetSec = 0.0;
  String _overlayLabel = '';

  void _releaseBusyFor(int opGen) {
    if (!mounted || _disposed) return;
    if (_busy && _busyOpGen == opGen) {
      setState(() {
        _busy = false;
        _busyOpGen = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final session = widget.initialSession;
    _liveEnabled =
        session?.liveEmbeddedTranslateEnabled ??
        widget.liveEmbeddedTranslateEnabled;
    _overlayActive = session?.overlayActive ?? widget.hasActiveSubtitleOverlay;
    if (session != null) {
      _bilingual = session.bilingual;
      _overlayLabel = session.label;
      if (session.overlayActive && session.cues.isNotEmpty) {
        _mountedCues = List<AiSubtitleCue>.of(session.cues);
        _mountedGlossary = Map<String, String>.of(session.glossary);
        _mountedOffsetSec = session.offset.inMilliseconds / 1000.0;
      }
      final restoreUnmountedDraft =
          session.draftCues.isNotEmpty && !session.draftMatchesOverlay;
      if (restoreUnmountedDraft) {
        _draftMatchesOverlay = false;
        _manualOffsetSec = session.draftOffset.inMilliseconds / 1000.0;
        _loadedCues = List<AiSubtitleCue>.of(session.draftCues);
        _status =
            '已恢复未挂载草稿：共 ${_loadedCues.length} 条外挂字幕，点击下方按钮可挂载或精译';
      } else if (session.cues.isNotEmpty) {
        _draftMatchesOverlay = session.overlayActive;
        _manualOffsetSec = session.offset.inMilliseconds / 1000.0;
        _loadedCues = List<AiSubtitleCue>.of(session.cues);
        final translatedCount = session.translatedCount;
        if (translatedCount > 0 || session.glossary.isNotEmpty) {
          _result = AiSubtitleTranslationResult(
            cues: List<AiSubtitleCue>.unmodifiable(_loadedCues),
            glossary: Map<String, String>.unmodifiable(session.glossary),
            bilingual: _bilingual,
            srtContent: '',
            translatedCount: translatedCount,
            totalCount: _loadedCues.length,
          );
          if (_result!.hasUntranslatedRemainder) {
            final nextIdx = session.nextUntranslatedIndex;
            _status =
                '已恢复当前影片进度：已精译 $translatedCount/${_loadedCues.length} 条（锁定术语 ${session.glossary.length} 项），可自第 ${nextIdx >= 0 ? nextIdx + 1 : translatedCount + 1} 条继续精译或微调时间轴';
          } else {
            _status =
                '已恢复当前影片精译字幕：共 ${_loadedCues.length} 条（锁定术语 ${session.glossary.length} 项），可继续微调时间轴';
          }
        } else {
          _status = '已恢复当前影片外挂字幕：共 ${_loadedCues.length} 条';
        }
      } else if (session.draftCues.isNotEmpty) {
        _draftMatchesOverlay = false;
        _manualOffsetSec = session.draftOffset.inMilliseconds / 1000.0;
        _loadedCues = List<AiSubtitleCue>.of(session.draftCues);
        _status = '已恢复未挂载草稿：共 ${_loadedCues.length} 条外挂字幕';
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _studioOpGen++;
    super.dispose();
  }

  void _emitSessionState() {
    final activeDraftCues =
        List<AiSubtitleCue>.unmodifiable(_result?.cues ?? _loadedCues);
    final activeDraftGlossary = Map<String, String>.unmodifiable(
      _result?.glossary ?? const <String, String>{},
    );
    final currentOffset =
        Duration(milliseconds: (_manualOffsetSec * 1000).round());
    final mountedCues = _overlayActive
        ? (_draftMatchesOverlay
            ? activeDraftCues
            : List<AiSubtitleCue>.unmodifiable(_mountedCues))
        : const <AiSubtitleCue>[];
    final mountedGlossary = _overlayActive
        ? (_draftMatchesOverlay
            ? activeDraftGlossary
            : Map<String, String>.unmodifiable(_mountedGlossary))
        : const <String, String>{};
    final mountedOffset = _overlayActive
        ? (_draftMatchesOverlay
            ? currentOffset
            : Duration(milliseconds: (_mountedOffsetSec * 1000).round()))
        : Duration.zero;
    widget.onSessionChanged?.call(
      AiSubtitleSessionState(
        cues: mountedCues,
        glossary: mountedGlossary,
        bilingual: _bilingual,
        offset: mountedOffset,
        label: _overlayLabel,
        overlayActive: _overlayActive,
        liveEmbeddedTranslateEnabled: _liveEnabled,
        draftCues: activeDraftCues,
        draftGlossary: activeDraftGlossary,
        draftOffset: currentOffset,
        draftMatchesOverlay: _overlayActive && _draftMatchesOverlay,
      ),
    );
  }

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
      // Importing a file only updates the studio draft and cancels any stale
      // in-flight translation without altering currently mounted screen cues.
      _studioOpGen++;
      setState(() {
        _busy = false;
        _busyOpGen = null;
        _loadedCues = cues;
        _result = null;
        _draftMatchesOverlay = false;
        _isError = cues.isEmpty;
        _status = cues.isEmpty
            ? '未能从所选文件中解析出有效时间轴台词'
            : '已载入 ${cues.length} 条外挂字幕草稿（尚未改变画面字幕），点击下方按钮即可精译或直接挂载';
      });
      _emitSessionState();
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
    _studioOpGen++;
    setState(() {
      _busy = false;
      _busyOpGen = null;
      _loadedCues = cues;
      _result = null;
      _draftMatchesOverlay = false;
      _isError = cues.isEmpty;
      _status = cues.isEmpty
          ? '剪贴板内容不是标准 SRT / VTT / ASS 时间轴格式'
          : '已从剪贴板解析 ${cues.length} 条字幕草稿（尚未改变画面字幕）';
    });
    _emitSessionState();
  }

  Future<void> _applyDirectMountOnly() async {
    if (_loadedCues.isEmpty || widget.onApplySubtitleOverlay == null) return;
    final opGen = ++_studioOpGen;
    final offset = Duration(milliseconds: (_manualOffsetSec * 1000).round());
    final nextLabel = '外挂原文字幕';
    await widget.onApplySubtitleOverlay!(
      _loadedCues,
      bilingual: _bilingual,
      offset: offset,
      label: nextLabel,
    );
    if (!mounted || _disposed || opGen != _studioOpGen) return;
    setState(() {
      _busy = false;
      _busyOpGen = null;
      _overlayLabel = nextLabel;
      _mountedCues = List<AiSubtitleCue>.of(_loadedCues);
      _mountedGlossary = const <String, String>{};
      _mountedOffsetSec = _manualOffsetSec;
      _overlayActive = true;
      _draftMatchesOverlay = true;
      _isError = false;
      _status = '已将 ${_loadedCues.length} 条外挂字幕直接挂载显示到当前播放器画面';
    });
    _emitSessionState();
  }

  Future<void> _runTranslate({bool continueRemaining = false}) async {
    if (_busy) return;
    var sourceCues = (_result != null && continueRemaining)
        ? List<AiSubtitleCue>.of(_result!.cues)
        : _loadedCues;
    var usedLiveEmbeddedAnchor = false;
    if (sourceCues.isEmpty && widget.currentActiveCues.isNotEmpty) {
      sourceCues = List<AiSubtitleCue>.of(widget.currentActiveCues);
    } else if (sourceCues.isEmpty && widget.currentActiveCueLines.isNotEmpty) {
      final joined = widget.currentActiveCueLines
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join('\n');
      if (joined.isNotEmpty) {
        final anchor = widget.currentPlaybackPosition;
        final start = anchor > const Duration(seconds: 1)
            ? anchor - const Duration(seconds: 1)
            : Duration.zero;
        final end = anchor + const Duration(seconds: 6);
        sourceCues = <AiSubtitleCue>[
          AiSubtitleCue(
            index: 1,
            start: start,
            end: end,
            text: joined,
          ),
        ];
        usedLiveEmbeddedAnchor = true;
      }
    }
    if (sourceCues.isEmpty) {
      if (widget.onToggleLiveEmbeddedTranslate != null && !_liveEnabled) {
        setState(() {
          _liveEnabled = true;
          _isError = false;
          _status = '已为您开启「内封字幕实时双语翻译」——播放外语内封字幕片源时将自动在画面底部叠层显示中文译文。若片源无内封字幕，请导入本地 .srt / .ass 文件。';
        });
        widget.onToggleLiveEmbeddedTranslate!(true);
        _emitSessionState();
        return;
      }
      setState(() {
        _isError = true;
        _status = '请先导入本地外挂字幕文件（.srt / .vtt / .ass）、粘贴字幕文本，或开启上方「内封字幕实时双语翻译」';
      });
      return;
    }
    var startIndex = 0;
    if (continueRemaining) {
      final firstUntranslated =
          sourceCues.indexWhere((c) => c.translatedText.trim().isEmpty);
      if (firstUntranslated < 0) return;
      startIndex = firstUntranslated;
    }
    final opGen = ++_studioOpGen;
    final capturedMountGen = widget.getOverlayMountGen?.call();
    bool isOperationCancelled() =>
        !mounted ||
        _disposed ||
        opGen != _studioOpGen ||
        (capturedMountGen != null &&
            widget.getOverlayMountGen?.call() != capturedMountGen);

    setState(() {
      _busy = true;
      _busyOpGen = opGen;
      _isError = false;
      _status = continueRemaining
          ? '正在继续精译剩余字幕（自第 ${startIndex + 1} 条起），完整时间轴保持连续…'
          : '正在提取专有名词表并进行双语上下文精译（保留全片完整时间轴）…';
    });
    try {
      final res = await AiLabService.instance.translateSubtitleCues(
        seriesTitle: widget.seriesTitle,
        episodeLabel: widget.episodeLabel,
        cues: sourceCues,
        bilingual: _bilingual,
        existingGlossary: continueRemaining
            ? (_result?.glossary ?? const <String, String>{})
            : const <String, String>{},
        startIndex: startIndex,
      );
      if (isOperationCancelled()) return;
      final offset = Duration(milliseconds: (_manualOffsetSec * 1000).round());
      final label = _bilingual ? 'AI 中外双语精译' : 'AI 简体中文精译';
      if (usedLiveEmbeddedAnchor &&
          widget.onToggleLiveEmbeddedTranslate != null &&
          !_liveEnabled) {
        _liveEnabled = true;
        widget.onToggleLiveEmbeddedTranslate!(true);
      }
      if (widget.onApplySubtitleOverlay != null) {
        await widget.onApplySubtitleOverlay!(
          res.cues,
          bilingual: _bilingual,
          offset: offset,
          label: label,
        );
      }
      if (!mounted || _disposed || opGen != _studioOpGen) return;
      if (widget.onMountTranslatedSrt != null) {
        final dir = await getTemporaryDirectory();
        if (!mounted || _disposed || opGen != _studioOpGen) return;
        final outFile = File(
          '${dir.path}/marco_ai_sub_${DateTime.now().millisecondsSinceEpoch}.srt',
        );
        final shiftedSrt = AiLabService.serializeToSrt(
          res.cues,
          bilingual: _bilingual,
          offset: offset,
        );
        await outFile.writeAsString(shiftedSrt, flush: true);
        if (!mounted || _disposed || opGen != _studioOpGen) return;
        await widget.onMountTranslatedSrt!(outFile, label);
      }
      if (!mounted || _disposed || opGen != _studioOpGen) return;
      setState(() {
        _overlayLabel = label;
        _loadedCues = List<AiSubtitleCue>.of(res.cues);
        _mountedCues = List<AiSubtitleCue>.of(res.cues);
        _mountedGlossary = Map<String, String>.of(res.glossary);
        _mountedOffsetSec = _manualOffsetSec;
        _result = res;
        _overlayActive = true;
        _draftMatchesOverlay = true;
        _busy = false;
        _busyOpGen = null;
        _isError = false;
        _status = res.hasUntranslatedRemainder
            ? '已精译 ${res.translatedCount}/${res.totalCount} 条并挂载全片完整 ${res.totalCount} 条时间轴（未译段将按原文继续显示，锁定术语 ${res.glossary.length} 项）'
            : (usedLiveEmbeddedAnchor
                  ? '已按当前时间轴精译实时台词并同步开启后续内封字幕双语直显（锁定术语 ${res.glossary.length} 项）'
                  : '已完成全部 ${res.totalCount} 条字幕精译并直接在播放器画面启用显示（锁定术语 ${res.glossary.length} 项）');
      });
      _emitSessionState();
    } catch (e) {
      if (!mounted || _disposed || opGen != _studioOpGen) return;
      setState(() {
        _busy = false;
        _busyOpGen = null;
        _isError = true;
        _status = '$e';
      });
    } finally {
      _releaseBusyFor(opGen);
    }
  }

  Future<void> _updateOffset(double delta) async {
    setState(() => _manualOffsetSec += delta);
    final activeCues = _result?.cues ?? (_loadedCues.isNotEmpty ? _loadedCues : null);
    final label = _overlayLabel.isNotEmpty
        ? _overlayLabel
        : (_bilingual ? 'AI 中外双语精译' : 'AI 简体中文精译');
    if (activeCues != null &&
        activeCues.isNotEmpty &&
        _overlayActive &&
        _draftMatchesOverlay &&
        widget.onApplySubtitleOverlay != null) {
      _mountedOffsetSec = _manualOffsetSec;
      await widget.onApplySubtitleOverlay!(
        activeCues,
        bilingual: _bilingual,
        offset: Duration(milliseconds: (_manualOffsetSec * 1000).round()),
        label: label,
      );
    }
    _emitSessionState();
  }

  Future<void> _suggestOffset() async {
    if (_busy || _loadedCues.isEmpty) return;
    final opGen = ++_studioOpGen;
    setState(() {
      _busy = true;
      _busyOpGen = opGen;
      _isError = false;
      _status = '正在分析片头时长与首句台词密度…';
    });
    try {
      final res = await AiLabService.instance.suggestSubtitleOffset(
        seriesTitle: widget.seriesTitle,
        firstCues: _loadedCues,
        skipIntroSeconds: widget.skipIntroSeconds,
      );
      if (!mounted || _disposed || opGen != _studioOpGen) return;
      setState(() {
        _busy = false;
        _busyOpGen = null;
        _manualOffsetSec = res.offsetSeconds;
        _status =
            '建议偏移 ${res.offsetSeconds >= 0 ? "+${res.offsetSeconds.toStringAsFixed(1)}" : res.offsetSeconds.toStringAsFixed(1)} 秒：${res.reasonZh}';
      });
      final activeCues = _result?.cues ?? _loadedCues;
      if (_overlayActive &&
          _draftMatchesOverlay &&
          activeCues.isNotEmpty &&
          widget.onApplySubtitleOverlay != null) {
        _mountedOffsetSec = _manualOffsetSec;
        final label = _overlayLabel.isNotEmpty
            ? _overlayLabel
            : (_bilingual ? 'AI 中外双语精译' : 'AI 简体中文精译');
        await widget.onApplySubtitleOverlay!(
          activeCues,
          bilingual: _bilingual,
          offset: Duration(milliseconds: (_manualOffsetSec * 1000).round()),
          label: label,
        );
      }
      _emitSessionState();
    } catch (e) {
      if (!mounted || _disposed || opGen != _studioOpGen) return;
      setState(() {
        _busy = false;
        _busyOpGen = null;
        _isError = true;
        _status = '$e';
      });
    } finally {
      _releaseBusyFor(opGen);
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
          if (widget.onToggleLiveEmbeddedTranslate != null) ...[
            Container(
              key: const ValueKey('ai-sub-live-toggle-row'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.captions_bubble_fill,
                    color: p.systemBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '内封外语字幕实时双语精译',
                          style: TextStyle(
                            color: p.labelPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '实时捕获 MKV/内封外语台词并在全内核画面直显双语字幕',
                          style: TextStyle(
                            color: p.labelSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  CupertinoSwitch(
                    key: const ValueKey('ai-sub-live-switch'),
                    value: _liveEnabled,
                    activeTrackColor: AppleColors.systemGreen,
                    onChanged: (v) {
                      HapticFeedback.selectionClick();
                      setState(() => _liveEnabled = v);
                      widget.onToggleLiveEmbeddedTranslate!(v);
                      _emitSessionState();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            '也可导入本地外挂字幕（.srt / .vtt / .ass），锁定角色译名生成双语字幕并在 AVPlayer / MDK / MPV 画面直接渲染：',
            style: TextStyle(color: p.labelSecondary, fontSize: 12.8, height: 1.45),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: CupertinoButton(
                  key: const ValueKey('ai-sub-pick-file-btn'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: cardBg,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: _pickSubtitleFile,
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
                  onPressed: _pasteSubtitleText,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        CupertinoIcons.doc_on_clipboard_fill,
                        size: 16,
                        color: p.systemBlue,
                      ),
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
              if (v == null || v == _bilingual) return;
              // Switching display language adjusts ONLY the currently mounted
              // overlay track and NEVER auto-mounts an unmounted draft. If an
              // in-flight translation/continuation was running under the old
              // language mode, cancel it cleanly and release its busy state.
              final hadInFlight = _busy;
              if (hadInFlight) {
                _studioOpGen++;
              }
              setState(() {
                _bilingual = v;
                if (hadInFlight) {
                  _busy = false;
                  _busyOpGen = null;
                }
              });
              final mountedTarget = _draftMatchesOverlay
                  ? (_result?.cues ?? (_loadedCues.isNotEmpty ? _loadedCues : _mountedCues))
                  : _mountedCues;
              final mountedOffsetSec =
                  _draftMatchesOverlay ? _manualOffsetSec : _mountedOffsetSec;
              if (_overlayActive &&
                  mountedTarget.isNotEmpty &&
                  widget.onApplySubtitleOverlay != null) {
                final label = _bilingual ? 'AI 中外双语精译' : 'AI 简体中文精译';
                _overlayLabel = label;
                unawaited(
                  widget.onApplySubtitleOverlay!(
                    mountedTarget,
                    bilingual: _bilingual,
                    offset: Duration(
                      milliseconds: (mountedOffsetSec * 1000).round(),
                    ),
                    label: label,
                  ),
                );
              }
              _emitSessionState();
            },
          ),
          if (_loadedCues.isNotEmpty || _overlayActive) ...[
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
                  onPressed: _busy ? null : () => unawaited(_updateOffset(-0.5)),
                  child: const Text('-0.5s', style: TextStyle(fontSize: 12.5)),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: const Size(32, 28),
                  onPressed: _busy ? null : () => unawaited(_updateOffset(0.5)),
                  child: const Text('+0.5s', style: TextStyle(fontSize: 12.5)),
                ),
                if (_loadedCues.isNotEmpty)
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
              '本片锁定角色与专有名词表',
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
          Row(
            children: [
              if (_loadedCues.isNotEmpty && widget.onApplySubtitleOverlay != null) ...[
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: CupertinoButton(
                      key: const ValueKey('ai-sub-direct-mount-btn'),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      color: cardBg,
                      borderRadius: BorderRadius.circular(14),
                      onPressed: _busy ? null : _applyDirectMountOnly,
                      child: Text(
                        '直接显示原字幕',
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 46,
                  child: CupertinoButton(
                    key: const ValueKey('ai-sub-translate-mount-btn'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    color: AppleColors.systemBlue,
                    borderRadius: BorderRadius.circular(14),
                    onPressed: _busy ? null : _runTranslate,
                    child: _busy
                        ? const CupertinoActivityIndicator(color: Colors.white)
                        : const Text(
                            'AI 精译并画面直显',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
          if (_result != null && _result!.hasUntranslatedRemainder) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: CupertinoButton(
                key: const ValueKey('ai-sub-continue-translate-btn'),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                color: cardBg,
                borderRadius: BorderRadius.circular(12),
                onPressed: _busy
                    ? null
                    : () => unawaited(_runTranslate(continueRemaining: true)),
                child: Text(
                  '继续精译剩余 ${_result!.totalCount - _result!.translatedCount} 条字幕',
                  style: TextStyle(
                    color: p.systemBlue,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if ((_overlayActive || _liveEnabled) &&
              widget.onClearSubtitleOverlay != null) ...[
            const SizedBox(height: 10),
            CupertinoButton(
              key: const ValueKey('ai-sub-clear-overlay-btn'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              minimumSize: const Size(0, 34),
              onPressed: () {
                HapticFeedback.selectionClick();
                _studioOpGen++;
                widget.onClearSubtitleOverlay!();
                widget.onToggleLiveEmbeddedTranslate?.call(false);
                setState(() {
                  _busy = false;
                  _busyOpGen = null;
                  _overlayActive = false;
                  _draftMatchesOverlay = false;
                  _liveEnabled = false;
                  _loadedCues = const <AiSubtitleCue>[];
                  _mountedCues = const <AiSubtitleCue>[];
                  _mountedGlossary = const <String, String>{};
                  _mountedOffsetSec = 0.0;
                  _result = null;
                  _manualOffsetSec = 0.0;
                  _overlayLabel = '';
                  _status = '已关闭画面 AI 字幕叠层';
                });
                _emitSessionState();
              },
              child: const Text(
                '关闭当前 AI 字幕显示',
                style: TextStyle(
                  color: AppleColors.systemRed,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Grounded AI Feature 2: Zero-Spoiler Watch Brief & Setting Background (`零剧透看点与设定背景科普`).
Future<void> showIosAiWatchBriefSheet(
  BuildContext context, {
  required String title,
  String year = '',
  String genreOrRemarks = '',
  String overview = '',
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 零剧透看点与背景科普',
    maxWidth: 500,
    builder: (ctx) => FutureBuilder<AiWatchBriefResult>(
      future: AiLabService.instance.generateWatchBrief(
        title: title,
        year: year,
        genreOrRemarks: genreOrRemarks,
        overview: overview,
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
              '获取看点失败：${snap.error}',
              style: const TextStyle(color: AppleColors.systemRed, fontSize: 13.5),
            ),
          );
        }
        final data = snap.data!;
        return SingleChildScrollView(
          key: const ValueKey('ai-watch-brief-sheet'),
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: p.systemBlue.withValues(alpha: p.isDark ? 0.18 : 0.10),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Text(
                  data.oneLineHook,
                  key: const ValueKey('ai-watch-brief-hook'),
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                  ),
                ),
              ),
              if (data.highlights.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  '零剧透核心看点',
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 12.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final h in data.highlights)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '• $h',
                            style: TextStyle(
                              color: p.labelPrimary,
                              fontSize: 13.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (data.backgroundContext.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  '创作背景与世界观设定科普',
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 12.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                for (final b in data.backgroundContext)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Text(
                        b,
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 13.2,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
              ],
              if (data.viewingNote.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppleColors.systemPurple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Text(
                    '观影建议：${data.viewingNote}',
                    style: TextStyle(
                      color: p.labelPrimary,
                      fontSize: 12.8,
                      height: 1.42,
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

/// Grounded AI Feature 3: Post-Credits Stinger & Edition Differences Guide (`片尾彩蛋与版本差异提示`).
Future<void> showIosAiPostCreditsSheet(
  BuildContext context, {
  required String title,
  String year = '',
  String overview = '',
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 片尾彩蛋与版本提示',
    maxWidth: 480,
    builder: (ctx) => FutureBuilder<AiPostCreditsResult>(
      future: AiLabService.instance.checkPostCreditsGuide(
        title: title,
        year: year,
        overview: overview,
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
              '查询彩蛋提示失败：${snap.error}',
              style: const TextStyle(color: AppleColors.systemRed, fontSize: 13.5),
            ),
          );
        }
        final res = snap.data!;
        final badgeColor = res.status == 'has_stinger'
            ? AppleColors.systemGreen
            : (res.status == 'none'
                  ? AppleColors.systemBlue
                  : AppleColors.systemOrange);
        return SingleChildScrollView(
          key: const ValueKey('ai-post-credits-sheet'),
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        res.badgeLabelZh,
                        key: const ValueKey('ai-post-credits-badge'),
                        style: TextStyle(
                          color: badgeColor,
                          fontSize: 12.8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      res.stingerSummaryZh,
                      style: TextStyle(
                        color: p.labelPrimary,
                        fontSize: 14.2,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (res.versionTipZh.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: p.systemBlue.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '片源规格与版本提示',
                        style: TextStyle(
                          color: p.systemBlue,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        res.versionTipZh,
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 13.3,
                          height: 1.45,
                        ),
                      ),
                    ],
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

/// Grounded AI Feature 5: Interactive Spoiler-Aware Movie/Series Q&A (`自由观影问答`).
Future<void> showIosAiWorkQaSheet(
  BuildContext context, {
  required String title,
  String year = '',
  String overview = '',
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 自由观影问答',
    maxWidth: 500,
    builder: (ctx) => _IosAiWorkQaBody(
      title: title,
      year: year,
      overview: overview,
    ),
  );
}

class _IosAiWorkQaBody extends StatefulWidget {
  final String title;
  final String year;
  final String overview;

  const _IosAiWorkQaBody({
    required this.title,
    required this.year,
    required this.overview,
  });

  @override
  State<_IosAiWorkQaBody> createState() => _IosAiWorkQaBodyState();
}

class _IosAiWorkQaBodyState extends State<_IosAiWorkQaBody> {
  static const List<String> _quickPrompts = <String>[
    '这部作品有哪些真实背景或改编渊源？',
    '核心世界观设定是什么（不要剧透结局）？',
    '导演的叙事风格和视听看点有哪些？',
    '适合合家欢或周末放松观看吗？',
  ];

  final TextEditingController _qCtrl = TextEditingController();
  bool _spoilerFree = true;
  bool _loading = false;
  String? _answer;
  String? _error;

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  Future<void> _ask(String q) async {
    final clean = q.trim();
    if (clean.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ans = await AiLabService.instance.askAboutWork(
        title: widget.title,
        year: widget.year,
        overview: widget.overview,
        question: clean,
        spoilerFree: _spoilerFree,
      );
      if (!mounted) return;
      setState(() {
        _answer = ans;
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
      key: const ValueKey('ai-work-qa-sheet'),
      padding: EdgeInsets.fromLTRB(
        18,
        12,
        18,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '围绕《${widget.title}》自由提问（不确定细节绝不瞎编）',
                  style: TextStyle(color: p.labelSecondary, fontSize: 12.8),
                ),
              ),
              Text(
                '防剧透',
                style: TextStyle(
                  color: p.labelPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              CupertinoSwitch(
                value: _spoilerFree,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) => setState(() => _spoilerFree = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final preset in _quickPrompts)
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _qCtrl.text = preset;
                    unawaited(_ask(preset));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5.5,
                    ),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      preset,
                      style: TextStyle(
                        color: p.labelPrimary,
                        fontSize: 12,
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
                  key: const ValueKey('ai-work-qa-field'),
                  controller: _qCtrl,
                  placeholder: '输入关于本片设定、背景或版本的疑问…',
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  onSubmitted: _ask,
                ),
              ),
              const SizedBox(width: 8),
              CupertinoButton(
                key: const ValueKey('ai-work-qa-submit-btn'),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                color: AppleColors.systemBlue,
                borderRadius: BorderRadius.circular(11),
                onPressed: _loading ? null : () => _ask(_qCtrl.text),
                child: const Text(
                  '提问',
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
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CupertinoActivityIndicator(radius: 12)),
            )
          else if (_error != null)
            Text(_error!, style: const TextStyle(color: AppleColors.systemRed))
          else if (_answer != null)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                _answer!,
                key: const ValueKey('ai-work-qa-answer'),
                style: TextStyle(
                  color: p.labelPrimary,
                  fontSize: 14,
                  height: 1.54,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Scenario 4 UI: Taste Portrait & Mood Sommelier (`观影口味画像与「今晚看什么」/ 看完这部看什么`).
Future<void> showIosAiMoodSommelierSheet(
  BuildContext context, {
  required List<String> recentHistoryTitles,
  required List<String> favoriteTitles,
  required List<(CmsSite, CmsVideo)> availableLibrarySnapshot,
  String initialMoodPrompt = '',
  String sheetTitle = 'AI 今晚看什么 · 私人策展',
  required void Function(AiCuratedPick pick) onSelectPick,
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: sheetTitle,
    maxWidth: 500,
    builder: (_) => _IosAiMoodSommelierBody(
      recentHistoryTitles: recentHistoryTitles,
      favoriteTitles: favoriteTitles,
      availableLibrarySnapshot: availableLibrarySnapshot,
      initialMoodPrompt: initialMoodPrompt,
      onSelectPick: onSelectPick,
    ),
  );
}

class _IosAiMoodSommelierBody extends StatefulWidget {
  final List<String> recentHistoryTitles;
  final List<String> favoriteTitles;
  final List<(CmsSite, CmsVideo)> availableLibrarySnapshot;
  final String initialMoodPrompt;
  final void Function(AiCuratedPick pick) onSelectPick;

  const _IosAiMoodSommelierBody({
    required this.recentHistoryTitles,
    required this.favoriteTitles,
    required this.availableLibrarySnapshot,
    required this.initialMoodPrompt,
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

  late final TextEditingController _moodCtrl;
  bool _loading = true;
  String? _error;
  AiMoodSommelierResult? _result;

  @override
  void initState() {
    super.initState();
    _moodCtrl = TextEditingController(text: widget.initialMoodPrompt);
    unawaited(_curate(widget.initialMoodPrompt));
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

/// DetailScreen AI Hub: grounded Watch Brief, Post-Credits & Edition Guide,
/// Spoiler-Free Work Q&A, Messy Episode Curating (for episodic series only),
/// and user Custom Skills.
Future<void> showIosDetailAiLabSheet(
  BuildContext context, {
  required String title,
  required String year,
  required String overview,
  String genreOrRemarks = '',
  required int currentEpisodeNumber,
  required List<CmsEpisode> currentLineEpisodes,
  bool isMultiVersionMovie = false,
  required Future<void> Function(EpisodeScrapeOverride override, String summary)
      onApplyEpisodeOverride,
}) async {
  final cfg = AiService.instance.config;
  final watchBriefEnabled = cfg.spoilerFreeRecapEnabled;
  final skills = cfg.effectiveSkills
      .where((s) => s.target.showsInDetail)
      .toList();
  final showEpisodeCurate =
      currentLineEpisodes.length > 1 && !isMultiVersionMovie;
  final hasAnyFeature = watchBriefEnabled || showEpisodeCurate || skills.isNotEmpty;

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
              if (!hasAnyFeature)
                Container(
                  key: const ValueKey('detail-ai-lab-all-disabled-notice'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '「零剧透看点与观影导览」等相关功能开关当前已关闭，可在「设置 → AI 观影实验室」中开启后再使用。',
                    style: TextStyle(
                      color: p.labelSecondary,
                      fontSize: 13.2,
                      height: 1.48,
                    ),
                  ),
                ),
              if (watchBriefEnabled) ...[
                _buildHubActionTile(
                  p: p,
                  cardBg: cardBg,
                  icon: CupertinoIcons.film_fill,
                  iconColor: AppleColors.systemBlue,
                  title: '零剧透看点与设定背景科普',
                  subtitle: '梳理创作渊源、核心设定与视听看点，绝不剧透结局',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      showIosAiWatchBriefSheet(
                        context,
                        title: title,
                        year: year,
                        genreOrRemarks: genreOrRemarks,
                        overview: overview,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                _buildHubActionTile(
                  p: p,
                  cardBg: cardBg,
                  icon: CupertinoIcons.sparkles,
                  iconColor: AppleColors.systemTeal,
                  title: '片尾彩蛋与版本差异提示',
                  subtitle: '查询是否有片尾彩蛋及 IMAX / 杜比视界 / 导剪版差异',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      showIosAiPostCreditsSheet(
                        context,
                        title: title,
                        year: year,
                        overview: overview,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                _buildHubActionTile(
                  p: p,
                  cardBg: cardBg,
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  iconColor: AppleColors.systemIndigo,
                  title: '自由观影问答（防剧透）',
                  subtitle: '围绕本片改编背景、世界观或观影疑问自由提问',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(
                      showIosAiWorkQaSheet(
                        context,
                        title: title,
                        year: year,
                        overview: overview,
                      ),
                    );
                  },
                ),
              ],
              if (showEpisodeCurate) ...[
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
                            episode: isMultiVersionMovie
                                ? ''
                                : '第 $currentEpisodeNumber 集',
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

/// Player AI Sheet: Online Danmaku Search, Auto-Match & Timeline Offset Alignment.
Future<void> showIosAiDanmuMatchSheet(
  BuildContext context, {
  required String title,
  required String episodeName,
  required int episodeNumber,
  String year = '',
  int durationSec = 0,
  required DanmuSettings currentDanmuSettings,
  required int initialOffsetMs,
  List<({int timeMs, String text})> sampleSubtitles = const [],
  required void Function(AiOnlineDanmuCandidate candidate, List<DanmuItem> items)
      onApplyDanmu,
  required ValueChanged<int> onUpdateOffsetMs,
  AiDanmuMatcher? matcherOverride,
}) async {
  await showIos27LiquidSheet<void>(
    context: context,
    title: 'AI 全网搜弹幕',
    maxWidth: 500,
    builder: (ctx) => _IosAiDanmuMatchBody(
      title: title,
      episodeName: episodeName,
      episodeNumber: episodeNumber,
      year: year,
      durationSec: durationSec,
      currentDanmuSettings: currentDanmuSettings,
      initialOffsetMs: initialOffsetMs,
      sampleSubtitles: sampleSubtitles,
      onApplyDanmu: onApplyDanmu,
      onUpdateOffsetMs: onUpdateOffsetMs,
      matcherOverride: matcherOverride,
    ),
  );
}

class _IosAiDanmuMatchBody extends StatefulWidget {
  final String title;
  final String episodeName;
  final int episodeNumber;
  final String year;
  final int durationSec;
  final DanmuSettings currentDanmuSettings;
  final int initialOffsetMs;
  final List<({int timeMs, String text})> sampleSubtitles;
  final void Function(AiOnlineDanmuCandidate candidate, List<DanmuItem> items)
      onApplyDanmu;
  final ValueChanged<int> onUpdateOffsetMs;
  final AiDanmuMatcher? matcherOverride;

  const _IosAiDanmuMatchBody({
    required this.title,
    required this.episodeName,
    required this.episodeNumber,
    required this.year,
    required this.durationSec,
    required this.currentDanmuSettings,
    required this.initialOffsetMs,
    required this.sampleSubtitles,
    required this.onApplyDanmu,
    required this.onUpdateOffsetMs,
    this.matcherOverride,
  });

  @override
  State<_IosAiDanmuMatchBody> createState() => _IosAiDanmuMatchBodyState();
}

class _IosAiDanmuMatchBodyState extends State<_IosAiDanmuMatchBody> {
  late final AiDanmuMatcher _matcher;
  late final bool _ownsMatcher;
  late final TextEditingController _keywordCtrl;
  late final TextEditingController _epCtrl;

  bool _searching = false;
  bool _aligningOffset = false;
  String? _statusMessage;
  bool _statusIsError = false;
  String? _offsetReason;
  late int _offsetMs;
  List<AiOnlineDanmuCandidate> _candidates = const <AiOnlineDanmuCandidate>[];
  AiOnlineDanmuCandidate? _selected;
  List<DanmuItem> _loadedItems = const <DanmuItem>[];
  int _opGen = 0;

  @override
  void initState() {
    super.initState();
    _ownsMatcher = widget.matcherOverride == null;
    _matcher = widget.matcherOverride ?? AiDanmuMatcher();
    _offsetMs = widget.initialOffsetMs.clamp(-30000, 30000);
    _keywordCtrl = TextEditingController(text: widget.title);
    _epCtrl = TextEditingController(
      text: widget.episodeNumber > 0 ? '${widget.episodeNumber}' : '1',
    );
    _searching = true;
    _statusMessage = '正在提炼片名并检索全网弹幕源…';
    _statusIsError = false;
    unawaited(_runSearch(autoUsePlanKeyword: true, fromInitState: true));
  }

  @override
  void dispose() {
    _opGen++;
    _keywordCtrl.dispose();
    _epCtrl.dispose();
    if (_ownsMatcher) {
      _matcher.dispose();
    }
    super.dispose();
  }

  Future<void> _runSearch({
    required bool autoUsePlanKeyword,
    bool fromInitState = false,
  }) async {
    final myGen = ++_opGen;
    if (!fromInitState && mounted) {
      setState(() {
        _searching = true;
        _statusMessage = '正在提炼片名并检索全网弹幕源…';
        _statusIsError = false;
      });
    }
    final manualKw = autoUsePlanKeyword ? '' : _keywordCtrl.text.trim();
    final manualEp = int.tryParse(_epCtrl.text.trim());
    try {
      final outcome = await _matcher.autoMatchAndLoad(
        rawTitle: widget.title,
        rawEpisodeName: widget.episodeName,
        fallbackEpisodeIndex: widget.episodeNumber,
        year: widget.year,
        durationSec: widget.durationSec,
        manualKeywordOverride: manualKw,
        manualEpisodeOverride: autoUsePlanKeyword ? null : manualEp,
        danmuSettings: widget.currentDanmuSettings,
      );
      if (!mounted || myGen != _opGen) return;
      if (outcome.plan.canonicalTitle.isNotEmpty &&
          autoUsePlanKeyword &&
          _keywordCtrl.text.trim() == widget.title.trim()) {
        _keywordCtrl.text = outcome.plan.canonicalTitle;
      }
      if (outcome.plan.episodeNumber > 0 && autoUsePlanKeyword) {
        _epCtrl.text = '${outcome.plan.episodeNumber}';
      }
      setState(() {
        _searching = false;
        _candidates = outcome.candidates;
        _selected = outcome.selected;
        _loadedItems = outcome.items;
        _statusMessage = outcome.messageZh;
        _statusIsError = outcome.items.isEmpty && outcome.candidates.isEmpty;
      });
      if (outcome.selected != null && outcome.items.isNotEmpty) {
        widget.onApplyDanmu(outcome.selected!, outcome.items);
      }
    } catch (e) {
      if (!mounted || myGen != _opGen) return;
      setState(() {
        _searching = false;
        _statusMessage = '匹配失败：$e';
        _statusIsError = true;
      });
    }
  }

  Future<void> _selectCandidate(AiOnlineDanmuCandidate cand) async {
    final myGen = ++_opGen;
    setState(() {
      _searching = true;
      _statusMessage = '正在拉取 ${cand.sourceLabel} 弹幕…';
      _statusIsError = false;
    });
    try {
      final items = await _matcher.fetchCandidateDanmu(
        cand,
        danmuSettings: widget.currentDanmuSettings,
      );
      if (!mounted || myGen != _opGen) return;
      if (items.isEmpty) {
        setState(() {
          _searching = false;
          _selected = cand;
          _loadedItems = const <DanmuItem>[];
          _statusMessage = '该候选暂无可用弹幕，请换一条试试';
          _statusIsError = true;
        });
        return;
      }
      setState(() {
        _searching = false;
        _selected = cand;
        _loadedItems = items;
        _statusMessage =
            '已切换并加载 ${items.length} 条弹幕 · ${cand.sourceLabel}（${cand.workTitle}）';
        _statusIsError = false;
      });
      widget.onApplyDanmu(cand, items);
    } catch (e) {
      if (!mounted || myGen != _opGen) return;
      setState(() {
        _searching = false;
        _statusMessage = '拉取弹幕失败：$e';
        _statusIsError = true;
      });
    }
  }

  void _applyOffsetMs(int nextOffsetMs) {
    final clamped = nextOffsetMs.clamp(-30000, 30000);
    setState(() {
      _offsetMs = clamped;
    });
    widget.onUpdateOffsetMs(clamped);
  }

  Future<void> _runAiTimelineOffset() async {
    if (_aligningOffset || _loadedItems.isEmpty) return;
    setState(() {
      _aligningOffset = true;
      _offsetReason = '正在分析时长差与弹幕/台词时间戳…';
    });
    try {
      final res = await _matcher.suggestTimelineOffset(
        title: _selected?.workTitle ?? widget.title,
        episodeLabel: _selected?.episodeTitle ?? widget.episodeName,
        videoDurationSec: widget.durationSec,
        candidateDurationSec: _selected?.durationSec ?? 0,
        sampleSubtitles: widget.sampleSubtitles,
        danmuItems: _loadedItems,
      );
      if (!mounted) return;
      setState(() {
        _aligningOffset = false;
        _offsetReason = res.reasonZh;
      });
      _applyOffsetMs(res.offsetMs);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aligningOffset = false;
        _offsetReason = '时间轴校对失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg =
        p.isDark ? const Color(0xFF26262B) : const Color(0xFFF3F4F8);
    final fieldBg =
        p.isDark ? const Color(0xFF1C1C20) : const Color(0xFFFFFFFF);
    final offsetSecStr = _offsetMs == 0
        ? '0.0s'
        : '${_offsetMs > 0 ? "+" : ""}${(_offsetMs / 1000).toStringAsFixed(1)}s';

    return Column(
      key: const ValueKey('ios-ai-danmu-match-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: CupertinoTextField(
                      key: const ValueKey('ios-ai-danmu-keyword-field'),
                      controller: _keywordCtrl,
                      placeholder: '输入片名关键词',
                      style: TextStyle(color: p.labelPrimary, fontSize: 13.5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: fieldBg,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      onSubmitted: (_) => unawaited(_runSearch(autoUsePlanKeyword: false)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: CupertinoTextField(
                      key: const ValueKey('ios-ai-danmu-ep-field'),
                      controller: _epCtrl,
                      placeholder: '集号',
                      keyboardType: TextInputType.number,
                      style: TextStyle(color: p.labelPrimary, fontSize: 13.5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: fieldBg,
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CupertinoButton(
                    key: const ValueKey('ios-ai-danmu-search-btn'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    minimumSize: const Size(48, 34),
                    color: p.systemBlue,
                    borderRadius: BorderRadius.circular(9),
                    onPressed: _searching
                        ? null
                        : () => unawaited(_runSearch(autoUsePlanKeyword: false)),
                    child: const Text(
                      '搜索',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (_searching) ...[
                      const CupertinoActivityIndicator(radius: 8),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(
                          color: _statusIsError
                              ? AppleColors.systemOrange
                              : p.labelPrimary,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '时间轴微调：$offsetSecStr',
                      style: TextStyle(
                        color: p.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    key: const ValueKey('ios-ai-danmu-ai-offset-btn'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    minimumSize: const Size(40, 28),
                    color: AppleColors.systemIndigo.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                    onPressed: (_aligningOffset || _loadedItems.isEmpty)
                        ? null
                        : _runAiTimelineOffset,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_aligningOffset) ...[
                          const CupertinoActivityIndicator(radius: 7),
                          const SizedBox(width: 5),
                        ] else ...[
                          const Icon(
                            CupertinoIcons.sparkles,
                            size: 13,
                            color: AppleColors.systemIndigo,
                          ),
                          const SizedBox(width: 4),
                        ],
                        const Text(
                          'AI 校对时间轴',
                          style: TextStyle(
                            color: AppleColors.systemIndigo,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final step in const <(String, int, bool)>[
                    ('-2s', -2000, false),
                    ('-0.5s', -500, false),
                    ('归零', 0, true),
                    ('+0.5s', 500, false),
                    ('+2s', 2000, false),
                  ])
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      minimumSize: const Size(42, 28),
                      color: p.isDark
                          ? const Color(0xFF34343B)
                          : const Color(0xFFE5E6EC),
                      borderRadius: BorderRadius.circular(8),
                      onPressed: () =>
                          _applyOffsetMs(step.$3 ? 0 : _offsetMs + step.$2),
                      child: Text(
                        step.$1,
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              if (_offsetReason != null && _offsetReason!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _offsetReason!,
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_candidates.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            '匹配候选（点击切换弹幕池）',
            style: TextStyle(
              color: p.labelSecondary,
              fontSize: 12.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (final c in _candidates.take(12))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                key: ValueKey('ios-ai-danmu-cand-${c.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: _searching ? null : () => unawaited(_selectCandidate(c)),
                child: Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(12),
                    border: _selected?.id == c.id
                        ? Border.all(color: p.systemBlue, width: 1.2)
                        : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c.workTitle} · ${c.episodeTitle}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.labelPrimary,
                                fontSize: 13.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${c.sourceLabel} · 匹配度 ${(c.confidence * 100).round()}%${c.durationSec > 0 ? " · ${c.durationSec ~/ 60}分钟" : ""}',
                              style: TextStyle(
                                color: p.labelSecondary,
                                fontSize: 11.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_selected?.id == c.id)
                        Icon(
                          CupertinoIcons.checkmark_circle_fill,
                          color: p.systemBlue,
                          size: 18,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

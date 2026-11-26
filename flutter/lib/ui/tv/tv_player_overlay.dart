// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/ohos_runtime.dart';
import '../../core/video_kernel.dart';
import '../apple_theme.dart';
import 'tv_focus_widgets.dart';

/// Opens the 10-foot living-room player control panel for D-pad / TV remotes.
Future<void> showTvPlayerControlSheet({
  required BuildContext context,
  required Player player,
  required double currentSpeed,
  required ValueChanged<double> onSpeedSelected,
  required BoxFit currentFit,
  required ValueChanged<BoxFit> onFitSelected,
  VoidCallback? onOpenEpisodes,
  bool isLiveStream = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (sheetCtx) => TvPlayerControlSheet(
      player: player,
      initialSpeed: currentSpeed,
      onSpeedSelected: onSpeedSelected,
      initialFit: currentFit,
      onFitSelected: onFitSelected,
      onOpenEpisodes: onOpenEpisodes == null
          ? null
          : () {
              Navigator.of(sheetCtx).pop();
              onOpenEpisodes();
            },
      isLiveStream: isLiveStream,
    ),
  );
}

/// 10-foot D-pad focusable player control panel exposing playback rate (`0.75x`–`2.0x`),
/// audio track switching, subtitle track switching (including native `SubtitleTrack.no()`),
/// aspect ratio (`BoxFit.contain` / `cover` / `fill`), and live resolution badge.
class TvPlayerControlSheet extends StatefulWidget {
  static const List<double> supportedSpeeds =
      OhosPlatformPlayer.supportedSpeeds;

  final Player player;
  final double initialSpeed;
  final ValueChanged<double> onSpeedSelected;
  final BoxFit initialFit;
  final ValueChanged<BoxFit> onFitSelected;
  final VoidCallback? onOpenEpisodes;
  final bool isLiveStream;

  const TvPlayerControlSheet({
    super.key,
    required this.player,
    required this.initialSpeed,
    required this.onSpeedSelected,
    required this.initialFit,
    required this.onFitSelected,
    this.onOpenEpisodes,
    this.isLiveStream = false,
  });

  @override
  State<TvPlayerControlSheet> createState() => _TvPlayerControlSheetState();
}

class _TvPlayerControlSheetState extends State<TvPlayerControlSheet> {
  late double _speed;
  late BoxFit _fit;
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _speed = widget.player.platform is OhosPlatformPlayer || OhosRuntime.isOhos
        ? OhosPlatformPlayer.normalizeSupportedRate(widget.initialSpeed)
        : widget.initialSpeed;
    _fit = widget.initialFit;
    void refresh(dynamic _) {
      if (mounted) {
        setState(() {});
      }
    }

    _subs.add(widget.player.stream.width.listen(refresh));
    _subs.add(widget.player.stream.height.listen(refresh));
    _subs.add(widget.player.stream.tracks.listen(refresh));
    _subs.add(widget.player.stream.track.listen(refresh));
    _subs.add(widget.player.stream.buffering.listen(refresh));
    if (widget.player.platform is OhosPlatformPlayer) {
      _subs.add(widget.player.stream.rate.listen((r) {
        final normalized = OhosPlatformPlayer.normalizeSupportedRate(r);
        if (mounted && (_speed - normalized).abs() >= 0.01) {
          setState(() => _speed = normalized);
        }
      }));
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  static String _formatSpeedLabel(double speed) {
    final fixed = speed.toStringAsFixed(2);
    final trimmed = fixed
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    final normalized = trimmed.contains('.') ? trimmed : '$trimmed.0';
    return '${normalized}x';
  }

  static String _audioTrackLabel(AudioTrack track) {
    if (track == AudioTrack.auto() || track.id == 'auto') {
      return '默认音轨';
    }
    if (track == AudioTrack.no() || track.id == 'no') {
      return '静音音轨';
    }
    final parts = <String>[
      if ((track.title ?? '').trim().isNotEmpty) track.title!.trim(),
      if ((track.language ?? '').trim().isNotEmpty &&
          track.language!.trim() != (track.title ?? '').trim())
        track.language!.trim(),
      if ((track.codec ?? '').trim().isNotEmpty)
        track.codec!.trim().toUpperCase(),
    ];
    if (parts.isNotEmpty) {
      return parts.join(' · ');
    }
    return '音轨 ${track.id}';
  }

  static String _subtitleTrackLabel(SubtitleTrack track) {
    if (track == SubtitleTrack.no() || track.id == 'no') {
      return '关闭字幕';
    }
    if (track == SubtitleTrack.auto() || track.id == 'auto') {
      return '自动字幕';
    }
    final parts = <String>[
      if ((track.title ?? '').trim().isNotEmpty) track.title!.trim(),
      if ((track.language ?? '').trim().isNotEmpty &&
          track.language!.trim() != (track.title ?? '').trim())
        track.language!.trim(),
    ];
    if (parts.isNotEmpty) {
      return parts.join(' · ');
    }
    return '字幕 ${track.id}';
  }

  @override
  Widget build(BuildContext context) {
    final pState = widget.player.state;
    final resBadge = pState.videoResolutionLabel;
    final ohosPlatform = widget.player.platform is OhosPlatformPlayer
        ? widget.player.platform as OhosPlatformPlayer
        : null;

    final rawAudio = pState.tracks.audio
        .where((t) => t != AudioTrack.no() && t.id != 'no')
        .toList(growable: false);
    final audioChoices = rawAudio.isEmpty
        ? <AudioTrack>[AudioTrack.auto()]
        : rawAudio;
    final activeAudio = pState.track.audio;

    final subtitleChoices = <SubtitleTrack>[
      SubtitleTrack.no(),
      ...pState.tracks.subtitle.where(
        (t) => t != SubtitleTrack.no() && t.id != 'no',
      ),
    ];
    final activeSubtitle = pState.track.subtitle;

    final fitOptions = <(BoxFit, String)>[
      (BoxFit.contain, '适应屏幕'),
      (BoxFit.cover, '裁切填满'),
      (BoxFit.fill, '拉伸铺满'),
    ];

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(32, 0, 32, 24),
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 24),
          decoration: BoxDecoration(
            color: const Color(0xF2141720),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 32,
                offset: Offset(0, -6),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.slider_horizontal_3,
                      color: AppleColors.systemBlue,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '播控与音画设置',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (resBadge.isNotEmpty) ...[
                      const SizedBox(width: 14),
                      _buildStatusBadge(
                        resBadge,
                        accent: resBadge.startsWith('4K')
                            ? const Color(0xFFF5A623)
                            : AppleColors.systemBlue,
                      ),
                    ],
                    if (OhosRuntime.isOhos) ...[
                      const SizedBox(width: 8),
                      _buildStatusBadge(
                        'AVPlayer 硬解',
                        accent: AppleColors.systemGreen,
                      ),
                    ],
                    if (ohosPlatform != null &&
                        pState.buffering &&
                        ohosPlatform.bufferingPercent < 100) ...[
                      const SizedBox(width: 8),
                      _buildStatusBadge(
                        '缓冲 ${ohosPlatform.bufferingPercent}%',
                        accent: AppleColors.systemBlue,
                      ),
                    ],
                    const Spacer(),
                    if (widget.onOpenEpisodes != null) ...[
                      TvFocusPill(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        onSelect: widget.onOpenEpisodes,
                        child: const Text(
                          '选集 / 换源',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    TvFocusPill(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      onSelect: () => Navigator.of(context).maybePop(),
                      child: const Text('关闭', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (!widget.isLiveStream) ...[
                  _buildSectionRow(
                    label: '播放倍速',
                    children: [
                      for (var i = 0;
                          i < TvPlayerControlSheet.supportedSpeeds.length;
                          i++)
                        Builder(
                          builder: (_) {
                            final s = TvPlayerControlSheet.supportedSpeeds[i];
                            final isSelected = (_speed - s).abs() < 0.01;
                            final label = _formatSpeedLabel(s);
                            return TvFocusPill(
                              autofocus: isSelected ||
                                  ((s - 1.0).abs() < 0.01 &&
                                      !TvPlayerControlSheet.supportedSpeeds.any(
                                        (v) => (_speed - v).abs() < 0.01,
                                      )),
                              selected: isSelected,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 9,
                              ),
                              onSelect: () {
                                setState(() => _speed = s);
                                unawaited(widget.player.setRate(s));
                                widget.onSpeedSelected(s);
                              },
                              child: Text(
                                label,
                                style: const TextStyle(fontSize: 14),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                _buildSectionRow(
                  label: '音轨切换',
                  children: [
                    for (final track in audioChoices)
                      Builder(
                        builder: (_) {
                          final selected = track == activeAudio ||
                              track.id == activeAudio.id;
                          return TvFocusPill(
                            selected: selected,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            onSelect: () {
                              unawaited(widget.player.setAudioTrack(track));
                              setState(() {});
                            },
                            child: Text(
                              _audioTrackLabel(track),
                              style: const TextStyle(fontSize: 14),
                            ),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSectionRow(
                  label: '字幕切换',
                  children: [
                    for (final sub in subtitleChoices)
                      Builder(
                        builder: (_) {
                          final selected = sub == activeSubtitle ||
                              sub.id == activeSubtitle.id;
                          return TvFocusPill(
                            selected: selected,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            onSelect: () {
                              unawaited(widget.player.setSubtitleTrack(sub));
                              setState(() {});
                            },
                            child: Text(
                              _subtitleTrackLabel(sub),
                              style: const TextStyle(fontSize: 14),
                            ),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSectionRow(
                  label: '画面比例',
                  children: [
                    for (var i = 0; i < fitOptions.length; i++)
                      Builder(
                        builder: (_) {
                          final (fitMode, title) = fitOptions[i];
                          final selected = _fit == fitMode;
                          return TvFocusPill(
                            autofocus: widget.isLiveStream && selected,
                            selected: selected,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            onSelect: () {
                              setState(() => _fit = fitMode);
                              widget.onFitSelected(fitMode);
                            },
                            child: Text(
                              title,
                              style: const TextStyle(fontSize: 14),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String label, {required Color accent}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.72)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent == const Color(0xFFF5A623)
              ? const Color(0xFFFFCA58)
              : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildSectionRow({
    required String label,
    required List<Widget> children,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(
              color: AppleColors.labelSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < children.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      right: i == children.length - 1 ? 0 : 10,
                    ),
                    child: children[i],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

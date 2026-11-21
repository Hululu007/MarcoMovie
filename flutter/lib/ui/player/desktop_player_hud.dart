// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show
        Colors,
        Divider,
        IconButton,
        InkWell,
        Material,
        MaterialType,
        TextButton,
        Tooltip;

import '../apple_theme.dart';
import '../ios_liquid_glass.dart';
import '../windows_appearance.dart';

/// Desktop keyboard arrow hold fast-forward / rewind preview capsule.
class DesktopScrubPreviewCapsule extends StatelessWidget {
  final int direction;
  final String targetTimeText;
  final String deltaText;
  final double speedSecPerSec;
  final bool isHoldPreview;
  final bool reduceTransparency;

  const DesktopScrubPreviewCapsule({
    super.key,
    required this.direction,
    required this.targetTimeText,
    required this.deltaText,
    required this.speedSecPerSec,
    required this.isHoldPreview,
    this.reduceTransparency = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveReduce = reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        MediaQuery.highContrastOf(context);
    final bgColor = effectiveReduce || isWindowsDesktopUi
        ? const Color(0xEB16161C)
        : const Color(0xCC16161C);
    final arrow = direction >= 0 ? '⏩' : '⏪';
    final speedPart =
        isHoldPreview ? ' · ${speedSecPerSec.round()}s/s' : '';

    return IgnorePointer(
      child: Container(
        key: const Key('desktop-scrub-preview-capsule'),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withValues(alpha: effectiveReduce ? 0.45 : 0.22),
            width: 0.85,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x52000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$arrow $targetTimeText ($deltaText)$speedPart',
              style: const TextStyle(
                color: AppleColors.labelPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              '松开方向键跳转 · 按 Esc 取消',
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Width breakpoints shared between [DesktopPlayerHud] and its overflow
/// "More" popover so primary bar items are never duplicated inside "More".
class DesktopHudBarVisibility {
  final bool showInlineVolume;
  final bool showSpeed;
  final bool showDanmu;
  final bool showSubtitles;
  final bool showAnime4k;
  final bool showSleepTimer;

  const DesktopHudBarVisibility({
    required this.showInlineVolume,
    required this.showSpeed,
    required this.showDanmu,
    required this.showSubtitles,
    required this.showAnime4k,
    required this.showSleepTimer,
  });

  factory DesktopHudBarVisibility.forWidth(
    double width, {
    required bool isLive,
    required bool danmuAvailable,
    required bool anime4kAvailable,
  }) {
    return DesktopHudBarVisibility(
      showInlineVolume: width >= 820,
      showSpeed: !isLive && width >= 760,
      showDanmu: !isLive && danmuAvailable && width >= 860,
      showSubtitles: !isLive && width >= 960,
      showAnime4k: anime4kAvailable && width >= 1080,
      showSleepTimer: width >= 1160,
    );
  }
}

/// Refactored Windows desktop cinema player HUD:
/// - Top scrim header (back + title + fused badges, zero lock clutter)
/// - Midline far-left lock button (matching locked-state unlock anchor)
/// - Center canvas Play/Pause + Rewind 15s + Fast-Forward 15s transport controls
/// - Full-width edge-to-edge bottom progress bar & clean desktop action row
/// - PC-native anchored "More" popover menu (zero duplicates, zero touch swipe)
class DesktopPlayerHud extends StatelessWidget {
  final bool embedded;
  final String title;
  final bool playing;
  final bool isLive;
  final bool isFullscreen;
  final double normalSpeed;
  final double volume;
  final Stream<double>? volumeStream;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback? onMuteToggle;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;
  final VoidCallback? onPrevEpisode;
  final VoidCallback? onNextEpisode;
  final bool moreControlsOpen;
  final bool sleepTimerActive;
  final String sleepTimerLabel;
  final bool danmuEnabled;
  final VoidCallback? onDanmuToggle;
  final VoidCallback? onDanmuSettingsTap;
  final bool anime4kVisible;
  final bool anime4kActive;
  final String anime4kLabel;
  final VoidCallback? onAnime4kTap;
  final Widget topHeader;
  final Widget? lockButton;
  final Widget? progressBar;
  final Widget transportButtons;
  final Widget moreToolsDock;
  final VoidCallback onExit;
  final VoidCallback onPlayPause;
  final VoidCallback onVolumeTap;
  final VoidCallback onEpisodesTap;
  final VoidCallback onSpeedTap;
  final VoidCallback onSubtitlesTap;
  final VoidCallback onSleepTimerTap;
  final VoidCallback onToggleMore;
  final VoidCallback? onCloseMore;
  final VoidCallback onToggleExpand;

  const DesktopPlayerHud({
    super.key,
    required this.embedded,
    required this.title,
    required this.playing,
    required this.isLive,
    this.isFullscreen = false,
    required this.normalSpeed,
    this.volume = 100.0,
    this.volumeStream,
    this.onVolumeChanged,
    this.onMuteToggle,
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
    this.onPrevEpisode,
    this.onNextEpisode,
    required this.moreControlsOpen,
    required this.sleepTimerActive,
    required this.sleepTimerLabel,
    this.danmuEnabled = false,
    this.onDanmuToggle,
    this.onDanmuSettingsTap,
    this.anime4kVisible = false,
    this.anime4kActive = false,
    this.anime4kLabel = 'Anime4K',
    this.onAnime4kTap,
    required this.topHeader,
    this.lockButton,
    required this.progressBar,
    required this.transportButtons,
    required this.moreToolsDock,
    required this.onExit,
    required this.onPlayPause,
    required this.onVolumeTap,
    required this.onEpisodesTap,
    required this.onSpeedTap,
    required this.onSubtitlesTap,
    required this.onSleepTimerTap,
    required this.onToggleMore,
    this.onCloseMore,
    required this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return ExcludeFocus(
        child: Stack(
          key: const Key('desktop-player-hud-embedded'),
          children: [
            Positioned(
              left: 15,
              right: 15,
              top: 12,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '停止播放',
                    onPressed: onExit,
                    icon: const Icon(CupertinoIcons.xmark, color: Colors.white),
                  ),
                ],
              ),
            ),
            if (moreControlsOpen)
              Positioned(
                right: 12,
                bottom: 72,
                child: moreToolsDock,
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: WinPanel(
                dark: true,
                padding: const EdgeInsets.all(6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: playing ? '暂停' : '播放',
                      onPressed: onPlayPause,
                      icon: Icon(
                        playing
                            ? CupertinoIcons.pause_fill
                            : CupertinoIcons.play_fill,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '音量',
                      onPressed: onVolumeTap,
                      icon: const Icon(
                        CupertinoIcons.volume_up,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '线路',
                      onPressed: onEpisodesTap,
                      icon: const Icon(
                        CupertinoIcons.list_bullet,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '更多',
                      onPressed: onToggleMore,
                      icon: const Icon(
                        CupertinoIcons.ellipsis,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '展开播放',
                      onPressed: onToggleExpand,
                      icon: const Icon(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final visibility = DesktopHudBarVisibility.forWidth(
      width,
      isLive: isLive,
      danmuAvailable: onDanmuToggle != null,
      anime4kAvailable: anime4kVisible && onAnime4kTap != null,
    );

    Widget barButton(
      String label,
      IconData icon,
      VoidCallback action, {
      bool highlighted = false,
      Key? key,
    }) {
      return TextButton.icon(
        key: key,
        onPressed: action,
        style: TextButton.styleFrom(
          foregroundColor:
              highlighted ? AppleColors.systemCyan : const Color(0xEEFFFFFF),
          backgroundColor: highlighted
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.transparent,
          overlayColor: Colors.white.withValues(alpha: 0.12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
        ),
      );
    }

    Widget iconAction({
      Key? key,
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
      bool highlighted = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: IconButton(
          key: key,
          onPressed: onPressed,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          splashRadius: 18,
          icon: Icon(
            icon,
            size: 18,
            color: highlighted
                ? AppleColors.systemCyan
                : const Color(0xEEFFFFFF),
          ),
        ),
      );
    }

    Widget buildVolumeControl() {
      if (!visibility.showInlineVolume || onVolumeChanged == null) {
        return iconAction(
          icon: volume <= 0.1
              ? CupertinoIcons.volume_off
              : CupertinoIcons.volume_up,
          tooltip: '音量',
          onPressed: onVolumeTap,
        );
      }
      return StreamBuilder<double>(
        stream: volumeStream,
        initialData: volume,
        builder: (context, snapshot) {
          final currentVol = (snapshot.data ?? volume).clamp(0.0, 100.0);
          final icon = currentVol <= 0.5
              ? CupertinoIcons.volume_off
              : currentVol < 50
                  ? CupertinoIcons.volume_down
                  : CupertinoIcons.volume_up;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconAction(
                icon: icon,
                tooltip: currentVol <= 0.5 ? '取消静音 (M)' : '静音 (M)',
                onPressed: onMuteToggle ?? onVolumeTap,
              ),
              _DesktopInlineVolumeTrack(
                value: currentVol,
                onChanged: onVolumeChanged!,
              ),
            ],
          );
        },
      );
    }

    return ExcludeFocus(
      child: Stack(
        key: const Key('desktop-player-hud'),
        fit: StackFit.expand,
        children: [
          // Top soft cinema scrim + header
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xC8000000),
                    Color(0x52000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
                  child: topHeader,
                ),
              ),
            ),
          ),
          // Center canvas transport controls: Rewind 15s, Play/Pause, Forward 15s
          Positioned.fill(
            child: Center(
              child: transportButtons,
            ),
          ),
          // Midline far-left lock button (aligned with locked-state unlock anchor)
          if (lockButton != null)
            Positioned(
              left: 20,
              top: 0,
              bottom: 0,
              child: SafeArea(
                right: false,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: lockButton!,
                ),
              ),
            ),
          // Dismiss barrier when "More" desktop popover is open
          if (moreControlsOpen && onCloseMore != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onCloseMore,
                child: const SizedBox.expand(),
              ),
            ),
          // Bottom full-width cinema control bar (progress bar + toolbar)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x9E000000),
                    Color(0xE8000000),
                  ],
                  stops: [0.0, 0.42, 1.0],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 26, 24, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isLive && progressBar != null) ...[
                        progressBar!,
                        const SizedBox(height: 6),
                      ],
                      Row(
                        children: [
                          if (hasPrevEpisode && onPrevEpisode != null)
                            iconAction(
                              icon: CupertinoIcons.backward_end_fill,
                              tooltip: isLive ? '上一源 (P)' : '上一集 (P)',
                              onPressed: onPrevEpisode!,
                            ),
                          if (hasNextEpisode && onNextEpisode != null)
                            iconAction(
                              icon: CupertinoIcons.forward_end_fill,
                              tooltip: isLive ? '下一源 (N)' : '下一集 (N)',
                              onPressed: onNextEpisode!,
                            ),
                          buildVolumeControl(),
                          const Spacer(),
                          if (visibility.showSpeed)
                            barButton(
                              '$normalSpeed×',
                              CupertinoIcons.speedometer,
                              onSpeedTap,
                              highlighted: normalSpeed != 1.0,
                            ),
                          if (visibility.showDanmu)
                            barButton(
                              danmuEnabled ? '弹幕开' : '弹幕',
                              danmuEnabled
                                  ? CupertinoIcons.chat_bubble_text_fill
                                  : CupertinoIcons.chat_bubble_text,
                              onDanmuToggle!,
                              highlighted: danmuEnabled,
                              key: const Key('desktop-danmu-toggle-button'),
                            ),
                          if (visibility.showSubtitles)
                            barButton(
                              '字幕',
                              CupertinoIcons.captions_bubble,
                              onSubtitlesTap,
                            ),
                          if (visibility.showAnime4k)
                            barButton(
                              anime4kLabel,
                              CupertinoIcons.wand_stars,
                              onAnime4kTap!,
                              highlighted: anime4kActive,
                              key: const Key('desktop-anime4k-button'),
                            ),
                          if (visibility.showSleepTimer)
                            barButton(
                              sleepTimerActive ? sleepTimerLabel : '定时',
                              CupertinoIcons.moon_zzz_fill,
                              onSleepTimerTap,
                              highlighted: sleepTimerActive,
                              key: const Key('desktop-sleep-timer-button'),
                            ),
                          barButton(
                            isLive ? '信号' : '选集',
                            CupertinoIcons.list_bullet,
                            onEpisodesTap,
                          ),
                          barButton(
                            '更多',
                            CupertinoIcons.ellipsis,
                            onToggleMore,
                            highlighted: moreControlsOpen,
                            key: const Key('desktop-more-button'),
                          ),
                          const SizedBox(width: 2),
                          iconAction(
                            key: const Key('player-fullscreen-toggle'),
                            icon: isFullscreen
                                ? CupertinoIcons.fullscreen_exit
                                : CupertinoIcons.fullscreen,
                            tooltip: isFullscreen ? '退出全屏 (F)' : '全屏 (F)',
                            onPressed: onToggleExpand,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Desktop PC-native anchored "More" popover menu (bottom-right above "更多")
          if (moreControlsOpen)
            Positioned(
              right: 24,
              bottom: isLive ? 66 : 106,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 324,
                  maxHeight: math.max(180.0, size.height - 172.0),
                ),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) {},
                      );
                    }
                  },
                  child: moreToolsDock,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopInlineVolumeTrack extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _DesktopInlineVolumeTrack({
    required this.value,
    required this.onChanged,
  });

  @override
  State<_DesktopInlineVolumeTrack> createState() =>
      _DesktopInlineVolumeTrackState();
}

class _DesktopInlineVolumeTrackState extends State<_DesktopInlineVolumeTrack> {
  static const double _trackWidth = 78.0;
  bool _hovered = false;

  void _updateFromDx(double dx) {
    final next = ((dx / _trackWidth).clamp(0.0, 1.0) * 100.0);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final fraction = (widget.value / 100.0).clamp(0.0, 1.0);
    final fillW = _trackWidth * fraction;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _updateFromDx(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => _updateFromDx(d.localPosition.dx),
        child: SizedBox(
          width: _trackWidth + 10,
          height: 28,
          child: Center(
            child: SizedBox(
              width: _trackWidth,
              height: 12,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    width: _trackWidth,
                    height: _hovered ? 4.0 : 3.0,
                    decoration: BoxDecoration(
                      color: const Color(0x40FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Container(
                    width: fillW,
                    height: _hovered ? 4.0 : 3.0,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Positioned(
                    left: (fillW - 5).clamp(0.0, _trackWidth - 10),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x55000000),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reusable desktop popover menu card for secondary player controls.
class DesktopPlayerMorePopover extends StatelessWidget {
  final List<Widget> sections;

  const DesktopPlayerMorePopover({
    super.key,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('desktop-more-menu-popover'),
      width: 312,
      decoration: BoxDecoration(
        color: const Color(0xF2141821),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x7A000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 14,
                      indent: 14,
                      endIndent: 14,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  sections[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DesktopMoreMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? valueText;
  final bool active;
  final Widget? trailing;
  final VoidCallback onTap;

  const DesktopMoreMenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.valueText,
    this.active = false,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? AppleColors.systemCyan : const Color(0xCCFFFFFF),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? AppleColors.systemCyan : Colors.white,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (valueText != null && valueText!.isNotEmpty) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(
                  valueText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else ...[
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.chevron_right,
                size: 12,
                color: Color(0x66FFFFFF),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

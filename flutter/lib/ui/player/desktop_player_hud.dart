// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, IconButton, TextButton;

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

/// Desktop HUD container preserving Windows `winFastGlass` blur-free [WinPanel]
/// surfaces and existing desktop shortcuts/controls while integrating Sleep
/// Timer and M2 shortcuts (`S` speed cycle, scroll wheel volume, arrow scrub).
class DesktopPlayerHud extends StatelessWidget {
  final bool embedded;
  final String title;
  final bool playing;
  final bool isLive;
  final double normalSpeed;
  final bool moreControlsOpen;
  final bool sleepTimerActive;
  final String sleepTimerLabel;
  final Widget topHeader;
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
  final VoidCallback onToggleExpand;

  const DesktopPlayerHud({
    super.key,
    required this.embedded,
    required this.title,
    required this.playing,
    required this.isLive,
    required this.normalSpeed,
    required this.moreControlsOpen,
    required this.sleepTimerActive,
    required this.sleepTimerLabel,
    required this.topHeader,
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
                left: 12,
                right: 12,
                bottom: 84,
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

    final width = MediaQuery.sizeOf(context).width;
    Widget control(
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
              highlighted ? AppleColors.systemCyan : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        icon: Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      );
    }

    return ExcludeFocus(
      child: SafeArea(
        child: Stack(
          key: const Key('desktop-player-hud'),
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 28,
              right: 28,
              top: 20,
              child: topHeader,
            ),
            if (moreControlsOpen)
              Positioned(
                left: 24,
                right: 24,
                bottom: 190,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: moreToolsDock,
                  ),
                ),
              ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 27,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: WinPanel(
                    dark: true,
                    radius: 30,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 12,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isLive && progressBar != null) progressBar!,
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            transportButtons,
                            const Spacer(),
                            if (!isLive && width >= 880)
                              control(
                                '$normalSpeed×',
                                CupertinoIcons.speedometer,
                                onSpeedTap,
                              ),
                            if (!isLive && width >= 1000)
                              control(
                                '字幕',
                                CupertinoIcons.captions_bubble,
                                onSubtitlesTap,
                              ),
                            if (width >= 1120)
                              control(
                                sleepTimerActive ? sleepTimerLabel : '定时',
                                CupertinoIcons.moon_zzz_fill,
                                onSleepTimerTap,
                                highlighted: sleepTimerActive,
                                key: const Key('desktop-sleep-timer-button'),
                              ),
                            control(
                              isLive ? '信号' : '选集',
                              CupertinoIcons.list_bullet,
                              onEpisodesTap,
                            ),
                            if (width >= 780)
                              control(
                                '音量',
                                CupertinoIcons.volume_up,
                                onVolumeTap,
                              ),
                            control(
                              '更多',
                              CupertinoIcons.ellipsis,
                              onToggleMore,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

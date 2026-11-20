// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../apple_theme.dart';
import '../ios_liquid_glass.dart';
import 'start_spec_overlay.dart';

/// Metrics aligned 1:1 with `shared/ui-spec/motion-tokens.json`
/// `ios26PlayerGlassMetrics`.
class Ios26PlayerGlassMetrics {
  static const double topCapsuleHeightPt = 40.0;
  static const double topCapsuleRadiusPt = 20.0;
  static const double centerPrimaryButtonSizePt = 76.0;
  static const double centerSecondaryButtonSizePt = 56.0;
  static const double scrubberTrackIdleHeightPt = 5.0;
  static const double scrubberTrackExpandedHeightPt = 10.0;
  static const double dockCapsuleRadiusPt = 22.0;
  static const int maxPrimaryDockActions = 7;
}

/// Unified iOS / iPadOS 26 Concentric Spatial Cinema Player HUD.
///
/// Architectural guarantees:
/// - **Zero `UiKitView` controls** are mounted over the active 60fps video
///   texture, preventing Impeller platform-view layer slicing and capture holes.
/// - **`glasswork.frag` runs ONLY while this widget is mounted** (HUD visible);
///   unmounting on HUD hide gives zero GPU shader cost.
/// - Automatically degrades to high-contrast solid surfaces (`#F51E1E22`,
///   border alpha `>= 0.45`, zero shader refraction) under system
///   `reduceTransparency` / high-contrast mode, and graceful dark frosted glass
///   on iOS 15–18.
/// - Retires the legacy 16-item right vertical strip in favor of a streamlined
///   `<= 7`-action bottom concentric capsule dock + top-right native `…` sheet.
class IosPlayerChrome extends StatelessWidget {
  final String title;
  final String episodeName;
  final String lineName;
  final bool isLive;
  final bool playing;
  final bool loading;
  final bool buffering;
  final bool hasError;
  final Duration position;
  final Duration duration;
  final bool isScrubbing;
  final int scrubPositionMs;
  final double playbackSpeed;
  final int skipIntroSec;
  final int skipOutroSec;
  final List<PlayerSpecBadge> specBadges;
  final String fallbackSpecsLabel;
  final bool specBadgesExpanded;
  final bool isLandscape;
  final bool danmuEnabled;
  final bool sleepTimerActive;
  final bool hasMultipleLines;
  final bool storageReduceTransparency;

  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind15;
  final VoidCallback onForward15;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final ValueChanged<double> onScrubEnd;
  final VoidCallback onScrubCancel;
  final VoidCallback onEpisodesTap;
  final VoidCallback onLinesTap;
  final VoidCallback onSpeedTap;
  final VoidCallback onDanmuToggle;
  final VoidCallback onDanmuSettingsTap;
  final VoidCallback onAspectAndStrategyTap;
  final VoidCallback onAudioSubtitleTap;
  final VoidCallback onMoreTap;
  final VoidCallback onLockTap;
  final VoidCallback onFullscreenToggle;
  final VoidCallback onInteraction;

  const IosPlayerChrome({
    super.key,
    required this.title,
    required this.episodeName,
    required this.lineName,
    required this.isLive,
    required this.playing,
    required this.loading,
    required this.buffering,
    required this.hasError,
    required this.position,
    required this.duration,
    required this.isScrubbing,
    required this.scrubPositionMs,
    required this.playbackSpeed,
    required this.skipIntroSec,
    required this.skipOutroSec,
    required this.specBadges,
    required this.fallbackSpecsLabel,
    required this.specBadgesExpanded,
    required this.isLandscape,
    required this.danmuEnabled,
    required this.sleepTimerActive,
    required this.hasMultipleLines,
    required this.storageReduceTransparency,
    required this.onBack,
    required this.onPlayPause,
    required this.onRewind15,
    required this.onForward15,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onScrubCancel,
    required this.onEpisodesTap,
    required this.onLinesTap,
    required this.onSpeedTap,
    required this.onDanmuToggle,
    required this.onDanmuSettingsTap,
    required this.onAspectAndStrategyTap,
    required this.onAudioSubtitleTap,
    required this.onMoreTap,
    required this.onLockTap,
    required this.onFullscreenToggle,
    required this.onInteraction,
  });

  static String formatTimestamp(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String formatSpeedBadge(double speed) {
    final s = speed.toStringAsFixed(2);
    if (s.endsWith('00')) return '${speed.toStringAsFixed(1)}×';
    if (s.endsWith('0')) return '${speed.toStringAsFixed(1)}×';
    return '$s×';
  }

  @override
  Widget build(BuildContext context) {
    final reduceTransparency = storageReduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final ios26Visual = IosLiquidGlassBridge.isAvailable && !reduceTransparency;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isCompactWidth = width < 440;
        final isUltraCompact = width < 340;
        final horizInset = isLandscape ? 20.0 : (isUltraCompact ? 10.0 : 14.0);
        final topInset = isLandscape ? 12.0 : 10.0;
        final bottomInset = isLandscape ? 14.0 : 12.0;

        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Subtle cinema gradient scrims for guaranteed typography legibility
              // over bright video scenes (pure gradient, zero blur overhead).
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 112,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x99000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 156,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xAD000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),

              SafeArea(
                child: Stack(
                  key: const Key('ios-player-chrome-root'),
                  fit: StackFit.expand,
                  children: [
                    // 1. Top Spatial Floating Header (40pt concentric capsules)
                    Positioned(
                      left: horizInset,
                      right: horizInset,
                      top: topInset,
                      child: _buildTopSpatialHeader(
                        context,
                        width: width,
                        isCompactWidth: isCompactWidth,
                        isUltraCompact: isUltraCompact,
                        ios26Visual: ios26Visual,
                        reduceTransparency: reduceTransparency,
                        reduceMotion: reduceMotion,
                      ),
                    ),

                    // 2. Center Refractive Transport (56pt / 76pt / 56pt)
                    if (!loading && !buffering && !hasError)
                      Center(
                        child: _buildCenterTransport(
                          ios26Visual: ios26Visual,
                          reduceTransparency: reduceTransparency,
                          reduceMotion: reduceMotion,
                          isUltraCompact: isUltraCompact,
                        ),
                      ),

                    // 3. Bottom Fluid Scrubber + Streamlined <=7 Primary Capsule Dock
                    Positioned(
                      left: horizInset,
                      right: horizInset,
                      bottom: bottomInset,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isLandscape ? 680.0 : 580.0,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isLive) ...[
                                IosFluidScrubberCapsule(
                                  key: const Key('player-progress-bar'),
                                  position: position,
                                  duration: duration,
                                  isScrubbing: isScrubbing,
                                  scrubPositionMs: scrubPositionMs,
                                  skipIntroSec: skipIntroSec,
                                  skipOutroSec: skipOutroSec,
                                  ios26Visual: ios26Visual,
                                  reduceTransparency: reduceTransparency,
                                  reduceMotion: reduceMotion,
                                  onInteraction: onInteraction,
                                  onScrubStart: onScrubStart,
                                  onScrubUpdate: onScrubUpdate,
                                  onScrubEnd: onScrubEnd,
                                  onScrubCancel: onScrubCancel,
                                ),
                                const SizedBox(height: 10),
                              ],
                              _buildPrimaryCapsuleDock(
                                width: width,
                                ios26Visual: ios26Visual,
                                reduceTransparency: reduceTransparency,
                                reduceMotion: reduceMotion,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopSpatialHeader(
    BuildContext context, {
    required double width,
    required bool isCompactWidth,
    required bool isUltraCompact,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    return Listener(
      key: const Key('ios-player-top-header-hit-area'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onInteraction(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
        // Left: 40pt concentric rounded glass back capsule (radius = 20pt).
        _IosRefractivePressButton(
          key: const Key('ios-player-back-button'),
          reduceMotion: reduceMotion,
          onTap: () {
            onInteraction();
            onBack();
          },
          child: _IosSpatialGlassSurface(
            height: Ios26PlayerGlassMetrics.topCapsuleHeightPt,
            width: isUltraCompact
                ? Ios26PlayerGlassMetrics.topCapsuleHeightPt
                : null,
            borderRadius: Ios26PlayerGlassMetrics.topCapsuleRadiusPt,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            padding: isUltraCompact
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.chevron_back,
                  color: AppleColors.labelPrimary,
                  size: 18,
                ),
                if (!isUltraCompact) ...[
                  const SizedBox(width: 4),
                  const Text(
                    '返回',
                    maxLines: 1,
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Center: crisp title/episode hierarchy + integrated dynamic spec badge bar
        // (strictly inside Expanded so it NEVER collides with the left back capsule).
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                  ),
                  if (isLive) ...[
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppleColors.systemRed.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '直播中',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              if (isCompactWidth) ...[
                Text(
                  '$episodeName · $lineName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (specBadges.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  InlineSpecBadgeRow(
                    badges: specBadges,
                    expanded: specBadgesExpanded,
                    concentric: true,
                    reduceTransparency: reduceTransparency,
                  ),
                ] else if (fallbackSpecsLabel.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    key: const Key('player-video-specs'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: reduceTransparency
                          ? const Color(0xEB25252B)
                          : const Color(0x3DFFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: reduceTransparency ? 0.45 : 0.22,
                        ),
                        width: 0.7,
                      ),
                    ),
                    child: Text(
                      fallbackSpecsLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ] else
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '$episodeName · $lineName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (specBadges.isNotEmpty) ...[
                      const SizedBox(width: 7),
                      Flexible(
                        child: InlineSpecBadgeRow(
                          badges: specBadges,
                          expanded: specBadgesExpanded,
                          concentric: true,
                          reduceTransparency: reduceTransparency,
                        ),
                      ),
                    ] else if (fallbackSpecsLabel.isNotEmpty) ...[
                      const SizedBox(width: 7),
                      Container(
                        key: const Key('player-video-specs'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: reduceTransparency
                              ? const Color(0xEB25252B)
                              : const Color(0x3DFFFFFF),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: reduceTransparency ? 0.45 : 0.22,
                            ),
                            width: 0.7,
                          ),
                        ),
                        child: Text(
                          fallbackSpecsLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),

        const SizedBox(width: 10),

        // Right: 40pt circular glass quick group (auto-collapses cleanly on narrow widths).
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isUltraCompact && (!isCompactWidth || width >= 370)) ...[
              _buildTopCircleButton(
                key: const Key('ios-player-danmu-quick'),
                icon: danmuEnabled
                    ? CupertinoIcons.chat_bubble_text_fill
                    : CupertinoIcons.chat_bubble_text,
                active: danmuEnabled,
                semanticLabel: '弹幕开关',
                ios26Visual: ios26Visual,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                onTap: onDanmuToggle,
              ),
              const SizedBox(width: 8),
            ],
            if (!isCompactWidth) ...[
              _buildTopCircleButton(
                key: const Key('ios-player-tracks-button'),
                icon: CupertinoIcons.captions_bubble_fill,
                active: false,
                semanticLabel: '音轨与字幕',
                ios26Visual: ios26Visual,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                onTap: onAudioSubtitleTap,
              ),
              const SizedBox(width: 8),
            ],
            _buildTopCircleButton(
              key: const Key('ios-player-more-button'),
              icon: CupertinoIcons.ellipsis,
              active: sleepTimerActive,
              showDot: sleepTimerActive,
              semanticLabel: '更多与定时关闭',
              ios26Visual: ios26Visual,
              reduceTransparency: reduceTransparency,
              reduceMotion: reduceMotion,
              onTap: onMoreTap,
            ),
          ],
        ),
      ],
      ),
    );
  }

  Widget _buildTopCircleButton({
    required Key key,
    required IconData icon,
    required bool active,
    required String semanticLabel,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
    required VoidCallback onTap,
    bool showDot = false,
  }) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: _IosRefractivePressButton(
        key: key,
        reduceMotion: reduceMotion,
        onTap: () {
          onInteraction();
          onTap();
        },
        child: _IosSpatialGlassSurface(
          width: Ios26PlayerGlassMetrics.topCapsuleHeightPt,
          height: Ios26PlayerGlassMetrics.topCapsuleHeightPt,
          borderRadius: Ios26PlayerGlassMetrics.topCapsuleRadiusPt,
          ios26Visual: ios26Visual,
          reduceTransparency: reduceTransparency,
          tint: active ? AppleColors.systemBlue : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                color: active ? Colors.white : AppleColors.labelPrimary,
                size: 18,
              ),
              if (showDot)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 6.5,
                    height: 6.5,
                    decoration: const BoxDecoration(
                      color: AppleColors.systemOrange,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterTransport({
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
    required bool isUltraCompact,
  }) {
    final playButton = _IosRefractivePressButton(
      key: const Key('player-center-play-pause'),
      reduceMotion: reduceMotion,
      onTap: () {
        onInteraction();
        onPlayPause();
      },
      child: _IosSpatialGlassSurface(
        width: Ios26PlayerGlassMetrics.centerPrimaryButtonSizePt,
        height: Ios26PlayerGlassMetrics.centerPrimaryButtonSizePt,
        borderRadius: Ios26PlayerGlassMetrics.centerPrimaryButtonSizePt * 0.5,
        ios26Visual: ios26Visual,
        reduceTransparency: reduceTransparency,
        heroHighlight: true,
        child: Center(
          child: Icon(
            playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
            color: Colors.white,
            size: 34,
          ),
        ),
      ),
    );

    if (isLive) return playButton;

    final gap = isUltraCompact ? 20.0 : 32.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IosRefractivePressButton(
          key: const Key('player-center-rewind'),
          reduceMotion: reduceMotion,
          onTap: () {
            onInteraction();
            onRewind15();
          },
          child: _IosSpatialGlassSurface(
            width: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            height: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            borderRadius:
                Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt * 0.5,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            child: const Center(
              child: Icon(
                CupertinoIcons.gobackward_15,
                color: AppleColors.labelPrimary,
                size: 25,
              ),
            ),
          ),
        ),
        SizedBox(width: gap),
        playButton,
        SizedBox(width: gap),
        _IosRefractivePressButton(
          key: const Key('player-center-forward'),
          reduceMotion: reduceMotion,
          onTap: () {
            onInteraction();
            onForward15();
          },
          child: _IosSpatialGlassSurface(
            width: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            height: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            borderRadius:
                Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt * 0.5,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            child: const Center(
              child: Icon(
                CupertinoIcons.goforward_15,
                color: AppleColors.labelPrimary,
                size: 25,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrimaryCapsuleDock({
    required double width,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    final actions = <_IosDockAction>[
      _IosDockAction(
        id: 'episodes',
        icon: CupertinoIcons.square_grid_2x2_fill,
        label: isLive ? '信号' : '选集',
        onTap: onEpisodesTap,
      ),
      if (hasMultipleLines || !isLive)
        _IosDockAction(
          id: 'lines',
          icon: CupertinoIcons.layers_alt_fill,
          label: '线路',
          onTap: onLinesTap,
        ),
      if (!isLive)
        _IosDockAction(
          id: 'speed',
          icon: CupertinoIcons.speedometer,
          label: formatSpeedBadge(playbackSpeed),
          active: (playbackSpeed - 1.0).abs() > 0.01,
          onTap: onSpeedTap,
        ),
      _IosDockAction(
        id: 'danmu',
        icon: CupertinoIcons.chat_bubble_text_fill,
        label: '弹幕',
        active: danmuEnabled,
        onTap: onDanmuSettingsTap,
      ),
      _IosDockAction(
        id: 'aspect',
        icon: CupertinoIcons.slider_horizontal_3,
        label: '画面',
        onTap: onAspectAndStrategyTap,
      ),
      _IosDockAction(
        key: const Key('player-lock-button'),
        id: 'lock',
        icon: CupertinoIcons.lock_open_fill,
        label: '锁屏',
        onTap: onLockTap,
      ),
      _IosDockAction(
        key: const Key('player-fullscreen-toggle'),
        id: 'fullscreen',
        icon: isLandscape
            ? CupertinoIcons.fullscreen_exit
            : CupertinoIcons.fullscreen,
        label: isLandscape ? '竖屏' : '全屏',
        onTap: onFullscreenToggle,
      ),
    ];

    final bounded = actions
        .take(Ios26PlayerGlassMetrics.maxPrimaryDockActions)
        .toList(growable: false);
    final dockKey = isLandscape
        ? const Key('ios-player-primary-dock')
        : const Key('player-tool-dock-portrait');
    final useScrollable = width < 430;

    final rowChildren = <Widget>[
      for (var i = 0; i < bounded.length; i++)
        useScrollable
            ? Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                child: _buildDockActionButton(
                  bounded[i],
                  compact: true,
                  reduceMotion: reduceMotion,
                ),
              )
            : Expanded(
                child: _buildDockActionButton(
                  bounded[i],
                  compact: width < 460,
                  reduceMotion: reduceMotion,
                ),
              ),
    ];

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onInteraction(),
      child: _IosSpatialGlassSurface(
        key: dockKey,
        borderRadius: Ios26PlayerGlassMetrics.dockCapsuleRadiusPt,
        ios26Visual: ios26Visual,
        reduceTransparency: reduceTransparency,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: useScrollable
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(mainAxisSize: MainAxisSize.min, children: rowChildren),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: rowChildren,
              ),
      ),
    );
  }

  Widget _buildDockActionButton(
    _IosDockAction action, {
    required bool compact,
    required bool reduceMotion,
  }) {
    final fg = action.active ? AppleColors.systemCyan : AppleColors.labelPrimary;
    return _IosRefractivePressButton(
      key: action.key ?? ValueKey('ios-dock-action-${action.id}'),
      reduceMotion: reduceMotion,
      onTap: () {
        onInteraction();
        action.onTap();
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 6,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: action.active
              ? AppleColors.systemBlue.withValues(alpha: 0.24)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, color: fg, size: compact ? 17 : 18),
            const SizedBox(height: 3),
            Text(
              action.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: action.active ? fg : AppleColors.labelSecondary,
                fontSize: 10.5,
                fontWeight: action.active ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IosDockAction {
  final Key? key;
  final String id;
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _IosDockAction({
    this.key,
    required this.id,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
}

/// Interactive fluid expanding scrubber capsule for iOS/iPadOS 26:
/// - Resting track height: `5pt` (`scrubberTrackIdleHeightPt`).
/// - Active touch/drag height: springs to `10pt` (`scrubberTrackExpandedHeightPt`)
///   via the `hudPopup` physical spring (`response: 0.28, dampingRatio: 0.86`,
///   instant snap when `reduceMotion` is enabled) with subtle luminous glow,
///   tabular numeric timestamps, strict single-pointer `pointerId` tracking,
///   opaque capsule hit absorption, and intro/outro ticks.
class IosFluidScrubberCapsule extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final bool isScrubbing;
  final int scrubPositionMs;
  final int skipIntroSec;
  final int skipOutroSec;
  final bool ios26Visual;
  final bool reduceTransparency;
  final bool reduceMotion;
  final VoidCallback? onInteraction;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final ValueChanged<double> onScrubEnd;
  final VoidCallback onScrubCancel;

  const IosFluidScrubberCapsule({
    super.key,
    required this.position,
    required this.duration,
    required this.isScrubbing,
    required this.scrubPositionMs,
    required this.skipIntroSec,
    required this.skipOutroSec,
    required this.ios26Visual,
    required this.reduceTransparency,
    required this.reduceMotion,
    this.onInteraction,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onScrubCancel,
  });

  @override
  State<IosFluidScrubberCapsule> createState() =>
      _IosFluidScrubberCapsuleState();
}

class _IosFluidScrubberCapsuleState extends State<IosFluidScrubberCapsule>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _hudPopupSpring =
      SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: (2 * math.pi / 0.28) * (2 * math.pi / 0.28),
    ratio: 0.86,
  );

  late final AnimationController _expandCtrl = AnimationController.unbounded(
    vsync: this,
    value: widget.isScrubbing ? 1.0 : 0.0,
  );

  int? _activePointerId;
  double _localDragMs = 0;

  bool get _pointerActive => _activePointerId != null;
  bool get _expanded => _pointerActive || widget.isScrubbing;

  void _syncSpringExpansion() {
    final target = _expanded ? 1.0 : 0.0;
    if (widget.reduceMotion) {
      _expandCtrl.stop();
      _expandCtrl.value = target;
      return;
    }
    final sim = SpringSimulation(
      _hudPopupSpring,
      _expandCtrl.value,
      target,
      _expandCtrl.velocity,
    );
    _expandCtrl.animateWith(sim);
  }

  @override
  void didUpdateWidget(covariant IosFluidScrubberCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isScrubbing != widget.isScrubbing ||
        oldWidget.reduceMotion != widget.reduceMotion) {
      _syncSpringExpansion();
    }
  }

  @override
  void dispose() {
    final wasDragging = _activePointerId != null;
    _activePointerId = null;
    _expandCtrl.dispose();
    if (wasDragging) {
      widget.onScrubCancel();
    }
    super.dispose();
  }

  double _valueForLocalX(double localX, double trackWidth) {
    final durMs = widget.duration.inMilliseconds;
    if (durMs <= 0 || trackWidth <= 0) return 0;
    final ratio = (localX / trackWidth).clamp(0.0, 1.0);
    return ratio * durMs;
  }

  @override
  Widget build(BuildContext context) {
    final durMs = widget.duration.inMilliseconds;
    final hasDuration = durMs > 0;
    final activeMs = _pointerActive
        ? _localDragMs
        : (widget.isScrubbing
            ? widget.scrubPositionMs.toDouble()
            : widget.position.inMilliseconds.toDouble());
    final clampedMs = hasDuration ? activeMs.clamp(0.0, durMs.toDouble()) : 0.0;
    final fraction = hasDuration ? (clampedMs / durMs).clamp(0.0, 1.0) : 0.0;
    final currentDuration = Duration(milliseconds: clampedMs.round());
    final remainingMs = math.max(0, durMs - clampedMs.round());
    final remainingLabel = hasDuration
        ? '-${IosPlayerChrome.formatTimestamp(Duration(milliseconds: remainingMs))}'
        : '--:--';

    final introFrac = hasDuration && widget.skipIntroSec > 0
        ? ((widget.skipIntroSec * 1000) / durMs).clamp(0.0, 1.0)
        : null;
    final outroFrac =
        hasDuration && widget.skipOutroSec > 0 && durMs > widget.skipOutroSec * 1000
            ? ((durMs - widget.skipOutroSec * 1000) / durMs).clamp(0.0, 1.0)
            : null;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (!_pointerActive) {
          widget.onInteraction?.call();
        }
      },
      child: _IosSpatialGlassSurface(
        borderRadius: Ios26PlayerGlassMetrics.dockCapsuleRadiusPt,
        ios26Visual: widget.ios26Visual,
        reduceTransparency: widget.reduceTransparency,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        child: Row(
          children: [
            Text(
              IosPlayerChrome.formatTimestamp(currentDuration),
              key: const Key('ios-fluid-scrubber-elapsed'),
              style: const TextStyle(
                color: AppleColors.labelPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final trackW = math.max(1.0, constraints.maxWidth);
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: hasDuration
                        ? (event) {
                            if (_activePointerId != null) return;
                            final nextMs =
                                _valueForLocalX(event.localPosition.dx, trackW);
                            HapticFeedback.selectionClick();
                            setState(() {
                              _activePointerId = event.pointer;
                              _localDragMs = nextMs;
                            });
                            _syncSpringExpansion();
                            widget.onScrubStart(nextMs);
                          }
                        : null,
                    onPointerMove: hasDuration
                        ? (event) {
                            if (event.pointer != _activePointerId) return;
                            final nextMs =
                                _valueForLocalX(event.localPosition.dx, trackW);
                            setState(() => _localDragMs = nextMs);
                            widget.onScrubUpdate(nextMs);
                          }
                        : null,
                    onPointerUp: hasDuration
                        ? (event) {
                            if (event.pointer != _activePointerId) return;
                            final nextMs =
                                _valueForLocalX(event.localPosition.dx, trackW);
                            setState(() => _activePointerId = null);
                            _syncSpringExpansion();
                            widget.onScrubEnd(nextMs);
                          }
                        : null,
                    onPointerCancel: hasDuration
                        ? (event) {
                            if (event.pointer != _activePointerId) return;
                            setState(() => _activePointerId = null);
                            _syncSpringExpansion();
                            widget.onScrubCancel();
                          }
                        : null,
                    child: GestureDetector(
                      key: const Key('ios-fluid-scrubber-hit-area'),
                      behavior: HitTestBehavior.opaque,
                      // Claim horizontal drag in gesture arena so parent scroll/
                      // video gestures never steal active scrubber drags.
                      onHorizontalDragStart: hasDuration ? (_) {} : null,
                      onHorizontalDragUpdate: hasDuration ? (_) {} : null,
                      onHorizontalDragEnd: hasDuration ? (_) {} : null,
                      child: SizedBox(
                        height: 28,
                        child: Center(
                          child: AnimatedBuilder(
                            animation: _expandCtrl,
                            builder: (context, _) {
                              final t = _expandCtrl.value;
                              final trackHeight =
                                  (Ios26PlayerGlassMetrics.scrubberTrackIdleHeightPt +
                                          (Ios26PlayerGlassMetrics
                                                      .scrubberTrackExpandedHeightPt -
                                                  Ios26PlayerGlassMetrics
                                                      .scrubberTrackIdleHeightPt) *
                                              t)
                                      .clamp(3.0, 14.0);
                              final glowActive =
                                  t > 0.15 && !widget.reduceTransparency;
                              return Container(
                                key: const Key('ios-fluid-scrubber-track'),
                                height: trackHeight,
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: widget.reduceTransparency
                                      ? const Color(0x66FFFFFF)
                                      : const Color(0x3DFFFFFF),
                                  borderRadius:
                                      BorderRadius.circular(trackHeight * 0.5),
                                  boxShadow: glowActive
                                      ? [
                                          BoxShadow(
                                            color: Colors.white.withValues(
                                              alpha: (0.22 * t).clamp(0.0, 0.28),
                                            ),
                                            blurRadius: 10,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: ClipRRect(
                                  borderRadius:
                                      BorderRadius.circular(trackHeight * 0.5),
                                  child: CustomPaint(
                                    painter: _FluidTrackPainter(
                                      fraction: fraction,
                                      expanded: _expanded,
                                      introMarker: introFrac,
                                      outroMarker: outroFrac,
                                      reduceTransparency:
                                          widget.reduceTransparency,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 11),
            Text(
              remainingLabel,
              key: const Key('ios-fluid-scrubber-remaining'),
              style: const TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FluidTrackPainter extends CustomPainter {
  final double fraction;
  final bool expanded;
  final double? introMarker;
  final double? outroMarker;
  final bool reduceTransparency;

  const _FluidTrackPainter({
    required this.fraction,
    required this.expanded,
    required this.introMarker,
    required this.outroMarker,
    required this.reduceTransparency,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fillW = (size.width * fraction).clamp(0.0, size.width);
    if (fillW > 0) {
      final fillRect = Rect.fromLTWH(0, 0, fillW, size.height);
      final paint = Paint();
      if (expanded && !reduceTransparency) {
        paint.shader = const LinearGradient(
          colors: [Color(0xFFEBF5FF), Color(0xFFFFFFFF)],
        ).createShader(fillRect);
      } else {
        paint.color = Colors.white.withValues(alpha: expanded ? 1.0 : 0.92);
      }
      canvas.drawRect(fillRect, paint);
    }

    final markerPaint = Paint()..color = const Color(0xE6FFD60A);
    if (introMarker != null && introMarker! > 0.01 && introMarker! < 0.99) {
      final x = size.width * introMarker!;
      canvas.drawRect(Rect.fromLTWH(x - 1.0, 0, 2.0, size.height), markerPaint);
    }
    if (outroMarker != null && outroMarker! > 0.01 && outroMarker! < 0.99) {
      final x = size.width * outroMarker!;
      canvas.drawRect(Rect.fromLTWH(x - 1.0, 0, 2.0, size.height), markerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FluidTrackPainter old) =>
      old.fraction != fraction ||
      old.expanded != expanded ||
      old.introMarker != introMarker ||
      old.outroMarker != outroMarker ||
      old.reduceTransparency != reduceTransparency;
}

/// Tactile spring-like press feedback matching `pressFeedback` (`0.16s`) and
/// `MarcoInteractiveCircleGlassControl` highlight compression.
class _IosRefractivePressButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool reduceMotion;

  const _IosRefractivePressButton({
    super.key,
    required this.child,
    required this.onTap,
    required this.reduceMotion,
  });

  @override
  State<_IosRefractivePressButton> createState() =>
      _IosRefractivePressButtonState();
}

class _IosRefractivePressButtonState extends State<_IosRefractivePressButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        if (!_pressed) setState(() => _pressed = true);
      },
      onTapUp: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      onTapCancel: () {
        if (_pressed) setState(() => _pressed = false);
      },
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: (!widget.reduceMotion && _pressed) ? 0.92 : 1.0,
        duration: Duration(milliseconds: widget.reduceMotion ? 0 : 160),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// 135° directional specular rim matched 1:1 with Home/Detail `_LiquidRimPainter`
/// in `apple_theme.dart`: bright top-left highlight, quiet sides, subtle
/// bottom-right bounce light, and thin inner top glass thickness glow.
class _IosSpatialRimPainter extends CustomPainter {
  final ShapeBorder shape;
  final double strength;

  const _IosSpatialRimPainter({required this.shape, this.strength = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final outer = shape.getOuterPath(rect.deflate(0.5));
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.54 * strength),
          Colors.white.withValues(alpha: 0.16 * strength),
          Colors.white.withValues(alpha: 0.06 * strength),
          Colors.white.withValues(alpha: 0.24 * strength),
        ],
        stops: const [0.0, 0.30, 0.68, 1.0],
      ).createShader(rect);
    canvas.drawPath(outer, rim);

    final inner = shape.getOuterPath(rect.deflate(1.5));
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.26 * strength),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.08 * strength),
        ],
        stops: const [0.0, 0.46, 1.0],
      ).createShader(rect);
    canvas.drawPath(inner, glow);
  }

  @override
  bool shouldRepaint(covariant _IosSpatialRimPainter old) =>
      old.shape != shape || old.strength != strength;
}

/// Concentric Liquid Glass surface unified with Home/Detail `LiquidGlass` +
/// `_LiquidRimPainter` in `apple_theme.dart`:
/// - On iOS 26+ (`ios26Visual == true` and `!reduceTransparency`), mounts
///   `GlassworkBackdrop` (`glasswork.frag`) with dark obsidian tint (`#3D161820`)
///   and 135° directional specular rim (unmounts completely when HUD hides ->
///   0 GPU cost).
/// - On iOS 15–18 (`ios26Visual == false` and `!reduceTransparency`), renders a
///   lightweight high-contrast dark obsidian translucent fallback with 135°
///   directional rim and NEVER mounts `GlassworkBackdrop` (0 shader passes).
/// - Under `reduceTransparency`, renders opaque `#F51E1E22` with `>= 0.45` rim
///   and 0 shader passes.
class _IosSpatialGlassSurface extends StatelessWidget {
  static const Color _darkGlassTint = Color(0x3D161820);
  static const Color _heroDarkGlassTint = Color(0x52161820);

  final Widget child;
  final double? width;
  final double? height;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool ios26Visual;
  final bool reduceTransparency;
  final bool heroHighlight;
  final Color? tint;

  const _IosSpatialGlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.ios26Visual,
    required this.reduceTransparency,
    this.width,
    this.height,
    this.padding,
    this.heroHighlight = false,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final shape = RoundedRectangleBorder(borderRadius: radius);

    if (reduceTransparency) {
      final base = tint != null
          ? Color.alphaBlend(
              tint!.withValues(alpha: 0.72),
              const Color(0xF51E1E22),
            )
          : (heroHighlight
              ? const Color(0xF526272E)
              : const Color(0xF51E1E22));
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Container(
          width: width,
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: base,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.48),
              width: 1.0,
            ),
          ),
          child: child,
        ),
      );
    }

    // iOS 15–18 / non-iOS26 fallback: lightweight high-contrast dark obsidian
    // translucent surface with 135° specular rim and ZERO GlassworkBackdrop.
    if (!ios26Visual) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: [
            BoxShadow(
              color: heroHighlight
                  ? const Color(0x59000000)
                  : const Color(0x45000000),
              blurRadius: heroHighlight ? 22 : 14,
              offset: Offset(0, heroHighlight ? 8 : 5),
            ),
            const BoxShadow(
              color: Color(0x26000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            foregroundPainter: _IosSpatialRimPainter(
              shape: shape,
              strength: heroHighlight ? 0.92 : 0.76,
            ),
            child: Container(
              width: width,
              height: height,
              padding: padding,
              decoration: ShapeDecoration(
                shape: shape,
                gradient: _fallbackTranslucentGradient(),
              ),
              child: child,
            ),
          ),
        ),
      );
    }

    // iOS 26+ Liquid Glass surface: unified dark obsidian tint (#3D161820) +
    // GlassworkBackdrop + 135° directional specular rim matching Home/Detail.
    final baseTint = tint ?? (heroHighlight ? _heroDarkGlassTint : _darkGlassTint);
    final rimMultiplier = heroHighlight ? 1.12 : 1.0;

    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: [
          BoxShadow(
            color: heroHighlight
                ? const Color(0x66000000)
                : const Color(0x59000000),
            blurRadius: heroHighlight ? 30 : 24,
            offset: Offset(0, heroHighlight ? 12 : 10),
          ),
          const BoxShadow(
            color: Color(0x26000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        clipBehavior: Clip.antiAlias,
        child: GlassworkBackdrop(
          radius: borderRadius,
          child: ValueListenableBuilder<double>(
            valueListenable: GlassworkBackdrop.intensity,
            builder: (context, strength, _) {
              final s = strength.clamp(0.0, 1.0);
              return CustomPaint(
                foregroundPainter: _IosSpatialRimPainter(
                  shape: shape,
                  strength: rimMultiplier * (0.28 + 0.92 * s),
                ),
                child: Container(
                  width: width,
                  height: height,
                  padding: padding,
                  decoration: ShapeDecoration(
                    shape: shape,
                    gradient: _ios26RefractiveGradient(baseTint, s),
                  ),
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  LinearGradient _ios26RefractiveGradient(Color baseTint, double s) {
    if (tint != null) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            Color.fromRGBO(255, 255, 255, 0.04 + 0.08 * s),
            tint!.withValues(alpha: 0.60),
          ),
          tint!.withValues(alpha: 0.46),
          Color.alphaBlend(
            Color.fromRGBO(255, 255, 255, 0.02 + 0.045 * s),
            tint!.withValues(alpha: 0.52),
          ),
        ],
        stops: const [0.0, 0.52, 1.0],
      );
    }
    final topSpecAlpha = (heroHighlight ? 0.05 : 0.03) + 0.08 * s;
    final bottomSpecAlpha = (heroHighlight ? 0.02 : 0.015) + 0.045 * s;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          Color.fromRGBO(255, 255, 255, topSpecAlpha),
          baseTint,
        ),
        baseTint,
        Color.alphaBlend(
          Color.fromRGBO(255, 255, 255, bottomSpecAlpha),
          baseTint,
        ),
      ],
      stops: const [0.0, 0.52, 1.0],
    );
  }

  LinearGradient _fallbackTranslucentGradient() {
    if (tint != null) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            tint!.withValues(alpha: 0.70),
            const Color(0xCC161820),
          ),
          Color.alphaBlend(
            tint!.withValues(alpha: 0.56),
            const Color(0xC2161820),
          ),
        ],
      );
    }
    if (heroHighlight) {
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xD4232630), Color(0xC8161820), Color(0xD01C1E27)],
        stops: [0.0, 0.52, 1.0],
      );
    }
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xC41E2029), Color(0xB8161820), Color(0xC01A1C25)],
      stops: [0.0, 0.52, 1.0],
    );
  }
}

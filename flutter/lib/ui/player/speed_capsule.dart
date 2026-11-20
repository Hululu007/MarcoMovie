// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;

import '../apple_theme.dart';
import '../ios_liquid_glass.dart';

/// Display mode for [PlayerSpeedCapsule].
enum SpeedCapsuleMode {
  hidden,
  boosting,
  lockReady,
  locked,
}

/// Top-center speed boost / swipe-up lock capsule aligned with
/// `player-hud-spec.md §4.3` and `motion-tokens.json`.
///
/// - [SpeedCapsuleMode.boosting]: `"⏩ 2.0× 倍速播放中"` + 4 detent ticks +
///   `"左右滑动调速 · 上滑锁定"`.
/// - [SpeedCapsuleMode.lockReady]: accented lock-ready state
///   `"松手即可锁定 2.0×"`.
/// - [SpeedCapsuleMode.locked]: compact tappable capsule
///   `"🔒 2.0× 锁定中 · 点击恢复"` that dims to `0.72` opacity after 3 seconds.
class PlayerSpeedCapsule extends StatefulWidget {
  final SpeedCapsuleMode mode;
  final double speed;
  final int activeDetentIndex;
  final List<double> detents;
  final VoidCallback? onUnlockTap;
  final bool reduceTransparency;

  const PlayerSpeedCapsule({
    super.key,
    required this.mode,
    required this.speed,
    this.activeDetentIndex = 2,
    this.detents = const <double>[1.25, 1.5, 2.0, 3.0],
    this.onUnlockTap,
    this.reduceTransparency = false,
  });

  static String formatSpeed(double value) {
    final fixed = value.toStringAsFixed(2);
    if (fixed.endsWith('00')) return value.toStringAsFixed(1);
    if (fixed.endsWith('0')) return value.toStringAsFixed(1);
    return fixed;
  }

  @override
  State<PlayerSpeedCapsule> createState() => _PlayerSpeedCapsuleState();
}

class _PlayerSpeedCapsuleState extends State<PlayerSpeedCapsule> {
  Timer? _dimTimer;
  bool _dimmedLocked = false;

  @override
  void initState() {
    super.initState();
    _syncLockedDimTimer();
  }

  @override
  void didUpdateWidget(covariant PlayerSpeedCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode || oldWidget.speed != widget.speed) {
      _syncLockedDimTimer();
    }
  }

  void _syncLockedDimTimer() {
    _dimTimer?.cancel();
    _dimTimer = null;
    if (widget.mode == SpeedCapsuleMode.locked) {
      if (_dimmedLocked) {
        _dimmedLocked = false;
      }
      _dimTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && widget.mode == SpeedCapsuleMode.locked) {
          setState(() => _dimmedLocked = true);
        }
      });
    } else {
      _dimmedLocked = false;
    }
  }

  @override
  void dispose() {
    _dimTimer?.cancel();
    _dimTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == SpeedCapsuleMode.hidden) {
      return const SizedBox.shrink();
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final effectiveReduce = widget.reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final speedLabel = PlayerSpeedCapsule.formatSpeed(widget.speed);

    if (widget.mode == SpeedCapsuleMode.locked) {
      final bgColor =
          effectiveReduce ? const Color(0xF51E1E22) : const Color(0xC814151B);
      final borderColor = effectiveReduce
          ? Colors.white.withValues(alpha: 0.48)
          : AppleColors.systemCyan.withValues(alpha: 0.55);
      return AnimatedOpacity(
        opacity: _dimmedLocked ? 0.72 : 1.0,
        duration: Duration(milliseconds: reduceMotion ? 120 : 220),
        child: GestureDetector(
          key: const Key('player-speed-locked-capsule'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onUnlockTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7.5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: borderColor, width: 0.9),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x4D000000),
                  blurRadius: 14,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  CupertinoIcons.lock_fill,
                  color: AppleColors.systemCyan,
                  size: 13.5,
                ),
                const SizedBox(width: 6),
                Text(
                  '$speedLabel× 锁定中 · 点击恢复',
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isLockReady = widget.mode == SpeedCapsuleMode.lockReady;
    final bgColor = effectiveReduce
        ? const Color(0xF51E1E22)
        : (isLockReady ? const Color(0xE013233A) : const Color(0xD416171E));
    final borderColor = isLockReady
        ? AppleColors.systemBlue.withValues(alpha: 0.9)
        : Colors.white.withValues(alpha: effectiveReduce ? 0.48 : 0.24);

    return IgnorePointer(
      child: AnimatedScale(
        scale: (!reduceMotion && isLockReady) ? 1.04 : 1.0,
        duration: Duration(milliseconds: reduceMotion ? 0 : 180),
        curve: Curves.easeOutCubic,
        child: Container(
          key: Key(
            isLockReady
                ? 'player-speed-lock-ready-capsule'
                : 'player-speed-boosting-capsule',
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: borderColor,
              width: isLockReady ? 1.2 : 0.85,
            ),
            boxShadow: [
              BoxShadow(
                color: isLockReady
                    ? AppleColors.systemBlue.withValues(alpha: 0.28)
                    : const Color(0x52000000),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isLockReady
                        ? CupertinoIcons.lock_fill
                        : CupertinoIcons.forward_fill,
                    color: isLockReady
                        ? AppleColors.systemCyan
                        : AppleColors.labelPrimary,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$speedLabel× 倍速播放中',
                    style: const TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.detents.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    _DetentPill(
                      label:
                          '${PlayerSpeedCapsule.formatSpeed(widget.detents[i])}×',
                      active: i == widget.activeDetentIndex,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 5),
              Text(
                isLockReady ? '松手即可锁定 $speedLabel×' : '左右滑动调速 · 上滑锁定',
                style: TextStyle(
                  color: isLockReady
                      ? AppleColors.systemCyan
                      : AppleColors.labelSecondary,
                  fontSize: 11.5,
                  fontWeight: isLockReady ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetentPill extends StatelessWidget {
  final String label;
  final bool active;

  const _DetentPill({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: active ? AppleColors.systemBlue : const Color(0x24FFFFFF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.white : AppleColors.labelSecondary,
          fontSize: 10.5,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

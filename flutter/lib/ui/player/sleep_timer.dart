// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;

import '../apple_theme.dart';
import '../ios_liquid_glass.dart';

/// Session-scoped sleep timer presets (`off` on cold start).
enum SleepTimerMode {
  off,
  minutes15,
  minutes30,
  minutes60,
  minutes90,
  endOfEpisode,
}

extension SleepTimerModeLabel on SleepTimerMode {
  String get label => switch (this) {
        SleepTimerMode.off => '关闭',
        SleepTimerMode.minutes15 => '15 分钟',
        SleepTimerMode.minutes30 => '30 分钟',
        SleepTimerMode.minutes60 => '60 分钟',
        SleepTimerMode.minutes90 => '90 分钟',
        SleepTimerMode.endOfEpisode => '播完本集',
      };

  int? get durationSeconds => switch (this) {
        SleepTimerMode.off => null,
        SleepTimerMode.minutes15 => 15 * 60,
        SleepTimerMode.minutes30 => 30 * 60,
        SleepTimerMode.minutes60 => 60 * 60,
        SleepTimerMode.minutes90 => 90 * 60,
        SleepTimerMode.endOfEpisode => null,
      };
}

/// Session-only sleep timer controller with 30-second pre-expiry warning,
/// `+15m` extension, cancel, and end-of-episode trigger.
class SleepTimerController extends ChangeNotifier {
  static const int warningWindowSeconds = 30;
  static const int extendSeconds = 15 * 60;

  final VoidCallback onTriggered;
  final Duration tickInterval;

  SleepTimerMode _mode = SleepTimerMode.off;
  int _remainingSeconds = 0;
  Timer? _timer;
  bool _disposed = false;

  SleepTimerController({
    required this.onTriggered,
    this.tickInterval = const Duration(seconds: 1),
  });

  SleepTimerMode get mode => _mode;
  bool get isActive => _mode != SleepTimerMode.off;
  int get remainingSeconds => _remainingSeconds;
  bool get isCountdownMode =>
      _mode != SleepTimerMode.off && _mode != SleepTimerMode.endOfEpisode;

  /// True during the final 30 seconds before automatic pause.
  bool get showWarningBanner =>
      isCountdownMode &&
      _remainingSeconds > 0 &&
      _remainingSeconds <= warningWindowSeconds;

  String get shortStatusLabel {
    if (_mode == SleepTimerMode.off) return '关闭';
    if (_mode == SleepTimerMode.endOfEpisode) return '播完本集';
    final mins = (_remainingSeconds / 60).ceil();
    if (_remainingSeconds <= 60) return '${_remainingSeconds}s';
    return '$mins分钟';
  }

  /// Configures a new sleep timer mode. Always resets any previous timer.
  void setMode(SleepTimerMode nextMode, {int? overrideDurationSeconds}) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _mode = nextMode;
    if (nextMode == SleepTimerMode.off ||
        nextMode == SleepTimerMode.endOfEpisode) {
      _remainingSeconds = 0;
      notifyListeners();
      return;
    }
    _remainingSeconds =
        overrideDurationSeconds ?? nextMode.durationSeconds ?? 15 * 60;
    if (_remainingSeconds <= 0) {
      _triggerNow();
      return;
    }
    _timer = Timer.periodic(tickInterval, (_) => tickOnce());
    notifyListeners();
  }

  /// Extends an active countdown by 15 minutes (or starts a 15-minute timer if
  /// invoked while off/end-of-episode).
  void extend15Minutes() {
    if (_disposed) return;
    if (!isCountdownMode) {
      setMode(SleepTimerMode.minutes15);
      return;
    }
    _remainingSeconds += extendSeconds;
    notifyListeners();
  }

  /// Cancels any active sleep timer.
  void cancel() {
    if (_disposed) return;
    if (_mode == SleepTimerMode.off && _timer == null) return;
    _timer?.cancel();
    _timer = null;
    _mode = SleepTimerMode.off;
    _remainingSeconds = 0;
    notifyListeners();
  }

  /// Advances the countdown by 1 second (exposed for deterministic unit tests).
  void tickOnce() {
    if (_disposed || !isCountdownMode) return;
    _remainingSeconds = _remainingSeconds - 1;
    if (_remainingSeconds <= 0) {
      _triggerNow();
      return;
    }
    notifyListeners();
  }

  /// Call when the current episode finishes playback. Returns `true` if the
  /// sleep timer intercepted completion and paused instead of advancing.
  bool handleEpisodeCompleted() {
    if (_disposed || _mode != SleepTimerMode.endOfEpisode) return false;
    _triggerNow();
    return true;
  }

  void _triggerNow() {
    _timer?.cancel();
    _timer = null;
    _mode = SleepTimerMode.off;
    _remainingSeconds = 0;
    notifyListeners();
    onTriggered();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Lightweight top banner displayed during the final 30 seconds before
/// [SleepTimerController] pauses playback.
class SleepTimerWarningBanner extends StatelessWidget {
  final int remainingSeconds;
  final VoidCallback onExtend15m;
  final VoidCallback onCancel;
  final bool reduceTransparency;

  const SleepTimerWarningBanner({
    super.key,
    required this.remainingSeconds,
    required this.onExtend15m,
    required this.onCancel,
    this.reduceTransparency = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveReduce = reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final bgColor =
        effectiveReduce ? const Color(0xF51E1E22) : const Color(0xCC16161C);
    final borderColor = Colors.white.withValues(
      alpha: effectiveReduce ? 0.45 : 0.24,
    );

    return Container(
      key: const Key('sleep-timer-warning-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor, width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4D000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.moon_zzz_fill,
            color: AppleColors.systemOrange,
            size: 15,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              '定时关闭还剩 ${remainingSeconds}s',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppleColors.labelPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          CupertinoButton(
            key: const Key('sleep-timer-extend'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: const Size(0, 26),
            color: AppleColors.systemBlue,
            borderRadius: BorderRadius.circular(999),
            onPressed: onExtend15m,
            child: const Text(
              '延长15分',
              style: TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
          CupertinoButton(
            key: const Key('sleep-timer-cancel'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            minimumSize: const Size(0, 26),
            color: const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(999),
            onPressed: onCancel,
            child: const Text(
              '取消',
              style: TextStyle(
                color: AppleColors.labelPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

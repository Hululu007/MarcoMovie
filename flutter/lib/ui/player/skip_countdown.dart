// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;

import '../apple_theme.dart';
import '../ios_liquid_glass.dart';

enum SkipCountdownKind {
  intro,
  outro,
}

/// Manages a cancellable 3-second (`3000ms`) skip intro / skip outro countdown.
class SkipCountdownController extends ChangeNotifier {
  static const int defaultDurationMs = 3000;
  static const int _tickStepMs = 100;

  Timer? _timer;
  SkipCountdownKind? _kind;
  int _totalMs = defaultDurationMs;
  int _remainingMs = 0;
  VoidCallback? _onConfirm;
  VoidCallback? _onCancel;
  bool _disposed = false;

  bool get isActive => _kind != null && _remainingMs > 0;
  SkipCountdownKind? get kind => _kind;
  int get remainingMs => _remainingMs;
  int get totalMs => _totalMs;
  int get remainingSeconds => (_remainingMs / 1000.0).ceil().clamp(1, 9);
  double get progress =>
      _totalMs <= 0 ? 1.0 : (1.0 - _remainingMs / _totalMs).clamp(0.0, 1.0);

  void start({
    required SkipCountdownKind kind,
    required VoidCallback onConfirm,
    VoidCallback? onCancel,
    int durationMs = defaultDurationMs,
  }) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _kind = kind;
    _totalMs = durationMs > 0 ? durationMs : defaultDurationMs;
    _remainingMs = _totalMs;
    _onConfirm = onConfirm;
    _onCancel = onCancel;
    _timer = Timer.periodic(
      const Duration(milliseconds: _tickStepMs),
      (_) => advanceMs(_tickStepMs),
    );
    notifyListeners();
  }

  /// Advances the countdown by [elapsedMs] (exposed for deterministic tests).
  void advanceMs(int elapsedMs) {
    if (_disposed || !isActive) return;
    _remainingMs = _remainingMs - elapsedMs;
    if (_remainingMs <= 0) {
      confirmNow();
      return;
    }
    notifyListeners();
  }

  /// Confirms and executes the skip immediately.
  void confirmNow() {
    if (_disposed || _kind == null) return;
    final cb = _onConfirm;
    _clearInternal();
    notifyListeners();
    cb?.call();
  }

  /// Cancels the pending skip without jumping.
  void cancel() {
    if (_disposed || _kind == null) return;
    final cb = _onCancel;
    _clearInternal();
    notifyListeners();
    cb?.call();
  }

  /// Silently resets without invoking either callback (e.g. on episode change).
  void reset() {
    if (_disposed) return;
    if (_kind == null && _timer == null) return;
    _clearInternal();
    notifyListeners();
  }

  void _clearInternal() {
    _timer?.cancel();
    _timer = null;
    _kind = null;
    _remainingMs = 0;
    _onConfirm = null;
    _onCancel = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _clearInternal();
    super.dispose();
  }
}

/// Compact lower-left glass card displaying the cancellable skip countdown.
class SkipCountdownOverlay extends StatelessWidget {
  final SkipCountdownKind kind;
  final int remainingSeconds;
  final double progress;
  final VoidCallback onSkipNow;
  final VoidCallback onCancel;
  final bool reduceTransparency;
  final bool reduceMotion;

  const SkipCountdownOverlay({
    super.key,
    required this.kind,
    required this.remainingSeconds,
    required this.progress,
    required this.onSkipNow,
    required this.onCancel,
    this.reduceTransparency = false,
    this.reduceMotion = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveReduce = reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final label = kind == SkipCountdownKind.intro
        ? '即将跳过片头 (${remainingSeconds}s)'
        : '即将跳过片尾 (${remainingSeconds}s)';
    final bgColor =
        effectiveReduce ? const Color(0xF51E1E22) : const Color(0xCC16161C);
    final borderColor = Colors.white.withValues(
      alpha: effectiveReduce ? 0.45 : 0.24,
    );

    return Container(
      key: const Key('skip-countdown-overlay'),
      constraints: const BoxConstraints(maxWidth: 310),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor, width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.forward_end_fill,
                    color: AppleColors.systemCyan,
                    size: 15,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
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
                    key: const Key('skip-countdown-now'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4.5,
                    ),
                    minimumSize: const Size(0, 28),
                    color: AppleColors.systemBlue,
                    borderRadius: BorderRadius.circular(999),
                    onPressed: onSkipNow,
                    child: const Text(
                      '立即跳过',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  CupertinoButton(
                    key: const Key('skip-countdown-cancel'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4.5,
                    ),
                    minimumSize: const Size(0, 28),
                    color: const Color(0x30FFFFFF),
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
            ),
            SizedBox(
              height: 2.5,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: const ColoredBox(
                    color: AppleColors.systemBlue,
                    child: SizedBox.expand(),
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

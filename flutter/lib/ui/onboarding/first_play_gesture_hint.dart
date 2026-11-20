// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/ohos_runtime.dart';
import 'onboarding_prefs.dart';

enum FirstPlayHintPlatform { touch, tv, desktop }

FirstPlayHintPlatform resolveFirstPlayHintPlatform({
  TargetPlatform? platform,
  bool isTv = false,
}) {
  if (isTv) return FirstPlayHintPlatform.tv;
  final target = platform ?? defaultTargetPlatform;
  switch (target) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return FirstPlayHintPlatform.desktop;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return FirstPlayHintPlatform.touch;
  }
}

/// Lightweight first-play gesture hint capsule mounted above the player bottom
/// control bar (avoiding top-left StartSpecOverlay).
///
/// Automatically suppressed on HarmonyOS NEXT (`!OhosRuntime.isOhos`), after 3
/// sessions, or immediately on one-tap "不再提示 / Don't show again".
class FirstPlayGestureHint extends StatefulWidget {
  final OnboardingPrefs prefs;
  final FirstPlayHintPlatform? platformOverride;
  final bool? isChinese;
  final bool reduceTransparency;
  final Duration dwellDuration;
  final Duration displayDuration;
  final VoidCallback? onDismissed;

  const FirstPlayGestureHint({
    super.key,
    required this.prefs,
    this.platformOverride,
    this.isChinese,
    this.reduceTransparency = false,
    this.dwellDuration = const Duration(milliseconds: 2000),
    this.displayDuration = const Duration(milliseconds: 4500),
    this.onDismissed,
  });

  static String hintCopy(FirstPlayHintPlatform platform, {required bool zh}) {
    switch (platform) {
      case FirstPlayHintPlatform.tv:
        return zh
            ? '长按左右键加速快进/快退 · 松手即播 · 返回键取消'
            : 'Hold Left/Right to scrub · Release to play · Back to cancel';
      case FirstPlayHintPlatform.desktop:
        return zh
            ? '长按 ←/→ 快进预览 · 滚轮音量 · S / [ ] 倍速 · D 弹幕'
            : 'Hold ←/→ to scrub · Scroll volume · S / [ ] speed · D danmaku';
      case FirstPlayHintPlatform.touch:
        return zh
            ? '长按 2.0× 倍速 · 左右滑调速 · 上滑锁定 · 两侧双击快进快退'
            : 'Hold 2.0× speed · Slide to adjust · Swipe up to lock · Double-tap sides to seek';
    }
  }

  static String dismissLabel({required bool zh}) {
    return zh ? '知道了 / 不再提示' : "Got it / Don't show again";
  }

  @override
  State<FirstPlayGestureHint> createState() => _FirstPlayGestureHintState();
}

class _FirstPlayGestureHintState extends State<FirstPlayGestureHint> {
  bool _visible = false;
  bool _counted = false;
  Timer? _dwellTimer;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    if (!OhosRuntime.isOhos && widget.prefs.shouldShowFirstPlayHint()) {
      _visible = true;
      _dwellTimer = Timer(widget.dwellDuration, _recordDwell);
      _hideTimer = Timer(widget.displayDuration, _autoHide);
    }
  }

  Future<void> _recordDwell() async {
    if (!mounted || !_visible || _counted) return;
    _counted = true;
    await widget.prefs.recordFirstPlayHintShown();
  }

  void _autoHide() {
    if (!mounted || !_visible) return;
    setState(() => _visible = false);
    widget.onDismissed?.call();
  }

  Future<void> _dismissForever() async {
    _dwellTimer?.cancel();
    _hideTimer?.cancel();
    await widget.prefs.dismissFirstPlayHintForever();
    if (!mounted) return;
    setState(() => _visible = false);
    widget.onDismissed?.call();
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos || !_visible) {
      return const SizedBox.shrink();
    }

    final locale = Localizations.maybeLocaleOf(context);
    final zh = widget.isChinese ?? (locale?.languageCode.toLowerCase() != 'en');
    final platform = widget.platformOverride ??
        resolveFirstPlayHintPlatform(platform: Theme.of(context).platform);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final highContrast =
        widget.reduceTransparency || MediaQuery.highContrastOf(context);

    final bgColor = highContrast
        ? const Color(0xEB16161A)
        : const Color(0xCC12141C);
    final borderColor = highContrast
        ? const Color(0x73FFFFFF)
        : const Color(0x38FFFFFF);

    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.0,
      duration: Duration(milliseconds: reduceMotion ? 120 : 180),
      curve: reduceMotion ? Curves.linear : const Cubic(0.2, 0.0, 0.0, 1.0),
      child: Semantics(
        liveRegion: true,
        label: FirstPlayGestureHint.hintCopy(platform, zh: zh),
        child: Container(
          key: const Key('first_play_gesture_hint_capsule'),
          constraints: const BoxConstraints(maxWidth: 680),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              Text(
                FirstPlayGestureHint.hintCopy(platform, zh: zh),
                style: const TextStyle(
                  color: Color(0xFFF5F5F7),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              InkWell(
                key: const Key('first_play_gesture_hint_dismiss'),
                borderRadius: BorderRadius.circular(14),
                onTap: _dismissForever,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x2E0A84FF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0x665AC8FA),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    FirstPlayGestureHint.dismissLabel(zh: zh),
                    style: const TextStyle(
                      color: Color(0xFF64D2FF),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

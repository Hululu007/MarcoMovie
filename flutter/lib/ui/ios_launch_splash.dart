import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'apple_theme.dart';

/// Shared geometry constant matching `LaunchScreen.storyboard`'s centered
/// `76 × 76 pt` transparent `LaunchImage` (`logo_mark.png`) so cold launch
/// transitions from UIKit `LaunchScreen` -> `MarcoBootstrapApp` ->
/// `IosLaunchCurtainHost` with zero positional jump and zero square backdrop.
const double kIosLaunchMarkSize = 76.0;

/// Cinema-grade iOS launch stage rendering the transparent metallic `M`
/// film-ribbon mark (`assets/logo_mark.png`) at exact screen center `(0, 0)`
/// with a soft ambient radial halo and optional diagonal specular light sweep.
class IosLaunchStageView extends StatelessWidget {
  final bool isDark;
  final double shimmerProgress;
  final double glowIntensity;
  final bool showWordmark;
  final Widget? bottomAccessory;

  const IosLaunchStageView({
    super.key,
    required this.isDark,
    this.shimmerProgress = 0.0,
    this.glowIntensity = 0.45,
    this.showWordmark = true,
    this.bottomAccessory,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppleColors.background : ApplePalette.light.background;
    final haloCore = isDark
        ? const Color(0xFF6482B8).withValues(alpha: 0.16 * glowIntensity)
        : const Color(0xFF3B82F6).withValues(alpha: 0.09 * glowIntensity);
    final haloMid = isDark
        ? const Color(0xFF1E293B).withValues(alpha: 0.08 * glowIntensity)
        : const Color(0xFF94A3B8).withValues(alpha: 0.04 * glowIntensity);

    Widget mark = SizedBox(
      key: const ValueKey('marco-ios-launch-mark'),
      width: kIosLaunchMarkSize,
      height: kIosLaunchMarkSize,
      child: Image.asset(
        'assets/logo_mark.png',
        width: kIosLaunchMarkSize,
        height: kIosLaunchMarkSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => const MarcoBrandLogo(
          iconSize: kIosLaunchMarkSize,
          showWordmark: false,
        ),
      ),
    );

    if (shimmerProgress > 0.001 && shimmerProgress < 0.999) {
      final sweepCenter = -0.8 + shimmerProgress * 2.6;
      mark = ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) {
          return LinearGradient(
            begin: const Alignment(-1.0, -0.55),
            end: const Alignment(1.0, 0.55),
            colors: [
              Colors.transparent,
              Colors.white.withValues(alpha: isDark ? 0.34 : 0.48),
              Colors.transparent,
            ],
            stops: [
              (sweepCenter - 0.24).clamp(0.0, 1.0),
              sweepCenter.clamp(0.0, 1.0),
              (sweepCenter + 0.24).clamp(0.0, 1.0),
            ],
          ).createShader(bounds);
        },
        child: mark,
      );
    }

    final primaryWordColor =
        isDark ? const Color(0xFFF8FAFC) : const Color(0xFF111114);
    final secondaryWordColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return ColoredBox(
      color: bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Soft optical cinema halo centered behind the transparent mark
          Center(
            child: IgnorePointer(
              child: Container(
                width: 248,
                height: 248,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      haloCore,
                      haloMid,
                      bg.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.48, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // Exact (0, 0) centered transparent M ribbon mark matching Storyboard
          Center(child: mark),
          // Wordmark & bootstrap status positioned below center so the mark
          // itself never shifts vertically between Storyboard and Flutter.
          if (showWordmark || bottomAccessory != null)
            Align(
              alignment: const Alignment(0.0, 0.36),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showWordmark)
                      Text.rich(
                        TextSpan(
                          style: const TextStyle(
                            fontSize: 16,
                            letterSpacing: 1.8,
                            height: 1.15,
                            decoration: TextDecoration.none,
                          ),
                          children: [
                            TextSpan(
                              text: 'MARCO',
                              style: TextStyle(
                                color: primaryWordColor.withValues(alpha: 0.92),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: ' MOVIE',
                              style: TextStyle(
                                color:
                                    secondaryWordColor.withValues(alpha: 0.82),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        textScaler: TextScaler.noScaling,
                      ),
                    if (showWordmark && bottomAccessory != null)
                      const SizedBox(height: 18),
                    if (bottomAccessory != null) bottomAccessory!,
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One-shot Apple TV+ style opening curtain for iOS/iPadOS.
///
/// Plays a 680 ms specular sweep + subtle camera-through scale/fade dissolve
/// over the live shell, never blocks pointer events (`IgnorePointer`), skips
/// automatically when Reduce Motion is enabled, and unmounts completely once
/// completed so zero tickers remain active.
class IosLaunchCurtainHost extends StatefulWidget {
  @visibleForTesting
  static bool debugEnableInTest = false;

  final Widget child;

  const IosLaunchCurtainHost({
    super.key,
    required this.child,
  });

  @override
  State<IosLaunchCurtainHost> createState() => _IosLaunchCurtainHostState();
}

class _IosLaunchCurtainHostState extends State<IosLaunchCurtainHost>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  bool _completed = false;
  bool _started = false;

  bool _shouldSkipAnimation(BuildContext context) {
    final inFlutterTest =
        !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
    if (inFlutterTest && !IosLaunchCurtainHost.debugEnableInTest) {
      return true;
    }
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ??
        View.maybeOf(context)
            ?.platformDispatcher
            .accessibilityFeatures
            .disableAnimations ??
        false;
    return reduceMotion;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_completed || _started) return;
    if (_shouldSkipAnimation(context)) {
      _completed = true;
      return;
    }
    _started = true;
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    );
    _controller = ctrl;
    ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() {
          _completed = true;
        });
        _controller?.dispose();
        _controller = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_completed) {
        ctrl.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (_completed || ctrl == null) {
      return widget.child;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          key: const ValueKey('marco-ios-launch-curtain'),
          ignoring: true,
          child: AnimatedBuilder(
            animation: ctrl,
            builder: (context, _) {
              final t = ctrl.value;
              final shimmer = Curves.easeInOutSine.transform(
                (t / 0.62).clamp(0.0, 1.0),
              );
              final fadeT = Curves.easeInOutCubic.transform(
                ((t - 0.22) / 0.78).clamp(0.0, 1.0),
              );
              final scaleT = Curves.easeOutQuart.transform(
                ((t - 0.14) / 0.86).clamp(0.0, 1.0),
              );
              final opacity = (1.0 - fadeT).clamp(0.0, 1.0);
              final scale = 1.0 + 0.085 * scaleT;
              final glow = 0.45 + 0.55 * (1.0 - (t - 0.35).abs() * 2.0).clamp(0.0, 1.0);
              return Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  child: IosLaunchStageView(
                    isDark: isDark,
                    shimmerProgress: shimmer,
                    glowIntensity: glow,
                    showWordmark: true,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

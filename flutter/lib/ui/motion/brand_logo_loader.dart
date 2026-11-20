// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/ohos_runtime.dart';
import 'motion_tokens.dart';

/// Shared normalized vector geometry & timing math for the F8 metallic
/// film-ribbon `M` brand loader, faithfully matching `logo_mark.png`,
/// `StartupIntro.BrandView`, and `MarcoBrandLogo`.
final class BrandRibbonGeometry {
  BrandRibbonGeometry._();

  /// Normalized sprocket perforation anchor ratios along the continuous ribbon.
  static const List<double> sprocketRatios = <double>[
    0.16,
    0.27,
    0.38,
    0.72,
    0.84,
  ];

  /// Builds the canonical continuous metallic film-ribbon `M` path inside [size].
  static Path buildRibbonPath(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(0.12 * w, 0.72 * h)
      ..cubicTo(
        0.06 * w,
        0.44 * h,
        0.24 * w,
        0.22 * h,
        0.41 * w,
        0.29 * h,
      )
      ..cubicTo(
        0.51 * w,
        0.33 * h,
        0.49 * w,
        0.64 * h,
        0.57 * w,
        0.63 * h,
      )
      ..cubicTo(
        0.65 * w,
        0.62 * h,
        0.73 * w,
        0.19 * h,
        0.92 * w,
        0.27 * h,
      );
  }

  static double _easeInOutCubic(double t) {
    final x = t.clamp(0.0, 1.0);
    return x < 0.5 ? 4.0 * x * x * x : 1.0 - math.pow(-2.0 * x + 2.0, 3) / 2.0;
  }

  /// Fraction `[0.0, 1.0]` of the continuous ribbon path traced at cycle [phase].
  static double computeStrokeFraction(double phase, bool reducedMotion) {
    if (reducedMotion) return 1.0;
    final p = phase.clamp(0.0, 1.0);
    if (p >= 0.56) return 1.0;
    return _easeInOutCubic(p / 0.56);
  }

  /// Diagonal metallic sheen progress `[0.0, 1.0]` during the second half of the
  /// 1.6s loop, or `-1.0` when inactive or under reduce-motion.
  static double computeSheenProgress(double phase, bool reducedMotion) {
    if (reducedMotion) return -1.0;
    final p = phase.clamp(0.0, 1.0);
    if (p < 0.48 || p > 0.90) return -1.0;
    return _easeInOutCubic((p - 0.48) / (0.90 - 0.48));
  }

  /// Ribbon opacity at cycle [phase]. Under reduce-motion, breathes gently within
  /// `[MotionTokens.reduceMotionLogoMinAlpha, MotionTokens.reduceMotionLogoMaxAlpha]` (`0.72..1.0`).
  static double computeRibbonAlpha(double phase, bool reducedMotion) {
    final p = phase.clamp(0.0, 1.0);
    if (reducedMotion) {
      const minA = MotionTokens.reduceMotionLogoMinAlpha;
      const maxA = MotionTokens.reduceMotionLogoMaxAlpha;
      return minA + (maxA - minA) * (0.5 + 0.5 * math.cos(2.0 * math.pi * p));
    }
    if (p <= 0.90) return 1.0;
    if (p <= 0.97) {
      final t = (p - 0.90) / 0.07;
      return 1.0 - 0.65 * t;
    }
    final t = (p - 0.97) / 0.03;
    return 0.35 + 0.65 * t;
  }
}

/// F8 Brand Metallic Film-Ribbon `M` Loader (`1600ms` continuous stroke +
/// diagonal metallic sheen sweep).
///
/// Degrades to a calm static breathing opacity (`0.72..1.0`) under reduce-motion,
/// renders a static crisp brand mark on HarmonyOS (`OhosRuntime.isOhos`), and
/// stops its [AnimationController] immediately whenever hidden or backgrounded.
class BrandLogoLoader extends StatefulWidget {
  final double size;
  final bool active;
  final bool? reduceMotionOverride;
  final String? semanticsLabel;

  const BrandLogoLoader({
    super.key,
    this.size = 44.0,
    this.active = true,
    this.reduceMotionOverride,
    this.semanticsLabel,
  });

  @override
  State<BrandLogoLoader> createState() => BrandLogoLoaderState();
}

@visibleForTesting
class BrandLogoLoaderState extends State<BrandLogoLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final AppLifecycleListener _lifecycleListener;

  bool _lifecycleResumed = true;
  bool _tickerModeEnabled = true;
  bool _isCurrentRoute = true;
  bool _reduceMotion = false;

  bool get isAnimating => _controller.isAnimating;
  bool get isReducedMotion => _reduceMotion;
  double get phase => _controller.value;

  @override
  void initState() {
    super.initState();
    final initialState = WidgetsBinding.instance.lifecycleState;
    _lifecycleResumed =
        initialState == null || initialState == AppLifecycleState.resumed;

    _controller = AnimationController(
      vsync: this,
      duration: MotionTokens.durationLogoLoop,
    );
    _lifecycleListener = AppLifecycleListener(
      onStateChange: _handleLifecycleState,
    );
  }

  void _handleLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_lifecycleResumed == resumed) return;
    _lifecycleResumed = resumed;
    _syncController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        widget.reduceMotionOverride ?? MediaQuery.disableAnimationsOf(context);
    _tickerModeEnabled = TickerMode.of(context);
    _isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
    _syncController();
  }

  @override
  void didUpdateWidget(covariant BrandLogoLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reduceMotionOverride != widget.reduceMotionOverride) {
      _reduceMotion =
          widget.reduceMotionOverride ?? MediaQuery.disableAnimationsOf(context);
    }
    _syncController();
  }

  bool get _shouldAnimate =>
      mounted &&
      widget.active &&
      !OhosRuntime.isOhos &&
      _tickerModeEnabled &&
      _isCurrentRoute &&
      _lifecycleResumed;

  void _syncController() {
    if (_shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveReduced = _reduceMotion || OhosRuntime.isOhos;
    return Semantics(
      label: widget.semanticsLabel ?? '正在加载',
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: BrandRibbonLoaderPainter(
              progressListenable: _controller,
              reducedMotion: effectiveReduced,
              staticSnapshot: OhosRuntime.isOhos,
            ),
          ),
        ),
      ),
    );
  }
}

/// Lightweight CustomPainter drawing Marco Movie's metallic film-ribbon `M`
/// with continuous path stroke tracing, sprocket accents, and metallic sheen.
class BrandRibbonLoaderPainter extends CustomPainter {
  final ValueListenable<double> progressListenable;
  final bool reducedMotion;
  final bool staticSnapshot;

  Size? _cachedSize;
  Path? _cachedFullPath;
  ui.PathMetric? _cachedMetric;
  Size? _cachedMetallicSize;
  int _cachedMetallicAlpha = -1;
  ui.Shader? _cachedMetallicShader;

  final Paint _guidePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _metallicPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _sheenPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _sprocketPaint = Paint()..style = PaintingStyle.fill;

  BrandRibbonLoaderPainter({
    required this.progressListenable,
    required this.reducedMotion,
    this.staticSnapshot = false,
  }) : super(repaint: progressListenable);

  void _ensurePathCache(Size size) {
    if (_cachedSize == size && _cachedFullPath != null) return;
    _cachedSize = size;
    final path = BrandRibbonGeometry.buildRibbonPath(size);
    _cachedFullPath = path;
    final iterator = path.computeMetrics().iterator;
    _cachedMetric = iterator.moveNext() ? iterator.current : null;
  }

  ui.Shader _ensureMetallicShader(Size size, double alpha) {
    final alphaKey = (alpha.clamp(0.0, 1.0) * 255.0).round();
    if (_cachedMetallicShader != null &&
        _cachedMetallicSize == size &&
        _cachedMetallicAlpha == alphaKey) {
      return _cachedMetallicShader!;
    }
    _cachedMetallicSize = size;
    _cachedMetallicAlpha = alphaKey;
    final a = alphaKey / 255.0;
    final shader = ui.Gradient.linear(
      Offset(size.width * 0.08, size.height * 0.78),
      Offset(size.width * 0.94, size.height * 0.22),
      <Color>[
        Color.fromRGBO(106, 112, 126, a),
        Color.fromRGBO(210, 214, 224, a),
        Color.fromRGBO(244, 246, 250, a),
        Color.fromRGBO(234, 216, 198, a),
        Color.fromRGBO(172, 178, 190, a),
      ],
      const <double>[0.0, 0.28, 0.54, 0.76, 1.0],
    );
    _cachedMetallicShader = shader;
    return shader;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _ensurePathCache(size);
    final fullPath = _cachedFullPath;
    final metric = _cachedMetric;
    if (fullPath == null || metric == null || metric.length <= 0.0) return;

    final phase = staticSnapshot ? 0.0 : progressListenable.value;
    final strokeFraction =
        BrandRibbonGeometry.computeStrokeFraction(phase, reducedMotion);
    final sheenProgress =
        BrandRibbonGeometry.computeSheenProgress(phase, reducedMotion);
    final alpha = BrandRibbonGeometry.computeRibbonAlpha(phase, reducedMotion);

    final minDim = math.min(size.width, size.height);
    final ribbonWidth = math.max(2.4, minDim * 0.145);

    // 1) Subtle dark-slate silhouette guide track so the M stays grounded.
    _guidePaint
      ..strokeWidth = ribbonWidth
      ..color = Color.fromRGBO(168, 174, 188, 0.16 * alpha);
    canvas.drawPath(fullPath, _guidePaint);

    // 2) Traced metallic film-ribbon stroke matching logo_mark.png brushed platinum + champagne tone.
    final tracedPath = strokeFraction >= 0.999
        ? fullPath
        : metric.extractPath(0.0, metric.length * strokeFraction);

    _metallicPaint
      ..strokeWidth = ribbonWidth
      ..shader = _ensureMetallicShader(size, alpha);
    canvas.drawPath(tracedPath, _metallicPaint);

    // 3) Diagonal metallic sheen sweep during the second half of the 1.6s loop
    // (drawn directly along the traced ribbon stroke with zero saveLayer overhead).
    if (sheenProgress >= 0.0 && sheenProgress <= 1.0) {
      final sweepX = (-0.35 + 1.70 * sheenProgress) * size.width;
      final band = size.width * 0.28;
      _sheenPaint
        ..strokeWidth = ribbonWidth * 0.96
        ..shader = ui.Gradient.linear(
          Offset(sweepX - band, size.height * 0.15),
          Offset(sweepX + band, size.height * 0.85),
          <Color>[
            const Color(0x00FFFFFF),
            Color.fromRGBO(255, 255, 255, 0.85 * alpha),
            Color.fromRGBO(245, 232, 214, 0.55 * alpha),
            const Color(0x00FFFFFF),
          ],
          const <double>[0.0, 0.46, 0.62, 1.0],
        );
      canvas.drawPath(tracedPath, _sheenPaint);
    }

    // 4) Film sprocket perforations along traced portion (only when large enough to stay crisp).
    if (minDim >= 24.0) {
      final holeW = math.max(1.4, ribbonWidth * 0.34);
      final holeH = math.max(1.2, ribbonWidth * 0.26);
      final holeRadius = Radius.circular(math.max(0.5, holeH * 0.28));
      _sprocketPaint.color = Color.fromRGBO(20, 22, 27, 0.78 * alpha);
      for (final ratio in BrandRibbonGeometry.sprocketRatios) {
        if (ratio > strokeFraction - 0.02) continue;
        final tangent = metric.getTangentForOffset(metric.length * ratio);
        if (tangent == null) continue;
        canvas.save();
        canvas.translate(tangent.position.dx, tangent.position.dy);
        canvas.rotate(-tangent.angle);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: holeW, height: holeH),
            holeRadius,
          ),
          _sprocketPaint,
        );
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant BrandRibbonLoaderPainter oldDelegate) =>
      oldDelegate.reducedMotion != reducedMotion ||
      oldDelegate.staticSnapshot != staticSnapshot;
}

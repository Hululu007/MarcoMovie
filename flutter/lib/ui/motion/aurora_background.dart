// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/ohos_runtime.dart';
import 'motion_tokens.dart';

/// Loads `shaders/aurora.frag`. Injectable for unit tests.
typedef AuroraProgramLoader = Future<ui.FragmentProgram> Function(
  String assetKey,
);

/// Exact 16-float uniform layout matching `flutter/shaders/aurora.frag`.
@immutable
class AuroraShaderUniforms {
  final List<double> floats;

  const AuroraShaderUniforms._(this.floats);

  factory AuroraShaderUniforms.fromState({
    required Size canvasSizeLogical,
    required double elapsedSec,
    double strength = MotionTokens.auroraDefaultStrength,
    Color waveBlue = MotionTokens.auroraWaveBlue,
    Color waveTeal = MotionTokens.auroraWaveTeal,
    Color waveIndigo = MotionTokens.auroraWaveIndigo,
    Color wavePurple = MotionTokens.auroraWavePurple,
  }) {
    final wrappedSec = MotionTokens.wrapAuroraElapsedSeconds(elapsedSec);
    return AuroraShaderUniforms._(<double>[
      math.max(canvasSizeLogical.width, 1.0), // 0: uCanvasSize.x (lp)
      math.max(canvasSizeLogical.height, 1.0), // 1: uCanvasSize.y (lp)
      wrappedSec, // 2: uElapsedSec mod 6283.1853
      strength.clamp(0.0, 1.0), // 3: uStrength
      waveBlue.r, // 4: uWaveBlue.r
      waveBlue.g, // 5: uWaveBlue.g
      waveBlue.b, // 6: uWaveBlue.b
      waveTeal.r, // 7: uWaveTeal.r
      waveTeal.g, // 8: uWaveTeal.g
      waveTeal.b, // 9: uWaveTeal.b
      waveIndigo.r, // 10: uWaveIndigo.r
      waveIndigo.g, // 11: uWaveIndigo.g
      waveIndigo.b, // 12: uWaveIndigo.b
      wavePurple.r, // 13: uWavePurple.r
      wavePurple.g, // 14: uWavePurple.g
      wavePurple.b, // 15: uWavePurple.b
    ]);
  }

  void applyTo(ui.FragmentShader shader) {
    for (int i = 0; i < floats.length; i++) {
      shader.setFloat(i, floats[i]);
    }
  }
}

/// Standalone four-tone low-frequency flowing aurora backdrop (`Marco Aurora`).
///
/// Intended strictly for onboarding, about, and empty-state screens (never
/// during active video playback). Stops its [Ticker] immediately when hidden,
/// occluded by another route, backgrounded via [WidgetsBindingObserver], running
/// under reduce-motion, on HarmonyOS (`OhosRuntime.isOhos`), or on Windows.
class AuroraBackground extends StatefulWidget {
  static const String shaderAssetPath = 'shaders/aurora.frag';

  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram?>? _loadingProgram;
  static bool _shaderLoadFailed = false;

  @visibleForTesting
  static AuroraProgramLoader? debugProgramLoaderOverride;

  static ui.FragmentProgram? get cachedProgram => _cachedProgram;
  static bool get shaderLoadFailed => _shaderLoadFailed;

  @visibleForTesting
  static void resetForTesting() {
    _cachedProgram = null;
    _loadingProgram = null;
    _shaderLoadFailed = false;
    debugProgramLoaderOverride = null;
  }

  static Future<ui.FragmentProgram?> prewarmShader() {
    if (OhosRuntime.isOhos) {
      return Future<ui.FragmentProgram?>.value(null);
    }
    if (_cachedProgram != null) {
      return Future<ui.FragmentProgram?>.value(_cachedProgram);
    }
    if (_shaderLoadFailed) {
      return Future<ui.FragmentProgram?>.value(null);
    }
    final existing = _loadingProgram;
    if (existing != null) return existing;

    final loader = debugProgramLoaderOverride ?? ui.FragmentProgram.fromAsset;
    final future = () async {
      try {
        final program = await loader(shaderAssetPath);
        _cachedProgram = program;
        _shaderLoadFailed = false;
        return program;
      } catch (_) {
        _cachedProgram = null;
        _shaderLoadFailed = true;
        return null;
      } finally {
        _loadingProgram = null;
      }
    }();
    _loadingProgram = future;
    return future;
  }

  /// Pure policy predicate controlling whether the frame Ticker may run.
  static bool shouldRunTicker({
    required bool active,
    required bool reduceMotion,
    required bool isOhos,
    required bool isWindowsStatic,
    required bool tickerModeEnabled,
    required bool isCurrentRoute,
    required bool lifecycleResumed,
    required double strength,
  }) {
    return active &&
        !reduceMotion &&
        !isOhos &&
        !isWindowsStatic &&
        tickerModeEnabled &&
        isCurrentRoute &&
        lifecycleResumed &&
        strength > 0.005;
  }

  final bool active;
  final double strength;
  final Color baseCanvasColor;
  final Color waveBlue;
  final Color waveTeal;
  final Color waveIndigo;
  final Color wavePurple;
  final ui.FragmentProgram? shaderProgram;
  final bool? reduceMotionOverride;
  final bool allowAnimationOnWindows;
  final Widget? child;

  const AuroraBackground({
    super.key,
    this.active = true,
    this.strength = MotionTokens.auroraDefaultStrength,
    this.baseCanvasColor = MotionTokens.auroraBaseCanvas,
    this.waveBlue = MotionTokens.auroraWaveBlue,
    this.waveTeal = MotionTokens.auroraWaveTeal,
    this.waveIndigo = MotionTokens.auroraWaveIndigo,
    this.wavePurple = MotionTokens.auroraWavePurple,
    this.shaderProgram,
    this.reduceMotionOverride,
    this.allowAnimationOnWindows = false,
    this.child,
  });

  @override
  State<AuroraBackground> createState() => AuroraBackgroundState();
}

@visibleForTesting
class AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final ValueNotifier<double> _elapsedNotifier = ValueNotifier<double>(0.0);

  ui.FragmentShader? _shader;
  ui.FragmentProgram? _boundProgram;
  Duration? _lastTickElapsed;
  double _accumulatedSec = 0.0;
  bool _lifecycleResumed = true;
  bool _tickerModeEnabled = true;
  bool _isCurrentRoute = true;
  bool _reduceMotion = false;

  bool get isTickerRunning => _ticker.isActive;
  bool get hasActiveShader => _shader != null;
  double get elapsedSeconds => _elapsedNotifier.value;

  bool get _isWindowsStatic =>
      !widget.allowAnimationOnWindows &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    final initialState = WidgetsBinding.instance.lifecycleState;
    _lifecycleResumed =
        initialState == null || initialState == AppLifecycleState.resumed;

    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addObserver(this);
    _initShader();
  }

  void _initShader() {
    if (OhosRuntime.isOhos || _isWindowsStatic) {
      _disposeShader();
      return;
    }
    final direct = widget.shaderProgram ?? AuroraBackground.cachedProgram;
    if (direct != null) {
      _bindProgram(direct);
      return;
    }
    AuroraBackground.prewarmShader().then((program) {
      if (!mounted || OhosRuntime.isOhos || _isWindowsStatic) {
        return;
      }
      final effective = widget.shaderProgram ?? program;
      if (effective == null) return;
      setState(() {
        _bindProgram(effective);
      });
    });
  }

  void _bindProgram(ui.FragmentProgram program) {
    if (identical(program, _boundProgram) && _shader != null) return;
    _disposeShader();
    _boundProgram = program;
    try {
      _shader = program.fragmentShader();
    } catch (_) {
      _shader = null;
    }
  }

  void _disposeShader() {
    final shader = _shader;
    _shader = null;
    _boundProgram = null;
    shader?.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_lifecycleResumed == resumed) return;
    _lifecycleResumed = resumed;
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        widget.reduceMotionOverride ?? MediaQuery.disableAnimationsOf(context);
    _tickerModeEnabled = TickerMode.of(context);
    _isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
    if (_reduceMotion) {
      _accumulatedSec = MotionTokens.reduceMotionAuroraFrozenTimeSec;
      _elapsedNotifier.value = MotionTokens.reduceMotionAuroraFrozenTimeSec;
    }
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant AuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reduceMotionOverride != widget.reduceMotionOverride) {
      _reduceMotion =
          widget.reduceMotionOverride ?? MediaQuery.disableAnimationsOf(context);
      if (_reduceMotion) {
        _accumulatedSec = MotionTokens.reduceMotionAuroraFrozenTimeSec;
        _elapsedNotifier.value = MotionTokens.reduceMotionAuroraFrozenTimeSec;
      }
    }
    if (oldWidget.shaderProgram != widget.shaderProgram ||
        oldWidget.allowAnimationOnWindows != widget.allowAnimationOnWindows) {
      _initShader();
    }
    _syncTicker();
  }

  void _syncTicker() {
    final run = mounted &&
        AuroraBackground.shouldRunTicker(
          active: widget.active,
          reduceMotion: _reduceMotion,
          isOhos: OhosRuntime.isOhos,
          isWindowsStatic: _isWindowsStatic,
          tickerModeEnabled: _tickerModeEnabled,
          isCurrentRoute: _isCurrentRoute,
          lifecycleResumed: _lifecycleResumed,
          strength: widget.strength,
        );
    if (run) {
      if (!_ticker.isActive) {
        _lastTickElapsed = null;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
      _lastTickElapsed = null;
    }
  }

  void _onTick(Duration elapsed) {
    final prev = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (prev == null) return;
    final dtSec = (elapsed - prev).inMicroseconds / 1000000.0;
    if (dtSec <= 0.0) return;
    final clampedDt = math.min(dtSec, 0.1);
    _accumulatedSec =
        MotionTokens.wrapAuroraElapsedSeconds(_accumulatedSec + clampedDt);
    _elapsedNotifier.value = _accumulatedSec;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _elapsedNotifier.dispose();
    _disposeShader();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useShader = !OhosRuntime.isOhos && !_isWindowsStatic && _shader != null;
    final painter = useShader
        ? AuroraShaderPainter(
            shader: _shader!,
            elapsedListenable: _elapsedNotifier,
            strength: widget.strength,
            waveBlue: widget.waveBlue,
            waveTeal: widget.waveTeal,
            waveIndigo: widget.waveIndigo,
            wavePurple: widget.wavePurple,
            fallbackBaseCanvas: widget.baseCanvasColor,
          )
        : AuroraFallbackPainter(
            elapsedListenable: _elapsedNotifier,
            strength: widget.strength,
            baseCanvasColor: widget.baseCanvasColor,
            waveBlue: widget.waveBlue,
            waveTeal: widget.waveTeal,
            waveIndigo: widget.waveIndigo,
            wavePurple: widget.wavePurple,
          );

    return RepaintBoundary(
      child: CustomPaint(
        painter: painter,
        child: widget.child ?? const SizedBox.expand(),
      ),
    );
  }
}

/// CustomPainter rendering `aurora.frag` via `Canvas.drawRect` in logical pixels.
class AuroraShaderPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final ValueListenable<double> elapsedListenable;
  final double strength;
  final Color waveBlue;
  final Color waveTeal;
  final Color waveIndigo;
  final Color wavePurple;
  final Color fallbackBaseCanvas;

  AuroraShaderPainter({
    required this.shader,
    required this.elapsedListenable,
    required this.strength,
    required this.waveBlue,
    required this.waveTeal,
    required this.waveIndigo,
    required this.wavePurple,
    required this.fallbackBaseCanvas,
  }) : super(repaint: elapsedListenable);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    try {
      final uniforms = AuroraShaderUniforms.fromState(
        canvasSizeLogical: size,
        elapsedSec: elapsedListenable.value,
        strength: strength,
        waveBlue: waveBlue,
        waveTeal: waveTeal,
        waveIndigo: waveIndigo,
        wavePurple: wavePurple,
      );
      uniforms.applyTo(shader);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } catch (_) {
      canvas.drawRect(Offset.zero & size, Paint()..color = fallbackBaseCanvas);
    }
  }

  @override
  bool shouldRepaint(covariant AuroraShaderPainter oldDelegate) =>
      oldDelegate.shader != shader ||
      oldDelegate.strength != strength ||
      oldDelegate.waveBlue != waveBlue ||
      oldDelegate.waveTeal != waveTeal ||
      oldDelegate.waveIndigo != waveIndigo ||
      oldDelegate.wavePurple != wavePurple;
}

/// Zero-shader static/canvas aurora fallback for OHOS, Windows, or shader load errors.
class AuroraFallbackPainter extends CustomPainter {
  final ValueListenable<double> elapsedListenable;
  final double strength;
  final Color baseCanvasColor;
  final Color waveBlue;
  final Color waveTeal;
  final Color waveIndigo;
  final Color wavePurple;

  AuroraFallbackPainter({
    required this.elapsedListenable,
    required this.strength,
    required this.baseCanvasColor,
    required this.waveBlue,
    required this.waveTeal,
    required this.waveIndigo,
    required this.wavePurple,
  }) : super(repaint: elapsedListenable);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = baseCanvasColor);
    final eff = strength.clamp(0.0, 1.0);
    if (eff <= 0.005) return;

    final t = elapsedListenable.value * MotionTokens.auroraTimeRateRadPerSec;
    final maxDim = math.max(size.width, size.height);

    final c1 = Color.lerp(waveBlue, waveTeal, 0.5 + 0.5 * math.sin(t))!;
    _drawGlow(
      canvas,
      Offset(
        size.width * (0.28 + 0.08 * math.sin(t * 0.7)),
        size.height * (0.34 + 0.06 * math.cos(t * 0.55)),
      ),
      maxDim * 0.62,
      c1.withValues(alpha: 0.34 * eff),
    );
    _drawGlow(
      canvas,
      Offset(
        size.width * (0.74 + 0.07 * math.cos(t * 0.85)),
        size.height * (0.46 + 0.07 * math.sin(t * 0.45)),
      ),
      maxDim * 0.58,
      waveIndigo.withValues(alpha: 0.30 * eff),
    );
    _drawGlow(
      canvas,
      Offset(
        size.width * (0.50 + 0.14 * math.sin(t * 0.55)),
        size.height * (0.64 - 0.08 * math.cos(t * 0.65)),
      ),
      maxDim * 0.54,
      wavePurple.withValues(alpha: 0.25 * eff),
    );
  }

  void _drawGlow(Canvas canvas, Offset center, double radius, Color color) {
    final shader = ui.Gradient.radial(
      center,
      math.max(radius, 1.0),
      <Color>[color, color.withValues(alpha: 0.0)],
      const <double>[0.0, 1.0],
    );
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant AuroraFallbackPainter oldDelegate) =>
      oldDelegate.strength != strength ||
      oldDelegate.baseCanvasColor != baseCanvasColor ||
      oldDelegate.waveBlue != waveBlue ||
      oldDelegate.waveTeal != waveTeal ||
      oldDelegate.waveIndigo != waveIndigo ||
      oldDelegate.wavePurple != wavePurple;
}

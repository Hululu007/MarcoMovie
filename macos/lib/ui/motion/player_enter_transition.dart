// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../core/ohos_runtime.dart';
import '../ios_liquid_glass.dart';
import 'motion_tokens.dart';

/// Resolved execution tier for Detail -> Player transitions.
enum PlayerTransitionMode {
  /// Full Cinema Portal GLSL shader transition (`420ms` enter / `300ms` exit).
  shaderPortal,

  /// Accessibility fallback 1: `MediaQuery.disableAnimationsOf(context) == true`.
  /// Skips snapshot and shader; runs `150ms` linear crossfade (`scale == 1.0`).
  reducedCrossFade,

  /// Automatic fallback 2 & 3: shader load failure, HarmonyOS runtime,
  /// snapshot capture latency `> 16ms`, missing snapshot, or Windows fast mode.
  /// Runs `220ms` (`185ms` Windows fast mode) `0.96 -> 1.0` scale + decelerate fade.
  scaleFadeFallback,
}

/// Optional wrapper matching `IosNativeRouteGate.runWithPlaceholders` in Wave 2.
typedef TransitionCaptureGate<T> = Future<T> Function(
  Future<T> Function() action,
);

/// Captures a detail-page backdrop image at the requested pixel ratio.
typedef BackdropImageCapturer = Future<ui.Image?> Function(double pixelRatio);

/// Loads the `player_enter.frag` [ui.FragmentProgram]. Injectable for unit tests.
typedef FragmentProgramLoader = Future<ui.FragmentProgram> Function(
  String assetKey,
);

/// Owned snapshot bundle captured before entering the player route.
///
/// Guarantees idempotent [dispose] of owned [ui.Image] GPU textures.
class PlayerTransitionSnapshot {
  ui.Image? _backdropImage;
  ui.Image? _posterImage;
  final bool ownsBackdrop;
  final bool ownsPoster;
  final Rect posterOriginLogical;
  final double posterRadiusLogical;
  final double posterAspect;
  final Duration captureDuration;
  final bool exceededBudget;
  bool _disposed = false;

  PlayerTransitionSnapshot({
    ui.Image? backdropImage,
    ui.Image? posterImage,
    this.ownsBackdrop = true,
    this.ownsPoster = false,
    this.posterOriginLogical = Rect.zero,
    this.posterRadiusLogical = 12.0,
    double? posterAspect,
    this.captureDuration = Duration.zero,
    this.exceededBudget = false,
  })  : _backdropImage = backdropImage,
        _posterImage = posterImage,
        posterAspect = _resolvePosterAspect(posterImage, posterAspect);

  static double _resolvePosterAspect(ui.Image? poster, double? explicit) {
    if (explicit != null && explicit.isFinite && explicit > 0.01) {
      return explicit;
    }
    if (poster != null && poster.height > 0) {
      return poster.width / math.max(poster.height, 1);
    }
    return 2.0 / 3.0;
  }

  ui.Image? get backdropImage => _disposed ? null : _backdropImage;
  ui.Image? get posterImage => _disposed ? null : _posterImage;
  bool get hasBackdrop => !_disposed && _backdropImage != null;
  bool get hasPoster => !_disposed && _posterImage != null;
  bool get isDisposed => _disposed;

  /// Releases owned GPU textures. Safe to call multiple times.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final backdrop = _backdropImage;
    final poster = _posterImage;
    _backdropImage = null;
    _posterImage = null;
    try {
      if (ownsBackdrop && backdrop != null) {
        backdrop.dispose();
      }
    } finally {
      if (ownsPoster && poster != null) {
        poster.dispose();
      }
    }
  }
}

/// Exact 15-float uniform payload matching `flutter/shaders/player_enter.frag`.
///
/// All coordinates are strictly in Flutter `CustomPainter` logical pixels (`lp`)
/// and must never be pre-multiplied by `devicePixelRatio`.
@immutable
class PlayerEnterShaderUniforms {
  final List<double> floats;

  const PlayerEnterShaderUniforms._(this.floats);

  factory PlayerEnterShaderUniforms.fromLayout({
    required Size viewportLogical,
    required double progress,
    required Rect posterOriginLogical,
    required EdgeInsets safePaddingLogical,
    required double posterRadiusLogical,
    required bool posterAvailable,
    required double posterAspect,
  }) {
    final p = progress.clamp(0.0, 1.0);
    final recedeTilt = 0.10 * math.sin(math.pi * p);
    final safeAspect = (posterAspect.isFinite && posterAspect > 0.0001)
        ? posterAspect
        : (2.0 / 3.0);
    final bool hasValidPortal = posterAvailable &&
        posterOriginLogical.width >= 1.0 &&
        posterOriginLogical.height >= 1.0;
    final Rect effectiveOrigin =
        hasValidPortal ? posterOriginLogical : Rect.zero;
    final double effectiveRadius = hasValidPortal ? posterRadiusLogical : 0.0;
    return PlayerEnterShaderUniforms._(<double>[
      math.max(viewportLogical.width, 1.0), // 0: uViewport.x (lp)
      math.max(viewportLogical.height, 1.0), // 1: uViewport.y (lp)
      p, // 2: uProgress
      recedeTilt, // 3: uRecedeTilt
      effectiveOrigin.left, // 4: uPosterOrigin.x (lp)
      effectiveOrigin.top, // 5: uPosterOrigin.y (lp)
      math.max(effectiveOrigin.width, 0.0), // 6: uPosterOrigin.z (lp)
      math.max(effectiveOrigin.height, 0.0), // 7: uPosterOrigin.w (lp)
      math.max(safePaddingLogical.left, 0.0), // 8: uSafePadding.x (lp)
      math.max(safePaddingLogical.top, 0.0), // 9: uSafePadding.y (lp)
      math.max(safePaddingLogical.right, 0.0), // 10: uSafePadding.z (lp)
      math.max(safePaddingLogical.bottom, 0.0), // 11: uSafePadding.w (lp)
      math.max(effectiveRadius, 0.0), // 12: uPosterRadius (lp)
      hasValidPortal ? 1.0 : 0.0, // 13: uPosterAvailable
      safeAspect, // 14: uPosterAspect
    ]);
  }

  void applyTo(ui.FragmentShader shader) {
    for (int i = 0; i < floats.length; i++) {
      shader.setFloat(i, floats[i]);
    }
  }
}

/// Standalone Cinema Portal transition coordinator, shader cache, capture gate,
/// and three-tier automatic fallback engine.
class PlayerEnterTransition extends StatefulWidget {
  static const String shaderAssetPath = 'shaders/player_enter.frag';
  static const int defaultMaxCaptureEdgePx = 1280;

  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram?>? _loadingProgram;
  static bool _shaderLoadFailed = false;
  static bool _preferFastTransition = false;
  static ui.Image? _transparentPlaceholder;

  @visibleForTesting
  static FragmentProgramLoader? debugProgramLoaderOverride;

  /// Session latch set automatically whenever `toImage()` exceeds `16ms`.
  static bool get preferFastTransition => _preferFastTransition;

  static bool get shaderLoadFailed => _shaderLoadFailed;

  static ui.FragmentProgram? get cachedProgram => _cachedProgram;

  @visibleForTesting
  static void setPreferFastTransitionForTest(bool value) {
    _preferFastTransition = value;
  }

  @visibleForTesting
  static void resetForTesting() {
    _cachedProgram = null;
    _loadingProgram = null;
    _shaderLoadFailed = false;
    _preferFastTransition = false;
    debugProgramLoaderOverride = null;
    final placeholder = _transparentPlaceholder;
    _transparentPlaceholder = null;
    placeholder?.dispose();
  }

  /// Prewarms `shaders/player_enter.frag` once. On HarmonyOS or load failure,
  /// marks [_shaderLoadFailed] and gracefully returns `null`.
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

  /// Computes a bounded `pixelRatio` so the longest edge stays `<= maxEdgePx`.
  static double computeCapturePixelRatio({
    required Size logicalSize,
    required double devicePixelRatio,
    int maxEdgePx = defaultMaxCaptureEdgePx,
  }) {
    final safeDpr =
        devicePixelRatio.isFinite && devicePixelRatio > 0.0 ? devicePixelRatio : 1.0;
    final longestLogical = math.max(logicalSize.width, logicalSize.height);
    if (!longestLogical.isFinite || longestLogical <= 0.0) {
      return math.min(safeDpr, 1.0);
    }
    final maxAllowedRatio = maxEdgePx / longestLogical;
    return math.min(safeDpr, maxAllowedRatio).clamp(0.25, safeDpr);
  }

  /// Returns `true` only on iOS / iPadOS when HarmonyOS is inactive AND native
  /// iOS 26+ Liquid Glass (`UiKitView`) surfaces are active. Avoids an extra
  /// ~16.7ms `postFrameCallback` wait on iOS 15–18 devices without `UiKitView`.
  static bool shouldUseIosRouteGate({bool? isOhosOverride}) {
    final isOhos = isOhosOverride ?? OhosRuntime.isOhos;
    return !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !isOhos &&
        IosLiquidGlassBridge.isAvailable;
  }

  /// Synchronously clones an already-decoded [ui.Image] currently painted by a
  /// [RenderImage] inside [key]'s subtree (zero decode latency, zero network).
  /// Caller owns the returned handle and MUST dispose it on every exit path.
  static ui.Image? cloneRenderedImage(GlobalKey? key) {
    if (OhosRuntime.isOhos || key == null) return null;
    final root = key.currentContext?.findRenderObject();
    if (root == null) return null;
    ui.Image? cloned;
    void visit(RenderObject node) {
      if (cloned != null) return;
      if (node is RenderImage) {
        final img = node.image;
        if (img != null && img.width > 0 && img.height > 0) {
          try {
            cloned = img.clone();
            return;
          } catch (_) {
            // Fall through if the render image was disposed mid-frame.
          }
        }
      }
      node.visitChildren(visit);
    }

    visit(root);
    return cloned;
  }

  /// Decodes already-loaded in-memory poster bytes into a bounded [ui.Image]
  /// without network I/O. Guarantees disposal of intermediate codec buffers and
  /// disposes any late-arriving image if [timeout] expires first.
  static Future<ui.Image?> decodePosterBytes(
    Uint8List bytes, {
    int maxEdgePx = 720,
    Duration timeout = const Duration(milliseconds: 50),
  }) async {
    if (OhosRuntime.isOhos || bytes.isEmpty) return null;
    var timedOut = false;
    final decodeFuture =
        _decodeBoundedPosterBytes(bytes, maxEdgePx: maxEdgePx).then((img) {
      if (timedOut) {
        img?.dispose();
        return null;
      }
      return img;
    });
    try {
      return await decodeFuture.timeout(timeout, onTimeout: () {
        timedOut = true;
        return null;
      });
    } catch (_) {
      timedOut = true;
      return null;
    }
  }

  static Future<ui.Image?> _decodeBoundedPosterBytes(
    Uint8List bytes, {
    required int maxEdgePx,
  }) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      if (w <= 0 || h <= 0) return null;
      int? targetWidth;
      int? targetHeight;
      final longest = math.max(w, h);
      if (maxEdgePx > 0 && longest > maxEdgePx) {
        final scale = maxEdgePx / longest;
        targetWidth = math.max(1, (w * scale).round());
        targetHeight = math.max(1, (h * scale).round());
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// Captures a bounded backdrop screenshot with `Stopwatch` budget enforcement.
  ///
  /// - Skips capture immediately when [reduceMotion], [OhosRuntime.isOhos],
  ///   [preferFastTransition], or [useFastWindowsMode] is active.
  /// - Enforces `<= 16ms` capture budget (`MotionTokens.hudTransitionCaptureBudgetMs`):
  ///   when exceeded, marks [preferFastTransition] = `true` and immediately disposes
  ///   both the captured backdrop [ui.Image] and any owned [posterImage] in `try/finally`.
  /// - Accepts optional [routeGateWrapper] for iOS 26 `IosNativeRouteGate.runWithPlaceholders`.
  static Future<PlayerTransitionSnapshot> captureBackdrop({
    RenderRepaintBoundary? boundary,
    BackdropImageCapturer? customCapturer,
    TransitionCaptureGate<ui.Image?>? routeGateWrapper,
    Size? logicalSize,
    double devicePixelRatio = 1.0,
    Rect posterOriginLogical = Rect.zero,
    double posterRadiusLogical = 12.0,
    ui.Image? posterImage,
    bool ownsPoster = false,
    double? posterAspect,
    bool reduceMotion = false,
    bool useFastWindowsMode = false,
    int maxEdgePx = defaultMaxCaptureEdgePx,
    int budgetMs = MotionTokens.hudTransitionCaptureBudgetMs,
    Duration Function(Duration measured)? debugElapsedOverride,
  }) async {
    ui.Image? captured;
    bool backdropOwnershipTransferred = false;
    bool posterOwnershipTransferred = false;
    Duration measuredCapture = Duration.zero;
    try {
      if (reduceMotion ||
          OhosRuntime.isOhos ||
          _preferFastTransition ||
          useFastWindowsMode ||
          _shaderLoadFailed) {
        return PlayerTransitionSnapshot(
          posterOriginLogical: posterOriginLogical,
          posterRadiusLogical: posterRadiusLogical,
          posterAspect: posterAspect,
          exceededBudget: _preferFastTransition,
        );
      }

      final targetSize = logicalSize ??
          (boundary != null && boundary.hasSize ? boundary.size : Size.zero);
      final pixelRatio = computeCapturePixelRatio(
        logicalSize: targetSize,
        devicePixelRatio: devicePixelRatio,
        maxEdgePx: maxEdgePx,
      );

      final capturer = customCapturer ??
          (boundary != null
              ? (double ratio) => boundary.toImage(pixelRatio: ratio)
              : null);
      if (capturer == null) {
        return PlayerTransitionSnapshot(
          posterOriginLogical: posterOriginLogical,
          posterRadiusLogical: posterRadiusLogical,
          posterAspect: posterAspect,
        );
      }

      Future<ui.Image?> runTimedCapture() async {
        final sw = Stopwatch()..start();
        try {
          return await capturer(pixelRatio);
        } finally {
          sw.stop();
          measuredCapture = sw.elapsed;
        }
      }

      if (routeGateWrapper != null) {
        captured = await routeGateWrapper(runTimedCapture);
      } else {
        captured = await runTimedCapture();
      }
      final elapsed = debugElapsedOverride != null
          ? debugElapsedOverride(measuredCapture)
          : measuredCapture;
      final exceeded = elapsed.inMicroseconds > budgetMs * 1000;
      if (exceeded) {
        _preferFastTransition = true;
        return PlayerTransitionSnapshot(
          posterOriginLogical: posterOriginLogical,
          posterRadiusLogical: posterRadiusLogical,
          posterAspect: posterAspect,
          captureDuration: elapsed,
          exceededBudget: true,
        );
      }
      if (captured == null) {
        return PlayerTransitionSnapshot(
          posterOriginLogical: posterOriginLogical,
          posterRadiusLogical: posterRadiusLogical,
          posterAspect: posterAspect,
          captureDuration: elapsed,
        );
      }
      final snapshot = PlayerTransitionSnapshot(
        backdropImage: captured,
        posterImage: posterImage,
        ownsBackdrop: true,
        ownsPoster: ownsPoster,
        posterOriginLogical: posterOriginLogical,
        posterRadiusLogical: posterRadiusLogical,
        posterAspect: posterAspect,
        captureDuration: elapsed,
        exceededBudget: false,
      );
      backdropOwnershipTransferred = true;
      posterOwnershipTransferred = true;
      return snapshot;
    } catch (_) {
      return PlayerTransitionSnapshot(
        posterOriginLogical: posterOriginLogical,
        posterRadiusLogical: posterRadiusLogical,
        posterAspect: posterAspect,
        captureDuration: measuredCapture,
      );
    } finally {
      try {
        if (!backdropOwnershipTransferred && captured != null) {
          captured.dispose();
        }
      } finally {
        if (!posterOwnershipTransferred && ownsPoster && posterImage != null) {
          posterImage.dispose();
        }
      }
    }
  }

  /// Resolves the transition mode cleanly according to all 3 automatic fallbacks.
  static PlayerTransitionMode resolveMode({
    required bool reduceMotion,
    required bool hasShaderProgram,
    required bool hasBackdropImage,
    bool preferFast = false,
    bool useFastWindowsMode = false,
    bool? isOhosOverride,
  }) {
    // Fallback 1: reduce-motion always wins -> 150ms linear crossfade.
    if (reduceMotion) {
      return PlayerTransitionMode.reducedCrossFade;
    }
    final ohos = isOhosOverride ?? OhosRuntime.isOhos;
    // Fallback 2 & 3: OHOS, shader unavailable/failed, snapshot latency > 16ms,
    // Windows fast mode, or missing backdrop -> scale + fade fallback.
    if (ohos ||
        useFastWindowsMode ||
        preferFast ||
        _preferFastTransition ||
        _shaderLoadFailed ||
        !hasShaderProgram ||
        !hasBackdropImage) {
      return PlayerTransitionMode.scaleFadeFallback;
    }
    return PlayerTransitionMode.shaderPortal;
  }

  /// Resolves enter/exit transition durations for a given [PlayerTransitionMode].
  static Duration enterDurationFor(
    PlayerTransitionMode mode, {
    bool useFastWindowsMode = false,
  }) {
    switch (mode) {
      case PlayerTransitionMode.reducedCrossFade:
        return MotionTokens.durationFast;
      case PlayerTransitionMode.scaleFadeFallback:
        return useFastWindowsMode
            ? MotionTokens.durationWindowsRouteEnter
            : MotionTokens.durationStandard;
      case PlayerTransitionMode.shaderPortal:
        return MotionTokens.durationTransitionEnter;
    }
  }

  static Duration exitDurationFor(
    PlayerTransitionMode mode, {
    bool useFastWindowsMode = false,
  }) {
    switch (mode) {
      case PlayerTransitionMode.reducedCrossFade:
        return MotionTokens.durationFast;
      case PlayerTransitionMode.scaleFadeFallback:
        return useFastWindowsMode
            ? MotionTokens.durationWindowsRouteExit
            : MotionTokens.durationStandard;
      case PlayerTransitionMode.shaderPortal:
        return MotionTokens.durationTransitionExit;
    }
  }

  static ui.Image _ensurePlaceholderPosterImage() {
    final existing = _transparentPlaceholder;
    if (existing != null) return existing;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0x00000000),
    );
    final picture = recorder.endRecording();
    try {
      final image = picture.toImageSync(1, 1);
      _transparentPlaceholder = image;
      return image;
    } finally {
      picture.dispose();
    }
  }

  final Animation<double> animation;
  final Widget child;
  final PlayerTransitionSnapshot? snapshot;
  final ui.FragmentProgram? shaderProgram;
  final bool? reduceMotionOverride;
  final bool useFastWindowsMode;
  final bool disposeSnapshotOnComplete;
  final ValueChanged<PlayerTransitionMode>? onModeResolved;

  const PlayerEnterTransition({
    super.key,
    required this.animation,
    required this.child,
    this.snapshot,
    this.shaderProgram,
    this.reduceMotionOverride,
    this.useFastWindowsMode = false,
    this.disposeSnapshotOnComplete = true,
    this.onModeResolved,
  });

  @override
  State<PlayerEnterTransition> createState() => PlayerEnterTransitionState();
}

@visibleForTesting
class PlayerEnterTransitionState extends State<PlayerEnterTransition> {
  ui.FragmentShader? _shader;
  ui.FragmentProgram? _boundProgram;
  PlayerTransitionMode? _lastReportedMode;
  bool _snapshotReleased = false;
  bool _enterCompleted = false;
  ModalRoute<dynamic>? _route;
  late CurvedAnimation _linearAnimation;
  late CurvedAnimation _scaleFadeAnimation;
  late Animation<double> _scaleTweenAnimation;

  PlayerTransitionMode? get lastResolvedMode => _lastReportedMode;
  bool get hasActiveShader => _shader != null;
  bool get _isRouteOffstage => _route?.offstage ?? false;

  @override
  void initState() {
    super.initState();
    _enterCompleted = widget.animation.status == AnimationStatus.completed;
    _initAnimations();
    widget.animation.addStatusListener(_handleAnimationStatus);
    if (!_enterCompleted) {
      _syncShader();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (!_isRouteOffstage &&
        _enterCompleted &&
        !_snapshotReleased &&
        (widget.animation.status == AnimationStatus.forward ||
            widget.animation.status == AnimationStatus.dismissed)) {
      _enterCompleted = false;
      _syncShader();
    }
  }

  void _initAnimations() {
    _linearAnimation = CurvedAnimation(
      parent: widget.animation,
      curve: MotionTokens.curveLinear,
    );
    _scaleFadeAnimation = CurvedAnimation(
      parent: widget.animation,
      curve: MotionTokens.curveDecelerate,
      reverseCurve: MotionTokens.curveAccelerate,
    );
    _scaleTweenAnimation =
        Tween<double>(begin: 0.96, end: 1.0).animate(_scaleFadeAnimation);
  }

  void _disposeAnimations() {
    _linearAnimation.dispose();
    _scaleFadeAnimation.dispose();
  }

  @override
  void didUpdateWidget(covariant PlayerEnterTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_handleAnimationStatus);
      _disposeAnimations();
      _initAnimations();
      widget.animation.addStatusListener(_handleAnimationStatus);
    }
    if (oldWidget.snapshot != widget.snapshot) {
      _snapshotReleased = false;
      _enterCompleted = widget.animation.status == AnimationStatus.completed;
    }
    if (oldWidget.shaderProgram != widget.shaderProgram && !_enterCompleted) {
      _syncShader();
    }
  }

  void _syncShader() {
    final program = widget.shaderProgram ?? PlayerEnterTransition.cachedProgram;
    if (identical(program, _boundProgram)) return;
    _disposeShader();
    _boundProgram = program;
    if (program != null && !OhosRuntime.isOhos) {
      try {
        _shader = program.fragmentShader();
      } catch (_) {
        _shader = null;
      }
    }
  }

  void _disposeShader() {
    final shader = _shader;
    _shader = null;
    _boundProgram = null;
    shader?.dispose();
  }

  void _releaseOwnedResources() {
    _disposeShader();
    if (widget.disposeSnapshotOnComplete && !_snapshotReleased) {
      _snapshotReleased = true;
      widget.snapshot?.dispose();
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    // ModalRoute builds its first frame offstage with kAlwaysCompleteAnimation
    // (for Hero layout) before switching the ProxyAnimation to the real forward
    // transition controller. Re-arm the shader when transitioning out of that
    // offstage measurement frame so Navigator.push runs the Cinema Portal shader.
    if ((status == AnimationStatus.forward ||
            status == AnimationStatus.dismissed) &&
        _enterCompleted &&
        !_snapshotReleased) {
      _enterCompleted = false;
      _syncShader();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (status == AnimationStatus.completed) {
      if (_isRouteOffstage) {
        return;
      }
      final hadActiveOverlay = !_enterCompleted ||
          _shader != null ||
          (widget.disposeSnapshotOnComplete &&
              !_snapshotReleased &&
              widget.snapshot != null);
      _enterCompleted = true;
      _releaseOwnedResources();
      if (hadActiveOverlay && mounted) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleAnimationStatus);
    _disposeAnimations();
    try {
      _disposeShader();
    } finally {
      if (widget.disposeSnapshotOnComplete && !_snapshotReleased) {
        _snapshotReleased = true;
        widget.snapshot?.dispose();
      }
    }
    super.dispose();
  }

  void _reportMode(PlayerTransitionMode mode) {
    if (_enterCompleted &&
        _lastReportedMode == PlayerTransitionMode.shaderPortal &&
        mode == PlayerTransitionMode.scaleFadeFallback) {
      // Do not spuriously downgrade the reported enter mode after post-completion cleanup.
      return;
    }
    if (_lastReportedMode == mode) return;
    _lastReportedMode = mode;
    widget.onModeResolved?.call(mode);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        widget.reduceMotionOverride ?? MediaQuery.disableAnimationsOf(context);
    final snapshot = widget.snapshot;
    final mode = PlayerEnterTransition.resolveMode(
      reduceMotion: reduceMotion,
      hasShaderProgram: !_enterCompleted && _shader != null,
      hasBackdropImage: !_enterCompleted && snapshot != null && snapshot.hasBackdrop,
      preferFast: snapshot?.exceededBudget ?? false,
      useFastWindowsMode: widget.useFastWindowsMode,
    );
    if (!_isRouteOffstage) {
      _reportMode(mode);
    }

    final bool showPortalOverlay = mode == PlayerTransitionMode.shaderPortal &&
        !_enterCompleted &&
        _shader != null &&
        snapshot != null &&
        snapshot.hasBackdrop;

    final Animation<double> effectiveOpacity;
    final Animation<double> effectiveScale;
    if (showPortalOverlay) {
      // Underlying player stays at full opacity/scale while the shader dissolves above it.
      effectiveOpacity = kAlwaysCompleteAnimation;
      effectiveScale = kAlwaysCompleteAnimation;
    } else if (mode == PlayerTransitionMode.reducedCrossFade) {
      // Fallback 1 (reduce-motion): 150ms linear crossfade with fixed scale == 1.0.
      effectiveOpacity = _linearAnimation;
      effectiveScale = kAlwaysCompleteAnimation;
    } else {
      // Fallback 2/3 AND post-completion reverse exit (1.0 -> 0.0): smooth scale + fade.
      effectiveOpacity = _scaleFadeAnimation;
      effectiveScale = _scaleTweenAnimation;
    }

    final EdgeInsets safePadding =
        showPortalOverlay ? MediaQuery.paddingOf(context) : EdgeInsets.zero;

    // Maintain an invariant FadeTransition -> ScaleTransition -> Stack ancestor chain
    // around widget.child (always slot 0) so stateful player children are never disposed
    // or remounted when the enter shader completes, MediaQuery changes, or the route pops.
    return FadeTransition(
      opacity: effectiveOpacity,
      child: ScaleTransition(
        scale: effectiveScale,
        child: Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            widget.child,
            if (showPortalOverlay)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: widget.animation,
                    builder: (context, _) {
                      final t = widget.animation.value.clamp(0.0, 1.0);
                      final activeSnapshot = widget.snapshot;
                      final activeShader = _shader;
                      if (t >= 0.999 ||
                          activeShader == null ||
                          activeSnapshot == null ||
                          !activeSnapshot.hasBackdrop) {
                        return const SizedBox.shrink();
                      }
                      return RepaintBoundary(
                        child: CustomPaint(
                          painter: PlayerEnterShaderPainter(
                            shader: activeShader,
                            progress: t,
                            snapshot: activeSnapshot,
                            safePaddingLogical: safePadding,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// CustomPainter rendering `player_enter.frag` directly via `Canvas.drawRect`
/// in logical pixels (never `BackdropFilter` / `ImageFilter.shader`).
class PlayerEnterShaderPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final double progress;
  final PlayerTransitionSnapshot snapshot;
  final EdgeInsets safePaddingLogical;

  const PlayerEnterShaderPainter({
    required this.shader,
    required this.progress,
    required this.snapshot,
    required this.safePaddingLogical,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !snapshot.hasBackdrop) return;
    final backdrop = snapshot.backdropImage;
    if (backdrop == null) return;
    try {
      final uniforms = PlayerEnterShaderUniforms.fromLayout(
        viewportLogical: size,
        progress: progress,
        posterOriginLogical: snapshot.posterOriginLogical,
        safePaddingLogical: safePaddingLogical,
        posterRadiusLogical: snapshot.posterRadiusLogical,
        posterAvailable: snapshot.hasPoster,
        posterAspect: snapshot.posterAspect,
      );
      uniforms.applyTo(shader);
      shader.setImageSampler(0, backdrop);
      shader.setImageSampler(
        1,
        snapshot.posterImage ??
            PlayerEnterTransition._ensurePlaceholderPosterImage(),
      );
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } catch (_) {
      final handoffAlpha = (1.0 - ((progress - 0.68) / 0.32).clamp(0.0, 1.0));
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(0, 0, 0, handoffAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant PlayerEnterShaderPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.shader != shader ||
      oldDelegate.snapshot != snapshot ||
      oldDelegate.safePaddingLogical != safePaddingLogical;
}

/// Ready-to-wire `PageRoute` for Detail -> Player navigation with automatic
/// Cinema Portal shader, three-tier fallback, and guaranteed snapshot disposal.
class PlayerEnterPageRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final PlayerTransitionSnapshot? snapshot;
  final ui.FragmentProgram? shaderProgram;
  final bool reduceMotion;
  final bool useFastWindowsMode;
  final ValueChanged<PlayerTransitionMode>? onModeResolved;
  final PlayerTransitionMode _resolvedMode;

  PlayerEnterPageRoute({
    required this.builder,
    this.snapshot,
    this.shaderProgram,
    this.reduceMotion = false,
    this.useFastWindowsMode = false,
    this.onModeResolved,
    super.settings,
    super.fullscreenDialog = false,
  }) : _resolvedMode = PlayerEnterTransition.resolveMode(
          reduceMotion: reduceMotion,
          hasShaderProgram:
              (shaderProgram ?? PlayerEnterTransition.cachedProgram) != null,
          hasBackdropImage: snapshot != null && snapshot.hasBackdrop,
          preferFast: snapshot?.exceededBudget ?? false,
          useFastWindowsMode: useFastWindowsMode,
        );

  PlayerTransitionMode get resolvedMode => _resolvedMode;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => PlayerEnterTransition.enterDurationFor(
        _resolvedMode,
        useFastWindowsMode: useFastWindowsMode,
      );

  @override
  Duration get reverseTransitionDuration =>
      PlayerEnterTransition.exitDurationFor(
        _resolvedMode,
        useFastWindowsMode: useFastWindowsMode,
      );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return PlayerEnterTransition(
      animation: animation,
      snapshot: snapshot,
      shaderProgram: shaderProgram,
      reduceMotionOverride: reduceMotion ? true : null,
      useFastWindowsMode: useFastWindowsMode,
      disposeSnapshotOnComplete: true,
      onModeResolved: onModeResolved,
      child: child,
    );
  }

  @override
  void dispose() {
    try {
      snapshot?.dispose();
    } finally {
      super.dispose();
    }
  }
}

Rect _resolvePosterOriginLogical({
  GlobalKey? posterKey,
  RenderRepaintBoundary? backdropBoundary,
  Size? viewportSize,
}) {
  final posterCtx = posterKey?.currentContext;
  if (posterCtx == null) return Rect.zero;
  final ro = posterCtx.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize || ro.size.isEmpty) return Rect.zero;
  try {
    final origin = backdropBoundary != null && backdropBoundary.attached
        ? ro.localToGlobal(Offset.zero, ancestor: backdropBoundary)
        : ro.localToGlobal(Offset.zero);
    final rect = origin & ro.size;
    final bounds = backdropBoundary != null && backdropBoundary.hasSize
        ? backdropBoundary.size
        : viewportSize;
    if (bounds != null && !bounds.isEmpty && !(Offset.zero & bounds).overlaps(rect)) {
      return Rect.zero;
    }
    return rect;
  } catch (_) {
    return Rect.zero;
  }
}

/// Unified no-black-hole Detail -> Player route helper combining:
/// 1. [IosNativeRouteGate.runWithPlaceholders] (strict `try/finally` guarantee
///    to restore native iOS 26 `UiKitView`s even on exception or cancellation),
/// 2. Bounded [PlayerEnterTransition.captureBackdrop] (`<= 1280px` longest edge,
///    `16ms` capture budget -> session `preferFastTransition` latch, immediate
///    `ui.Image.dispose()` on budget overrun / error / unmount / completion),
/// 3. Triple automatic degradation:
///    - Tier 1: `MediaQuery.disableAnimationsOf(context)` -> `150ms` linear fade
///    - Tier 2: shader failure / `OhosRuntime.isOhos` / Windows fast mode ->
///      `220ms` (`185ms` Windows fast) scale + fade
///    - Tier 3: `toImage() > 16ms` -> session `preferFastTransition` scale + fade
Future<T?> pushPlayerRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  GlobalKey? backdropBoundaryKey,
  GlobalKey? posterKey,
  double posterRadiusLogical = 12.0,
  ui.Image? posterImage,
  bool ownsPoster = false,
  bool? useFastWindowsMode,
  RouteSettings? settings,
  bool fullscreenDialog = false,
  TransitionCaptureGate<ui.Image?>? captureGateOverride,
  BackdropImageCapturer? debugCapturer,
  Duration Function(Duration measured)? debugElapsedOverride,
  ValueChanged<PlayerTransitionMode>? onModeResolved,
  ui.FragmentProgram? debugShaderProgram,
}) async {
  bool posterOwnershipTransferred = false;
  PlayerTransitionSnapshot? snapshot;
  ui.FragmentProgram? program;
  late final bool reduceMotion;
  late final bool fastWindows;
  late final NavigatorState navigator;

  try {
    reduceMotion = MediaQuery.disableAnimationsOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final viewportSize = MediaQuery.sizeOf(context);
    final isOhos = OhosRuntime.isOhos;
    fastWindows = useFastWindowsMode ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);
    navigator = Navigator.of(context);

    if (!reduceMotion && !isOhos && !fastWindows) {
      program = debugShaderProgram ?? PlayerEnterTransition.cachedProgram;
      if (program == null && !PlayerEnterTransition.shaderLoadFailed) {
        // Trigger non-blocking warmup for subsequent entries; fall back to
        // 220ms scale + fade on the cold frame rather than stalling playback.
        unawaited(PlayerEnterTransition.prewarmShader());
      }

      if (program != null && !PlayerEnterTransition.preferFastTransition) {
        RenderRepaintBoundary? boundary;
        final boundaryObj =
            backdropBoundaryKey?.currentContext?.findRenderObject();
        if (boundaryObj is RenderRepaintBoundary && boundaryObj.hasSize) {
          boundary = boundaryObj;
        }
        final posterOrigin = _resolvePosterOriginLogical(
          posterKey: posterKey,
          backdropBoundary: boundary,
          viewportSize: viewportSize,
        );
        final hasPortalOrigin =
            posterOrigin.width >= 1.0 && posterOrigin.height >= 1.0;
        final ui.Image? effectivePoster = hasPortalOrigin ? posterImage : null;
        final bool effectiveOwnsPoster =
            hasPortalOrigin && ownsPoster && effectivePoster != null;

        final shouldUseIosGate =
            PlayerEnterTransition.shouldUseIosRouteGate(isOhosOverride: isOhos);
        final TransitionCaptureGate<ui.Image?>? gate = captureGateOverride ??
            (shouldUseIosGate
                ? (Future<ui.Image?> Function() action) =>
                    IosNativeRouteGate.runWithPlaceholders<ui.Image?>(action)
                : null);

        if (effectiveOwnsPoster) {
          posterOwnershipTransferred = true;
        }
        snapshot = await PlayerEnterTransition.captureBackdrop(
          boundary: boundary,
          customCapturer: debugCapturer,
          routeGateWrapper: gate,
          logicalSize: boundary != null ? boundary.size : viewportSize,
          devicePixelRatio: dpr,
          posterOriginLogical: hasPortalOrigin ? posterOrigin : Rect.zero,
          posterRadiusLogical: posterRadiusLogical,
          posterImage: effectivePoster,
          ownsPoster: effectiveOwnsPoster,
          reduceMotion: reduceMotion,
          useFastWindowsMode: fastWindows,
          debugElapsedOverride: debugElapsedOverride,
        );
      }
    }
  } finally {
    // If capture was skipped, threw before captureBackdrop took ownership, or
    // posterOrigin resolved to Rect.zero, immediately release caller-owned
    // posterImage so GPU textures never leak on any early-exit path.
    if (!posterOwnershipTransferred && ownsPoster && posterImage != null) {
      posterOwnershipTransferred = true;
      posterImage.dispose();
    }
  }

  if (!context.mounted) {
    snapshot?.dispose();
    return null;
  }

  final route = PlayerEnterPageRoute<T>(
    builder: builder,
    snapshot: snapshot,
    shaderProgram: program,
    reduceMotion: reduceMotion,
    useFastWindowsMode: fastWindows,
    onModeResolved: onModeResolved,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );

  try {
    return await navigator.push<T>(route);
  } catch (_) {
    snapshot?.dispose();
    rethrow;
  }
}

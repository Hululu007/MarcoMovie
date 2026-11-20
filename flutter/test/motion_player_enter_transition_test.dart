// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/motion/motion_tokens.dart';
import 'package:marco_movie/ui/motion/player_enter_transition.dart';

ui.Image _createSolidTestImage(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(width, height);
  } finally {
    picture.dispose();
  }
}

ui.Image _createStripedPosterImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final third = height / 3.0;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), third),
    Paint()..color = const Color(0xFFE02020),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, third, width.toDouble(), third),
    Paint()..color = const Color(0xFF20D050),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, third * 2, width.toDouble(), height - third * 2),
    Paint()..color = const Color(0xFFE02020),
  );
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(width, height);
  } finally {
    picture.dispose();
  }
}

(int r, int g, int b, int a) _readPixel(
  ByteData rgba,
  int width,
  int x,
  int y,
) {
  final offset = (y * width + x) * 4;
  return (
    rgba.getUint8(offset),
    rgba.getUint8(offset + 1),
    rgba.getUint8(offset + 2),
    rgba.getUint8(offset + 3),
  );
}

void main() {
  tearDown(() {
    PlayerEnterTransition.resetForTesting();
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  test('player_enter.frag source satisfies OpenGLES Y-flip, premul alpha & clean-room contracts',
      () {
    final shaderSrc = File('shaders/player_enter.frag').readAsStringSync();
    expect(shaderSrc, contains('#include <flutter/runtime_effect.glsl>'));
    expect(shaderSrc, contains('#ifdef IMPELLER_TARGET_OPENGLES'));
    expect(shaderSrc, contains('uv.y = 1.0 - uv.y;'));
    expect(shaderSrc, contains('FlutterFragCoord().xy'));
    expect(shaderSrc, contains('coverScale'));
    expect(shaderSrc, contains('composed.rgb * handoffAlpha'));

    final dartCodeOnly = File('lib/ui/motion/player_enter_transition.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(dartCodeOnly.contains('ImageFilter.shader'), isFalse);
    expect(dartCodeOnly.contains('BackdropFilter'), isFalse);
  });

  test('PlayerEnterShaderUniforms packs exact 15 logical-pixel floats without dpr scaling', () {
    const logicalSize = Size(390, 844);
    const posterRect = Rect.fromLTWH(24, 120, 120, 180);
    const safePadding = EdgeInsets.only(top: 47, bottom: 34);
    final uniforms = PlayerEnterShaderUniforms.fromLayout(
      viewportLogical: logicalSize,
      progress: 0.5,
      posterOriginLogical: posterRect,
      safePaddingLogical: safePadding,
      posterRadiusLogical: 14.0,
      posterAvailable: true,
      posterAspect: 2.0 / 3.0,
    );

    expect(uniforms.floats.length, 15);
    expect(uniforms.floats[0], 390.0); // uViewport.x (lp, NOT multiplied by dpr)
    expect(uniforms.floats[1], 844.0); // uViewport.y (lp)
    expect(uniforms.floats[2], 0.5); // uProgress
    expect(uniforms.floats[3], closeTo(0.10, 1e-6)); // uRecedeTilt at sin(pi/2)
    expect(uniforms.floats[4], 24.0); // uPosterOrigin.left
    expect(uniforms.floats[5], 120.0); // uPosterOrigin.top
    expect(uniforms.floats[6], 120.0); // uPosterOrigin.width
    expect(uniforms.floats[7], 180.0); // uPosterOrigin.height
    expect(uniforms.floats[8], 0.0); // uSafePadding.left
    expect(uniforms.floats[9], 47.0); // uSafePadding.top
    expect(uniforms.floats[10], 0.0); // uSafePadding.right
    expect(uniforms.floats[11], 34.0); // uSafePadding.bottom
    expect(uniforms.floats[12], 14.0); // uPosterRadius
    expect(uniforms.floats[13], 1.0); // uPosterAvailable
    expect(uniforms.floats[14], closeTo(0.666667, 1e-4)); // uPosterAspect
  });

  testWidgets('real player_enter.frag compiles, binds all 15 floats + 2 samplers, paints & disposes ui.Image',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final program = await PlayerEnterTransition.prewarmShader();
    expect(program, isNotNull, reason: 'player_enter.frag must compile and load');

    final backdrop = _createSolidTestImage(320, 568, const Color(0xFF182638));
    final poster = _createSolidTestImage(120, 180, const Color(0xFF0A84FF));
    final snapshot = PlayerTransitionSnapshot(
      backdropImage: backdrop,
      posterImage: poster,
      ownsBackdrop: true,
      ownsPoster: true,
      posterOriginLogical: const Rect.fromLTWH(20, 90, 110, 165),
      posterRadiusLogical: 12.0,
    );

    final controller = AnimationController(
      vsync: tester,
      duration: MotionTokens.durationTransitionEnter,
      value: 0.35,
    );
    addTearDown(controller.dispose);

    PlayerTransitionMode? resolvedMode;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerEnterTransition(
          animation: controller,
          snapshot: snapshot,
          shaderProgram: program,
          onModeResolved: (m) => resolvedMode = m,
          child: const ColoredBox(color: Color(0xFF000000)),
        ),
      ),
    );

    expect(resolvedMode, PlayerTransitionMode.shaderPortal);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
    expect(snapshot.isDisposed, isFalse);

    // Completing transition must immediately dispose owned ui.Image snapshot.
    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.status, AnimationStatus.completed);
    expect(snapshot.isDisposed, isTrue);
    expect(snapshot.backdropImage, isNull);
    expect(snapshot.posterImage, isNull);
  });

  testWidgets('Fallback 1: disableAnimations / reduce-motion -> 150ms linear crossfade',
      (tester) async {
    final program = await PlayerEnterTransition.prewarmShader();
    final snapshot = PlayerTransitionSnapshot(
      backdropImage: _createSolidTestImage(160, 240, const Color(0xFF102030)),
      ownsBackdrop: true,
    );
    final controller = AnimationController(
      vsync: tester,
      duration: MotionTokens.durationFast,
      value: 0.5,
    );
    addTearDown(controller.dispose);

    PlayerTransitionMode? resolvedMode;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: PlayerEnterTransition(
            animation: controller,
            snapshot: snapshot,
            shaderProgram: program,
            onModeResolved: (m) => resolvedMode = m,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );

    expect(resolvedMode, PlayerTransitionMode.reducedCrossFade);
    expect(
      PlayerEnterTransition.enterDurationFor(PlayerTransitionMode.reducedCrossFade),
      const Duration(milliseconds: 150),
    );
    final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
    final scale = tester.widget<ScaleTransition>(find.byType(ScaleTransition));
    expect(fade.opacity.value, closeTo(0.5, 1e-6));
    expect(scale.scale.value, 1.0);
    controller.value = 0.0;
    await tester.pump();
    expect(fade.opacity.value, closeTo(0.0, 1e-6));
    expect(scale.scale.value, 1.0);

    // Capture must also skip immediately under reduceMotion.
    var capturerCalled = false;
    final skipped = await PlayerEnterTransition.captureBackdrop(
      customCapturer: (_) async {
        capturerCalled = true;
        return _createSolidTestImage(10, 10, const Color(0xFF000000));
      },
      reduceMotion: true,
    );
    expect(capturerCalled, isFalse);
    expect(skipped.hasBackdrop, isFalse);

    // Unmounting mid-transition must still dispose owned snapshot cleanly.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(snapshot.isDisposed, isTrue);
  });

  testWidgets('Fallback 2: shader load failure -> 220ms scale+fade fallback',
      (tester) async {
    PlayerEnterTransition.debugProgramLoaderOverride = (_) async {
      throw StateError('Simulated shader compilation failure');
    };

    final loaded = await PlayerEnterTransition.prewarmShader();
    expect(loaded, isNull);
    expect(PlayerEnterTransition.shaderLoadFailed, isTrue);

    final snapshot = PlayerTransitionSnapshot(
      backdropImage: _createSolidTestImage(160, 240, const Color(0xFF102030)),
      ownsBackdrop: true,
    );
    final controller = AnimationController(
      vsync: tester,
      duration: MotionTokens.durationStandard,
      value: 0.5,
    );
    addTearDown(controller.dispose);

    PlayerTransitionMode? resolvedMode;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerEnterTransition(
          animation: controller,
          snapshot: snapshot,
          onModeResolved: (m) => resolvedMode = m,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    expect(resolvedMode, PlayerTransitionMode.scaleFadeFallback);
    expect(
      PlayerEnterTransition.enterDurationFor(PlayerTransitionMode.scaleFadeFallback),
      const Duration(milliseconds: 220),
    );
    expect(find.byType(ScaleTransition), findsOneWidget);
    expect(find.byType(FadeTransition), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(snapshot.isDisposed, isTrue);
  });

  testWidgets('Fallback 3: snapshot latency > 16ms -> disposes image, latches preferFast & uses scale+fade',
      (tester) async {
    final program = await PlayerEnterTransition.prewarmShader();
    expect(program, isNotNull);

    ui.Image? capturedRef;
    var gateInvoked = false;
    final slowSnapshot = await PlayerEnterTransition.captureBackdrop(
      logicalSize: const Size(390, 844),
      devicePixelRatio: 3.0,
      routeGateWrapper: (action) async {
        gateInvoked = true;
        return action();
      },
      customCapturer: (pixelRatio) async {
        // Longest logical edge 844 -> max edge 1280 => pixelRatio <= 1280/844 ~= 1.516
        expect(pixelRatio, lessThanOrEqualTo(1280.0 / 844.0 + 1e-6));
        capturedRef = _createSolidTestImage(100, 100, const Color(0xFF223344));
        return capturedRef;
      },
      debugElapsedOverride: (_) => const Duration(milliseconds: 24),
    );

    expect(gateInvoked, isTrue);
    expect(slowSnapshot.exceededBudget, isTrue);
    expect(slowSnapshot.hasBackdrop, isFalse);
    expect(PlayerEnterTransition.preferFastTransition, isTrue);
    // Captured image must already have been disposed in try/finally when budget exceeded!
    expect(capturedRef, isNotNull);
    expect(capturedRef!.debugDisposed, isTrue);

    // Subsequent capture short-circuits without invoking capturer again.
    var secondCaptureCalled = false;
    final followUp = await PlayerEnterTransition.captureBackdrop(
      customCapturer: (_) async {
        secondCaptureCalled = true;
        return _createSolidTestImage(16, 16, const Color(0xFF000000));
      },
    );
    expect(secondCaptureCalled, isFalse);
    expect(followUp.exceededBudget, isTrue);

    final controller = AnimationController(
      vsync: tester,
      duration: MotionTokens.durationStandard,
      value: 0.4,
    );
    addTearDown(controller.dispose);

    PlayerTransitionMode? resolvedMode;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PlayerEnterTransition(
          animation: controller,
          snapshot: slowSnapshot,
          shaderProgram: program,
          onModeResolved: (m) => resolvedMode = m,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    expect(resolvedMode, PlayerTransitionMode.scaleFadeFallback);
    expect(find.byType(ScaleTransition), findsOneWidget);
    expect(find.byType(FadeTransition), findsOneWidget);
  });

  testWidgets('HarmonyOS runtime guard skips shader prewarm and falls back to scale+fade',
      (tester) async {
    OhosRuntime.debugIsOhosOverride = true;
    final program = await PlayerEnterTransition.prewarmShader();
    expect(program, isNull);

    final mode = PlayerEnterTransition.resolveMode(
      reduceMotion: false,
      hasShaderProgram: true,
      hasBackdropImage: true,
    );
    expect(mode, PlayerTransitionMode.scaleFadeFallback);
  });

  testWidgets('PlayerEnterPageRoute honors durations and disposes snapshot on mid-flight pop',
      (tester) async {
    final program = await PlayerEnterTransition.prewarmShader();
    expect(program, isNotNull);

    final snapshot = PlayerTransitionSnapshot(
      backdropImage: _createSolidTestImage(200, 360, const Color(0xFF141C28)),
      ownsBackdrop: true,
    );
    final route = PlayerEnterPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('PlayerRoute')),
      snapshot: snapshot,
      shaderProgram: program,
    );
    expect(route.resolvedMode, PlayerTransitionMode.shaderPortal);
    expect(route.transitionDuration, const Duration(milliseconds: 420));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 300));

    final fastWinRoute = PlayerEnterPageRoute<void>(
      builder: (_) => const SizedBox.shrink(),
      useFastWindowsMode: true,
    );
    expect(fastWinRoute.resolvedMode, PlayerTransitionMode.scaleFadeFallback);
    expect(fastWinRoute.transitionDuration, const Duration(milliseconds: 185));
    expect(fastWinRoute.reverseTransitionDuration, const Duration(milliseconds: 150));

    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('DetailHome')),
      ),
    );
    navKey.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('PlayerRoute'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Pop mid-transition -> route dispose must release owned ui.Image snapshot.
    navKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(snapshot.isDisposed, isTrue);
  });

  testWidgets(
      'CRITICAL-1 regression: stateful player child is NEVER disposed/remounted across enter, completion, MediaQuery rebuild & reverse pop',
      (tester) async {
    final program = await PlayerEnterTransition.prewarmShader();
    expect(program, isNotNull);

    final snapshot = PlayerTransitionSnapshot(
      backdropImage: _createSolidTestImage(240, 420, const Color(0xFF1A2230)),
      ownsBackdrop: true,
    );
    final controller = AnimationController(
      vsync: tester,
      duration: MotionTokens.durationTransitionEnter,
      reverseDuration: MotionTokens.durationTransitionExit,
      value: 0.0,
    );
    addTearDown(controller.dispose);

    int initStateCount = 0;
    int disposeCount = 0;
    final resolvedModes = <PlayerTransitionMode>[];
    EdgeInsets padding = const EdgeInsets.only(top: 47, bottom: 34);
    bool disableAnimations = false;
    late StateSetter outerSetState;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          outerSetState = setState;
          return MediaQuery(
            data: MediaQueryData(
              padding: padding,
              disableAnimations: disableAnimations,
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: PlayerEnterTransition(
                animation: controller,
                snapshot: snapshot,
                shaderProgram: program,
                onModeResolved: resolvedModes.add,
                child: _LifecycleProbeChild(
                  onInit: () => initStateCount++,
                  onDispose: () => disposeCount++,
                ),
              ),
            ),
          );
        },
      ),
    );

    expect(initStateCount, 1);
    expect(disposeCount, 0);
    expect(resolvedModes, <PlayerTransitionMode>[PlayerTransitionMode.shaderPortal]);

    // 1) Forward enter 0.0 -> 0.5 -> 1.0 (settled): child state stays intact, snapshot disposed.
    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 210));
    expect(initStateCount, 1);
    expect(disposeCount, 0);

    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.status, AnimationStatus.completed);
    expect(snapshot.isDisposed, isTrue);
    expect(initStateCount, 1);
    expect(disposeCount, 0);
    expect(resolvedModes, <PlayerTransitionMode>[PlayerTransitionMode.shaderPortal]);

    // 2) Post-completion MediaQuery safe-area inset change during playback (e.g. HUD toggle / rotation).
    outerSetState(() => padding = EdgeInsets.zero);
    await tester.pump();
    expect(initStateCount, 1);
    expect(disposeCount, 0);
    expect(resolvedModes, <PlayerTransitionMode>[PlayerTransitionMode.shaderPortal]);

    // 3) Reverse exit (1.0 -> 0.5 -> 0.0): child never remounted AND exit smoothly animates!
    controller.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(initStateCount, 1);
    expect(disposeCount, 0);
    final midReverseFade = tester.widget<FadeTransition>(find.byType(FadeTransition));
    final midReverseScale = tester.widget<ScaleTransition>(find.byType(ScaleTransition));
    expect(midReverseFade.opacity.value, greaterThan(0.05));
    expect(midReverseFade.opacity.value, lessThan(0.95));
    expect(midReverseScale.scale.value, greaterThan(0.96));
    expect(midReverseScale.scale.value, lessThan(1.0));

    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.status, AnimationStatus.dismissed);
    expect(initStateCount, 1);
    expect(disposeCount, 0);

    // Toggle reduceMotion while mounted -> still invariant tree, zero remount.
    outerSetState(() => disableAnimations = true);
    await tester.pump();
    expect(initStateCount, 1);
    expect(disposeCount, 0);
  });

  testWidgets(
      'MAJOR-2 regression: routeGateWrapper endOfFrame vsync wait is NOT charged against 16ms capture budget',
      (tester) async {
    late PlayerTransitionSnapshot result;
    await tester.runAsync(() async {
      result = await PlayerEnterTransition.captureBackdrop(
        logicalSize: const Size(390, 844),
        devicePixelRatio: 3.0,
        routeGateWrapper: (action) async {
          // Simulate 60Hz iOS 26 placeholder swap + endOfFrame vsync wait (> 16ms).
          await Future<void>.delayed(const Duration(milliseconds: 25));
          return action();
        },
        customCapturer: (_) async =>
            _createSolidTestImage(100, 100, const Color(0xFF223344)),
      );
    });

    addTearDown(result.dispose);
    expect(result.exceededBudget, isFalse);
    expect(PlayerEnterTransition.preferFastTransition, isFalse);
    expect(result.hasBackdrop, isTrue);
    expect(
      result.captureDuration.inMilliseconds,
      lessThanOrEqualTo(MotionTokens.hudTransitionCaptureBudgetMs),
    );
  });

  test(
    'M-03: player_enter.frag flips Y under IMPELLER_TARGET_OPENGLES ONLY in sampleBackdrop and NEVER in samplePoster',
    () {
      final shaderSrc = File('shaders/player_enter.frag').readAsStringSync();
      final backdropFn = RegExp(
        r'vec4\s+sampleBackdrop\s*\([^)]*\)\s*\{[\s\S]*?\}',
      ).firstMatch(shaderSrc);
      final posterFn = RegExp(
        r'vec4\s+samplePoster\s*\([^)]*\)\s*\{[\s\S]*?\}',
      ).firstMatch(shaderSrc);

      expect(backdropFn, isNotNull);
      expect(posterFn, isNotNull);

      final backdropBody = backdropFn!.group(0)!;
      final posterBody = posterFn!.group(0)!;

      expect(backdropBody, contains('#ifdef IMPELLER_TARGET_OPENGLES'));
      expect(backdropBody, contains('uv.y = 1.0 - uv.y;'));
      expect(posterBody, isNot(contains('IMPELLER_TARGET_OPENGLES')));
      expect(posterBody, isNot(contains('uv.y = 1.0 - uv.y')));
      // S-01(c): must never embed the opaque #121216 placeholder slab.
      expect(shaderSrc, isNot(contains('vec3(0.071, 0.071, 0.086)')));
    },
  );

  testWidgets(
    'S-01(c): real player_enter.frag suppresses portal when uPosterAvailable == 0 (zero #121216 occlusion) and preserves BoxFit.cover when ready',
    (tester) async {
      final program = await PlayerEnterTransition.prewarmShader();
      expect(program, isNotNull);

      // Verify Dart-side uniform guard zeroes poster origin when posterAvailable == false.
      final disabledUniforms = PlayerEnterShaderUniforms.fromLayout(
        viewportLogical: const Size(200, 200),
        progress: 0.0,
        posterOriginLogical: const Rect.fromLTWH(20, 30, 80, 120),
        safePaddingLogical: EdgeInsets.zero,
        posterRadiusLogical: 18.0,
        posterAvailable: false,
        posterAspect: 2.0 / 3.0,
      );
      expect(disabledUniforms.floats[4], 0.0);
      expect(disabledUniforms.floats[5], 0.0);
      expect(disabledUniforms.floats[6], 0.0);
      expect(disabledUniforms.floats[7], 0.0);
      expect(disabledUniforms.floats[13], 0.0);

      final backdrop = _createSolidTestImage(200, 200, const Color(0xFF2890E0));
      final poster = _createStripedPosterImage(60, 90);
      addTearDown(backdrop.dispose);
      addTearDown(poster.dispose);

      // 1) Even if raw shader uniforms pass non-zero uPosterOrigin + uPosterAvailable = 0.0,
      // GLSL MUST suppress foreground portal (zero #121216 gray block over backdrop).
      ByteData? noPosterRgba;
      await tester.runAsync(() async {
        final shader = program!.fragmentShader();
        try {
          const rawFloats = <double>[
            200.0, 200.0, // uViewport
            0.0, // uProgress
            0.0, // uRecedeTilt
            20.0, 30.0, 80.0, 120.0, // non-zero uPosterOrigin
            0.0, 0.0, 0.0, 0.0, // uSafePadding
            18.0, // uPosterRadius
            0.0, // uPosterAvailable == false
            2.0 / 3.0, // uPosterAspect
          ];
          for (var i = 0; i < rawFloats.length; i++) {
            shader.setFloat(i, rawFloats[i]);
          }
          shader.setImageSampler(0, backdrop);
          shader.setImageSampler(1, poster);

          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 200, 200),
            Paint()..shader = shader,
          );
          final picture = recorder.endRecording();
          final rendered = picture.toImageSync(200, 200);
          picture.dispose();
          try {
            noPosterRgba = await rendered.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
          } finally {
            rendered.dispose();
          }
        } finally {
          shader.dispose();
        }
      });

      expect(noPosterRgba, isNotNull);
      final insideNoPoster = _readPixel(noPosterRgba!, 200, 60, 90);
      final outsideNoPoster = _readPixel(noPosterRgba!, 200, 160, 40);
      expect(insideNoPoster.$1, inInclusiveRange(32, 48));
      expect(insideNoPoster.$2, inInclusiveRange(136, 152));
      expect(insideNoPoster.$3, inInclusiveRange(216, 232));
      expect(outsideNoPoster.$1, inInclusiveRange(32, 48));
      expect(outsideNoPoster.$2, inInclusiveRange(136, 152));
      expect(outsideNoPoster.$3, inInclusiveRange(216, 232));

      // 2) With posterAvailable == true, frame 0 shows 2:3 striped poster inside card rect
      // and unoccluded backdrop outside; mid-flight expands with BoxFit.cover vertical crop.
      final snapshot = PlayerTransitionSnapshot(
        backdropImage: backdrop,
        posterImage: poster,
        ownsBackdrop: false,
        ownsPoster: false,
        posterOriginLogical: const Rect.fromLTWH(20, 40, 60, 90),
        posterRadiusLogical: 8.0,
      );
      ByteData? readyFrame0Rgba;
      ByteData? readyMidRgba;
      await tester.runAsync(() async {
        for (final entry in <(double, void Function(ByteData?))>[
          (0.0, (d) => readyFrame0Rgba = d),
          (0.45, (d) => readyMidRgba = d),
        ]) {
          final shader = program!.fragmentShader();
          try {
            final painter = PlayerEnterShaderPainter(
              shader: shader,
              progress: entry.$1,
              snapshot: snapshot,
              safePaddingLogical: EdgeInsets.zero,
            );
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            painter.paint(canvas, const Size(200, 200));
            final picture = recorder.endRecording();
            final rendered = picture.toImageSync(200, 200);
            picture.dispose();
            try {
              entry.$2(
                await rendered.toByteData(format: ui.ImageByteFormat.rawRgba),
              );
            } finally {
              rendered.dispose();
            }
          } finally {
            shader.dispose();
          }
        }
      });

      expect(readyFrame0Rgba, isNotNull);
      expect(readyMidRgba, isNotNull);
      // Frame 0: center of poster card (50, 85) -> green middle stripe; top (50, 50) -> red stripe;
      // outside card (160, 85) -> backdrop blue.
      final f0Center = _readPixel(readyFrame0Rgba!, 200, 50, 85);
      final f0Top = _readPixel(readyFrame0Rgba!, 200, 50, 50);
      final f0Outside = _readPixel(readyFrame0Rgba!, 200, 160, 85);
      expect(f0Center.$2, greaterThan(f0Center.$1 + 100));
      expect(f0Center.$2, greaterThan(f0Center.$3 + 80));
      expect(f0Top.$1, greaterThan(f0Top.$2 + 100));
      expect(f0Outside.$3, greaterThan(f0Outside.$1 + 120));

      // Progress 0.45: expanded toward centered 16:9 viewport -> center of viewport (100, 100)
      // shows BoxFit.cover cropped green middle stripe (G dominant over R and B).
      final midCenter = _readPixel(readyMidRgba!, 200, 100, 100);
      expect(midCenter.$2, greaterThan(midCenter.$1 + 60));
      expect(midCenter.$2, greaterThan(midCenter.$3 + 40));
    },
  );

  testWidgets(
    'S-01(a): captureBackdrop immediately disposes caller-owned posterImage on >16ms timeout, error, null capture, and skip paths',
    (tester) async {
      // 1) Budget overrun (>16ms) disposes both backdrop and owned poster immediately.
      final slowPoster = _createSolidTestImage(40, 60, const Color(0xFFAA4422));
      ui.Image? slowBackdrop;
      final slowSnap = await PlayerEnterTransition.captureBackdrop(
        posterImage: slowPoster,
        ownsPoster: true,
        posterOriginLogical: const Rect.fromLTWH(10, 10, 40, 60),
        customCapturer: (_) async {
          slowBackdrop = _createSolidTestImage(80, 80, const Color(0xFF102030));
          return slowBackdrop;
        },
        debugElapsedOverride: (_) => const Duration(milliseconds: 25),
      );
      expect(slowSnap.exceededBudget, isTrue);
      expect(slowBackdrop!.debugDisposed, isTrue);
      expect(slowPoster.debugDisposed, isTrue);
      slowSnap.dispose(); // idempotent, zero double-dispose

      // 2) Early-skip (preferFastTransition latched) disposes owned poster immediately.
      final skipPoster = _createSolidTestImage(40, 60, const Color(0xFFAA4422));
      final skipSnap = await PlayerEnterTransition.captureBackdrop(
        posterImage: skipPoster,
        ownsPoster: true,
      );
      expect(skipPoster.debugDisposed, isTrue);
      skipSnap.dispose();

      // 3) Capturer throws -> owned poster disposed immediately.
      PlayerEnterTransition.resetForTesting();
      final errPoster = _createSolidTestImage(40, 60, const Color(0xFFAA4422));
      final errSnap = await PlayerEnterTransition.captureBackdrop(
        posterImage: errPoster,
        ownsPoster: true,
        customCapturer: (_) async => throw StateError('boom'),
      );
      expect(errPoster.debugDisposed, isTrue);
      expect(errSnap.hasBackdrop, isFalse);
      errSnap.dispose();

      // 4) Null capture -> owned poster disposed immediately.
      final nullPoster = _createSolidTestImage(40, 60, const Color(0xFFAA4422));
      final nullSnap = await PlayerEnterTransition.captureBackdrop(
        posterImage: nullPoster,
        ownsPoster: true,
        customCapturer: (_) async => null,
      );
      expect(nullPoster.debugDisposed, isTrue);
      expect(nullSnap.hasPoster, isFalse);
      nullSnap.dispose();
    },
  );

  testWidgets(
    'S-01(a): decodePosterBytes downscales oversized posters, handles corrupt bytes, honors OHOS guard, and pushPlayerRoute disposes on unmount',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      // 1) Valid & oversized PNG decoding via decodePosterBytes
      late Uint8List largePng;
      await tester.runAsync(() async {
        final raw = _createSolidTestImage(800, 1200, const Color(0xFF336699));
        try {
          largePng = (await raw.toByteData(format: ui.ImageByteFormat.png))!
              .buffer
              .asUint8List();
        } finally {
          raw.dispose();
        }
      });

      ui.Image? decoded;
      await tester.runAsync(() async {
        decoded = await PlayerEnterTransition.decodePosterBytes(
          largePng,
          maxEdgePx: 720,
        );
      });
      expect(decoded, isNotNull);
      expect(decoded!.width, 480);
      expect(decoded!.height, 720);
      decoded!.dispose();
      expect(decoded!.debugDisposed, isTrue);

      // Corrupt & empty bytes -> returns null cleanly
      expect(
        await PlayerEnterTransition.decodePosterBytes(Uint8List(0)),
        isNull,
      );
      expect(
        await PlayerEnterTransition.decodePosterBytes(
          Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
        ),
        isNull,
      );

      // OHOS guard -> returns null without decoding
      OhosRuntime.debugIsOhosOverride = true;
      expect(
        await PlayerEnterTransition.decodePosterBytes(largePng),
        isNull,
      );
      OhosRuntime.resetForTesting();

      // 2) Unmounting host context mid-capture MUST dispose both backdrop & owned poster.
      final program = await PlayerEnterTransition.prewarmShader();
      expect(program, isNotNull);
      final posterKey = GlobalKey();
      late BuildContext hostCtx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                hostCtx = ctx;
                return SizedBox(key: posterKey, width: 120, height: 180);
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final ownedPoster = _createSolidTestImage(60, 90, const Color(0xFF44AA66));
      ui.Image? capturedBackdrop;
      final captureCompleter = Completer<ui.Image?>();

      final routeFuture = pushPlayerRoute<void>(
        context: hostCtx,
        posterKey: posterKey,
        posterImage: ownedPoster,
        ownsPoster: true,
        debugShaderProgram: program,
        debugCapturer: (_) => captureCompleter.future,
        builder: (_) => const Scaffold(body: Text('never-mounted')),
      );
      await tester.pump();

      // Unmount host while capture is still pending, then complete capture.
      await tester.pumpWidget(const SizedBox.shrink());
      capturedBackdrop = _createSolidTestImage(100, 100, const Color(0xFF102030));
      captureCompleter.complete(capturedBackdrop);
      await routeFuture;

      expect(capturedBackdrop.debugDisposed, isTrue);
      expect(ownedPoster.debugDisposed, isTrue);
    },
  );

  testWidgets(
    'L-02: shouldUseIosRouteGate is true ONLY for iOS + !OhosRuntime.isOhos + IosLiquidGlassBridge.isAvailable',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(false);
      expect(PlayerEnterTransition.shouldUseIosRouteGate(), isFalse);

      IosLiquidGlassBridge.setAvailableForTest(true);
      expect(PlayerEnterTransition.shouldUseIosRouteGate(), isTrue);

      OhosRuntime.debugIsOhosOverride = true;
      expect(PlayerEnterTransition.shouldUseIosRouteGate(), isFalse);
      OhosRuntime.resetForTesting();
    },
  );

  testWidgets(
    'L-02: shouldUseIosRouteGate is false on macOS even if bridge override is true',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      expect(PlayerEnterTransition.shouldUseIosRouteGate(), isFalse);
    },
  );
}

class _LifecycleProbeChild extends StatefulWidget {
  final VoidCallback onInit;
  final VoidCallback onDispose;

  const _LifecycleProbeChild({
    required this.onInit,
    required this.onDispose,
  });

  @override
  State<_LifecycleProbeChild> createState() => _LifecycleProbeChildState();
}

class _LifecycleProbeChildState extends State<_LifecycleProbeChild> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF000000));
}

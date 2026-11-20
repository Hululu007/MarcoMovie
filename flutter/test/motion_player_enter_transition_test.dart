// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
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

void main() {
  tearDown(() {
    PlayerEnterTransition.resetForTesting();
    OhosRuntime.resetForTesting();
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
    expect(find.byType(FadeTransition), findsOneWidget);
    expect(find.byType(ScaleTransition), findsNothing);

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
}

// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/motion/aurora_background.dart';
import 'package:marco_movie/ui/motion/motion_tokens.dart';

void main() {
  tearDown(() {
    AuroraBackground.resetForTesting();
    OhosRuntime.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
  });

  test('aurora.frag source & 16-float uniform layout match transitions-spec.md', () {
    final shaderSrc = File('shaders/aurora.frag').readAsStringSync();
    expect(shaderSrc, contains('#include <flutter/runtime_effect.glsl>'));
    expect(shaderSrc, contains('FlutterFragCoord().xy'));
    expect(shaderSrc, contains('uElapsedSec * 0.38'));
    expect(shaderSrc.contains('sampler2D'), isFalse);

    final uniforms = AuroraShaderUniforms.fromState(
      canvasSizeLogical: const Size(412, 915),
      elapsedSec: MotionTokens.auroraWrapPeriodSec + 10.5,
      strength: 0.62,
    );
    expect(uniforms.floats.length, 16);
    expect(uniforms.floats[0], 412.0);
    expect(uniforms.floats[1], 915.0);
    expect(uniforms.floats[2], closeTo(10.5, 1e-4));
    expect(uniforms.floats[3], closeTo(0.62, 1e-6));
    expect(uniforms.floats[4], closeTo(0.039, 0.002)); // #0A84FF r
    expect(uniforms.floats[5], closeTo(0.518, 0.002)); // #0A84FF g
    expect(uniforms.floats[6], closeTo(1.000, 0.002)); // #0A84FF b
  });

  testWidgets('real aurora.frag compiles, binds 16 floats, ticks when visible & stops on all hidden states',
      (tester) async {
    final program = await AuroraBackground.prewarmShader();
    expect(program, isNotNull, reason: 'aurora.frag must compile and load');

    final key = GlobalKey<AuroraBackgroundState>();
    var active = true;
    var tickerEnabled = true;

    late StateSetter outerSetState;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            outerSetState = setState;
            return TickerMode(
              enabled: tickerEnabled,
              child: AuroraBackground(
                key: key,
                active: active,
                shaderProgram: program,
                child: const SizedBox.expand(),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(key.currentState!.hasActiveShader, isTrue);
    expect(key.currentState!.isTickerRunning, isTrue);
    expect(key.currentState!.elapsedSeconds, greaterThan(0.0));
    expect(tester.takeException(), isNull);

    // 1) App backgrounded -> Ticker stops immediately (zero background leak).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(key.currentState!.isTickerRunning, isFalse);
    final pausedTime = key.currentState!.elapsedSeconds;
    await tester.pump(const Duration(milliseconds: 200));
    expect(key.currentState!.elapsedSeconds, pausedTime);

    // Resume lifecycle -> Ticker resumes smoothly.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 50));
    expect(key.currentState!.isTickerRunning, isTrue);

    // 2) TickerMode disabled -> Ticker stops immediately.
    outerSetState(() => tickerEnabled = false);
    await tester.pump();
    expect(key.currentState!.isTickerRunning, isFalse);
    outerSetState(() => tickerEnabled = true);
    await tester.pump();
    expect(key.currentState!.isTickerRunning, isTrue);

    // 3) Occluded by a pushed route (ModalRoute.isCurrent == false) -> Ticker stops!
    final nav = Navigator.of(key.currentContext!);
    nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Overlay')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(key.currentState!.isTickerRunning, isFalse);

    nav.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(key.currentState!.isTickerRunning, isTrue);

    // 4) active == false (e.g. player active) -> Ticker stops immediately.
    outerSetState(() => active = false);
    await tester.pump();
    expect(key.currentState!.isTickerRunning, isFalse);
  });

  testWidgets('reduce-motion, HarmonyOS, Windows static & shader failure all freeze Ticker cleanly',
      (tester) async {
    // Reduce-motion: static frame at 0.0s, Ticker stopped.
    final rmKey = GlobalKey<AuroraBackgroundState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AuroraBackground(key: rmKey),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(rmKey.currentState!.isTickerRunning, isFalse);
    expect(rmKey.currentState!.elapsedSeconds, 0.0);

    // HarmonyOS guard: no shader load, no Ticker.
    OhosRuntime.debugIsOhosOverride = true;
    final ohosKey = GlobalKey<AuroraBackgroundState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AuroraBackground(key: ohosKey),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(ohosKey.currentState!.hasActiveShader, isFalse);
    expect(ohosKey.currentState!.isTickerRunning, isFalse);
    OhosRuntime.resetForTesting();

    // Windows desktop static default: zero GPU shader / zero Ticker.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final winKey = GlobalKey<AuroraBackgroundState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AuroraBackground(key: winKey),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(winKey.currentState!.hasActiveShader, isFalse);
    expect(winKey.currentState!.isTickerRunning, isFalse);
    debugDefaultTargetPlatformOverride = null;

    // Shader load error falls back gracefully to AuroraFallbackPainter.
    AuroraBackground.resetForTesting();
    AuroraBackground.debugProgramLoaderOverride = (_) async {
      throw StateError('Simulated aurora shader load failure');
    };
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: AuroraBackground(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(AuroraBackground.shaderLoadFailed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'MINOR-4 regression: async prewarmShader completion does not overwrite explicit shaderProgram prop',
      (tester) async {
    final realProgram = await ui.FragmentProgram.fromAsset('shaders/aurora.frag');
    final completer = Completer<ui.FragmentProgram>();
    AuroraBackground.debugProgramLoaderOverride = (_) => completer.future;

    final key = GlobalKey<AuroraBackgroundState>();
    ui.FragmentProgram? explicitProgram;
    late StateSetter outerSetState;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StatefulBuilder(
          builder: (context, setState) {
            outerSetState = setState;
            return AuroraBackground(
              key: key,
              shaderProgram: explicitProgram,
            );
          },
        ),
      ),
    );

    // Supply explicit shaderProgram before async prewarm completes.
    outerSetState(() => explicitProgram = realProgram);
    await tester.pump();
    expect(key.currentState!.hasActiveShader, isTrue);

    // Completing async prewarm later must keep explicit shader cleanly without errors.
    completer.complete(realProgram);
    await tester.pump();
    expect(key.currentState!.hasActiveShader, isTrue);
    expect(tester.takeException(), isNull);
  });
}

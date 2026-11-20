// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/motion/brand_logo_loader.dart';
import 'package:marco_movie/ui/motion/motion_tokens.dart';

void main() {
  tearDown(() {
    OhosRuntime.resetForTesting();
  });

  test('BrandRibbonGeometry curves match 1.6s trace+sheen and reduce-motion [0.72, 1.0] alpha',
      () {
    // Ribbon M silhouette fits cleanly inside its bounding box.
    final path = BrandRibbonGeometry.buildRibbonPath(const Size(100, 100));
    final bounds = path.getBounds();
    expect(bounds.left, greaterThan(4));
    expect(bounds.right, lessThan(96));
    expect(bounds.top, greaterThan(15));
    expect(bounds.bottom, lessThan(80));

    // Normal mode: first half stroke trace, second half metallic sheen.
    expect(BrandRibbonGeometry.computeStrokeFraction(0.0, false), 0.0);
    expect(
      BrandRibbonGeometry.computeStrokeFraction(0.28, false),
      inInclusiveRange(0.45, 0.55),
    );
    expect(BrandRibbonGeometry.computeStrokeFraction(0.56, false), 1.0);
    expect(BrandRibbonGeometry.computeStrokeFraction(0.95, false), 1.0);

    expect(BrandRibbonGeometry.computeSheenProgress(0.20, false), lessThan(0.0));
    expect(
      BrandRibbonGeometry.computeSheenProgress(0.69, false),
      inInclusiveRange(0.45, 0.55),
    );
    expect(BrandRibbonGeometry.computeSheenProgress(0.95, false), lessThan(0.0));

    // Reduce-motion: static full ribbon + calm breathing opacity in [0.72, 1.0].
    for (int i = 0; i <= 100; i++) {
      final p = i / 100.0;
      expect(BrandRibbonGeometry.computeStrokeFraction(p, true), 1.0);
      expect(BrandRibbonGeometry.computeSheenProgress(p, true), lessThan(0.0));
      final alpha = BrandRibbonGeometry.computeRibbonAlpha(p, true);
      expect(
        alpha,
        inInclusiveRange(
          MotionTokens.reduceMotionLogoMinAlpha - 1e-6,
          MotionTokens.reduceMotionLogoMaxAlpha + 1e-6,
        ),
      );
    }
    expect(BrandRibbonGeometry.computeRibbonAlpha(0.0, true), closeTo(1.0, 1e-6));
    expect(BrandRibbonGeometry.computeRibbonAlpha(0.5, true), closeTo(0.72, 1e-6));
  });

  testWidgets('BrandLogoLoader runs 1.6s loop, degrades under reduce-motion, guards OHOS & stops in background',
      (tester) async {
    final key = GlobalKey<BrandLogoLoaderState>();
    var active = true;
    late StateSetter outerSetState;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            outerSetState = setState;
            return Center(
              child: BrandLogoLoader(
                key: key,
                size: 56,
                active: active,
              ),
            );
          },
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(key.currentState!.isAnimating, isTrue);
    expect(key.currentState!.isReducedMotion, isFalse);
    expect(key.currentState!.phase, closeTo(0.25, 0.05));
    expect(tester.takeException(), isNull);

    // App backgrounded -> stops animation controller immediately.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(key.currentState!.isAnimating, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 400));
    expect(key.currentState!.isAnimating, isTrue);

    // Route occlusion -> stops animation controller immediately.
    final nav = Navigator.of(key.currentContext!);
    nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Covered')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(key.currentState!.isAnimating, isFalse);
    nav.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(key.currentState!.isAnimating, isTrue);

    // active == false -> stops immediately.
    outerSetState(() => active = false);
    await tester.pump();
    expect(key.currentState!.isAnimating, isFalse);

    // Reduce-motion mode paints calm static breathing opacity cleanly.
    final rmKey = GlobalKey<BrandLogoLoaderState>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: BrandLogoLoader(key: rmKey, size: 44)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(rmKey.currentState!.isReducedMotion, isTrue);
    expect(tester.takeException(), isNull);

    // HarmonyOS guard stops animation loop completely.
    OhosRuntime.debugIsOhosOverride = true;
    final ohosKey = GlobalKey<BrandLogoLoaderState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: BrandLogoLoader(key: ohosKey, size: 44)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(ohosKey.currentState!.isAnimating, isFalse);
    expect(tester.takeException(), isNull);
  });
}

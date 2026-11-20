// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/onboarding/first_play_gesture_hint.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    OhosRuntime.resetForTesting();
    GlassworkBackdrop.reduceTransparency.value = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
    GlassworkBackdrop.reduceTransparency.value = false;
  });

  group('OnboardingPrefs', () {
    test('tracks completion, 3-show cap, dismiss, replay reset, and OHOS guard',
        () async {
      final prefs = await OnboardingPrefs.load();
      expect(prefs.shouldShowOnboarding(), isTrue);
      expect(prefs.shouldShowFirstPlayHint(), isTrue);

      await prefs.markOnboardingCompleted();
      expect(prefs.doneVersion, OnboardingPrefs.currentVersion);
      expect(prefs.shouldShowOnboarding(), isFalse);

      expect(await prefs.recordFirstPlayHintShown(), 1);
      expect(prefs.shouldShowFirstPlayHint(), isTrue);
      expect(await prefs.recordFirstPlayHintShown(), 2);
      expect(prefs.shouldShowFirstPlayHint(), isTrue);
      expect(await prefs.recordFirstPlayHintShown(), 3);
      expect(prefs.shouldShowFirstPlayHint(), isFalse);

      await prefs.resetForReplay();
      expect(prefs.shouldShowOnboarding(), isTrue);
      expect(prefs.shouldShowFirstPlayHint(), isTrue);

      await prefs.dismissFirstPlayHintForever();
      expect(prefs.playHintDismissed, isTrue);
      expect(prefs.shouldShowFirstPlayHint(), isFalse);

      await prefs.resetForReplay();
      OhosRuntime.debugIsOhosOverride = true;
      expect(prefs.shouldShowOnboarding(), isFalse);
      expect(prefs.shouldShowFirstPlayHint(), isFalse);
    });
  });

  group('DemoPosterItem manifest', () {
    test('parses all 14 fictional generated demo posters from disk', () {
      final manifestFile = File('assets/demo/manifest.json');
      expect(manifestFile.existsSync(), isTrue);
      final items = DemoPosterItem.parseManifest(manifestFile.readAsStringSync());
      expect(items.length, 14);
      expect(kFallbackDemoPosters.length, 14);
      for (final item in items) {
        expect(item.badgeZh, '示例');
        expect(item.badgeEn, 'DEMO');
        expect(item.titleZh.startsWith('示例'), isTrue);
        expect(item.titleEn.startsWith('Sample'), isTrue);
        expect(item.specs, isNotEmpty);
      }
    });
  });

  group('OnboardingScreen widget', () {
    testWidgets('walks through all 5 acts, 14-poster grid, HUD demo, and callbacks',
        (tester) async {
      final prefs = await OnboardingPrefs.load();
      String? importedUrl;
      bool syncOpened = false;
      bool? finishedSkipped;

      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: OnboardingScreen(
            prefs: prefs,
            isChinese: true,
            platformOverride: FirstPlayHintPlatform.desktop,
            onImportConfig: (url) => importedUrl = url,
            onOpenSync: () => syncOpened = true,
            onFinished: (skipped) => finishedSkipped = skipped,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Act 1: wide 2-column layout + empty-shell disclaimer + import callback
      expect(find.byKey(const Key('onboarding_wide_two_column')), findsOneWidget);
      expect(find.textContaining('不内置、不提供、不托管'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding_act1_import_button')));
      await tester.pump();
      expect(importedUrl, '');

      // Act 2: all 14 demo posters in adaptive grid + mandatory "示例" badge + desktop Tooltip
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding_demo_poster_grid')), findsOneWidget);
      expect(find.byKey(const Key('demo_badge_demo_01')), findsOneWidget);
      expect(find.byKey(const Key('demo_badge_demo_14')), findsOneWidget);
      expect(find.byType(Tooltip), findsNWidgets(14));

      // Act 3: WebDAV / LAN sync
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('marco-movie-sync'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding_act3_sync_button')));
      await tester.pump();
      expect(syncOpened, isTrue);

      // Act 4: Component-level mock HUD preview + interactive state cycling
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding_act4_hud_preview')), findsOneWidget);
      expect(find.textContaining('状态 1/3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding_act4_cycle_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('状态 2/3'), findsOneWidget);

      // Act 5: Personalize & finish
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding_reduce_motion_switch')), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();

      expect(finishedSkipped, isFalse);
      expect(prefs.shouldShowOnboarding(), isFalse);
    });

    testWidgets('renders cleanly at 320pt narrow Split-View width without overflow',
        (tester) async {
      final prefs = await OnboardingPrefs.load();
      bool? finishedSkipped;

      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: OnboardingScreen(
            prefs: prefs,
            isChinese: false,
            onFinished: (skipped) => finishedSkipped = skipped,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('onboarding_compact_single_column')),
        findsOneWidget,
      );
      // Advance to Act 2 so Back + Dots + Next are all shown simultaneously at 320pt.
      await tester.tap(find.byKey(const Key('onboarding_next_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding_prev_button')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('onboarding_skip_button')));
      await tester.pumpAndSettle();
      expect(finishedSkipped, isTrue);
      expect(prefs.shouldShowOnboarding(), isFalse);
    });

    testWidgets('bypasses onboarding completely on HarmonyOS NEXT',
        (tester) async {
      OhosRuntime.debugIsOhosOverride = true;
      final prefs = await OnboardingPrefs.load();
      bool? finishedSkipped;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: OnboardingScreen(
            prefs: prefs,
            onFinished: (skipped) => finishedSkipped = skipped,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('onboarding_skip_button')), findsNothing);
      expect(finishedSkipped, isTrue);
    });
  });

  group('FirstPlayGestureHint widget', () {
    testWidgets('fades in, records dwell, fades out on dismiss, and works without Material ancestor',
        (tester) async {
      final prefs = await OnboardingPrefs.load();
      bool dismissedCallbackFired = false;

      // Mount directly under Directionality (like an OverlayEntry without Material).
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: Center(
              child: FirstPlayGestureHint(
                prefs: prefs,
                isChinese: true,
                platformOverride: FirstPlayHintPlatform.desktop,
                dwellDuration: const Duration(milliseconds: 50),
                displayDuration: const Duration(milliseconds: 400),
                onDismissed: () => dismissedCallbackFired = true,
              ),
            ),
          ),
        ),
      );

      // Starts at opacity 0.0 for fade-in, then animates to 1.0 post-frame.
      final initialOpacity = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('first_play_gesture_hint_opacity')),
      );
      expect(initialOpacity.opacity, 0.0);
      await tester.pump();
      final fadedInOpacity = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('first_play_gesture_hint_opacity')),
      );
      expect(fadedInOpacity.opacity, 1.0);
      expect(find.textContaining('滚轮音量'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 60));
      expect(prefs.playHintShownCount, 1);

      // Tap dismiss -> animates opacity to 0.0 first, then unmounts on animation end.
      await tester.tap(find.byKey(const Key('first_play_gesture_hint_dismiss')));
      await tester.pump();
      final fadingOutOpacity = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('first_play_gesture_hint_opacity')),
      );
      expect(fadingOutOpacity.opacity, 0.0);

      await tester.pumpAndSettle();
      expect(prefs.playHintDismissed, isTrue);
      expect(prefs.shouldShowFirstPlayHint(), isFalse);
      expect(dismissedCallbackFired, isTrue);
      expect(
        find.byKey(const Key('first_play_gesture_hint_capsule')),
        findsNothing,
      );
    });

    testWidgets('is suppressed on HarmonyOS NEXT', (tester) async {
      OhosRuntime.debugIsOhosOverride = true;
      final prefs = await OnboardingPrefs.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: FirstPlayGestureHint(prefs: prefs),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('first_play_gesture_hint_capsule')),
        findsNothing,
      );
    });
  });
}

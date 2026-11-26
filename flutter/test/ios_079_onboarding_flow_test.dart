// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/onboarding/first_play_gesture_hint.dart';
import 'package:marco_movie/ui/onboarding/ios_onboarding_flow.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    OhosRuntime.resetForTesting();
    GlassworkBackdrop.reduceTransparency.value = false;
    IosLiquidGlassBridge.setAvailableForTest(false);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    OhosRuntime.resetForTesting();
    GlassworkBackdrop.reduceTransparency.value = false;
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  group('iOS 0.7.9 Apple-style onboarding gating', () {
    test('gates strictly to TargetPlatform.iOS and excludes OHOS & other platforms',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(shouldUseIosOnboardingFlow(), isTrue);

      OhosRuntime.debugIsOhosOverride = true;
      expect(shouldUseIosOnboardingFlow(), isFalse);
      OhosRuntime.resetForTesting();

      for (final platform in const <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          shouldUseIosOnboardingFlow(),
          isFalse,
          reason: '$platform must keep non-iOS onboarding untouched',
        );
      }
    });

    testWidgets(
      'non-iOS platforms still render the unchanged legacy 5-act flow',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final prefs = await OnboardingPrefs.load();

        await tester.pumpWidget(
          MaterialApp(
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('ios_onboarding_flow')), findsNothing);
        expect(find.textContaining('不内置、不提供、不托管'), findsOneWidget);
      },
    );
  });

  group('iOS 0.7.9 Apple-style 5-page onboarding navigation & persistence', () {
    testWidgets(
      'walks all 5 pages via 继续 -> 开始使用, supports back, persists completion, and leaves zero scheduled frames',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = await OnboardingPrefs.load();
        bool? finishedSkipped;

        await tester.pumpWidget(
          MaterialApp(
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: true,
              onImportConfig: (_) {},
              onFinished: (skipped) => finishedSkipped = skipped,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);

        // Page 1: 欢迎使用 Marco + empty-shell legal disclaimer
        expect(find.byKey(const Key('ios_onboarding_flow')), findsOneWidget);
        expect(find.text('欢迎使用 Marco'), findsOneWidget);
        expect(find.text('不含任何内置资源'), findsOneWidget);
        expect(find.text('继续'), findsOneWidget);
        expect(find.text('跳过'), findsOneWidget);

        // Page 1 -> Page 2: 添加资源库
        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text('添加资源库'), findsOneWidget);
        expect(find.text('配置中心'), findsOneWidget);
        expect(find.text('WebDAV · SMB · 网盘'), findsOneWidget);
        expect(find.byKey(const Key('ios_onboarding_import_link')), findsOneWidget);

        // Test back button returns to Page 1 cleanly, then forward again to Page 2
        await tester.tap(find.byKey(const Key('onboarding_prev_button')));
        await tester.pumpAndSettle();
        expect(find.text('欢迎使用 Marco'), findsOneWidget);

        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();
        expect(find.text('添加资源库'), findsOneWidget);

        // Page 2 -> Page 3: 浏览与搜索
        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text('浏览与搜索'), findsOneWidget);
        expect(find.text('底部 Dock 切换'), findsOneWidget);
        expect(find.text('长按快捷气泡'), findsOneWidget);
        expect(find.text('全局搜索与片库筛选'), findsOneWidget);

        // Page 3 -> Page 4: 播放手势与多屏
        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text('播放手势与多屏'), findsOneWidget);
        expect(find.text('双击与长按倍速'), findsOneWidget);
        expect(find.text('横滑进度，竖滑亮度和音量'), findsOneWidget);
        expect(find.text('画中画与投屏'), findsOneWidget);

        // Page 4 -> Page 5: 我的片库与隐私 -> CTA becomes 开始使用
        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text('我的片库与隐私'), findsOneWidget);
        expect(find.text('收藏与历史海报墙'), findsOneWidget);
        expect(find.text('剧集收纳离线下载'), findsOneWidget);
        expect(find.text('隐私空间隔离'), findsOneWidget);
        expect(find.text('开始使用'), findsOneWidget);

        // Tap 开始使用 -> finishes with skipped=false and persists completion
        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(finishedSkipped, isFalse);
        expect(prefs.shouldShowOnboarding(), isFalse);
        expect(prefs.doneVersion, OnboardingPrefs.currentVersion);
      },
    );

    testWidgets(
      '跳过 completes onboarding immediately with skipped=true and persists OnboardingPrefs',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final prefs = await OnboardingPrefs.load();
        bool? finishedSkipped;

        await tester.pumpWidget(
          MaterialApp(
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: true,
              onFinished: (skipped) => finishedSkipped = skipped,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('onboarding_skip_button')));
        await tester.pumpAndSettle();

        expect(finishedSkipped, isTrue);
        expect(prefs.shouldShowOnboarding(), isFalse);
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );

    testWidgets(
      'Page 2 立即添加资源库 triggers onImportConfig and marks onboarding completed',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = await OnboardingPrefs.load();
        String? importedInput;
        bool? finishedSkipped;

        await tester.pumpWidget(
          MaterialApp(
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: true,
              onImportConfig: (val) => importedInput = val,
              onFinished: (skipped) => finishedSkipped = skipped,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pumpAndSettle();

        final importLink = find.byKey(const Key('ios_onboarding_import_link'));
        await tester.ensureVisible(importLink);
        await tester.tap(importLink);
        await tester.pumpAndSettle();

        expect(importedInput, '');
        expect(finishedSkipped, isFalse);
        expect(prefs.shouldShowOnboarding(), isFalse);
      },
    );

    testWidgets(
      'respects Reduce Motion with instant entrance, instant page jumps, and zero scheduled frames',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = await OnboardingPrefs.load();
        bool? finishedSkipped;

        await tester.pumpWidget(
          MaterialApp(
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: true,
              initialReduceMotion: true,
              onFinished: (skipped) => finishedSkipped = skipped,
            ),
          ),
        );
        // Zero-duration pumps (0ms elapsed) settle immediately under Reduce Motion,
        // proving no non-zero animation controller or ticker is running.
        await tester.pump();
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text('欢迎使用 Marco'), findsOneWidget);

        // Each tap jumps immediately at t=0ms without starting any animation ticker.
        for (var i = 0; i < 4; i++) {
          await tester.tap(find.byKey(const Key('onboarding_next_button')));
          await tester.pump();
          await tester.pump();
          expect(tester.binding.hasScheduledFrame, isFalse);
        }
        expect(find.text('我的片库与隐私'), findsOneWidget);
        expect(find.text('开始使用'), findsOneWidget);

        await tester.tap(find.byKey(const Key('onboarding_next_button')));
        await tester.pump();
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(finishedSkipped, isFalse);
        expect(prefs.shouldShowOnboarding(), isFalse);
      },
    );
  });

  group('iOS 0.7.9 responsive & Dynamic Type layout safety', () {
    testWidgets(
      'zero overflow across all 5 pages at 320x568 with textScale 1.3 in Light & Dark mode',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        for (final brightness in const [Brightness.light, Brightness.dark]) {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final prefs = await OnboardingPrefs.load();

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: child!,
              ),
              home: OnboardingScreen(
                prefs: prefs,
                isChinese: true,
                onImportConfig: (_) {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.binding.hasScheduledFrame, isFalse);

          for (var i = 0; i < 4; i++) {
            await tester.tap(find.byKey(const Key('onboarding_next_button')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(tester.binding.hasScheduledFrame, isFalse);
          }
        }
      },
    );

    testWidgets(
      'centers within 560pt maxWidth on iPad Pro 1024x1366 and adapts cleanly in landscape 844x390',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        // 1. iPad Pro 1024x1366
        tester.view.physicalSize = const Size(1024, 1366);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = await OnboardingPrefs.load();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: false,
              onImportConfig: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.binding.hasScheduledFrame, isFalse);

        final pagerBox = tester.getRect(find.byKey(const Key('ios_onboarding_pager')));
        expect(pagerBox.width, lessThanOrEqualTo(560.0));
        expect(pagerBox.center.dx, closeTo(512.0, 1.0));

        for (var i = 0; i < 4; i++) {
          await tester.tap(find.byKey(const Key('onboarding_next_button')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.binding.hasScheduledFrame, isFalse);
        }

        // 2. iPhone Landscape 844x390
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );

    testWidgets(
      'platformOverride FirstPlayHintPlatform.desktop keeps legacy flow testable even on iOS',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(1024, 768);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final prefs = await OnboardingPrefs.load();
        await tester.pumpWidget(
          MaterialApp(
            home: OnboardingScreen(
              prefs: prefs,
              isChinese: true,
              platformOverride: FirstPlayHintPlatform.desktop,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ios_onboarding_flow')), findsNothing);
        expect(find.byKey(const Key('onboarding_wide_two_column')), findsOneWidget);
      },
    );
  });
}

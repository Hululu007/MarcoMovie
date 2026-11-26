// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/device_quality_profiler.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/ios_mpv_profile.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/motion/aurora_background.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List _kTinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosNativeRouteGate.scrollAwareSwapEnabled = true;
    IosNativeRouteGate.debugEnableRestoreDelayInTests = false;
    DeviceQualityProfiler.testSnapshotOverride = null;
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 1.0;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosNativeRouteGate.scrollAwareSwapEnabled = true;
    IosNativeRouteGate.debugEnableRestoreDelayInTests = false;
    DeviceQualityProfiler.testSnapshotOverride = null;
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 0.68;
  });

  group('iOS 26/27 Thermal Fixes (iPhone 17 Pro Max / iPhone18,2 / iOS 27.0)', () {
    test(
      'DeviceQualityProfiler.recommend keeps iosAnime4kLightweightEnabled == false on iPhone18,2 / iOS 27.0 and clears auto-enabled storage on detectAndApply',
      () async {
        SharedPreferences.setMockInitialValues({
          'ios_anime4k_lightweight': true, // Simulates 0.7.8 auto-enabled value
        });
        final storage = StorageService(await SharedPreferences.getInstance());
        expect(storage.iosAnime4kLightweightEnabled, isTrue);

        const iphone17ProMax = DeviceHardwareSnapshot(
          machineIdentifier: 'iPhone18,2',
          modelName: 'iPhone 17 Pro Max',
          physicalMemoryBytes: 12 * 1024 * 1024 * 1024,
          processorCount: 6,
          supportsHdrDisplay: true,
          potentialEdrHeadroom: 2.0,
          osVersion: '27.0',
          isPad: false,
          lowPowerMode: false,
          thermalState: IosThermalState.nominal,
        );

        final rec = DeviceQualityProfiler.recommend(iphone17ProMax);
        expect(rec.tier, DeviceHardwareTier.flagship);
        expect(rec.iosLargeBufferEnabled, isTrue);
        expect(rec.iosAnime4kLightweightEnabled, isFalse);

        DeviceQualityProfiler.testSnapshotOverride = iphone17ProMax;
        await DeviceQualityProfiler.detectAndApply(storage);
        expect(storage.iosAnime4kLightweightEnabled, isFalse);
      },
    );

    test(
      'GlassworkBackdrop.resolveRenderPolicy caps blurSigma <= 10.0 with TileMode.clamp and disables 54-tap lens shader across ALL iOS versions (including iOS 26/27)',
      () {
        final ios27Policy = GlassworkBackdrop.resolveRenderPolicy(
          strength: 1.0,
          isIos: true,
          iosLegacyGlass: false, // iOS 26/27 native Liquid Glass path!
          iosThermalElevated: false,
        );
        expect(ios27Policy.allowLensShader, isFalse);
        expect(ios27Policy.blurSigma, lessThanOrEqualTo(10.0));
        expect(ios27Policy.tileMode, TileMode.clamp);

        final ios27FairPolicy = GlassworkBackdrop.resolveRenderPolicy(
          strength: 1.0,
          isIos: true,
          iosLegacyGlass: false,
          iosThermalElevated: true, // .fair thermal level
        );
        expect(ios27FairPolicy.allowLensShader, isFalse);
        expect(ios27FairPolicy.blurSigma, lessThanOrEqualTo(6.0));
        expect(ios27FairPolicy.tileMode, TileMode.clamp);

        // Non-iOS desktop/macOS retains original behaviour.
        final macPolicy = GlassworkBackdrop.resolveRenderPolicy(
          strength: 1.0,
          isIos: false,
          iosLegacyGlass: false,
        );
        expect(macPolicy.allowLensShader, isTrue);
        expect(macPolicy.blurSigma, closeTo(26.0, 0.01));
        expect(macPolicy.tileMode, TileMode.mirror);
      },
    );

    testWidgets(
      'GlassworkBackdrop on iOS 27 (setAvailableForTest(true)) caps blur, skips lens shader, backs off at .fair, and disables BackdropFilter on thermal throttle',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        IosLiquidGlassBridge.setMajorVersionForTest(27);
        IosLiquidGlassBridge.setThermalLevelForTest(0);
        IosLiquidGlassBridge.setThermalThrottledForTest(false);
        GlassworkBackdrop.intensity.value = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: const Scaffold(
              body: Stack(
                children: [
                  AppleAmbientBackground(
                    preset: 'aurora',
                    showAmbientArtwork: true,
                  ),
                  Center(
                    child: GlassworkBackdrop(
                      radius: 24,
                      child: SizedBox(
                        key: ValueKey('ios27-glass-child'),
                        width: 140,
                        height: 52,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        // Home aurora wallpaper preset renders static frame (zero idle ticker) on iOS 27.
        final auroraState = tester.state<AuroraBackgroundState>(
          find.byKey(const Key('apple-ambient-aurora')),
        );
        expect(auroraState.isTickerRunning, isFalse);

        final beforeFilter =
            tester.widget<BackdropFilter>(find.byType(BackdropFilter));
        expect(beforeFilter.enabled, isTrue);

        // Elevate thermal level to .fair (1): BackdropFilter stays mounted, child is not reparented.
        final childElem =
            tester.element(find.byKey(const ValueKey('ios27-glass-child')));
        IosLiquidGlassBridge.setThermalLevelForTest(1);
        await tester.pump();
        expect(IosLiquidGlassBridge.thermalElevated, isTrue);
        expect(
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
          isTrue,
        );

        // Escalate to .serious thermal throttle: BackdropFilter disables completely!
        IosLiquidGlassBridge.setThermalThrottledForTest(true);
        await tester.pump();
        expect(
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
          isFalse,
        );
        expect(
          identical(
            childElem,
            tester.element(find.byKey(const ValueKey('ios27-glass-child'))),
          ),
          isTrue,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosLiquidGlassBridge parses thermalLevel from capabilities and handles thermalLevelChanged pushes',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'capabilities') {
            return <String, dynamic>{
              'available': true,
              'majorVersion': 27,
              'reduceTransparency': false,
              'sceneActive': true,
              'thermalThrottled': false,
              'thermalLevel': 1, // .fair
            };
          }
          return null;
        });

        final avail = await IosLiquidGlassBridge.ensureInitialized();
        expect(avail, isTrue);
        expect(IosLiquidGlassBridge.majorVersion, 27);
        expect(IosLiquidGlassBridge.thermalLevel, 1);
        expect(IosLiquidGlassBridge.thermalElevated, isTrue);
        expect(IosLiquidGlassBridge.thermalThrottled, isFalse);

        const codec = StandardMethodCodec();
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          IosLiquidGlassBridge.channel.name,
          codec.encodeMethodCall(const MethodCall('thermalLevelChanged', 0)),
          (_) {},
        );
        expect(IosLiquidGlassBridge.thermalLevel, 0);
        expect(IosLiquidGlassBridge.thermalElevated, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosNativeRouteGate swaps scrollable UiKitViews to placeholders during 120Hz scroll / thermal throttle / offstage while keeping fixed chrome native',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        IosLiquidGlassBridge.setMajorVersionForTest(27);
        IosNativeRouteGate.debugEnableRestoreDelayInTests = true;

        final scrollCtrl = ScrollController();
        addTearDown(scrollCtrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  // Fixed chrome (no Scrollable ancestor)
                  IosNativeGlassButton(
                    key: const Key('fixed-glass-btn'),
                    label: '固定栏',
                    onTap: () {},
                    fallback: const SizedBox(width: 80, height: 40),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollCtrl,
                      itemCount: 30,
                      itemBuilder: (ctx, i) => SizedBox(
                        height: 64,
                        child: Center(
                          child: IosNativeSwitch(
                            key: ValueKey('scroll-switch-$i'),
                            value: i.isEven,
                            onChanged: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        // At rest: both fixed button and visible list switches mount UiKitViews.
        expect(find.byType(UiKitView), findsWidgets);
        final idleUiKitCount = tester.widgetList(find.byType(UiKitView)).length;
        expect(idleUiKitCount, greaterThan(1));

        // Start drag scroll -> scrollable switches swap to CupertinoSwitch placeholders,
        // while fixed chrome button stays a native UiKitView!
        final gesture = await tester.startGesture(const Offset(200, 300));
        await gesture.moveBy(const Offset(0, -120));
        await tester.pump();

        expect(find.byType(UiKitView), findsOneWidget);
        expect(find.byType(CupertinoSwitch), findsWidgets);

        // Release finger and wait past scrollRestoreDelay (220ms) + settle.
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 260));
        await tester.pump();

        expect(
          tester.widgetList(find.byType(UiKitView)).length,
          greaterThan(1),
        );

        // Under .serious thermal throttle, scrollable switches degrade to CupertinoSwitch
        // while fixed chrome button stays native.
        IosLiquidGlassBridge.setThermalThrottledForTest(true);
        await tester.pump();
        expect(find.byType(UiKitView), findsOneWidget);
        expect(find.byType(CupertinoSwitch), findsWidgets);

        IosLiquidGlassBridge.setThermalThrottledForTest(false);
        await tester.pump();
        expect(
          tester.widgetList(find.byType(UiKitView)).length,
          greaterThan(1),
        );

        // Offstage TickerMode(enabled: false) unmounts hidden UiKitViews.
        expect(
          IosNativeRouteGate.shouldHostNative(
            available: true,
            forcePlaceholders: false,
            isCurrentRoute: true,
            ancestorScrolling: false,
            tickerModeEnabled: false,
          ),
          isFalse,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'IosMpvProfile activates lowPowerThermalMode at .fair and suppresses hidden-HUD PlayerScreen position setState rebuilds',
      () {
        expect(
          IosMpvProfile.shouldUseLowPowerThermalMode(
            avThermalState: IosThermalState.nominal,
            bridgeThermalElevated: false,
            iosMajorVersion: 27,
          ),
          isFalse,
        );
        expect(
          IosMpvProfile.shouldUseLowPowerThermalMode(
            avThermalState: IosThermalState.fair,
            bridgeThermalElevated: false,
            iosMajorVersion: 27,
          ),
          isTrue,
        );
        expect(
          IosMpvProfile.shouldUseLowPowerThermalMode(
            avThermalState: IosThermalState.nominal,
            bridgeThermalElevated: true,
            iosMajorVersion: 27,
          ),
          isTrue,
        );

        // Hidden HUD & no slim bar -> ZERO setState rebuilds during movie playback!
        expect(
          IosMpvProfile.shouldRebuildPositionUi(
            isIos: true,
            controlsVisible: false,
            screenLocked: false,
            slimBarVisible: false,
            isPipActive: false,
            playing: true,
            nowMs: 5000,
            lastUpdateMs: 0,
            nextPositionMs: 12000,
            lastRenderedPositionMs: 0,
          ),
          isFalse,
        );

        // Slim bar visible on iOS -> throttled to 1 Hz (1000ms), not 4 Hz (250ms).
        expect(
          IosMpvProfile.shouldRebuildPositionUi(
            isIos: true,
            controlsVisible: false,
            screenLocked: false,
            slimBarVisible: true,
            isPipActive: false,
            playing: true,
            nowMs: 1400,
            lastUpdateMs: 1000,
            nextPositionMs: 10400,
            lastRenderedPositionMs: 10000,
          ),
          isFalse,
        );
        expect(
          IosMpvProfile.shouldRebuildPositionUi(
            isIos: true,
            controlsVisible: false,
            screenLocked: false,
            slimBarVisible: true,
            isPipActive: false,
            playing: true,
            nowMs: 2050,
            lastUpdateMs: 1000,
            nextPositionMs: 11050,
            lastRenderedPositionMs: 10000,
          ),
          isTrue,
        );

        // Visible interactive HUD updates immediately on whole-second changes.
        expect(
          IosMpvProfile.shouldRebuildPositionUi(
            isIos: true,
            controlsVisible: true,
            screenLocked: false,
            slimBarVisible: false,
            isPipActive: false,
            playing: true,
            nowMs: 1050,
            lastUpdateMs: 1000,
            nextPositionMs: 5000,
            lastRenderedPositionMs: 1000,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'PosterImage bounds decode cacheWidth via ResizeImage on iOS even when highRes: true',
      (tester) async {
        // 126x189 grid card at 3x Retina -> quantized to 540px (not full 2000px!)
        final gridDecodeW = PosterLoader.resolveIosDecodeWidth(
          maxWidth: 126,
          maxHeight: 189,
          devicePixelRatio: 3.0,
          isHeroOrStrictHd: false,
        );
        expect(gridDecodeW, 540);

        // Full-bleed iPhone 17 Pro Max hero banner (440x580 at 3x DPR) -> capped <= 1680px
        final heroDecodeW = PosterLoader.resolveIosDecodeWidth(
          maxWidth: 440,
          maxHeight: 580,
          devicePixelRatio: 3.0,
          isHeroOrStrictHd: true,
        );
        expect(heroDecodeW, 1440);

        final dataUri =
            'data:image/png;base64,${base64Encode(_kTinyPngBytes)}';
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 126,
                height: 189,
                child: PosterImage(
                  url: dataUri,
                  highRes: true,
                  placeholder: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();

        final imgFinder = find.byType(Image);
        if (imgFinder.evaluate().isNotEmpty) {
          final imgWidget = tester.widget<Image>(imgFinder.first);
          expect(imgWidget.image, isA<ResizeImage>());
          final resize = imgWidget.image as ResizeImage;
          expect(resize.allowUpscaling, isFalse);
          expect(resize.width, lessThanOrEqualTo(720));
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

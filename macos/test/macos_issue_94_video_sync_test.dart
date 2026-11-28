import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/macos_video_sync.dart';
import 'package:marco_movie/core/storage_file_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/macos_official_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    MacosDisplayRefreshBridge.debugQueryOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  group('Issue #94 — macOS CVDisplayLink vsync-paced frame sync policy & settings', () {
    test('MacosVideoSyncPolicy enforces CVDisplayLink & live-stream safety invariants', () async {
      const display120 = MacosDisplayRefreshInfo(
        refreshRateHz: 120.0,
        vsyncPaced: true,
        isVariableRefresh: true,
        source: 'nsscreen_max_fps',
        screenName: 'Built-in Retina Display',
      );
      const display60 = MacosDisplayRefreshInfo(
        refreshRateHz: 59.94,
        vsyncPaced: true,
        source: 'cg_display_mode',
        screenName: 'External 4K 60Hz',
      );
      const nonVsyncDisplay = MacosDisplayRefreshInfo(
        refreshRateHz: 120.0,
        vsyncPaced: false,
        source: 'nsscreen_max_fps',
      );

      // 1. Default auto on 120 Hz CVDisplayLink -> display-resample, no interpolation
      final auto120 = MacosVideoSyncPolicy.resolve(
        mode: MacosVideoSyncMode.auto,
        tscale: MacosVideoSyncTscale.oversample,
        display: display120,
        isLive: false,
      );
      expect(auto120.appliedDisplaySync, isTrue);
      expect(auto120.appliedInterpolation, isFalse);
      expect(auto120.mpvProperties['video-sync'], 'display-resample');
      expect(auto120.mpvProperties['display-fps-override'], '120.000');
      expect(auto120.mpvProperties['interpolation'], 'no');

      // 2. Smooth interpolation on fixed 59.94 Hz -> display-resample + interpolation + tscale
      final smooth60 = MacosVideoSyncPolicy.resolve(
        mode: MacosVideoSyncMode.smoothInterpolation,
        tscale: MacosVideoSyncTscale.mitchell,
        display: display60,
        isLive: false,
      );
      expect(smooth60.appliedDisplaySync, isTrue);
      expect(smooth60.appliedInterpolation, isTrue);
      expect(smooth60.mpvProperties['video-sync'], 'display-resample');
      expect(smooth60.mpvProperties['display-fps-override'], '59.940');
      expect(smooth60.mpvProperties['interpolation'], 'yes');
      expect(smooth60.mpvProperties['tscale'], 'mitchell');

      // 3. CRITICAL SAFETY INVARIANT: non-vsync-paced render path MUST fall back to audio
      // (prevents unthrottled 1200fps loop + >1000ms A/V drift!)
      for (final mode in MacosVideoSyncMode.values) {
        final fallback = MacosVideoSyncPolicy.resolve(
          mode: mode,
          tscale: MacosVideoSyncTscale.oversample,
          display: nonVsyncDisplay,
          isLive: false,
        );
        expect(fallback.appliedDisplaySync, isFalse);
        expect(fallback.mpvProperties['video-sync'], 'audio');
        expect(fallback.mpvProperties['interpolation'], 'no');
        expect(fallback.mpvProperties['display-fps-override'], '0');
      }

      // 4. Live streams MUST always stay on audio sync even on 120 Hz CVDisplayLink
      final livePlan = MacosVideoSyncPolicy.resolve(
        mode: MacosVideoSyncMode.smoothInterpolation,
        tscale: MacosVideoSyncTscale.oversample,
        display: display120,
        isLive: true,
      );
      expect(livePlan.appliedDisplaySync, isFalse);
      expect(livePlan.mpvProperties['video-sync'], 'audio');
      expect(livePlan.mpvProperties['display-fps-override'], '0');

      // 5. applyWithSetter writes exact mpv properties in sequence
      final applied = <String, String>{};
      await MacosVideoSyncPolicy.applyWithSetter(
        (k, v) async => applied[k] = v,
        mode: MacosVideoSyncMode.displayResample,
        tscale: MacosVideoSyncTscale.oversample,
        display: display120,
        isLive: false,
      );
      expect(applied['video-sync'], 'display-resample');
      expect(applied['display-fps-override'], '120.000');
      expect(applied['video-sync-max-video-change'], '5');
      expect(applied['interpolation'], 'no');
    });

    test('StorageService persists macOS video sync settings and resets cleanly to default', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init(
        fileStore: InMemoryStorageFileStore(),
      );

      expect(storage.macosVideoSyncMode, MacosVideoSyncMode.auto);
      expect(storage.macosVideoSyncTscale, MacosVideoSyncTscale.oversample);

      await storage.setMacosVideoSyncMode(MacosVideoSyncMode.smoothInterpolation);
      await storage.setMacosVideoSyncTscale(MacosVideoSyncTscale.mitchell);
      expect(storage.macosVideoSyncMode, MacosVideoSyncMode.smoothInterpolation);
      expect(storage.macosVideoSyncTscale, MacosVideoSyncTscale.mitchell);

      await storage.resetMacosVideoSyncSettings();
      expect(storage.macosVideoSyncMode, MacosVideoSyncMode.auto);
      expect(storage.macosVideoSyncTscale, MacosVideoSyncTscale.oversample);
    });

    test('MacosDisplayRefreshBridge parses native display payloads and streams screen changes', () async {
      final parsed = MacosDisplayRefreshInfo.tryParseMap(const {
        'refreshRateHz': 120,
        'vsyncPaced': true,
        'isVariableRefresh': true,
        'source': 'nsscreen_max_fps',
        'screenName': 'Built-in Retina Display',
      });
      expect(parsed, isNotNull);
      expect(parsed!.effectiveDisplayFps, 120.0);
      expect(parsed.isHighRefresh, isTrue);
      expect(parsed.formattedRefreshRate, '120 Hz（ProMotion）');

      final events = <MacosDisplayRefreshInfo>[];
      final sub = MacosDisplayRefreshBridge.changes.listen(events.add);
      addTearDown(sub.cancel);

      MacosDisplayRefreshBridge.debugEmitDisplayRefreshChange(parsed);
      await Future<void>.delayed(Duration.zero);
      expect(events, [parsed]);
    });

    testWidgets(
      'macOS Playback Settings shows detected Hz/CVDisplayLink status and resets to default on tap',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
      MacosDisplayRefreshBridge.debugQueryOverride = () async =>
          const MacosDisplayRefreshInfo(
            refreshRateHz: 120.0,
            vsyncPaced: true,
            isVariableRefresh: true,
            source: 'nsscreen_max_fps',
            screenName: 'Built-in Retina Display',
          );

      SharedPreferences.setMockInitialValues({
        MacosOfficialNoticePrefs.acknowledgedVersionKey:
            MacosOfficialNoticePrefs.currentVersion,
        OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
      });
      final storage = await StorageService.init(
        fileStore: InMemoryStorageFileStore(),
      );
      await storage.setMacosVideoSyncMode(MacosVideoSyncMode.smoothInterpolation);
      await storage.setMacosVideoSyncTscale(MacosVideoSyncTscale.mitchell);

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: CmsClient()),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Navigate to Settings tab
      final settingsNav = find.text('设置').last;
      expect(settingsNav, findsOneWidget);
      await tester.tap(settingsNav);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Open 播放与画质偏好
      final playbackTile = find.text('播放与画质偏好');
      expect(playbackTile, findsWidgets);
      await tester.tap(playbackTile.first);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Scroll down to macOS Frame-Pacing section
      final statusFinder = find.byKey(const ValueKey('macos-video-sync-status'));
      final resetFinder = find.byKey(const ValueKey('macos-video-sync-reset'));
      await tester.scrollUntilVisible(
        resetFinder,
        240,
        scrollable: find.byType(Scrollable).last,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(statusFinder, findsOneWidget);
      expect(find.textContaining('120 Hz（ProMotion） · CVDisplayLink 已就绪'), findsOneWidget);
      expect(find.textContaining('interpolation (mitchell)'), findsOneWidget);

      // Tap 恢复默认 -> restores default mode & tscale cleanly
      await tester.tap(resetFinder);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(storage.macosVideoSyncMode, MacosVideoSyncMode.auto);
      expect(storage.macosVideoSyncTscale, MacosVideoSyncTscale.oversample);
      expect(find.text('已默认'), findsOneWidget);
    });
  });
}

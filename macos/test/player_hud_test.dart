// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/player/desktop_player_hud.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player/skip_countdown.dart';
import 'package:marco_movie/ui/player/sleep_timer.dart';
import 'package:marco_movie/ui/player/slim_progress_bar.dart';
import 'package:marco_movie/ui/player/speed_capsule.dart';
import 'package:marco_movie/ui/player/start_spec_overlay.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _HudFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 2);
  Duration durationValue = const Duration(minutes: 20);
  double volumeValue = 80.0;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();

  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => playingValue;
  @override
  bool get completed => completedValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => bufferingValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  Track get track => trackValue;
}

class _HudFakeStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast();
  final heightCtrl = StreamController<int?>.broadcast();
  final trackCtrl = StreamController<Track>.broadcast();
  final tracksCtrl = StreamController<Tracks>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final bufferingCtrl = StreamController<bool>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();

  @override
  Stream<int?> get width => widthCtrl.stream;
  @override
  Stream<int?> get height => heightCtrl.stream;
  @override
  Stream<Track> get track => trackCtrl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtrl.stream;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<bool> get buffering => bufferingCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;

  Future<void> close() async {
    await Future.wait([
      widthCtrl.close(),
      heightCtrl.close(),
      trackCtrl.close(),
      tracksCtrl.close(),
      positionCtrl.close(),
      durationCtrl.close(),
      playingCtrl.close(),
      bufferingCtrl.close(),
      completedCtrl.close(),
      errorCtrl.close(),
    ]);
  }
}

class _HudFakePlayer extends Fake implements Player {
  final _HudFakeState _state = _HudFakeState();
  final _HudFakeStream _stream = _HudFakeStream();
  final List<Duration> seeks = <Duration>[];
  final List<double> rates = <double>[];
  final List<double> volumes = <double>[];
  Duration initialDuration = const Duration(minutes: 20);
  Duration initialPosition = const Duration(minutes: 2);
  int openCalls = 0;
  int pauseCalls = 0;
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalls++;
    if (playable is Media) _state.playlistValue = Playlist([playable]);
    _state.durationValue = initialDuration;
    _state.positionValue = initialPosition;
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> stop() async => _state.playingValue = false;
  @override
  Future<void> play() async {
    _state.playingValue = true;
    if (!disposed) _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _state.playingValue = false;
    if (!disposed) _stream.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    _state.playingValue = !_state.playingValue;
    if (!disposed) _stream.playingCtrl.add(_state.playingValue);
  }

  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
    _state.positionValue = duration;
    if (!disposed) _stream.positionCtrl.add(duration);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    _state.rateValue = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    _state.volumeValue = volume;
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');

  setUp(() {
    OhosRuntime.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      if (call.method == 'isMaximized') return false;
      return null;
    });
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  group('MediaSpecFusion dual-channel anti-mislabeling & combo rules', () {
    test('960x540 real video with 4K line metadata NEVER outputs 4K (outputs SD)', () {
      final badges = MediaSpecFusion.fuse(
        videoWidth: 960,
        videoHeight: 540,
        videoCodec: 'h264',
        audioCodec: 'aac',
        lineName: '4K专线',
        episodeName: '第01集 4K高码',
        streamUrl: 'https://media.example/video.mp4',
      );
      final labels = badges.map((b) => b.label).toList();
      expect(labels, contains('SD'));
      expect(labels, isNot(contains('4K')));
      expect(labels, contains('AVC'));
      expect(labels, contains('AAC'));
    });

    test('3840x2160 real video with adaptive 4K/1080P metadata keeps 4K and fuses DV · ATMOS', () {
      final badges = MediaSpecFusion.fuse(
        videoWidth: 3840,
        videoHeight: 2160,
        videoCodec: 'hevc',
        audioCodec: 'eac3',
        extraTrackInfo: 'Dolby Vision Atmos 5.1',
        lineName: '4K/1080P自适应',
        episodeName: 'Sample.2026.WEB-DL.HDR10%2B.DD%2B.5.1.mkv',
      );
      final labels = badges.map((b) => b.label).toList();
      expect(labels.first, '4K');
      expect(labels, contains('DV · ATMOS'));
      expect(labels, contains('HDR10+'));
      expect(labels.length, lessThanOrEqualTo(5));
    });

    test('10bit without HDR does not emit HDR10, and [5.1GB] does not emit 5.1 channel', () {
      final badges = MediaSpecFusion.fuse(
        videoWidth: 1920,
        videoHeight: 1080,
        lineName: '普通线路',
        episodeName: '[5.1GB] Sample.1080p.10bit.x265.mkv',
      );
      final labels = badges.map((b) => b.label).toList();
      expect(labels, contains('1080p'));
      expect(labels, contains('HEVC'));
      expect(labels, isNot(contains('HDR10')));
      expect(labels, isNot(contains('5.1')));
    });
  });

  group('StartSpecOverlay, SlimProgressBar, SpeedCapsule, SkipCountdown, SleepTimer', () {
    testWidgets(
      'StartSpecOverlay animates 180ms fade-in & 240ms fade-out until dismissed, hides immediately on controlsVisible, and wraps cleanly at 320pt',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(320, 640);
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final badges = MediaSpecFusion.fuse(
          videoWidth: 3840,
          videoHeight: 2160,
          videoCodec: 'hevc',
          audioCodec: 'eac3',
          extraTrackInfo: 'Dolby Vision Atmos 5.1',
          lineName: '4K REMUX 原盘',
          episodeName: 'Sample.2026.HDR10%2B.5.1.mkv',
        );
        expect(badges.length, 5);

        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                StartSpecOverlay(
                  badges: badges,
                  highlightActive: true,
                  controlsVisible: false,
                  concentric: true,
                ),
              ],
            ),
          ),
        );
        expect(find.byKey(const Key('player-start-spec-overlay')), findsOneWidget);
        expect(tester.takeException(), isNull);
        final fadeInStart = tester
            .widget<FadeTransition>(find.byKey(const Key('player-start-spec-overlay')))
            .opacity
            .value;
        expect(fadeInStart, lessThan(0.5));
        // Mid-fade-in (90ms of 180ms)
        await tester.pump(const Duration(milliseconds: 90));
        final fadeInMid = tester
            .widget<FadeTransition>(find.byKey(const Key('player-start-spec-overlay')))
            .opacity
            .value;
        expect(fadeInMid, greaterThan(0.0));
        expect(fadeInMid, lessThan(1.0));
        // Complete fade-in (180ms)
        await tester.pump(const Duration(milliseconds: 120));
        expect(
          tester
              .widget<FadeTransition>(find.byKey(const Key('player-start-spec-overlay')))
              .opacity
              .value,
          closeTo(1.0, 0.01),
        );
        // Verify Wrap fits strictly inside 320pt viewport with zero right overflow.
        final overlayRect = tester.getRect(
          find.byKey(const Key('player-start-spec-overlay')),
        );
        expect(overlayRect.right, lessThanOrEqualTo(320.0));

        // Transition highlightActive -> false while controls stay hidden -> 240ms fade-out.
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                StartSpecOverlay(
                  badges: badges,
                  highlightActive: false,
                  controlsVisible: false,
                  concentric: true,
                ),
              ],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(const Key('player-start-spec-overlay')), findsOneWidget);
        final fadeOutMid = tester
            .widget<FadeTransition>(find.byKey(const Key('player-start-spec-overlay')))
            .opacity
            .value;
        expect(fadeOutMid, greaterThan(0.0));
        expect(fadeOutMid, lessThan(1.0));
        // Finish 240ms fade-out -> unmounts strictly on dismissed.
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pump();
        expect(find.byKey(const Key('player-start-spec-overlay')), findsNothing);

        // Re-show then flip controlsVisible = true -> hides IMMEDIATELY (no back-button overlap).
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                StartSpecOverlay(
                  badges: badges,
                  highlightActive: true,
                  controlsVisible: false,
                ),
              ],
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('player-start-spec-overlay')), findsOneWidget);
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                StartSpecOverlay(
                  badges: badges,
                  highlightActive: true,
                  controlsVisible: true,
                ),
              ],
            ),
          ),
        );
        expect(find.byKey(const Key('player-start-spec-overlay')), findsNothing);
      },
    );

    testWidgets(
      'SleepTimerWarningBanner fits 320pt Split-View under 1.35x text scale with zero overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(320, 640);
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.35),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SleepTimerWarningBanner(
                    remainingSeconds: 25,
                    onExtend15m: () {},
                    onCancel: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('sleep-timer-warning-banner')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('SlimProgressBar respects visibility, live stream, and OHOS guard', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SlimProgressBar(
              visible: true,
              enabled: true,
              isLive: false,
              positionMs: 30000,
              durationMs: 120000,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('player-slim-progress-bar')), findsOneWidget);

      // Guarded off on HarmonyOS NEXT.
      OhosRuntime.debugIsOhosOverride = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SlimProgressBar(
              visible: true,
              enabled: true,
              isLive: false,
              positionMs: 30000,
              durationMs: 120000,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('player-slim-progress-bar')), findsNothing);
    });

    testWidgets('PlayerSpeedCapsule renders boosting, lockReady, locked dim & unlock tap', (tester) async {
      var unlocked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerSpeedCapsule(
              mode: SpeedCapsuleMode.boosting,
              speed: 2.0,
              activeDetentIndex: 2,
              onUnlockTap: () => unlocked++,
            ),
          ),
        ),
      );
      expect(find.text('2.0× 倍速播放中'), findsOneWidget);
      expect(find.text('左右滑动调速 · 上滑锁定'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerSpeedCapsule(
              mode: SpeedCapsuleMode.lockReady,
              speed: 3.0,
              activeDetentIndex: 3,
              onUnlockTap: () => unlocked++,
            ),
          ),
        ),
      );
      expect(find.text('松手即可锁定 3.0×'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerSpeedCapsule(
              mode: SpeedCapsuleMode.locked,
              speed: 3.0,
              activeDetentIndex: 3,
              onUnlockTap: () => unlocked++,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('player-speed-locked-capsule')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      final opacityWidget = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacityWidget.opacity, closeTo(0.72, 0.01));

      await tester.tap(find.byKey(const Key('player-speed-locked-capsule')));
      expect(unlocked, 1);
    });

    test('SkipCountdownController auto-confirms after 3000ms, confirms early, or cancels cleanly', () {
      var confirmed = 0;
      var cancelled = 0;
      final ctrl = SkipCountdownController();
      ctrl.start(
        kind: SkipCountdownKind.intro,
        onConfirm: () => confirmed++,
        onCancel: () => cancelled++,
      );
      expect(ctrl.isActive, isTrue);
      expect(ctrl.remainingSeconds, 3);

      ctrl.advanceMs(1500);
      expect(ctrl.remainingSeconds, 2);
      expect(confirmed, 0);

      ctrl.advanceMs(1500);
      expect(confirmed, 1);
      expect(ctrl.isActive, isFalse);

      ctrl.start(
        kind: SkipCountdownKind.outro,
        onConfirm: () => confirmed++,
        onCancel: () => cancelled++,
      );
      ctrl.cancel();
      expect(cancelled, 1);
      expect(confirmed, 1);
      ctrl.dispose();
    });

    test('SleepTimerController starts off, warns at <=30s, extends +15m, and handles endOfEpisode', () {
      var triggered = 0;
      final timer = SleepTimerController(onTriggered: () => triggered++);
      expect(timer.mode, SleepTimerMode.off);
      expect(timer.isActive, isFalse);

      timer.setMode(SleepTimerMode.minutes15, overrideDurationSeconds: 31);
      expect(timer.showWarningBanner, isFalse);
      timer.tickOnce();
      expect(timer.remainingSeconds, 30);
      expect(timer.showWarningBanner, isTrue);

      timer.extend15Minutes();
      expect(timer.remainingSeconds, 930);
      expect(timer.showWarningBanner, isFalse);

      timer.setMode(SleepTimerMode.minutes15, overrideDurationSeconds: 1);
      timer.tickOnce();
      expect(triggered, 1);
      expect(timer.mode, SleepTimerMode.off);

      timer.setMode(SleepTimerMode.endOfEpisode);
      expect(timer.handleEpisodeCompleted(), isTrue);
      expect(triggered, 2);
      expect(timer.mode, SleepTimerMode.off);
      timer.dispose();
    });

    test('PlayerHudPrefs persists snake_case keys and respects OhosRuntime guard', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = PlayerHudPrefs(isDesktop: false);
      await prefs.load();
      expect(prefs.data.doubleTapCenter, 'play_pause');
      expect(prefs.data.doubleTapSides, 'seek_10s');
      expect(prefs.data.skipCountdown, isTrue);

      await prefs.setDoubleTapSides('seek_15s');
      await prefs.setSkipCountdown(false);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('player_double_tap_sides'), 'seek_15s');
      expect(sp.getBool('player_skip_countdown'), isFalse);

      OhosRuntime.debugIsOhosOverride = true;
      expect(prefs.enhancedHudEnabled, isFalse);
      expect(prefs.effectiveStartSpecHud, isFalse);
      expect(prefs.effectiveSlimProgress, isFalse);
      prefs.dispose();
    });
  });

  group('Desktop PlayerScreen HUD & keyboard/scroll integration', () {
    testWidgets(
      'Windows desktop supports scroll wheel volume, S speed cycle, arrow hold scrub + Esc cancel, and slim progress bar',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 720);
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final player = _HudFakePlayer();
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
      addTearDown(hudPrefs.dispose);

      const site = CmsSite(
        key: 'desk_site',
        name: '测试源',
        type: 1,
        api: 'https://source.example/api',
        isPrivate: true,
      );
      const video = CmsVideo(
        id: 'desk_vid',
        title: '星海旅途',
        lines: [
          CmsLine(
            name: '4K高码',
            episodes: [
              CmsEpisode(name: '第01集', url: 'file:///tmp/desk_e1.mp4'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              WindowsAppearanceScope(controller: appearance, child: child!),
          home: PlayerScreen(
            site: site,
            video: video,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: hudPrefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const Key('desktop-player-hud')), findsOneWidget);
      expect(find.byKey(const Key('desktop-sleep-timer-button')), findsOneWidget);

      // Scroll wheel up increases volume +5% (80 -> 85).
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(640, 360),
          scrollDelta: Offset(0, -120),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.volumes, isNotEmpty);
      expect(player.volumes.last, 85.0);

      // S key cycles 1.0 -> 1.25 -> 1.5 -> 2.0 -> 1.0.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.rates.last, 1.25);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.rates.last, 1.5);

      // Hold ArrowRight >= 280ms enters DesktopScrubPreviewCapsule without seeking,
      // and Escape cancels preview WITHOUT popping PlayerScreen!
      player.seeks.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byType(DesktopScrubPreviewCapsule), findsOneWidget);
      expect(player.seeks, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(DesktopScrubPreviewCapsule), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(player.seeks, isEmpty);

      // Short press ArrowRight commits +15s on key up.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.seeks, hasLength(1));

      // Wait for desktop 2500ms idle hide -> SlimProgressBar becomes visible.
      await tester.pump(const Duration(milliseconds: 2700));
      final slimOpacity = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('player-slim-progress-bar')),
      );
      expect(slimOpacity.opacity, 1.0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
    );
  });

  group('Gate 1 regressions — S-03, M-03, L-06', () {
    testWidgets(
      'S-03: SkipCountdown silently freezes without setting outroSkipped on pause, background lifecycle, and screen lock, and re-evaluates on resume',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        await tester.binding.setSurfaceSize(const Size(844, 390));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        const site = CmsSite(
          key: 's03_site',
          name: '测试源',
          type: 1,
          api: 'https://source.example/api',
          isPrivate: true,
        );
        const video = CmsVideo(
          id: 's03_vid',
          title: '片尾倒计时守卫测试',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [
                CmsEpisode(name: '第01集', url: 'file:///tmp/s03_e1.mp4'),
                CmsEpisode(name: '第02集', url: 'file:///tmp/s03_e2.mp4'),
              ],
            ),
          ],
        );
        await storage.setVideoSkipOutroSec(
          site.key,
          video.id,
          90,
          isPrivate: true,
        );
        await storage.setAutoNext(true);

        final player = _HudFakePlayer()
          ..initialDuration = const Duration(minutes: 10)
          ..initialPosition = const Duration(minutes: 8, seconds: 40);
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(hudPrefs.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(player.openCalls, 1);
        expect(find.byKey(const Key('skip-countdown-overlay')), findsOneWidget);

        // (a) Pause during 3s countdown -> silently freezes/cancels, NEVER calls _stepEpisode(1).
        await player.pause();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('skip-countdown-overlay')), findsNothing);
        await tester.pump(const Duration(seconds: 4));
        expect(player.openCalls, 1);

        // (b) Resume playback -> re-evaluates cleanly (_outroSkippedForSession stayed false!).
        await player.play();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('skip-countdown-overlay')), findsOneWidget);

        // (c) Background / phone call (AppLifecycleState.inactive / paused) -> silently cancels, NEVER opens ep 2 in background.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('skip-countdown-overlay')), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(const Duration(seconds: 4));
        expect(player.openCalls, 1);

        // (d) Return to foreground -> re-evaluates cleanly!
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('skip-countdown-overlay')), findsOneWidget);

        // (e) Screen lock -> silently cancels, NEVER auto-advances while locked.
        if (find.byKey(const Key('player-lock-button')).evaluate().isEmpty) {
          await tester.tapAt(const Offset(420, 200));
          await tester.pump(const Duration(milliseconds: 300));
        }
        await tester.tap(find.byKey(const Key('player-lock-button')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('skip-countdown-overlay')), findsNothing);
        await tester.pump(const Duration(seconds: 4));
        expect(player.openCalls, 1);

        // (f) Unlock screen -> re-evaluates, and letting 3s elapse cleanly advances to Episode 2!
        await tester.tapAt(const Offset(420, 200));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byKey(const Key('player-unlock-button')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('skip-countdown-overlay')), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 3200));
        await tester.pump(const Duration(milliseconds: 200));
        expect(player.openCalls, 2);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'M-03: edge guard uses systemGestureInsetsOf (not viewPadding) for iPhone landscape Dynamic Island and Android gesture nav',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        await tester.binding.setSurfaceSize(const Size(844, 390));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        const site = CmsSite(
          key: 'm03_site',
          name: '测试源',
          type: 1,
          api: 'https://source.example/api',
          isPrivate: true,
        );
        const video = CmsVideo(
          id: 'm03_vid',
          title: '边缘避让测试',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [
                CmsEpisode(name: '第01集', url: 'file:///tmp/m03_e1.mp4'),
              ],
            ),
          ],
        );

        // Part 1: iPhone landscape Dynamic Island: viewPadding.left = 59, systemGestureInsets = 0.
        // Tapping x = 40 (between 24lp guard and 59lp notch padding) MUST NOT be swallowed!
        final player1 = _HudFakePlayer();
        final prefs1 = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs1.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.fromLTRB(59, 0, 59, 21),
                viewPadding: const EdgeInsets.fromLTRB(59, 0, 59, 21),
                systemGestureInsets: EdgeInsets.zero,
              ),
              child: child!,
            ),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player1,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs1,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        // Auto-hide controls first.
        await tester.pump(const Duration(milliseconds: 4500));
        expect(find.byKey(const Key('ios-player-chrome-root')), findsNothing);

        // Tap at x = 40, y = 200 -> should wake controls after 260ms single-tap settlement.
        await tester.tapAt(const Offset(40, 200));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('ios-player-chrome-root')), findsOneWidget);

        // Part 2: Android gesture nav simulation: viewPadding.left = 0, systemGestureInsets.left = 42.
        // Tapping x = 34 (< 42) MUST yield to system back gesture and NOT wake controls!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));

        final player2 = _HudFakePlayer();
        final prefs2 = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs2.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: EdgeInsets.zero,
                viewPadding: EdgeInsets.zero,
                systemGestureInsets: const EdgeInsets.fromLTRB(42, 0, 42, 0),
              ),
              child: child!,
            ),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player2,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs2,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 4500));
        expect(find.byKey(const Key('ios-player-chrome-root')), findsNothing);

        await tester.tapAt(const Offset(34, 200));
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.byKey(const Key('ios-player-chrome-root')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'M-03: external pause during 350ms downPending cancels pending long-press so 2.0x boost never starts on paused player',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        await tester.binding.setSurfaceSize(const Size(844, 390));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        const site = CmsSite(
          key: 'm03_pause_site',
          name: '测试源',
          type: 1,
          api: 'https://source.example/api',
          isPrivate: true,
        );
        const video = CmsVideo(
          id: 'm03_pause_vid',
          title: 'downPending暂停取消测试',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [
                CmsEpisode(name: '第01集', url: 'file:///tmp/m03p_e1.mp4'),
              ],
            ),
          ],
        );

        final player = _HudFakePlayer();
        final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 4500));
        player.rates.clear();

        // Start touch press (enters downPending with 350ms timer).
        final hold = await tester.startGesture(
          const Offset(420, 200),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 150));

        // External pause (e.g. headset unplugged / audio interruption) mid-downPending.
        await player.pause();
        await tester.pump(const Duration(milliseconds: 300));

        // 450ms elapsed > 350ms: MUST NOT have started 2.0x boost on paused player!
        expect(player.rates, isNot(contains(2.0)));
        expect(find.byKey(const Key('player-speed-boosting-capsule')), findsNothing);

        await hold.up();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'L-06: embedded PlayerScreen wakes controls on tap after auto-hide and skips SlimProgressBar ticks when hidden',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(640, 360);
        await tester.binding.setSurfaceSize(const Size(640, 360));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final player = _HudFakePlayer();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);

        const site = CmsSite(
          key: 'l06_site',
          name: '测试源',
          type: 1,
          api: 'https://source.example/api',
          isPrivate: true,
        );
        const video = CmsVideo(
          id: 'l06_vid',
          title: '内嵌模式唤醒测试',
          lines: [
            CmsLine(
              name: '主线路',
              episodes: [
                CmsEpisode(name: '第01集', url: 'file:///tmp/l06_e1.mp4'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              embedded: true,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('desktop-player-hud-embedded')), findsOneWidget);

        // Wait for 2500ms desktop idle auto-hide.
        await tester.pump(const Duration(milliseconds: 2700));
        expect(find.byKey(const Key('desktop-player-hud-embedded')), findsNothing);
        // SlimProgressBar is hidden in embedded mode.
        expect(find.byKey(const Key('player-slim-progress-bar')), findsNothing);

        // Tap video surface in embedded mode -> MUST wake controls!
        await tester.tapAt(const Offset(320, 180));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('desktop-player-hud-embedded')), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });
}

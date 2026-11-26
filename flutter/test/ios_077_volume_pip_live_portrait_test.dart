import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/live_station_badge.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockPlatformPlayer extends Fake implements PlatformPlayer {
  final Map<String, String> properties = <String, String>{};

  Future<void> setProperty(String key, String value) async {
    properties[key] = value;
  }
}

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(seconds: 5);
  Duration durationValue = const Duration(minutes: 45);
  double volumeValue = 100.0;
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

class _FakePlayerStream extends Fake implements PlayerStream {
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

class _RecordingFakePlayer extends Fake implements Player {
  final _FakePlayerState _state = _FakePlayerState();
  final _FakePlayerStream _stream = _FakePlayerStream();
  final _MockPlatformPlayer _platform = _MockPlatformPlayer();
  final List<Media> openedMedia = <Media>[];
  final List<double> softwareVolumeCalls = <double>[];
  bool disposed = false;

  @override
  PlatformPlayer? get platform => _platform;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedMedia.add(playable);
      _state.playlistValue = Playlist([playable]);
    }
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(1920);
      _stream.heightCtrl.add(1080);
      _stream.positionCtrl.add(const Duration(seconds: 1));
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double v) async {
    softwareVolumeCalls.add(v);
    _state.volumeValue = v;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosAvPlayerController.defaultChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('marco_movie/ios_avplayer_events'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('iOS Device System Volume vertical drag', () {
    testWidgets(
      'right-side vertical drag adjusts iOS device system volume instead of software volume, shows 设备音量 HUD, and detaches on dispose',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        double mockSysVol = 0.40;
        final setSystemVolumeCalls = <double>[];
        var detachCalls = 0;
        var getSystemVolumeCalls = 0;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosAvPlayerController.defaultChannel,
                (MethodCall call) async {
          switch (call.method) {
            case 'getSystemVolume':
              getSystemVolumeCalls++;
              return mockSysVol;
            case 'setSystemVolume':
              final next = (call.arguments as num).toDouble().clamp(0.0, 1.0);
              mockSysVol = next;
              setSystemVolumeCalls.add(next);
              return next;
            case 'detachSystemVolume':
              detachCalls++;
              return null;
            case 'getTelemetry':
              return <String, Object?>{
                'thermalState': 'nominal',
                'physicalMemoryBytes': 6442450944,
                'isPipSupported': true,
                'isPipPossible': true,
                'isPipActive': false,
                'systemVolume': mockSysVol,
                'isAirPlayActive': false,
              };
            default:
              return true;
          }
        });

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        final prefs = PlayerHudPrefs(isDesktop: false);
        final fakePlayer = _RecordingFakePlayer();

        const site = CmsSite(
          key: 'vod1',
          name: '测试源',
          type: 1,
          api: 'https://vod.example/api',
        );
        const video = CmsVideo(
          id: 'v1',
          title: '播放样片',
          lines: [
            CmsLine(
              name: '主线',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://cdn.example/v1.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 250));

        expect(getSystemVolumeCalls, greaterThanOrEqualTo(1));
        final softVolCountBefore = fakePlayer.softwareVolumeCalls.length;

        // Drag upward on right side (x = 700 > 844/2) -> increases device volume
        await tester.dragFrom(const Offset(700, 260), const Offset(0, -100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(setSystemVolumeCalls, isNotEmpty);
        expect(setSystemVolumeCalls.last, greaterThan(0.45));
        expect(find.textContaining('设备音量 '), findsOneWidget);
        // Software volume was NEVER touched by vertical drag!
        expect(fakePlayer.softwareVolumeCalls.length, softVolCountBefore);

        // Drag upward on left side (x = 120 < 844/2) -> adjusts brightness, NOT system volume
        final volCallsBeforeLeft = setSystemVolumeCalls.length;
        await tester.dragFrom(const Offset(120, 260), const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 100));
        expect(setSystemVolumeCalls.length, volCallsBeforeLeft);
        expect(find.textContaining('亮度'), findsOneWidget);

        // Dispose detaches hidden MPVolumeView
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        expect(detachCalls, greaterThanOrEqualTo(1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS Picture-in-Picture (画中画) controller & player integration', () {
    test('IosAvPlayerController notifies listeners when isPipSupported/isPipPossible change even while inactive', () {
      final ctrl = IosAvPlayerController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      var notifications = 0;
      ctrl.addListener(() => notifications++);

      ctrl.handleNativeEvent(const {
        'type': 'pipStateChanged',
        'active': false,
        'supported': true,
        'possible': false,
      });
      expect(ctrl.isPipSupported, isTrue);
      expect(ctrl.isPipPossible, isFalse);
      expect(notifications, 1);

      ctrl.handleNativeEvent(const {
        'type': 'pipStateChanged',
        'active': false,
        'supported': true,
        'possible': true,
      });
      expect(ctrl.isPipPossible, isTrue);
      expect(notifications, 2);

      // Hardware volume button update updates systemVolume & notifies
      ctrl.handleNativeEvent(const {
        'type': 'systemVolumeChanged',
        'volume': 0.72,
      });
      expect(ctrl.hasSystemVolume, isTrue);
      expect(ctrl.systemVolume, closeTo(0.72, 0.001));
      expect(notifications, 3);
    });

    testWidgets(
      'tapping PiP on AVPlayer defers until isPipPossible turns true then auto-starts, and MPV incompatible stream shows clear explanation',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var allowStartPip = false;
        var startPipCalls = 0;
        var stopPipCalls = 0;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('marco_movie/ios_avplayer_events'),
          (MethodCall call) async => null,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosAvPlayerController.defaultChannel,
                (MethodCall call) async {
          switch (call.method) {
            case 'getTelemetry':
              return <String, Object?>{
                'thermalState': 'nominal',
                'physicalMemoryBytes': 6442450944,
                'isPipSupported': true,
                'isPipPossible': allowStartPip,
                'isPipActive': false,
                'systemVolume': 0.5,
                'isAirPlayActive': false,
              };
            case 'open':
              return true;
            case 'startPip':
              startPipCalls++;
              return allowStartPip;
            case 'stopPip':
              stopPipCalls++;
              return null;
            case 'getSystemVolume':
              return 0.5;
            default:
              return true;
          }
        });

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        final prefs = PlayerHudPrefs(isDesktop: false);
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _RecordingFakePlayer();

        const site = CmsSite(
          key: 'vod1',
          name: '测试源',
          type: 1,
          api: 'https://vod.example/api',
        );
        const video = CmsVideo(
          id: 'pip_v1',
          title: '画中画测试片',
          lines: [
            CmsLine(
              name: '主线',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://cdn.example/pip.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // 1. Tap PiP before native layer marks isPipPossible -> arms auto-start
        final pipBtn = find.byKey(const Key('ios-player-pip-button'));
        expect(pipBtn, findsOneWidget);
        await tester.tap(pipBtn);
        await tester.pump(const Duration(milliseconds: 100));
        expect(startPipCalls, 1);
        expect(avCtrl.isPipActive, isFalse);

        // 2. Native reports isPipPossible=true -> PlayerScreen auto-starts PiP,
        // and isPipActive flips to true only after native confirms didStart.
        allowStartPip = true;
        avCtrl.handleNativeEvent(const {
          'type': 'pipStateChanged',
          'active': false,
          'supported': true,
          'possible': true,
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(startPipCalls, 2);
        expect(avCtrl.isPipActive, isFalse);

        avCtrl.handleNativeEvent(const {
          'type': 'pipStateChanged',
          'active': true,
          'supported': true,
          'possible': true,
          'phase': 'didStart',
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(avCtrl.isPipActive, isTrue);

        // 3. Tapping PiP again while active stops PiP cleanly
        await tester.tap(pipBtn);
        await tester.pump(const Duration(milliseconds: 100));
        expect(stopPipCalls, 1);
        expect(avCtrl.isPipActive, isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS Live TV Portrait Companion redesign (iPhone & iPad portrait)', () {
    testWidgets(
      'entering Live TV in iPhone portrait (390x844) and iPad portrait (820x1180) shows top 16:9 live box + redesigned companion with 1-tap line switch, search, group filter, and in-place channel zapping',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosAvPlayerController.defaultChannel,
                (MethodCall call) async {
          if (call.method == 'getSystemVolume') return 0.5;
          return true;
        });

        final ch1 = LiveChannel(
          name: 'CCTV-1 综合',
          group: '央视',
          urls: const [
            'http://live.example/cctv1-hd.m3u8',
            'http://live.example/cctv1-backup.m3u8',
          ],
          latencyMs: 95,
          health: LiveStreamHealth.fast,
        );
        final ch2 = LiveChannel(
          name: 'CCTV-6 电影',
          group: '央视',
          urls: const ['http://live.example/cctv6.m3u8'],
        );
        final ch3 = LiveChannel(
          name: '湖南卫视',
          group: '卫视',
          urls: const ['http://live.example/hunan.m3u8'],
          latencyMs: 140,
          health: LiveStreamHealth.smooth,
        );
        final groups = [
          LiveGroup(name: '央视', channels: [ch1, ch2]),
          LiveGroup(name: '卫视', channels: [ch3]),
        ];
        const liveSite = CmsSite(
          key: '__live__',
          name: '默认直播',
          type: 1,
          api: 'http://live.example/list.m3u',
        );
        final liveVideo = CmsVideo(
          id: ch1.name,
          title: ch1.name,
          lines: [CmsLine(name: ch1.group, episodes: ch1.episodes)],
        );

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        final prefs = PlayerHudPrefs(isDesktop: false);
        final fakePlayer = _RecordingFakePlayer();

        // 1. iPhone Portrait (390x844, Light mode)
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: PlayerScreen(
              site: liveSite,
              video: liveVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              liveGroups: groups,
              initialLiveChannel: ch1,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 250));

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('ios-portrait-video-box')), findsOneWidget);
        expect(find.byKey(const Key('ios-portrait-live-badge')), findsOneWidget);
        expect(
          find.byKey(const Key('ios-live-portrait-companion-sheet')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('ios-live-companion-pip-btn')), findsOneWidget);
        expect(find.byType(LiveStationBadge), findsWidgets);

        // Top video box height is compact 16:9 (~219pt), NOT full 844pt black screen!
        final videoBoxSize =
            tester.getSize(find.byKey(const Key('ios-portrait-video-box')));
        expect(videoBoxSize.height, lessThan(260.0));

        // 1-tap signal line switch -> opens backup URL
        await tester.tap(find.byKey(const ValueKey('ios-live-line-chip-1')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          fakePlayer.openedMedia.last.uri,
          'http://live.example/cctv1-backup.m3u8',
        );

        // Switch group pill to 卫视 -> tap 湖南卫视 in-place
        await tester.tap(find.byKey(const ValueKey('ios-live-group-pill-1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('ios-live-channel-card-卫视-湖南卫视')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(fakePlayer.openedMedia.last.uri, 'http://live.example/hunan.m3u8');

        // Search filters across all groups cleanly
        await tester.enterText(
          find.byKey(const Key('ios-live-companion-search')),
          '电影',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ios-live-channel-card-央视-CCTV-6 电影')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ios-live-channel-card-卫视-湖南卫视')),
          findsNothing,
        );

        // 2. Narrow 320x568 & iPad portrait 820x1180 Dark mode -> zero overflow!
        tester.view.physicalSize = const Size(320, 568);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(820, 1180);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('ios-live-portrait-companion-sheet')),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 650));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

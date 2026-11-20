// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _IosFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 3);
  Duration durationValue = const Duration(minutes: 30);
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

class _IosFakeStream extends Fake implements PlayerStream {
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

class _IosFakePlayer extends Fake implements Player {
  final _IosFakeState _state = _IosFakeState();
  final _IosFakeStream _stream = _IosFakeStream();
  final List<double> rates = <double>[];
  final List<Duration> seeks = <Duration>[];
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) _state.playlistValue = Playlist([playable]);
    _state.durationValue = const Duration(minutes: 30);
    _state.positionValue = const Duration(minutes: 3);
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(3840);
      _stream.heightCtrl.add(2160);
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
  Future<void> setVolume(double volume) async => _state.volumeValue = volume;
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

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    GlassworkBackdrop.reduceTransparency.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('IosLiquidGlassBridge & IosNativeRouteGate Wave 1 upgrades', () {
    testWidgets(
      'IosLiquidGlassBridge reads reduceTransparency from capabilities and live native notifications',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'capabilities') {
            return <String, dynamic>{
              'available': true,
              'majorVersion': 26,
              'sdk26': true,
              'reduceTransparency': true,
            };
          }
          return null;
        });

        await IosLiquidGlassBridge.ensureInitialized();
        expect(IosLiquidGlassBridge.isAvailable, isTrue);
        expect(IosLiquidGlassBridge.reduceTransparency, isTrue);

        // Simulate native push turning reduceTransparency back off.
        const codec = StandardMethodCodec();
        final envelope = codec.encodeMethodCall(
          const MethodCall('reduceTransparencyChanged', false),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          IosLiquidGlassBridge.channel.name,
          envelope,
          (_) {},
        );
        expect(IosLiquidGlassBridge.reduceTransparency, isFalse);
      },
    );

    testWidgets(
      'IosNativeRouteGate.runWithPlaceholders swaps UiKitView for Flutter placeholder and restores via try/finally on throw',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IosNativeGlassButton(
                style: 'circle',
                symbol: 'chevron.backward',
                onTap: () {},
                fallback: const SizedBox.shrink(),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(UiKitView), findsOneWidget);

        var sawPlaceholderDuringAction = false;
        Object? caughtError;
        final future = IosNativeRouteGate.runWithPlaceholders<void>(() async {
          sawPlaceholderDuringAction =
              IosNativeRouteGate.forcePlaceholders &&
              find.byType(UiKitView).evaluate().isEmpty &&
              find
                  .byKey(
                    const ValueKey('ios26-glass-button-transition-placeholder'),
                  )
                  .evaluate()
                  .isNotEmpty;
          throw StateError('simulated capture failure');
        }).catchError((Object e) {
          caughtError = e;
        });

        await tester.pump();
        await future;
        await tester.pump();

        expect(caughtError, isA<StateError>());
        expect(sawPlaceholderDuringAction, isTrue);
        expect(IosNativeRouteGate.forcePlaceholders, isFalse);
        expect(find.byType(UiKitView), findsOneWidget);
      },
    );
  });

  group('IosPlayerChrome — iOS 26 Concentric Spatial Cinema HUD', () {
    const site = CmsSite(
      key: 'ios_site',
      name: '测试片源',
      type: 1,
      api: 'https://source.example/api',
      isPrivate: true,
    );
    const video = CmsVideo(
      id: 'ios_vid_1',
      title: '星海旅途',
      lines: [
        CmsLine(
          name: '4K HDR10+ 原盘',
          episodes: [
            CmsEpisode(
              name: '第01集 DV.Atmos.HEVC.mkv',
              url: 'file:///tmp/ios_e1.mp4',
            ),
          ],
        ),
        CmsLine(
          name: '备用线路',
          episodes: [
            CmsEpisode(name: '第01集', url: 'file:///tmp/ios_e1_b.mp4'),
          ],
        ),
      ],
    );

    Future<void> mountIosPlayer(
      WidgetTester tester, {
      required Size surfaceSize,
      required _IosFakePlayer player,
      EdgeInsets padding = EdgeInsets.zero,
      bool isLive = false,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = surfaceSize;
      await tester.binding.setSurfaceSize(surfaceSize);
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: padding,
              viewPadding: padding,
            ),
            child: child!,
          ),
          home: PlayerScreen(
            site: site,
            video: video,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            isLive: isLive,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets(
      'zero UiKitViews over video, 40pt top / 56-76-56pt center, <=7 dock, zero spec/back overlap, and glasswork unmounts on hide',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          padding: const EdgeInsets.fromLTRB(59, 0, 59, 21), // Dynamic Island landscape
          player: player,
        );
        // Trigger 350ms start spec highlight.
        await tester.pump(const Duration(milliseconds: 400));

        // 1. HARD RENDERING RULE: Zero UiKitViews scattered on active video surface!
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        // 2. Old 16-item right vertical tool dock is retired.
        expect(find.byKey(const Key('player-tool-dock-landscape')), findsNothing);
        expect(find.byKey(const Key('ios-player-primary-dock')), findsOneWidget);

        // 3. Concentric geometry checks: 40pt back capsule, 56/76/56pt center transport.
        final backRect = tester.getRect(find.byKey(const Key('ios-player-back-button')));
        expect(backRect.height, closeTo(40.0, 0.5));
        final playSize = tester.getSize(find.byKey(const Key('player-center-play-pause')));
        final rewindSize = tester.getSize(find.byKey(const Key('player-center-rewind')));
        final forwardSize = tester.getSize(find.byKey(const Key('player-center-forward')));
        expect(playSize, const Size(76.0, 76.0));
        expect(rewindSize, const Size(56.0, 56.0));
        expect(forwardSize, const Size(56.0, 56.0));

        // 4. Inline spec badges never overlap top-left return capsule.
        final specRect = tester.getRect(find.byKey(const Key('player-video-specs')));
        expect(backRect.overlaps(specRect), isFalse);

        // 5. Fluid scrubber track springs from 5pt at rest to 10pt during touch/drag.
        expect(
          tester.getSize(find.byKey(const Key('ios-fluid-scrubber-track'))).height,
          closeTo(5.0, 0.5),
        );
        final hitCenter = tester.getCenter(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        final drag = await tester.startGesture(hitCenter, kind: PointerDeviceKind.touch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.getSize(find.byKey(const Key('ios-fluid-scrubber-track'))).height,
          closeTo(10.0, 0.5),
        );
        await drag.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 60));
        await drag.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.getSize(find.byKey(const Key('ios-fluid-scrubber-track'))).height,
          closeTo(5.0, 0.5),
        );
        expect(player.seeks, isNotEmpty);

        // 6. GlassworkBackdrop mounts while HUD is visible, and unmounts completely when HUD hides.
        expect(find.byType(GlassworkBackdrop), findsWidgets);
        await tester.pump(const Duration(seconds: 5));
        expect(find.byType(IosPlayerChrome), findsNothing);
        expect(find.byType(GlassworkBackdrop), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'iOS 26+ dispatches showOptionSheet (including forceOpaque under reduceTransparency) while iOS 15-18 uses Flutter fallback',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          calls.add(call);
          if (call.method == 'showOptionSheet') {
            final args = call.arguments as Map<dynamic, dynamic>;
            if (args['title'] == '播放倍速') return '4'; // 1.5x in speeds list
          }
          return null;
        });

        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );

        await tester.tap(find.byKey(const ValueKey('ios-dock-action-speed')));
        await tester.pump(const Duration(milliseconds: 100));
        final speedCall = calls.firstWhere((c) => c.method == 'showOptionSheet');
        expect((speedCall.arguments as Map)['forceOpaque'], isFalse);
        expect(player.rates.last, 1.5);

        // Enable reduceTransparency on iOS 26 -> GlassworkBackdrop unmounts,
        // AND native showOptionSheet STILL dispatches with forceOpaque: true!
        calls.clear();
        IosLiquidGlassBridge.setReduceTransparencyForTest(true);
        await tester.pump();
        expect(find.byType(GlassworkBackdrop), findsNothing);

        await tester.tap(find.byKey(const Key('ios-player-more-button')));
        await tester.pump(const Duration(milliseconds: 100));
        final opaqueCall = calls.firstWhere((c) => c.method == 'showOptionSheet');
        expect((opaqueCall.arguments as Map)['title'], '播放选项');
        expect((opaqueCall.arguments as Map)['forceOpaque'], isTrue);

        // On iOS 15-18 (isAvailable == false) -> Flutter AppleModalSheet fallback opens.
        calls.clear();
        IosLiquidGlassBridge.setAvailableForTest(false);
        await tester.pump();
        await tester.tap(find.byKey(const Key('ios-player-more-button')));
        await tester.pumpAndSettle();
        expect(calls.where((c) => c.method == 'showOptionSheet'), isEmpty);
        expect(find.text('播放选项'), findsOneWidget);
        expect(find.text('定时关闭'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'opaque hit absorbers block touches on top header, scrubber timestamps & dock padding from leaking to video surface',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        player.seeks.clear();
        player.rates.clear();

        // 1. Tap on scrubber elapsed timestamp -> must NOT toggle HUD off.
        final elapsedCenter = tester.getCenter(
          find.byKey(const Key('ios-fluid-scrubber-elapsed')),
        );
        await tester.tapAt(elapsedCenter);
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        // 2. Tap on bottom dock outer left padding edge -> must NOT toggle HUD off.
        final dockRect = tester.getRect(
          find.byKey(const Key('ios-player-primary-dock')),
        );
        await tester.tapAt(Offset(dockRect.left + 3, dockRect.center.dy));
        await tester.pump(const Duration(milliseconds: 320));
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        // 3. Hold >= 380ms on top header title area -> must NOT trigger 2.0x speed boost or horizontal seek!
        final titleCenter = tester.getCenter(find.text('星海旅途'));
        final hold = await tester.startGesture(
          titleCenter,
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 420));
        await hold.moveBy(const Offset(50, 0));
        await tester.pump(const Duration(milliseconds: 60));
        await hold.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates, isEmpty);
        expect(player.seeks, isEmpty);
        expect(find.byType(IosPlayerChrome), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'IosFluidScrubberCapsule tracks active pointerId so second finger cannot jump or prematurely commit scrub',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        player.seeks.clear();

        final trackRect = tester.getRect(
          find.byKey(const Key('ios-fluid-scrubber-hit-area')),
        );
        // Primary finger touches near 50% and drags right to 75%.
        final p1 = await tester.startGesture(
          Offset(trackRect.left + trackRect.width * 0.5, trackRect.center.dy),
          kind: PointerDeviceKind.touch,
          pointer: 11,
        );
        await tester.pump();
        await p1.moveTo(
          Offset(trackRect.left + trackRect.width * 0.75, trackRect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 50));

        // Second finger touches at 10% and lifts -> must NOT commit or reset scrub!
        final p2 = await tester.startGesture(
          Offset(trackRect.left + trackRect.width * 0.1, trackRect.center.dy),
          kind: PointerDeviceKind.touch,
          pointer: 22,
        );
        await tester.pump(const Duration(milliseconds: 30));
        await p2.moveTo(
          Offset(trackRect.left + trackRect.width * 0.15, trackRect.center.dy),
        );
        await p2.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.seeks, isEmpty);

        // Lifting primary finger commits near 75% (~22:30 of 30:00).
        await p1.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.seeks, hasLength(1));
        expect(
          player.seeks.single.inSeconds,
          closeTo(const Duration(minutes: 30).inSeconds * 0.75, 45),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'responsive layout passes with zero overflow across iPhone portrait, iPad full, and narrow iPad split-view',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        for (final size in const [
          Size(390, 844), // iPhone portrait
          Size(1024, 768), // iPad landscape
          Size(320, 768), // iPad 1/3 split-view
        ]) {
          final player = _IosFakePlayer();
          await mountIosPlayer(tester, surfaceSize: size, player: player);
          expect(find.byType(IosPlayerChrome), findsOneWidget);
          expect(find.byType(UiKitView), findsNothing);
          expect(tester.takeException(), isNull, reason: 'No overflow at $size');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 50));
        }
      },
    );

    testWidgets(
      'end-to-end iOS touch long-press -> horizontal slide -> swipe-up lock -> unlock capsule',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final player = _IosFakePlayer();
        await mountIosPlayer(
          tester,
          surfaceSize: const Size(844, 390),
          player: player,
        );
        // Hide controls cleanly first by waiting 4.5s so surface is fully open.
        await tester.pump(const Duration(milliseconds: 4500));
        expect(find.byType(IosPlayerChrome), findsNothing);
        player.rates.clear();

        // Long-press >= 350ms at center -> 2.0x boost.
        final gesture = await tester.startGesture(
          const Offset(420, 220),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 380));
        expect(player.rates.last, 2.0);
        expect(find.byKey(const Key('player-speed-boosting-capsule')), findsOneWidget);

        // Slide right +40dp -> 3.0x detent.
        await gesture.moveTo(const Offset(460, 220));
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.rates.last, 3.0);

        // Swipe up -55dp -> lockReady.
        await gesture.moveTo(const Offset(460, 165));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('player-speed-lock-ready-capsule')), findsOneWidget);

        // Release -> speedLocked capsule appears.
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsOneWidget);

        // Tap unlock capsule -> restores 1.0x.
        await tester.tap(find.byKey(const Key('player-speed-locked-capsule')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 1.0);
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsNothing);

        // Re-lock 2.0x then simulate external AVAudioSession / headset pause (!playing stream)
        // -> speed-lock MUST auto-unlock cleanly and restore 1.0x.
        final gesture2 = await tester.startGesture(
          const Offset(420, 220),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 380));
        await gesture2.moveTo(const Offset(420, 165));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture2.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 2.0);
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsOneWidget);

        await player.pause();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.rates.last, 1.0);
        expect(find.byKey(const Key('player-speed-locked-capsule')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });
}

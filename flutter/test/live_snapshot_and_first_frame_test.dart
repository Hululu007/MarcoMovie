import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _ControlledLiveState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = false;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = Duration.zero;
  double volumeValue = 100.0;
  double rateValue = 1.0;
  bool bufferingValue = true;
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

class _ControlledLiveStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast(sync: true);
  final heightCtrl = StreamController<int?>.broadcast(sync: true);
  final trackCtrl = StreamController<Track>.broadcast(sync: true);
  final tracksCtrl = StreamController<Tracks>.broadcast(sync: true);
  final positionCtrl = StreamController<Duration>.broadcast(sync: true);
  final durationCtrl = StreamController<Duration>.broadcast(sync: true);
  final playingCtrl = StreamController<bool>.broadcast(sync: true);
  final bufferingCtrl = StreamController<bool>.broadcast(sync: true);
  final completedCtrl = StreamController<bool>.broadcast(sync: true);
  final errorCtrl = StreamController<String>.broadcast(sync: true);
  final volumeCtrl = StreamController<double>.broadcast(sync: true);

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
  @override
  Stream<double> get volume => volumeCtrl.stream;

  Future<void> close() => Future.wait([
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
        volumeCtrl.close(),
      ]);
}

class _ControlledLivePlayer extends Fake implements Player {
  final _ControlledLiveState stateImpl = _ControlledLiveState();
  final _ControlledLiveStream streamImpl = _ControlledLiveStream();
  final List<Media> opened = <Media>[];
  bool delayNextOpen = false;
  Completer<void>? openGate;
  bool _disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => stateImpl;
  @override
  PlayerStream get stream => streamImpl;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (delayNextOpen) {
      delayNextOpen = false;
      openGate = Completer<void>();
      await openGate!.future;
    }
    if (playable is Media) {
      opened.add(playable);
      stateImpl.playlistValue = Playlist([playable]);
    }
    stateImpl.playingValue = play;
    stateImpl.bufferingValue = true;
    stateImpl.positionValue = Duration.zero;
    if (!_disposed) {
      streamImpl.playingCtrl.add(play);
      streamImpl.bufferingCtrl.add(true);
    }
  }

  @override
  Future<void> play() async {
    stateImpl.playingValue = true;
    if (!_disposed) streamImpl.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    stateImpl.playingValue = false;
    if (!_disposed) streamImpl.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (stateImpl.playingValue) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double v) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await streamImpl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('equal-length inline live channel URL update (a.m3u8 -> b.m3u8) invalidates cached snapshot immediately', () async {
    final storage = await initTestStorage();
    const inlineA = '#EXTM3U\n#EXTINF:-1,测试台\nhttp://live.example/a.m3u8\n';
    const inlineB = '#EXTM3U\n#EXTINF:-1,测试台\nhttp://live.example/b.m3u8\n';
    expect(inlineA.length, inlineB.length);

    const srcA = LiveSource(
      name: '内嵌直播',
      url: '',
      subscriptionId: 'sub-live-1',
      inlineContent: inlineA,
    );
    const srcB = LiveSource(
      name: '内嵌直播',
      url: '',
      subscriptionId: 'sub-live-1',
      inlineContent: inlineB,
    );

    final parsedA = CmsParser.parseLivePlaylist(inlineA);
    await storage.saveLiveSnapshot(srcA, parsedA);
    expect(storage.loadLiveSnapshot(srcA)?.first.channels.first.urls, [
      'http://live.example/a.m3u8',
    ]);

    // After subscription updates a.m3u8 -> equal-length b.m3u8, snapshot MUST miss!
    expect(storage.loadLiveSnapshot(srcB), isNull);

    final parsedB = CmsParser.parseLivePlaylist(inlineB);
    expect(parsedB.first.channels.first.urls, ['http://live.example/b.m3u8']);
    await storage.saveLiveSnapshot(srcB, parsedB);
    expect(storage.loadLiveSnapshot(srcB)?.first.channels.first.urls, [
      'http://live.example/b.m3u8',
    ]);
  });

  group('PlayerScreen live first-frame and startup session guards', () {
    const liveSite = CmsSite(
      key: 'live-site',
      name: '直播测试',
      type: 1,
      api: 'https://live.example/list.m3u',
    );
    const liveVideo = CmsVideo(
      id: 'live-ch',
      title: '频道 A',
      lines: [
        CmsLine(
          name: '频道 A',
          episodes: [
            CmsEpisode(name: '线路 1', url: 'http://live.example/a.m3u8'),
            CmsEpisode(name: '线路 2', url: 'http://live.example/b.m3u8'),
          ],
        ),
      ],
    );

    Future<_ControlledLivePlayer> mountLive(WidgetTester tester) async {
      final storage = await initTestStorage();
      final player = _ControlledLivePlayer();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            site: liveSite,
            video: liveVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            isLive: true,
            debugPlayer: player,
            debugHudPrefs: PlayerHudPrefs(isDesktop: true),
            debugVideoSurface: const ColoredBox(color: Colors.black),
            loadingIndicator: const SizedBox(
              key: Key('live-loading-indicator'),
              width: 24,
              height: 24,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      return player;
    }

    testWidgets('known resolution (1920x1080) without rendered progress does NOT clear loading indicator prematurely', (tester) async {
      final player = await mountLive(tester);
      addTearDown(player.dispose);

      expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

      // Emit dimensions, duration, playing=true, buffering=false while position stays 0.
      player.streamImpl.widthCtrl.add(1920);
      player.streamImpl.heightCtrl.add(1080);
      player.streamImpl.durationCtrl.add(const Duration(seconds: 12));
      player.streamImpl.playingCtrl.add(true);
      player.streamImpl.bufferingCtrl.add(false);
      await tester.pump();

      // Still no playback progress -> loading indicator MUST remain visible!
      expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

      // Once actual playback advances (> 0), loading clears cleanly.
      player.streamImpl.positionCtrl.add(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('stale width/height from previous channel during rapid channel switch cannot clear new channel loading', (tester) async {
      final player = await mountLive(tester);
      addTearDown(player.dispose);

      // Channel A finishes starting.
      player.streamImpl.widthCtrl.add(1280);
      player.streamImpl.heightCtrl.add(720);
      player.streamImpl.positionCtrl.add(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

      // Rapidly switch to Channel B (next source) while open() is still pending.
      player.delayNextOpen = true;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

      // Stale Channel A emits width/height while playlist still holds Channel A!
      player.streamImpl.widthCtrl.add(1920);
      player.streamImpl.heightCtrl.add(1080);
      await tester.pump();

      // New Channel B MUST still show loading indicator!
      expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

      // Complete Channel B open + emit Channel B real progress.
      player.openGate?.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(player.opened, hasLength(2));
      expect(player.opened.last.uri, 'http://live.example/b.m3u8');
      player.streamImpl.positionCtrl.add(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('audio-only radio stream (0x0 video) clears loading and plays cleanly when position advances', (tester) async {
      final player = await mountLive(tester);
      addTearDown(player.dispose);

      expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

      // Audio-only: no width/height ever emitted, only audio track + position progress.
      player.streamImpl.trackCtrl.add(
        Track(audio: AudioTrack('1', 'Radio AAC', 'zh', codec: 'aac')),
      );
      player.streamImpl.bufferingCtrl.add(false);
      player.streamImpl.positionCtrl.add(const Duration(milliseconds: 450));
      await tester.pump();

      expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

      // Advance past startup window (8s+) -> zero timeout errors.
      player.streamImpl.positionCtrl.add(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 9));
      expect(find.textContaining('超时'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('user pausing during live startup suspends timeout watchdog without spurious failure', (tester) async {
      final player = await mountLive(tester);
      addTearDown(player.dispose);

      // User actively pauses before first frame arrives.
      await player.pause();
      await tester.pump();

      // Wait longer than the 7s live startup timeout -> MUST NOT fail!
      await tester.pump(const Duration(seconds: 10));
      expect(find.textContaining('超时'), findsNothing);
      expect(find.textContaining('失败'), findsNothing);

      // User resumes and stream delivers progress -> clears loading cleanly.
      await player.play();
      await tester.pump();
      player.streamImpl.positionCtrl.add(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

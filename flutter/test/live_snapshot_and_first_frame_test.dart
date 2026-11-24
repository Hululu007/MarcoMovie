import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

bool _hasFfmpegTool() {
  try {
    return Process.runSync('ffmpeg', const ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

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

    Future<({_ControlledLivePlayer player, StreamController<bool> videoOutput})>
        mountLive(WidgetTester tester) async {
      final storage = await initTestStorage();
      final player = _ControlledLivePlayer();
      final videoOutput = StreamController<bool>.broadcast(sync: true);
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
            debugLiveVideoOutputStream: videoOutput.stream,
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
      return (player: player, videoOutput: videoOutput);
    }

    testWidgets(
      'known resolution (1920x1080) without video output does NOT clear loading; real video output clears cleanly',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final harness = await mountLive(tester);
        final player = harness.player;
        addTearDown(() async {
          await harness.videoOutput.close();
          await player.dispose();
        });

        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        // Emit dimensions, duration, playing=true, buffering=false while no video frame is displayed.
        player.streamImpl.trackCtrl.add(
          Track(
            video: VideoTrack('1', 'H264', 'und', codec: 'h264'),
            audio: AudioTrack('1', 'AAC', 'zh', codec: 'aac'),
          ),
        );
        player.streamImpl.widthCtrl.add(1920);
        player.streamImpl.heightCtrl.add(1080);
        player.streamImpl.durationCtrl.add(const Duration(seconds: 12));
        player.streamImpl.playingCtrl.add(true);
        player.streamImpl.bufferingCtrl.add(false);
        await tester.pump();

        // Still no displayed video frame -> loading indicator MUST remain visible!
        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        // Once actual video output is confirmed alongside playback progress, loading clears cleanly.
        player.streamImpl.positionCtrl.add(const Duration(milliseconds: 350));
        await tester.pump();
        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        harness.videoOutput.add(true);
        await tester.pump();
        expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'audio clock advancing with selected video track but NO video output keeps loading and triggers startup timeout recovery',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final harness = await mountLive(tester);
        final player = harness.player;
        addTearDown(() async {
          await harness.videoOutput.close();
          await player.dispose();
        });

        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);
        expect(player.opened, hasLength(1));

        // Simulate black-screen live stream: video track selected & 1920x1080 metadata known,
        // audio clock advances every second for 12s, but NO actual video output signal ever arrives.
        player.streamImpl.trackCtrl.add(
          Track(
            video: VideoTrack('1', 'HEVC', 'und', codec: 'hevc'),
            audio: AudioTrack('1', 'AAC', 'zh', codec: 'aac'),
          ),
        );
        player.streamImpl.widthCtrl.add(1920);
        player.streamImpl.heightCtrl.add(1080);
        player.streamImpl.playingCtrl.add(true);
        player.streamImpl.bufferingCtrl.add(false);
        await tester.pump();

        for (var sec = 1; sec <= 12; sec++) {
          player.streamImpl.positionCtrl.add(Duration(seconds: sec));
          await tester.pump(const Duration(seconds: 1));
        }

        // Loading indicator MUST remain visible and startup watchdog MUST have triggered recovery!
        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);
        expect(
          player.opened.length,
          greaterThan(1),
          reason:
              'Advancing audio clock alone must not cancel live startup timeout recovery when video output is absent',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'stale width/height from previous channel during rapid channel switch cannot clear new channel loading',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final harness = await mountLive(tester);
        final player = harness.player;
        addTearDown(() async {
          await harness.videoOutput.close();
          await player.dispose();
        });

        // Channel A finishes starting with real video output.
        player.streamImpl.trackCtrl.add(
          Track(video: VideoTrack('1', 'H264', 'und', codec: 'h264')),
        );
        player.streamImpl.widthCtrl.add(1280);
        player.streamImpl.heightCtrl.add(720);
        player.streamImpl.positionCtrl.add(const Duration(seconds: 1));
        harness.videoOutput.add(true);
        await tester.pump();
        expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

        // Rapidly switch to Channel B (next source) while open() is still pending.
        player.delayNextOpen = true;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        // Stale Channel A emits width/height and video output while playlist still holds Channel A!
        player.streamImpl.widthCtrl.add(1920);
        player.streamImpl.heightCtrl.add(1080);
        harness.videoOutput.add(true);
        await tester.pump();

        // New Channel B MUST still show loading indicator!
        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        // Complete Channel B open + emit Channel B video track, dimensions, progress & real video output.
        player.openGate?.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(player.opened, hasLength(2));
        expect(player.opened.last.uri, 'http://live.example/b.m3u8');
        player.streamImpl.trackCtrl.add(
          Track(video: VideoTrack('1', 'H264', 'und', codec: 'h264')),
        );
        player.streamImpl.widthCtrl.add(1280);
        player.streamImpl.heightCtrl.add(720);
        player.streamImpl.positionCtrl.add(const Duration(milliseconds: 400));
        await tester.pump();
        // Still waiting for Channel B's actual video output!
        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        harness.videoOutput.add(true);
        await tester.pump();
        expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'audio-only radio stream (0x0 video) clears loading and plays cleanly when position advances',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final harness = await mountLive(tester);
        final player = harness.player;
        addTearDown(() async {
          await harness.videoOutput.close();
          await player.dispose();
        });

        expect(find.byKey(const Key('live-loading-indicator')), findsOneWidget);

        // Audio-only: no video track, only audio track + position progress.
        player.streamImpl.trackCtrl.add(
          Track(
            video: VideoTrack.no(),
            audio: AudioTrack('1', 'Radio AAC', 'zh', codec: 'aac'),
          ),
        );
        player.streamImpl.bufferingCtrl.add(false);
        player.streamImpl.positionCtrl.add(const Duration(milliseconds: 450));
        await tester.pump();

        expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

        // Advance past startup window (8s+) -> zero timeout errors or spurious retries.
        player.streamImpl.positionCtrl.add(const Duration(seconds: 4));
        await tester.pump(const Duration(seconds: 9));
        expect(find.textContaining('超时'), findsNothing);
        expect(player.opened, hasLength(1));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    testWidgets(
      'user pausing during live startup suspends timeout watchdog without spurious failure',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final harness = await mountLive(tester);
        final player = harness.player;
        addTearDown(() async {
          await harness.videoOutput.close();
          await player.dispose();
        });

        // User actively pauses before first frame arrives.
        await player.pause();
        await tester.pump();

        // Wait longer than the 7s live startup timeout -> MUST NOT fail or retry!
        await tester.pump(const Duration(seconds: 10));
        expect(find.textContaining('超时'), findsNothing);
        expect(find.textContaining('失败'), findsNothing);
        expect(player.opened, hasLength(1));

        // User resumes and stream delivers real video output -> clears loading cleanly.
        await player.play();
        await tester.pump();
        player.streamImpl.trackCtrl.add(
          Track(video: VideoTrack('1', 'H264', 'und', codec: 'h264')),
        );
        player.streamImpl.widthCtrl.add(1280);
        player.streamImpl.heightCtrl.add(720);
        player.streamImpl.positionCtrl.add(const Duration(milliseconds: 500));
        harness.videoOutput.add(true);
        await tester.pump();
        expect(find.byKey(const Key('live-loading-indicator')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );

    test(
      'real libmpv live playback observes native video output on H.264+AAC, switches across identical-resolution channels, and plays audio-only radio',
      () async {
        final mpvLib = Platform.environment['MARCOMOVIE_TEST_MPV'];
        if (mpvLib == null || mpvLib.isEmpty || !_hasFfmpegTool()) {
          return;
        }
        MediaKit.ensureInitialized(libmpv: mpvLib);

        final work = await Directory.systemTemp.createTemp('marco-live-mpv-');
        addTearDown(() async {
          if (work.existsSync()) {
            work.deleteSync(recursive: true);
          }
        });

        final ch1 = File('${work.path}/ch1.ts');
        final ch2 = File('${work.path}/ch2.ts');
        final radio = File('${work.path}/radio.m4a');

        for (final spec in [
          (ch1, '0x1565c0', 440),
          (ch2, '0x2e7d32', 660),
        ]) {
          final res = Process.runSync('ffmpeg', [
            '-y',
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'color=c=${spec.$2}:s=320x180:r=25:d=3',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=${spec.$3}:sample_rate=48000:duration=3',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '-g',
            '25',
            '-c:a',
            'aac',
            '-b:a',
            '64k',
            '-f',
            'mpegts',
            spec.$1.path,
          ]);
          expect(res.exitCode, 0, reason: '${res.stderr}');
        }
        final rRes = Process.runSync('ffmpeg', [
          '-y',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=523:sample_rate=48000:duration=3',
          '-vn',
          '-c:a',
          'aac',
          '-b:a',
          '64k',
          radio.path,
        ]);
        expect(rRes.exitCode, 0, reason: '${rRes.stderr}');

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async => server.close(force: true));
        server.listen((req) async {
          final f = switch (req.uri.path) {
            '/ch1.ts' => ch1,
            '/ch2.ts' => ch2,
            '/radio.m4a' => radio,
            _ => null,
          };
          if (f == null) {
            req.response.statusCode = 404;
            await req.response.close();
            return;
          }
          final bytes = await f.readAsBytes();
          req.response.statusCode = 200;
          req.response.contentLength = bytes.length;
          req.response.add(bytes);
          await req.response.close();
        });

        final player = Player(
          configuration: const PlayerConfiguration(
            vo: 'null',
            muted: true,
          ),
        );
        addTearDown(() async => player.dispose());
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await native.setProperty('vid', 'auto');

        var voConfigured = false;
        var vfFpsPositive = false;
        var pictureTypeSeen = false;
        final signalCtrl = StreamController<String>.broadcast();
        addTearDown(signalCtrl.close);

        await native.observeProperty('vo-configured', (val) async {
          voConfigured = val.trim().toLowerCase() == 'yes';
          if (voConfigured) signalCtrl.add('vo-configured=yes');
        });
        await native.observeProperty('estimated-vf-fps', (val) async {
          if ((double.tryParse(val.trim()) ?? 0) > 0.1) {
            vfFpsPositive = true;
            signalCtrl.add('vf-fps=$val');
          }
        });
        await native.observeProperty('video-frame-info/picture-type', (val) async {
          if (val.trim().isNotEmpty) {
            pictureTypeSeen = true;
            signalCtrl.add('pic=$val');
          }
        });

        // 1. Channel 1 (real H.264+AAC) emits real video output signal and advances.
        await player.open(Media('http://127.0.0.1:${server.port}/ch1.ts'));
        await player.stream.position
            .firstWhere((p) => p.inMilliseconds >= 300)
            .timeout(const Duration(seconds: 10));
        expect(
          voConfigured || vfFpsPositive || pictureTypeSeen,
          isTrue,
          reason: 'Real H.264+AAC stream must confirm native video output',
        );

        // 2. Switch to Channel 2 (identical 320x180 resolution) -> fresh video output observed.
        voConfigured = false;
        vfFpsPositive = false;
        pictureTypeSeen = false;
        final ch2Signal = signalCtrl.stream.first.timeout(const Duration(seconds: 10));
        await player.open(Media('http://127.0.0.1:${server.port}/ch2.ts'));
        await ch2Signal;
        await player.stream.position
            .firstWhere((p) => p.inMilliseconds >= 300)
            .timeout(const Duration(seconds: 10));
        expect(
          voConfigured || vfFpsPositive || pictureTypeSeen,
          isTrue,
          reason: 'Identical-resolution channel switch must re-confirm native video output',
        );

        // 3. Switch to Channel 3 (audio-only AAC radio) -> advances cleanly with no video track.
        await player.open(Media('http://127.0.0.1:${server.port}/radio.m4a'));
        await player.stream.position
            .firstWhere((p) => p.inMilliseconds >= 300)
            .timeout(const Duration(seconds: 10));
        expect(
          player.state.tracks.video.any((t) => t.id != 'auto' && t.id != 'no'),
          isFalse,
        );
        expect(player.state.track.video.id, anyOf('no', 'auto'));
        expect(player.state.track.audio.id, isNot('no'));
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  });
}

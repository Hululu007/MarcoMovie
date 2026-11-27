import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/playback_status_telemetry.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _DelayedResolveClient extends CmsClient {
  final Completer<CmsEpisode> resolveGate;
  _DelayedResolveClient(this.resolveGate);

  @override
  Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
  }) =>
      resolveGate.future;
}

class _PhaseFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = false;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = const Duration(minutes: 20);
  double volumeValue = 80;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();
  int? widthValue = 1920;
  int? heightValue = 1080;

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
  @override
  int? get width => widthValue;
  @override
  int? get height => heightValue;
}

class _PhaseFakeStream extends Fake implements PlayerStream {
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
  final volumeCtrl = StreamController<double>.broadcast();

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

class _PhaseFakePlayer extends Fake implements Player {
  final _state = _PhaseFakeState();
  final _stream = _PhaseFakeStream();
  final List<Duration> seeks = [];
  Media? lastOpened;

  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;
  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      lastOpened = playable;
      _state.playlistValue = Playlist([playable]);
    }
  }

  @override
  Future<void> setVolume(double volume) async => _state.volumeValue = volume;
  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> play() async {
    _state.playingValue = true;
    _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    _state.playingValue = false;
    _stream.playingCtrl.add(false);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
  }

  @override
  Future<void> dispose() => _stream.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Batch 2 Item 5 — Playback phase (正在解析/正在连接/正在缓冲) & real network speed', () {
    test('PlaybackStatusController tracks resolving -> connecting -> buffering -> idle, expires stale speed, and suppresses local-file speed', () {
      var nowMs = 1000;
      final ctrl = PlaybackStatusController(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      );

      // 1. Startup resolving (no fake speed)
      ctrl.beginResolving(isLocalFile: false);
      expect(ctrl.phase, PlaybackLoadPhase.resolving);
      expect(ctrl.snapshot.formatLabel(episodeName: '第1集'), '正在解析 第1集…');

      // 2. Startup connecting (still no bytes yet -> no fake speed)
      ctrl.beginConnecting(isLocalFile: false);
      expect(ctrl.phase, PlaybackLoadPhase.connecting);
      expect(ctrl.snapshot.formatLabel(episodeName: '第1集'), '正在连接 第1集…');

      // 3. Real media bytes arrive -> switches to buffering + real speed
      nowMs = 1500;
      ctrl.onNetworkBytesReceived(256 * 1024); // 256 KiB
      nowMs = 2000;
      ctrl.onNetworkBytesReceived(256 * 1024); // 512 KiB over 500ms -> ~1.00 MB/s
      expect(ctrl.phase, PlaybackLoadPhase.buffering);
      final bufLabel = ctrl.snapshot.formatLabel(episodeName: '第1集');
      expect(bufLabel, startsWith('正在缓冲 第1集… · '));
      expect(bufLabel, contains('MB/s'));

      // 4. Stale throughput expires cleanly after >2.5s of no traffic
      nowMs = 5000;
      expect(ctrl.snapshot.networkBytesPerSecond, isNull);
      expect(ctrl.snapshot.formatLabel(episodeName: '第1集'), '正在缓冲 第1集…');

      // 5. Recovery clears prompt immediately
      ctrl.onPlaybackRecovered();
      expect(ctrl.isVisible, isFalse);
      expect(ctrl.snapshot.formatLabel(episodeName: '第1集'), isEmpty);

      // 6. Seek on network stream -> buffering with mpv cache-speed, clears on recovery
      nowMs = 6000;
      ctrl.beginSeek(isLocalFile: false);
      ctrl.onMpvCacheSpeed(420 * 1024); // 420 KB/s
      expect(ctrl.phase, PlaybackLoadPhase.buffering);
      expect(ctrl.snapshot.formatLabel(episodeName: '第1集'), '正在缓冲… · 420 KB/s');
      ctrl.onPlaybackRecovered();
      expect(ctrl.isVisible, isFalse);

      // 7. Local file never displays fake network speed
      ctrl.beginConnecting(isLocalFile: true);
      ctrl.onNetworkBytesReceived(1024 * 1024);
      ctrl.onMpvCacheSpeed(5 * 1024 * 1024);
      expect(ctrl.snapshot.networkBytesPerSecond, isNull);
      expect(ctrl.snapshot.formatLabel(episodeName: '本地影片.mkv'), '正在连接 本地影片.mkv…');
    });

    test('Controlled HTTP source with delayed resolution and delayed/throttled media transfer yields accurate phases and real speed', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final resolveRelease = Completer<void>();
        final mediaFirstByteRelease = Completer<void>();
        final mediaChunkPayload = List<int>.filled(64 * 1024, 0x47); // 64 KiB

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final base = 'http://127.0.0.1:${server.port}';

        server.listen((HttpRequest req) async {
          if (req.uri.path == '/t4' && req.uri.queryParameters.containsKey('play')) {
            await resolveRelease.future;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'parse': 0,
              'url': '$base/media/throttled.ts',
            }));
            await req.response.close();
            return;
          }
          if (req.uri.path == '/media/throttled.ts') {
            await mediaFirstByteRelease.future;
            req.response.headers.contentType = ContentType('video', 'mp2t');
            for (var i = 0; i < 4; i++) {
              req.response.add(mediaChunkPayload);
              await req.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            await req.response.close();
            return;
          }
          req.response.statusCode = 404;
          await req.response.close();
        });

        final status = PlaybackStatusController();
        final client = CmsClient();
        final site = CmsSite(
          key: 'controlled_t4',
          name: '可控测试源',
          type: 4,
          api: '$base/t4',
        );
        final ep = CmsEpisode(
          name: '第1集',
          url: 'mmt4://play?flag=line1&id=ep1',
        );

        // Phase 1: Delayed resolution
        status.beginResolving(isLocalFile: false);
        final resolveFuture = client.resolveEpisodeForPlayback(site, ep);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(status.phase, PlaybackLoadPhase.resolving);
        expect(status.snapshot.networkBytesPerSecond, isNull);

        resolveRelease.complete();
        final resolved = await resolveFuture;
        expect(resolved.url, '$base/media/throttled.ts');

        // Phase 2: Connecting while server delays first media byte
        status.beginConnecting(isLocalFile: false);
        final httpClient = http.Client();
        addTearDown(httpClient.close);
        final reqFuture =
            httpClient.send(http.Request('GET', Uri.parse(resolved.url)));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(status.phase, PlaybackLoadPhase.connecting);
        expect(status.snapshot.networkBytesPerSecond, isNull);

        // Phase 3: Throttled media transfer arrives -> buffering + real throughput
        mediaFirstByteRelease.complete();
        final resp = await reqFuture;
        var totalBytes = 0;
        await for (final chunk in resp.stream) {
          totalBytes += chunk.length;
          status.onNetworkBytesReceived(chunk.length);
        }
        expect(totalBytes, 4 * 64 * 1024);
        expect(status.phase, PlaybackLoadPhase.buffering);
        final speed = status.snapshot.networkBytesPerSecond;
        expect(speed, isNotNull);
        expect(speed!, greaterThan(0));
        expect(
          status.snapshot.formatLabel(episodeName: '第1集'),
          matches(RegExp(r'^正在缓冲 第1集… · \d+(\.\d+)? (KB/s|MB/s)$')),
        );

        // Phase 4: Playback recovered -> prompt disappears
        status.onPlaybackRecovered();
        expect(status.isVisible, isFalse);
      }, _RealHttpOverrides());
    });

    testWidgets(
      'PlayerScreen UI distinguishes 正在解析 -> 正在连接 -> 正在缓冲+real speed on startup and seek, and hides promptly on recovery',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
        );
        final resolveGate = Completer<CmsEpisode>();
        final fakePlayer = _PhaseFakePlayer();
        final upstreamBytesCtrl = StreamController<int>.broadcast();
        final cacheSpeedCtrl = StreamController<double>.broadcast();
        addTearDown(() async {
          await upstreamBytesCtrl.close();
          await cacheSpeedCtrl.close();
        });

        await tester.binding.setSurfaceSize(const Size(1280, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const site = CmsSite(
          key: 'demo_phase',
          name: '可控测试源',
          type: 4,
          api: 'https://demo.example/t4',
        );
        const video = CmsVideo(
          id: 'v1',
          title: '测试影片',
          lines: [
            CmsLine(
              name: '线路1',
              episodes: [
                CmsEpisode(name: '第1集', url: 'mmt4://play?flag=l1&id=1'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugVideoSurface: const SizedBox.expand(),
              debugHudPrefs: PlayerHudPrefs(isDesktop: true),
              debugClient: _DelayedResolveClient(resolveGate),
              debugUpstreamBytesStream: upstreamBytesCtrl.stream,
              debugCacheSpeedStream: cacheSpeedCtrl.stream,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        // 1. Delayed resolution -> 正在解析 (no speed)
        expect(find.byKey(const Key('player-loading-indicator')), findsOneWidget);
        final resolvingText = tester.widget<Text>(
          find.byKey(const Key('player-loading-phase-text')),
        );
        expect(resolvingText.data, '正在解析 第1集…');

        // 2. Resolution completes -> 正在连接 (no bytes yet -> no speed)
        resolveGate.complete(const CmsEpisode(
          name: '第1集',
          url: 'http://127.0.0.1:9/delayed.mp4',
        ));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        final connectingText = tester.widget<Text>(
          find.byKey(const Key('player-loading-phase-text')),
        );
        expect(connectingText.data, '正在连接 第1集…');

        // 3. Real throughput arrives -> 正在缓冲 + real speed
        cacheSpeedCtrl.add(2.5 * 1024 * 1024); // 2.50 MB/s
        fakePlayer._state.bufferingValue = true;
        fakePlayer._stream.bufferingCtrl.add(true);
        await tester.pump(const Duration(milliseconds: 50));
        final bufferingText = tester.widget<Text>(
          find.byKey(const Key('player-loading-phase-text')),
        );
        expect(bufferingText.data, '正在缓冲 第1集… · 2.50 MB/s');

        // 4. Playback starts & position advances -> indicator disappears promptly!
        fakePlayer._state.durationValue = const Duration(minutes: 20);
        fakePlayer._stream.durationCtrl.add(const Duration(minutes: 20));
        fakePlayer._state.bufferingValue = false;
        fakePlayer._state.playingValue = true;
        fakePlayer._state.positionValue = const Duration(milliseconds: 600);
        fakePlayer._stream.bufferingCtrl.add(false);
        fakePlayer._stream.playingCtrl.add(true);
        fakePlayer._stream.positionCtrl.add(const Duration(milliseconds: 600));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.byKey(const Key('player-loading-indicator')), findsNothing);

        // 5. Seek via Right Arrow key -> re-shows 正在缓冲 + real speed, then hides on recovery!
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(fakePlayer.seeks, isNotEmpty);
        expect(find.byKey(const Key('player-loading-indicator')), findsOneWidget);
        final seekText = tester.widget<Text>(
          find.byKey(const Key('player-loading-phase-text')),
        );
        expect(seekText.data, startsWith('正在缓冲…'));

        // Recovery after seek -> disappears promptly!
        fakePlayer._state.positionValue = const Duration(seconds: 12);
        fakePlayer._stream.positionCtrl.add(const Duration(seconds: 12));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.byKey(const Key('player-loading-indicator')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

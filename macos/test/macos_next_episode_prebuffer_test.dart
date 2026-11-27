import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/next_episode_prebuffer.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';

class _RealHttpOverrides extends HttpOverrides {}

/// Routes `https://bench.example/...` requests to a real local `HttpServer`
/// so tests exercise production `LocalMediaLease.shouldProxy` + `DiskBlockCache`
/// end-to-end without relaxing loopback SSRF guards.
class _LoopbackRewriteClient extends http.BaseClient {
  _LoopbackRewriteClient(this.localPort) : _inner = IOClient(HttpClient());
  final int localPort;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final rewrittenUri = request.url.replace(
      scheme: 'http',
      host: '127.0.0.1',
      port: localPort,
    );
    final abortFuture =
        request is http.AbortableRequest ? request.abortTrigger : null;
    final forwarded = abortFuture != null
        ? http.AbortableRequest(
            request.method,
            rewrittenUri,
            abortTrigger: abortFuture,
          )
        : http.Request(request.method, rewrittenUri);
    forwarded.followRedirects = request.followRedirects;
    forwarded.headers.addAll(request.headers);
    return _inner.send(forwarded);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

class _ControlledResolveClient extends CmsClient {
  _ControlledResolveClient({
    required this.resolveDelay,
    required this.urlMapper,
  });

  final Duration resolveDelay;
  final String Function(CmsEpisode ep) urlMapper;
  int resolveCalls = 0;
  final List<String> resolvedNames = <String>[];

  @override
  Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
    void Function(String stage)? onStage,
  }) async {
    resolveCalls++;
    resolvedNames.add(episode.name);
    if (resolveDelay > Duration.zero) {
      await Future<void>.delayed(resolveDelay);
    }
    return CmsEpisode(
      name: episode.name,
      url: urlMapper(episode),
      headers: const {'User-Agent': 'MarcoMovieBench/1.0'},
    );
  }
}

class _FakePlayerStream extends Fake implements PlayerStream {
  final _posCtrl = StreamController<Duration>.broadcast();
  final _durCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _tracksCtrl = StreamController<Tracks>.broadcast();
  final _trackCtrl = StreamController<Track>.broadcast();
  final _widthCtrl = StreamController<int?>.broadcast();
  final _heightCtrl = StreamController<int?>.broadcast();
  final _rateCtrl = StreamController<double>.broadcast();
  final _volCtrl = StreamController<double>.broadcast();
  final _bufferCtrl = StreamController<Duration>.broadcast();
  final _subtitleCtrl = StreamController<List<String>>.broadcast();
  final _playlistCtrl = StreamController<Playlist>.broadcast();
  final _logCtrl = StreamController<PlayerLog>.broadcast();

  void emitPosition(Duration d) => _posCtrl.add(d);
  void emitDuration(Duration d) => _durCtrl.add(d);
  void emitPlaying(bool v) => _playingCtrl.add(v);
  void emitBuffering(bool v) => _bufferingCtrl.add(v);

  @override
  Stream<Duration> get position => _posCtrl.stream;
  @override
  Stream<Duration> get duration => _durCtrl.stream;
  @override
  Stream<bool> get playing => _playingCtrl.stream;
  @override
  Stream<bool> get buffering => _bufferingCtrl.stream;
  @override
  Stream<bool> get completed => _completedCtrl.stream;
  @override
  Stream<String> get error => _errorCtrl.stream;
  @override
  Stream<Tracks> get tracks => _tracksCtrl.stream;
  @override
  Stream<Track> get track => _trackCtrl.stream;
  @override
  Stream<int?> get width => _widthCtrl.stream;
  @override
  Stream<int?> get height => _heightCtrl.stream;
  @override
  Stream<double> get rate => _rateCtrl.stream;
  @override
  Stream<double> get volume => _volCtrl.stream;
  @override
  Stream<Duration> get buffer => _bufferCtrl.stream;
  @override
  Stream<List<String>> get subtitle => _subtitleCtrl.stream;
  @override
  Stream<Playlist> get playlist => _playlistCtrl.stream;
  @override
  Stream<PlayerLog> get log => _logCtrl.stream;

  Future<void> dispose() async {
    await Future.wait([
      _posCtrl.close(),
      _durCtrl.close(),
      _playingCtrl.close(),
      _bufferingCtrl.close(),
      _completedCtrl.close(),
      _errorCtrl.close(),
      _tracksCtrl.close(),
      _trackCtrl.close(),
      _widthCtrl.close(),
      _heightCtrl.close(),
      _rateCtrl.close(),
      _volCtrl.close(),
      _bufferCtrl.close(),
      _subtitleCtrl.close(),
      _playlistCtrl.close(),
      _logCtrl.close(),
    ]);
  }
}

class _FakePlayer extends Fake implements Player {
  _FakePlayer(this.fakeStream);
  final _FakePlayerStream fakeStream;
  final List<String> openedUrls = <String>[];

  @override
  PlayerStream get stream => fakeStream;
  @override
  PlayerState get state => const PlayerState();
  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedUrls.add(playable.uri);
    }
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> setVideoTrack(VideoTrack track) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testSite = CmsSite(
    key: 'bench_vod',
    name: '预缓冲测试站',
    api: 'https://bench.example/api.php/provide/vod',
    type: 1,
  );

  group('Batch 2 Item 7 — Optional next-episode prebuffering', () {
    test('opt-in settings default OFF and normalize trigger timing & cache cap', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init(
        fileStore: InMemoryStorageFileStore(),
        secureStore: InMemorySecureCredentialStore(),
      );

      expect(storage.nextEpisodePrebufferEnabled, isFalse);
      expect(storage.nextEpisodePrebufferTriggerSec, 45);
      expect(storage.nextEpisodePrebufferMaxMb, 8);
      expect(
        storage.nextEpisodePrebufferConfig,
        const NextEpisodePrebufferConfig(
          enabled: false,
          triggerRemainingSeconds: 45,
          maxPrebufferMb: 8,
        ),
      );

      await storage.setNextEpisodePrebufferEnabled(true);
      await storage.setNextEpisodePrebufferTriggerSec(60);
      await storage.setNextEpisodePrebufferMaxMb(16);
      expect(storage.nextEpisodePrebufferEnabled, isTrue);
      expect(storage.nextEpisodePrebufferTriggerSec, 60);
      expect(storage.nextEpisodePrebufferMaxMb, 16);

      // Invalid values safely normalize to defaults.
      await storage.setNextEpisodePrebufferTriggerSec(999);
      await storage.setNextEpisodePrebufferMaxMb(999);
      expect(storage.nextEpisodePrebufferTriggerSec, 45);
      expect(storage.nextEpisodePrebufferMaxMb, 8);
    });

    test(
      'ON vs OFF benchmark: prebuffer reduces next-episode startup time, enforces hard cap, and leaves current episode unaffected',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = _RealHttpOverrides();
        addTearDown(() => HttpOverrides.global = prevOverrides);

        // Build deterministic 2 MiB synthetic payloads for Ep1 and Ep2.
        const payloadBytes = 2 * 1024 * 1024;
        final ep1Data = Uint8List.fromList(
          List<int>.generate(payloadBytes, (i) => (i * 7 + 13) & 0xff),
        );
        final ep2Data = Uint8List.fromList(
          List<int>.generate(payloadBytes, (i) => (i * 11 + 29) & 0xff),
        );

        var ep2MediaRequests = 0;
        var ep2UpstreamBytesSent = 0;
        var ep1UpstreamBytesSent = 0;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          final isEp2 = req.uri.path == '/ep2.mp4';
          final data = isEp2 ? ep2Data : ep1Data;
          if (isEp2) {
            ep2MediaRequests++;
            // Simulate realistic CDN first-byte latency on Ep2.
            await Future<void>.delayed(const Duration(milliseconds: 140));
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
          var start = 0;
          var end = data.length - 1;
          var partial = false;
          if (rangeHeader != null) {
            final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
            if (match != null) {
              start = int.parse(match.group(1)!);
              final endGroup = match.group(2);
              end = (endGroup != null && endGroup.isNotEmpty)
                  ? math.min(int.parse(endGroup), data.length - 1)
                  : data.length - 1;
              partial = true;
            }
          }
          final slice = Uint8List.sublistView(data, start, end + 1);
          req.response.statusCode =
              partial ? HttpStatus.partialContent : HttpStatus.ok;
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
          req.response.headers.contentLength = slice.length;
          if (partial) {
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${data.length}',
            );
          }
          if (isEp2) {
            ep2UpstreamBytesSent += slice.length;
          } else {
            ep1UpstreamBytesSent += slice.length;
          }
          req.response.add(slice);
          await req.response.close();
        });

        const ep2Raw = CmsEpisode(name: '第2集', url: 'resolve://ep2');
        final ep1RemoteUri = Uri.parse('https://bench.example/ep1.mp4');
        final ep2RemoteUri = Uri.parse('https://bench.example/ep2.mp4');

        // ---- Scenario A: Prebuffer OFF ----
        final offCacheDir = await Directory.systemTemp.createTemp('mm_prebuf_off_');
        addTearDown(() => offCacheDir.delete(recursive: true));
        final offDiskCache = DiskBlockCache(
          directory: offCacheDir,
          maxBytes: 16 * 1024 * 1024,
        );
        final offResolveClient = _ControlledResolveClient(
          resolveDelay: const Duration(milliseconds: 220),
          urlMapper: (_) => ep2RemoteUri.toString(),
        );
        final offTransport = _LoopbackRewriteClient(server.port);
        addTearDown(offTransport.close);

        final offCtrl = NextEpisodePrebufferController(
          client: offResolveClient,
          diskCache: offDiskCache,
          prefetchHttpClient: offTransport,
          debugMaxPrebufferBytesOverride: 512 * 1024,
        );
        final offTask = offCtrl.maybeStart(
          config: const NextEpisodePrebufferConfig(enabled: false),
          site: testSite,
          videoId: 'vid_bench',
          lineIndex: 0,
          nextEpisodeIndex: 1,
          nextEpisode: ep2Raw,
          isLive: false,
          embedded: false,
          isBlurayIso: false,
          repeatMode: 'off',
          isPlaying: true,
          isLoading: false,
          isBuffering: false,
          positionMs: 110000,
          durationMs: 120000,
        );
        expect(offTask, isNull);
        expect(offCtrl.extraNetworkBytes, 0);
        expect(ep2MediaRequests, 0);

        // Measure cold next-episode startup (resolve + first 256 KiB head block via LocalMediaLease).
        final offWatch = Stopwatch()..start();
        final offResolved = await offResolveClient.resolveEpisodeForPlayback(
          testSite,
          ep2Raw,
        );
        final offLease = await LocalMediaLease.open(
          target: Uri.parse(offResolved.url),
          headers: offResolved.headers,
          isCancelled: () => false,
          client: offTransport,
          enableDiskCache: true,
          diskCache: offDiskCache,
        );
        addTearDown(offLease.close);
        final ioClient = HttpClient();
        addTearDown(() => ioClient.close(force: true));
        final offReq = await ioClient.getUrl(offLease.url);
        offReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-262143');
        final offResp = await offReq.close();
        final offFirstBlock = await offResp.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        offWatch.stop();
        expect(offFirstBlock.length, 262144);
        expect(offFirstBlock, ep2Data.sublist(0, 262144));
        final offStartupMs = offWatch.elapsedMilliseconds;

        // ---- Scenario B: Prebuffer ON (512 KiB hard cap) ----
        ep2MediaRequests = 0;
        ep2UpstreamBytesSent = 0;
        ep1UpstreamBytesSent = 0;
        final onCacheDir = await Directory.systemTemp.createTemp('mm_prebuf_on_');
        addTearDown(() => onCacheDir.delete(recursive: true));
        final onDiskCache = DiskBlockCache(
          directory: onCacheDir,
          maxBytes: 16 * 1024 * 1024,
        );
        final onResolveClient = _ControlledResolveClient(
          resolveDelay: const Duration(milliseconds: 220),
          urlMapper: (_) => ep2RemoteUri.toString(),
        );
        final onTransport = _LoopbackRewriteClient(server.port);
        addTearDown(onTransport.close);

        final onCtrl = NextEpisodePrebufferController(
          client: onResolveClient,
          diskCache: onDiskCache,
          prefetchHttpClient: onTransport,
          debugMaxPrebufferBytesOverride: 512 * 1024, // 2 blocks = 512 KiB hard cap
        );

        // Before trigger window (remaining 90s > 45s) -> must NOT start!
        expect(
          onCtrl.maybeStart(
            config: const NextEpisodePrebufferConfig(
              enabled: true,
              triggerRemainingSeconds: 45,
              maxPrebufferMb: 8,
            ),
            site: testSite,
            videoId: 'vid_bench',
            lineIndex: 0,
            nextEpisodeIndex: 1,
            nextEpisode: ep2Raw,
            isLive: false,
            embedded: false,
            isBlurayIso: false,
            repeatMode: 'off',
            isPlaying: true,
            isLoading: false,
            isBuffering: false,
            positionMs: 30000,
            durationMs: 120000,
          ),
          isNull,
        );
        // While current episode is buffering -> must NOT steal bandwidth!
        expect(
          onCtrl.maybeStart(
            config: const NextEpisodePrebufferConfig(
              enabled: true,
              triggerRemainingSeconds: 45,
              maxPrebufferMb: 8,
            ),
            site: testSite,
            videoId: 'vid_bench',
            lineIndex: 0,
            nextEpisodeIndex: 1,
            nextEpisode: ep2Raw,
            isLive: false,
            embedded: false,
            isBlurayIso: false,
            repeatMode: 'off',
            isPlaying: true,
            isLoading: false,
            isBuffering: true,
            positionMs: 100000,
            durationMs: 120000,
          ),
          isNull,
        );

        // Now stream current Ep1 concurrently while prebuffering Ep2!
        final ep1Lease = await LocalMediaLease.open(
          target: ep1RemoteUri,
          isCancelled: () => false,
          client: onTransport,
          enableDiskCache: true,
          diskCache: onDiskCache,
        );
        addTearDown(ep1Lease.close);

        final ep1StreamFuture = () async {
          final req = await ioClient.getUrl(ep1Lease.url);
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-524287');
          final resp = await req.close();
          return resp.fold<List<int>>(<int>[], (b, c) => b..addAll(c));
        }();

        final prebufferTask = onCtrl.maybeStart(
          config: const NextEpisodePrebufferConfig(
            enabled: true,
            triggerRemainingSeconds: 45,
            maxPrebufferMb: 8,
          ),
          site: testSite,
          videoId: 'vid_bench',
          lineIndex: 0,
          nextEpisodeIndex: 1,
          nextEpisode: ep2Raw,
          isLive: false,
          embedded: false,
          isBlurayIso: false,
          repeatMode: 'off',
          isPlaying: true,
          isLoading: false,
          isBuffering: false,
          positionMs: 100000,
          durationMs: 120000,
        );
        expect(prebufferTask, isNotNull);

        final ep1Bytes = await ep1StreamFuture;
        await prebufferTask;

        // Current episode completed with exact byte integrity and zero disruption.
        expect(ep1Bytes.length, 524288);
        expect(ep1Bytes, ep1Data.sublist(0, 524288));
        expect(ep1UpstreamBytesSent, greaterThanOrEqualTo(524288));

        // Prebuffer respected the 512 KiB hard cap strictly!
        expect(onCtrl.hasPrepared, isTrue);
        expect(onCtrl.extraNetworkBytes, 512 * 1024);
        expect(ep2UpstreamBytesSent, 512 * 1024);
        final mediaRequestsBeforeSwitch = ep2MediaRequests;

        // Now measure warm next-episode startup using adopted PreparedNextEpisode + warmed DiskBlockCache!
        final onWatch = Stopwatch()..start();
        final adopted = onCtrl.adoptPrepared(
          siteKey: testSite.key,
          videoId: 'vid_bench',
          lineIndex: 0,
          episodeIndex: 1,
          rawEpisodeUrl: ep2Raw.url,
        );
        expect(adopted, isNotNull);
        final onLease = await LocalMediaLease.open(
          target: Uri.parse(adopted!.resolvedEpisode.url),
          headers: adopted.resolvedEpisode.headers,
          isCancelled: () => false,
          client: onTransport,
          enableDiskCache: true,
          diskCache: onDiskCache,
        );
        addTearDown(onLease.close);
        final onReq = await ioClient.getUrl(onLease.url);
        onReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-262143');
        final onResp = await onReq.close();
        final onFirstBlock = await onResp.fold<List<int>>(
          <int>[],
          (buf, chunk) => buf..addAll(chunk),
        );
        onWatch.stop();

        expect(onFirstBlock.length, 262144);
        expect(onFirstBlock, ep2Data.sublist(0, 262144));
        // Zero new upstream requests were needed to serve the first 256 KiB of Ep2!
        expect(ep2MediaRequests, mediaRequestsBeforeSwitch);
        expect(onResolveClient.resolveCalls, 1);
        final onStartupMs = onWatch.elapsedMilliseconds;

        // Verify massive latency win (OFF >= 340ms vs ON < 100ms).
        // ignore: avoid_print
        print(
          'BENCHMARK_PREBUFFER: OFF_startup_ms=$offStartupMs, '
          'ON_startup_ms=$onStartupMs, '
          'speedup_ms=${offStartupMs - onStartupMs}, '
          'extra_bytes=${onCtrl.extraNetworkBytes}, '
          'cap_bytes=${512 * 1024}, '
          'ep1_integrity=PASS',
        );
        expect(offStartupMs, greaterThanOrEqualTo(300));
        expect(onStartupMs, lessThan(offStartupMs ~/ 3));
      },
    );

    test(
      'cancellation matrix immediately aborts in-flight tasks on exit, source switch, manual jump, live entry, and repeat-one',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = _RealHttpOverrides();
        addTearDown(() => HttpOverrides.global = prevOverrides);

        // Slow server that drips chunks slowly so cancellation interrupts mid-flight.
        var totalServerBytesWritten = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          const totalLen = 8 * 1024 * 1024;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-262143/$totalLen',
          );
          req.response.headers.contentLength = 262144;
          final chunk = Uint8List(16384);
          try {
            for (var sent = 0; sent < 262144; sent += chunk.length) {
              req.response.add(chunk);
              await req.response.flush();
              totalServerBytesWritten += chunk.length;
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
            await req.response.close();
          } catch (_) {
            // Client aborted cleanly.
          }
        });

        final cacheDir = await Directory.systemTemp.createTemp('mm_prebuf_cancel_');
        addTearDown(() => cacheDir.delete(recursive: true));
        final diskCache = DiskBlockCache(
          directory: cacheDir,
          maxBytes: 8 * 1024 * 1024,
        );
        final transport = _LoopbackRewriteClient(server.port);
        addTearDown(transport.close);

        final resolveClient = _ControlledResolveClient(
          resolveDelay: const Duration(milliseconds: 30),
          urlMapper: (ep) => 'https://bench.example/${ep.name}.mp4',
        );

        final reasons = [
          NextEpisodePrebufferCancelReason.exit,
          NextEpisodePrebufferCancelReason.sourceSwitch,
          NextEpisodePrebufferCancelReason.manualJump,
          NextEpisodePrebufferCancelReason.liveMode,
          NextEpisodePrebufferCancelReason.repeatOne,
        ];

        for (var i = 0; i < reasons.length; i++) {
          final reason = reasons[i];
          final ctrl = NextEpisodePrebufferController(
            client: resolveClient,
            diskCache: diskCache,
            prefetchHttpClient: transport,
            debugMaxPrebufferBytesOverride: 2 * 1024 * 1024,
          );
          final task = ctrl.maybeStart(
            config: const NextEpisodePrebufferConfig(
              enabled: true,
              triggerRemainingSeconds: 45,
              maxPrebufferMb: 8,
            ),
            site: testSite,
            videoId: 'vid_cancel_$i',
            lineIndex: 0,
            nextEpisodeIndex: 1,
            nextEpisode: CmsEpisode(name: 'ep_$i', url: 'resolve://ep_$i'),
            isLive: false,
            embedded: false,
            isBlurayIso: false,
            repeatMode: 'off',
            isPlaying: true,
            isLoading: false,
            isBuffering: false,
            positionMs: 100000,
            durationMs: 120000,
          );
          expect(task, isNotNull);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await ctrl.cancelAll(reason);
          await task;

          expect(ctrl.lastCancelReason, reason);
          expect(ctrl.cancelCount, 1);
          expect(ctrl.isRunning, isFalse);
          expect(ctrl.hasPrepared, isFalse);
          expect(
            ctrl.extraNetworkBytes,
            lessThan(256 * 1024),
            reason: 'Cancelled prebuffer ($reason) must not keep downloading full blocks',
          );
        }
        expect(totalServerBytesWritten, greaterThan(0));
      },
    );

    testWidgets(
      'PlayerScreen triggers prebuffer near end, adopts prepared episode without re-resolving, and cancels on dispose',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          StorageService.keyNextEpisodePrebufferEnabled: true,
          StorageService.keyNextEpisodePrebufferTriggerSec: 45,
          StorageService.keyNextEpisodePrebufferMaxMb: 8,
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final hudPrefs = PlayerHudPrefs(isDesktop: true);

        final fakeStream = _FakePlayerStream();
        final fakePlayer = _FakePlayer(fakeStream);
        addTearDown(fakeStream.dispose);

        final resolveClient = _ControlledResolveClient(
          resolveDelay: const Duration(milliseconds: 10),
          urlMapper: (ep) => 'http://127.0.0.1:9/resolved_${ep.name}.mp4',
        );
        final prebufferCtrl = NextEpisodePrebufferController(
          client: resolveClient,
          diskCache: DiskBlockCache(maxBytes: 0), // Resolve-only in FakeAsync widget test
        );

        const video = CmsVideo(
          id: 'vid_widget_prebuf',
          title: '剧集预缓冲测试',
          lines: [
            CmsLine(
              name: '高速线路',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://bench.example/raw_ep1.mp4'),
                CmsEpisode(name: '第2集', url: 'https://bench.example/raw_ep2.mp4'),
                CmsEpisode(name: '第3集', url: 'https://bench.example/raw_ep3.mp4'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: testSite,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugVideoSurface: const SizedBox.expand(),
              debugHudPrefs: hudPrefs,
              debugClient: resolveClient,
              debugPrebufferController: prebufferCtrl,
            ),
          ),
        );

        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(resolveClient.resolveCalls, 1);

        // Simulate Ep1 smooth playback entering final 30s (within 45s trigger).
        fakeStream.emitDuration(const Duration(seconds: 120));
        fakeStream.emitPlaying(true);
        fakeStream.emitBuffering(false);
        fakeStream.emitPosition(const Duration(seconds: 90));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        // Ep2 should now be pre-resolved and prepared!
        expect(resolveClient.resolveCalls, 2);
        expect(resolveClient.resolvedNames, ['第1集', '第2集']);
        expect(prebufferCtrl.hasPrepared, isTrue);

        // Auto-next to Ep2 adopts the prepared episode with ZERO extra resolve calls!
        fakeStream._completedCtrl.add(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(prebufferCtrl.hitCount, 1);
        expect(resolveClient.resolveCalls, 2);

        // Now Ep2 approaches its end -> Ep3 is pre-resolved, then disposing cancels cleanly!
        fakeStream.emitDuration(const Duration(seconds: 120));
        fakeStream.emitPlaying(true);
        fakeStream.emitBuffering(false);
        fakeStream.emitPosition(const Duration(seconds: 90));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(resolveClient.resolveCalls, 3);
        expect(prebufferCtrl.hasPrepared, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(prebufferCtrl.hasPrepared, isFalse);
        expect(prebufferCtrl.lastCancelReason, NextEpisodePrebufferCancelReason.exit);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });
}

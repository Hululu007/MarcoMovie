import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'test_storage_helper.dart';

class _DirectLoopbackHttpOverrides extends HttpOverrides {}

class _IsolatedDownloadPaths extends PathProviderPlatform {
  final Directory root;
  _IsolatedDownloadPaths(this.root);

  @override
  Future<String?> getDownloadsPath() async => '${root.path}/downloads';
  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

bool _hasTool(String name) {
  try {
    final res = Process.runSync(name, ['-version']);
    return res.exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  final service = DownloadService.instance;
  final hasFfmpeg = _hasTool('ffmpeg') && _hasTool('ffprobe');

  Future<void> waitSettled(DownloadTask task) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (task.isActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (task.isActive) {
      throw StateError('Download did not settle: ${task.id} (${task.status})');
    }
  }

  test(
    'HLS master with separate AUDIO group downloads both H.264 video and AAC audio, survives server shutdown and app restart, and verifies with ffprobe (+ libmpv when available)',
    () async {
      final fixtureRoot =
          await Directory.systemTemp.createTemp('marco-hls-audio-test-');
      addTearDown(() async {
        for (final t in service.tasks) {
          await service.remove(t.id);
        }
        if (await fixtureRoot.exists()) {
          await fixtureRoot.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _IsolatedDownloadPaths(fixtureRoot);

      final mediaDir = Directory('${fixtureRoot.path}/origin_media')
        ..createSync(recursive: true);

      if (hasFfmpeg) {
        final vGen = Process.runSync('ffmpeg', [
          '-y',
          '-f',
          'lavfi',
          '-i',
          'testsrc=duration=3:size=320x180:rate=25',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          '-g',
          '25',
          '-hls_time',
          '1',
          '-hls_list_size',
          '0',
          '-hls_segment_filename',
          '${mediaDir.path}/v_%03d.ts',
          '${mediaDir.path}/video.m3u8',
        ]);
        expect(vGen.exitCode, 0, reason: '${vGen.stderr}');

        final aGen = Process.runSync('ffmpeg', [
          '-y',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=3',
          '-c:a',
          'aac',
          '-b:a',
          '96k',
          '-hls_time',
          '1',
          '-hls_list_size',
          '0',
          '-hls_segment_filename',
          '${mediaDir.path}/a_%03d.ts',
          '${mediaDir.path}/audio.m3u8',
        ]);
        expect(aGen.exitCode, 0, reason: '${aGen.stderr}');
      } else {
        // Fallback synthetic MPEG-TS packets if ffmpeg is unavailable in CI.
        final tsPacket = List<int>.filled(376, 0);
        tsPacket[0] = 0x47;
        tsPacket[188] = 0x47;
        File('${mediaDir.path}/v_000.ts').writeAsBytesSync(tsPacket);
        File('${mediaDir.path}/v_001.ts').writeAsBytesSync(tsPacket);
        File('${mediaDir.path}/a_000.ts').writeAsBytesSync(tsPacket);
        File('${mediaDir.path}/a_001.ts').writeAsBytesSync(tsPacket);
        File('${mediaDir.path}/video.m3u8').writeAsStringSync(
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n'
          '#EXTINF:1.0,\nv_000.ts\n#EXTINF:1.0,\nv_001.ts\n#EXT-X-ENDLIST\n',
        );
        File('${mediaDir.path}/audio.m3u8').writeAsStringSync(
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n'
          '#EXTINF:1.0,\na_000.ts\n#EXTINF:1.0,\na_001.ts\n#EXT-X-ENDLIST\n',
        );
      }

      File('${mediaDir.path}/master.m3u8').writeAsStringSync(
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud-aac",NAME="国语配音",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1200000,AUDIO="aud-aac"\n'
        'video.m3u8\n',
      );

      final requestedPaths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestedPaths.add(req.uri.path);
        final rel = req.uri.path.replaceFirst(RegExp(r'^/+'), '');
        final f = File('${mediaDir.path}/$rel');
        if (!f.existsSync()) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final bytes = await f.readAsBytes();
        req.response.statusCode = 200;
        req.response.contentLength = bytes.length;
        if (rel.endsWith('.m3u8')) {
          req.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
        } else {
          req.response.headers.contentType = ContentType('video', 'mp2t');
        }
        req.response.add(bytes);
        await req.response.close();
      });

      final client = CmsClient();
      await service.reloadFromDiskForTest(client);
      final site = CmsSite(
        key: 'hls-sep-site',
        name: 'HLS Sample',
        type: 1,
        api: 'http://127.0.0.1:${server.port}/cms',
      );
      final line = CmsLine(
        name: '主线',
        episodes: [
          CmsEpisode(
            name: '第1集',
            url: 'http://127.0.0.1:${server.port}/master.m3u8',
          ),
        ],
      );
      service.enqueue(
        site: site,
        video: const CmsVideo(id: 'sep-1', title: '分离音轨样片'),
        line: line,
        episodeIndexes: [0],
      );
      final task = service.taskFor(site.key, 'sep-1', line.name, 0)!;
      await waitSettled(task);

      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(task.filePath.endsWith('.m3u8'), isTrue);
      expect(task.totalBytes, greaterThan(500));
      expect(requestedPaths, contains('/master.m3u8'));
      expect(requestedPaths, contains('/video.m3u8'));
      expect(requestedPaths, contains('/audio.m3u8'));
      expect(requestedPaths.any((p) => p.startsWith('/v_')), isTrue);
      expect(requestedPaths.any((p) => p.startsWith('/a_')), isTrue);

      // Shut down the origin HTTP server completely, then simulate app restart.
      await server.close(force: true);
      await service.reloadFromDiskForTest(client);

      final restored = service.taskFor(site.key, 'sep-1', line.name, 0);
      expect(restored, isNotNull);
      expect(restored!.status, DownloadStatus.completed);
      expect(File(restored.filePath).existsSync(), isTrue);

      // Local offline .m3u8 must route to libmpv on iOS (AVPlayer cannot open file:// .m3u8).
      final avPrecheck =
          IosAvPlayerController.checkUrlCompatibility(restored.filePath);
      expect(avPrecheck.supported, isFalse);

      if (hasFfmpeg) {
        final probe = Process.runSync('ffprobe', [
          '-v',
          'error',
          '-show_entries',
          'stream=index,codec_type,codec_name',
          '-of',
          'json',
          restored.filePath,
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final decoded = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
        final streams = (decoded['streams'] as List).cast<Map<String, dynamic>>();
        expect(
          streams.any(
            (s) => s['codec_type'] == 'video' && s['codec_name'] == 'h264',
          ),
          isTrue,
          reason: 'Expected h264 video stream in $streams',
        );
        expect(
          streams.any(
            (s) => s['codec_type'] == 'audio' && s['codec_name'] == 'aac',
          ),
          isTrue,
          reason: 'Expected aac audio stream in $streams',
        );

        // Verify OfflineHlsLease serves the saved bundle strictly from its task directory
        // and blocks directory traversal.
        expect(OfflineHlsLease.isLocalM3u8(restored.filePath), isTrue);
        final offlineLease = await OfflineHlsLease.open(restored.filePath);
        addTearDown(offlineLease.close);

        final badStatus = await HttpOverrides.runWithHttpOverrides(() async {
          final hc = HttpClient();
          try {
            final badProbe = await hc.getUrl(
              offlineLease.url.replace(
                path: '${offlineLease.url.path.replaceFirst('master.m3u8', '')}..%2F..%2Fetc%2Fpasswd',
              ),
            );
            final badResp = await badProbe.close();
            await badResp.drain<void>();
            return badResp.statusCode;
          } finally {
            hc.close(force: true);
          }
        }, _DirectLoopbackHttpOverrides());
        expect(badStatus, HttpStatus.notFound);

        final mpvLib = Platform.environment['MARCOMOVIE_TEST_MPV'];
        if (mpvLib != null && mpvLib.isNotEmpty) {
          MediaKit.ensureInitialized(libmpv: mpvLib);
          final player = Player(
            configuration: const PlayerConfiguration(
              vo: 'null',
              muted: true,
              logLevel: MPVLogLevel.info,
            ),
          );
          final mpvLogs = <String>[];
          final logSub = player.stream.log.listen(
            (e) => mpvLogs.add('${e.level}/${e.prefix}: ${e.text}'),
          );
          final errSub = player.stream.error.listen(
            (e) => mpvLogs.add('ERR: $e'),
          );
          try {
            final dyn = player.platform as dynamic;
            await dyn.setProperty('ao', 'null');
            await dyn.setProperty(
              'demuxer-lavf-o',
              'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
                  'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto]',
            );
            final progressed = player.stream.position
                .firstWhere((p) => p.inMilliseconds >= 500)
                .timeout(
                  const Duration(seconds: 15),
                  onTimeout: () => throw TimeoutException(
                    'mpv did not advance on ${offlineLease.url}\n${mpvLogs.join('\n')}',
                  ),
                );
            await player.open(Media(offlineLease.url.toString()));
            await progressed;
            expect(
              player.state.tracks.audio
                  .any((t) => t.id != 'auto' && t.id != 'no'),
              isTrue,
              reason: 'Expected audio track in mpv: ${mpvLogs.join('\n')}',
            );
            expect(
              player.state.tracks.video
                  .any((t) => t.id != 'auto' && t.id != 'no'),
              isTrue,
              reason: 'Expected video track in mpv: ${mpvLogs.join('\n')}',
            );
            final seeked = player.stream.position
                .firstWhere((p) => p.inMilliseconds >= 1500)
                .timeout(const Duration(seconds: 10));
            await player.seek(const Duration(milliseconds: 1600));
            await seeked;
          } finally {
            await logSub.cancel();
            await errSub.cancel();
            await player.dispose();
          }
        }
      }
    },
  );

  test(
    'broken/missing/unsupported separate audio fails clearly; normal muxed HLS, pause/resume, retry, and existing downloads regress cleanly',
    () async {
      final fixtureRoot =
          await Directory.systemTemp.createTemp('marco-hls-regression-test-');
      addTearDown(() async {
        for (final t in service.tasks) {
          await service.remove(t.id);
        }
        if (await fixtureRoot.exists()) {
          await fixtureRoot.delete(recursive: true);
        }
      });
      PathProviderPlatform.instance = _IsolatedDownloadPaths(fixtureRoot);

      var failAudioOnce = true;
      final segHits = <String, int>{};
      final tsChunk = List<int>.filled(376, 0x11)
        ..[0] = 0x47
        ..[188] = 0x47;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final p = req.uri.path;
        segHits[p] = (segHits[p] ?? 0) + 1;
        if (p == '/missing_group.m3u8') {
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="ghost"\n'
            'v.m3u8\n',
          );
        } else if (p == '/missing_audio_404.m3u8') {
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",NAME="Main",DEFAULT=YES,URI="nope.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="a1"\n'
            'v.m3u8\n',
          );
        } else if (p == '/drm_audio_master.m3u8') {
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",NAME="Main",DEFAULT=YES,URI="drm_audio.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="a1"\n'
            'v.m3u8\n',
          );
        } else if (p == '/drm_audio.m3u8') {
          req.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"\n#EXTINF:1.0,\na0.ts\n#EXT-X-ENDLIST\n',
          );
        } else if (p == '/retry_master.m3u8') {
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",NAME="Main",DEFAULT=YES,URI="retry_audio.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="a1"\n'
            'v.m3u8\n',
          );
        } else if (p == '/retry_audio.m3u8') {
          if (failAudioOnce) {
            failAudioOnce = false;
            req.response.statusCode = 500;
            await req.response.close();
            return;
          }
          req.response.write('#EXTM3U\n#EXTINF:1.0,\na0.ts\n#EXT-X-ENDLIST\n');
        } else if (p == '/muxed.m3u8') {
          req.response.write('#EXTM3U\n#EXTINF:1.0,\nv0.ts\n#EXT-X-ENDLIST\n');
        } else if (p == '/v.m3u8') {
          req.response.write('#EXTM3U\n#EXTINF:1.0,\nv0.ts\n#EXT-X-ENDLIST\n');
        } else if (p == '/v0.ts' || p == '/a0.ts') {
          req.response.add(tsChunk);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final client = CmsClient();
      await service.reloadFromDiskForTest(client);
      final site = CmsSite(
        key: 'hls-reg',
        name: 'HLS Reg',
        type: 1,
        api: 'http://127.0.0.1:${server.port}/cms',
      );
      DownloadTask runOne(String id, String path) {
        final line = CmsLine(
          name: 'L',
          episodes: [
            CmsEpisode(
              name: id,
              url: 'http://127.0.0.1:${server.port}/$path',
            ),
          ],
        );
        service.enqueue(
          site: site,
          video: CmsVideo(id: id, title: id),
          line: line,
          episodeIndexes: [0],
        );
        return service.taskFor(site.key, id, 'L', 0)!;
      }

      // 1. Dangling AUDIO group fails with reason.
      final tMissing = runOne('missing-group', 'missing_group.m3u8');
      await waitSettled(tMissing);
      expect(tMissing.status, DownloadStatus.failed);
      expect(tMissing.error, contains('独立音轨组'));

      // 2. 404 audio playlist fails with reason (never video-only completed).
      final t404 = runOne('audio-404', 'missing_audio_404.m3u8');
      await waitSettled(t404);
      expect(t404.status, DownloadStatus.failed);
      expect(t404.error, contains('独立音轨'));

      // 3. SAMPLE-AES audio fails with clear reason.
      final tDrm = runOne('audio-drm', 'drm_audio_master.m3u8');
      await waitSettled(tDrm);
      expect(tDrm.status, DownloadStatus.failed);
      expect(tDrm.error, contains('专有加密'));

      // 4. Normal muxed HLS still produces single .ts file cleanly.
      final tMuxed = runOne('muxed', 'muxed.m3u8');
      await waitSettled(tMuxed);
      expect(tMuxed.status, DownloadStatus.completed);
      expect(tMuxed.filePath.endsWith('.ts'), isTrue);

      // 5. Transient audio failure + retry succeeds cleanly.
      final tRetry = runOne('retry', 'retry_master.m3u8');
      await waitSettled(tRetry);
      expect(tRetry.status, DownloadStatus.completed, reason: tRetry.error);

      // 6. Pause & remove / cancel leaves no orphaned task.
      final tCancel = runOne('cancel', 'muxed.m3u8');
      service.pause(tCancel.id);
      await waitSettled(tCancel);
      await service.remove(tCancel.id);
      expect(service.taskFor(site.key, 'cancel', 'L', 0), isNull);

      // 7. Existing completed muxed .ts download survives restart.
      await service.reloadFromDiskForTest(client);
      expect(
        service.taskFor(site.key, 'muxed', 'L', 0)?.status,
        DownloadStatus.completed,
      );
    },
  );

  testWidgets(
    'PlayerScreen opens downloaded offline .m3u8 bundle via OfflineHlsLease and tears down cleanly',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('marco-offline-player-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final hlsDir = Directory('${root.path}${Platform.pathSeparator}hls')
        ..createSync(recursive: true);
      final masterFile = File('${root.path}${Platform.pathSeparator}ep1.m3u8')
        ..writeAsStringSync(
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",NAME="Main",DEFAULT=YES,AUTOSELECT=YES,URI="hls/audio.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="a1"\n'
          'hls/video.m3u8\n',
        );
      File('${hlsDir.path}${Platform.pathSeparator}video.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXTINF:2.0,\nv0.ts\n#EXT-X-ENDLIST\n');
      File('${hlsDir.path}${Platform.pathSeparator}audio.m3u8')
          .writeAsStringSync('#EXTM3U\n#EXTINF:2.0,\na0.ts\n#EXT-X-ENDLIST\n');
      File('${hlsDir.path}${Platform.pathSeparator}v0.ts')
          .writeAsBytesSync(List<int>.filled(188, 0x47));
      File('${hlsDir.path}${Platform.pathSeparator}a0.ts')
          .writeAsBytesSync(List<int>.filled(188, 0x47));

      final storage = await initTestStorage();
      final player = _OfflineLeaseCapturePlayer();
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            site: const CmsSite(
              key: 'offline',
              name: '离线片库',
              type: 1,
              api: '',
            ),
            video: CmsVideo(
              id: 'offline-1',
              title: '离线双轨测试',
              lines: [
                CmsLine(
                  name: '已下载',
                  episodes: [
                    CmsEpisode(name: '第1集', url: masterFile.path),
                  ],
                ),
              ],
            ),
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
            debugVideoSurface: const ColoredBox(color: Colors.black),
          ),
        ),
      );

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump();
      await tester.pump();

      expect(player.openedUris, hasLength(1));
      final openedUri = Uri.parse(player.openedUris.single);
      expect(openedUri.host, '127.0.0.1');
      expect(openedUri.path, startsWith('/offline/'));
      expect(openedUri.path, endsWith('/master.m3u8'));

      // Unmount PlayerScreen -> OfflineHlsLease must close cleanly.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 650));
    },
  );
}

class _OfflineLeaseCaptureState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => false;
  @override
  bool get completed => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  double get volume => 100.0;
  @override
  double get rate => 1.0;
  @override
  bool get buffering => false;
  @override
  Tracks get tracks => const Tracks();
  @override
  Track get track => const Track();
}

class _OfflineLeaseCaptureStream extends Fake implements PlayerStream {
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

class _OfflineLeaseCapturePlayer extends Fake implements Player {
  final _OfflineLeaseCaptureState stateImpl = _OfflineLeaseCaptureState();
  final _OfflineLeaseCaptureStream streamImpl = _OfflineLeaseCaptureStream();
  final List<String> openedUris = <String>[];
  bool _disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => stateImpl;
  @override
  PlayerStream get stream => streamImpl;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedUris.add(playable.uri);
      stateImpl.playlistValue = Playlist([playable]);
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

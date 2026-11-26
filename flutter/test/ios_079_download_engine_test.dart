import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/models.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _EnginePaths extends PathProviderPlatform {
  final Directory root;
  _EnginePaths(this.root);
  @override
  Future<String?> getDownloadsPath() async => '${root.path}/downloads';
  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

/// MPEG-TS-like payload: 188-byte packets starting with the 0x47 sync byte.
Uint8List _tsPayload(int seed, int packets) {
  final out = Uint8List(packets * 188);
  for (var p = 0; p < packets; p++) {
    final base = p * 188;
    out[base] = 0x47;
    for (var i = 1; i < 188; i++) {
      out[base + i] = (seed * 131 + p * 17 + i * 7) & 0xFF;
    }
  }
  return out;
}

class _HlsFixture {
  final int segments;
  final int latencyMs;
  final List<Uint8List> plain;
  final List<Uint8List> wire;
  final bool encrypted;
  _HlsFixture({
    required this.segments,
    required this.latencyMs,
    required this.plain,
    required this.wire,
    this.encrypted = false,
  });
  Uint8List segmentPlain(int i) => plain[i % plain.length];
  Uint8List segmentWire(int i) => wire[i % wire.length];
}

Uint8List _bigFile(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + (i >> 9) + (i >> 17)) & 0xFF;
  }
  return out;
}

void main() {
  final service = DownloadService.instance;
  late Directory fixtureRoot;
  late HttpServer server;
  late CmsClient client;
  final fixtures = <String, _HlsFixture>{};
  final aesKey = Uint8List.fromList(List<int>.generate(16, (i) => 0x30 + i));
  final aesIv = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
  late Uint8List big;
  final bigRanges = <String>[];
  var bigConnections = 0;
  var maxConcurrentSegmentRequests = 0;
  var concurrentSegmentRequests = 0;
  final segmentHits = <String, Map<int, int>>{};
  var ignoreRangeOnFake = false;
  final timings = <String, int>{};

  String media(String path) => 'http://127.0.0.1:${server.port}/$path';
  const site = CmsSite(
    key: 'engine-src',
    name: 'engine',
    type: 1,
    api: 'http://127.0.0.1:1/cms',
  );

  DownloadTask enqueue(String videoId, String path) {
    final line = CmsLine(
      name: 'line',
      episodes: [CmsEpisode(name: 'ep1', url: media(path))],
    );
    service.enqueue(
      site: site,
      video: CmsVideo(id: videoId, title: videoId),
      line: line,
      episodeIndexes: [0],
    );
    return service.taskFor(site.key, videoId, 'line', 0)!;
  }

  Future<void> settled(DownloadTask task, {int seconds = 90}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (task.isActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (task.isActive) throw StateError('Download did not settle: ${task.id}');
  }

  Future<void> serveBig(HttpRequest request) async {
    bigConnections++;
    final res = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = big.length - 1;
    if (range != null && !ignoreRangeOnFake) {
      bigRanges.add(range);
      final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      if (m == null) {
        res.statusCode = 416;
        await res.close();
        return;
      }
      start = int.parse(m[1]!);
      if (m[2]!.isNotEmpty) end = int.parse(m[2]!);
      if (end >= big.length) end = big.length - 1;
      if (start > end) {
        res.statusCode = 416;
        res.headers.set('Content-Range', 'bytes */${big.length}');
        await res.close();
        return;
      }
      res.statusCode = 206;
      res.headers.set('Content-Range', 'bytes $start-$end/${big.length}');
    }
    res.headers.contentType = ContentType('video', 'mp4');
    res.headers.set('Accept-Ranges', 'bytes');
    res.contentLength = end - start + 1;
    // Per-connection throttle, like CDNs that cap each TCP stream.
    const chunk = 128 * 1024;
    try {
      for (var off = start; off <= end; off += chunk) {
        final stop = (off + chunk - 1 < end) ? off + chunk - 1 : end;
        res.add(Uint8List.sublistView(big, off, stop + 1));
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await res.close();
    } catch (_) {
      // Client cancelled (pause / range worker finished).
    }
  }

  setUpAll(() async {
    fixtureRoot = await Directory.systemTemp.createTemp('marco-dl-engine-');
    PathProviderPlatform.instance = _EnginePaths(fixtureRoot);
    big = _bigFile(24 * 1024 * 1024);

    // 1) Latency-bound HLS: 60 x 32 KB segments, 80 ms first-byte latency.
    final plain60 = [for (var i = 0; i < 60; i++) _tsPayload(i, 170)];
    fixtures['latency'] = _HlsFixture(
      segments: 60,
      latencyMs: 80,
      plain: plain60,
      wire: plain60,
    );
    // 2) Many tiny segments with long tokenised URLs (manifest pressure).
    final plainMany = [for (var i = 0; i < 16; i++) _tsPayload(i + 100, 40)];
    fixtures['many'] = _HlsFixture(
      segments: 900,
      latencyMs: 0,
      plain: plainMany,
      wire: plainMany,
    );
    // 3) AES-128 HLS: 36 x ~512 KB encrypted segments (CPU-bound decrypt).
    final plainAes = [for (var i = 0; i < 4; i++) _tsPayload(i + 200, 2790)];
    fixtures['aes'] = _HlsFixture(
      segments: 36,
      latencyMs: 5,
      plain: plainAes,
      wire: [
        for (final p in plainAes) CmsParser.aes128CbcEncrypt(p, aesKey, aesIv),
      ],
      encrypted: true,
    );

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final res = request.response;
      if (path == '/big.mp4') {
        await serveBig(request);
        return;
      }
      final m = RegExp(r'^/hls/(\w+)/(index\.m3u8|key\.bin|seg(\d+)\.ts)$')
          .firstMatch(path);
      if (m == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final fx = fixtures[m[1]!]!;
      if (m[2] == 'index.m3u8') {
        final ivHex =
            aesIv.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        final b = StringBuffer()
          ..writeln('#EXTM3U')
          ..writeln('#EXT-X-VERSION:3')
          ..writeln('#EXT-X-TARGETDURATION:4')
          ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
        if (fx.encrypted) {
          b.writeln('#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x$ivHex');
        }
        final token = List.filled(96, 'a').join();
        for (var i = 0; i < fx.segments; i++) {
          b
            ..writeln('#EXTINF:4.0,')
            ..writeln('seg$i.ts?auth_key=$token-$i&expires=1999999999');
        }
        b.writeln('#EXT-X-ENDLIST');
        res.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        res.write(b.toString());
        await res.close();
        return;
      }
      if (m[2] == 'key.bin') {
        res.add(aesKey);
        await res.close();
        return;
      }
      final idx = int.parse(m[3]!);
      final hitMap = segmentHits.putIfAbsent(m[1]!, () => <int, int>{});
      hitMap[idx] = (hitMap[idx] ?? 0) + 1;
      concurrentSegmentRequests++;
      if (concurrentSegmentRequests > maxConcurrentSegmentRequests) {
        maxConcurrentSegmentRequests = concurrentSegmentRequests;
      }
      try {
        // Later segments answer faster so completion order != playlist order.
        final jitter = fx.latencyMs == 0 ? 0 : (idx % 3) * 7;
        if (fx.latencyMs > 0) {
          await Future<void>.delayed(
            Duration(milliseconds: fx.latencyMs + jitter),
          );
        }
        final body = fx.segmentWire(idx);
        res.headers.contentType = ContentType('video', 'mp2t');
        res.contentLength = body.length;
        res.add(body);
        await res.close();
      } finally {
        concurrentSegmentRequests--;
      }
    });
    client = CmsClient();
    await service.init(client);
    expect(service.isReady, isTrue);
  });

  tearDownAll(() async {
    // ignore: avoid_print
    print('IOS079_DOWNLOAD_TIMINGS ${jsonEncode(timings)}');
    for (final task in service.tasks) {
      await service.remove(task.id);
    }
    await server.close(force: true);
  });

  Future<void> runHls(String name) async {
    final fx = fixtures[name]!;
    maxConcurrentSegmentRequests = 0;
    final sw = Stopwatch()..start();
    final task = enqueue('hls-$name', 'hls/$name/index.m3u8');
    await settled(task);
    sw.stop();
    timings['hls_$name'] = sw.elapsedMilliseconds;
    timings['hls_${name}_max_parallel'] = maxConcurrentSegmentRequests;
    expect(task.status, DownloadStatus.completed, reason: task.error);
    final bytes = await File(task.filePath).readAsBytes();
    final expected = BytesBuilder(copy: false);
    for (var i = 0; i < fx.segments; i++) {
      expected.add(fx.segmentPlain(i));
    }
    final want = expected.takeBytes();
    expect(bytes.length, want.length);
    expect(sha256.convert(bytes), sha256.convert(want),
        reason: 'segments must be assembled in playlist order');
    expect(task.receivedBytes, want.length);
  }

  test('latency-bound HLS downloads segments concurrently in order', () async {
    await runHls('latency');
    expect(timings['hls_latency_max_parallel'],
        greaterThanOrEqualTo(DownloadService.segmentConcurrency));
  });

  test('HLS with hundreds of tokenised segments completes quickly', () async {
    await runHls('many');
  });

  test('AES-128 HLS decrypts every segment correctly', () async {
    await runHls('aes');
  });

  test('large ranged MP4 downloads with parallel connections, byte-exact',
      () async {
    bigRanges.clear();
    bigConnections = 0;
    final sw = Stopwatch()..start();
    final task = enqueue('big-fresh', 'big.mp4');
    await settled(task);
    sw.stop();
    timings['mp4_24mb'] = sw.elapsedMilliseconds;
    timings['mp4_24mb_connections'] = bigConnections;
    expect(task.status, DownloadStatus.completed, reason: task.error);
    final bytes = await File(task.filePath).readAsBytes();
    expect(bytes.length, big.length);
    expect(sha256.convert(bytes), sha256.convert(big));
    expect(task.totalBytes, big.length);
    expect(bigConnections, greaterThan(1),
        reason: 'a 24 MB Range-capable file should use parallel connections');
    expect(bigRanges.where((r) => !r.endsWith('-')), isNotEmpty);
  });

  test('parallel MP4 download pauses and resumes to a byte-exact file',
      () async {
    bigRanges.clear();
    final task = enqueue('big-resume', 'big.mp4');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (task.receivedBytes < big.length * 0.3 &&
        task.isActive &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(task.isActive, isTrue);
    service.pause(task.id);
    await settled(task);
    expect(task.status, DownloadStatus.paused);
    final pausedAt = task.receivedBytes;
    expect(pausedAt, greaterThan(0));
    expect(pausedAt, lessThan(big.length));
    bigRanges.clear();
    service.resume(task.id);
    await settled(task);
    expect(task.status, DownloadStatus.completed, reason: task.error);
    final bytes = await File(task.filePath).readAsBytes();
    expect(sha256.convert(bytes), sha256.convert(big));
    // Resumed workers must continue from their own offsets, not from zero.
    expect(bigRanges, isNotEmpty);
    expect(bigRanges.every((r) => !r.startsWith('bytes=0-')), isTrue,
        reason: 'resume must not re-download completed prefix: $bigRanges');
  });

  test('HLS pause and resume reuses staged segments without re-downloading',
      () async {
    final fx = fixtures['latency']!;
    segmentHits['latency'] = <int, int>{};
    final task = enqueue('hls-pause-resume', 'hls/latency/index.m3u8');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (task.progress < 0.25 &&
        task.isActive &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(task.isActive, isTrue);
    service.pause(task.id);
    await settled(task);
    expect(task.status, DownloadStatus.paused);
    final completedBeforeResume =
        segmentHits['latency']!.entries.where((e) => e.value == 1).length;
    expect(completedBeforeResume, greaterThan(0));

    service.resume(task.id);
    await settled(task);
    expect(task.status, DownloadStatus.completed, reason: task.error);

    final bytes = await File(task.filePath).readAsBytes();
    final expected = BytesBuilder(copy: false);
    for (var i = 0; i < fx.segments; i++) {
      expected.add(fx.segmentPlain(i));
    }
    expect(sha256.convert(bytes), sha256.convert(expected.takeBytes()));
    // At most the in-flight worker segments at pause time may be requested twice.
    final reFetchedCount =
        segmentHits['latency']!.values.where((c) => c > 1).length;
    expect(
      reFetchedCount,
      lessThanOrEqualTo(DownloadService.segmentConcurrency),
      reason: 'already-staged segments must not be re-downloaded on resume',
    );
  });

  test(
      'server advertising Accept-Ranges but returning 200 on sub-ranges falls back cleanly to sequential download',
      () async {
    ignoreRangeOnFake = true;
    addTearDown(() => ignoreRangeOnFake = false);
    final task = enqueue('big-fallback-200', 'big.mp4');
    await settled(task);
    expect(task.status, DownloadStatus.completed, reason: task.error);
    final bytes = await File(task.filePath).readAsBytes();
    expect(sha256.convert(bytes), sha256.convert(big));
  });

  test('pauseTasks, resumeTasks, and removeTasks scope strictly to target ids',
      () async {
    final lineA = CmsLine(
      name: '主线',
      episodes: [
        CmsEpisode(name: '第1集', url: media('hls/latency/index.m3u8')),
        CmsEpisode(name: '第2集', url: media('hls/latency/index.m3u8')),
      ],
    );
    final lineB = CmsLine(
      name: '主线',
      episodes: [
        CmsEpisode(name: '正片', url: media('hls/latency/index.m3u8')),
      ],
    );
    service.enqueue(
      site: site,
      video: const CmsVideo(id: 'series-a', title: '剧集A'),
      line: lineA,
      episodeIndexes: [0, 1],
    );
    service.enqueue(
      site: site,
      video: const CmsVideo(id: 'series-b', title: '剧集B'),
      line: lineB,
      episodeIndexes: [0],
    );
    final a0 = service.taskFor(site.key, 'series-a', '主线', 0)!;
    final a1 = service.taskFor(site.key, 'series-a', '主线', 1)!;
    final b0 = service.taskFor(site.key, 'series-b', '主线', 0)!;

    service.pauseTasks([a0.id, a1.id]);
    await settled(a0);
    await settled(a1);
    expect(a0.status, DownloadStatus.paused);
    expect(a1.status, DownloadStatus.paused);
    // Series B was untouched and completes normally.
    await settled(b0);
    expect(b0.status, DownloadStatus.completed);

    service.resumeTasks([a0.id, a1.id]);
    await settled(a0);
    await settled(a1);
    expect(a0.status, DownloadStatus.completed);
    expect(a1.status, DownloadStatus.completed);

    final pathB = b0.filePath;
    await service.removeTasks([a0.id, a1.id]);
    expect(service.taskFor(site.key, 'series-a', '主线', 0), isNull);
    expect(service.taskFor(site.key, 'series-a', '主线', 1), isNull);
    expect(service.taskFor(site.key, 'series-b', '主线', 0), isNotNull);
    expect(await File(pathB).exists(), isTrue);
    await service.remove(b0.id);
  });
}

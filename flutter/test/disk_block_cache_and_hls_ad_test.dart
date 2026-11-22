import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/local_media_proxy.dart';

void main() {
  group('HLS VOD #EXT-X-DISCONTINUITY ad removal', () {
    test('removes domain-shifted discontinuity ad block on VOD with ENDLIST', () async {
      const playlist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:5.0,
https://cdn-main.example.com/v1/seg001.ts
#EXTINF:5.0,
https://cdn-main.example.com/v1/seg002.ts
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
https://ad-node.example.net/ads/spot1.ts
#EXTINF:5.0,
https://ad-node.example.net/ads/spot2.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
https://cdn-main.example.com/v1/seg003.ts
#EXTINF:10.0,
https://cdn-main.example.com/v1/seg004.ts
#EXT-X-ENDLIST
''';

      final res = LocalMediaLease.stripHlsAdsIfVod(
        playlist,
        Uri.parse('https://cdn-main.example.com/v1/index.m3u8'),
      );
      expect(res.removedSegments, 2);
      expect(res.removedDuration, closeTo(10.0, 0.001));
      expect(res.playlist, isNot(contains('ad-node.example.net')));
      expect(res.playlist, contains('seg001.ts'));
      expect(res.playlist, contains('seg003.ts'));
      expect(res.playlist, contains('#EXT-X-ENDLIST'));
    });

    test('never strips live playlists even with discontinuity and ad hosts', () {
      const livePlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:5.0,
https://cdn-main.example.com/live/100.ts
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
https://ad-node.example.net/ads/101.ts
#EXT-X-DISCONTINUITY
#EXTINF:15.0,
https://cdn-main.example.com/live/102.ts
''';

      // No ENDLIST and no PLAYLIST-TYPE:VOD
      final autoLive = LocalMediaLease.stripHlsAdsIfVod(
        livePlaylist,
        Uri.parse('https://cdn-main.example.com/live/stream.m3u8'),
      );
      expect(autoLive.removedSegments, 0);
      expect(autoLive.playlist, contains('ad-node.example.net'));

      // Even if ENDLIST were somehow present when caller marks isLive=true
      final forcedLive = LocalMediaLease.stripHlsAdsIfVod(
        '$livePlaylist\n#EXT-X-ENDLIST\n',
        Uri.parse('https://cdn-main.example.com/live/stream.m3u8'),
        isLive: true,
      );
      expect(forcedLive.removedSegments, 0);
    });

    test('respects safety bounds (>40% duration or >60s segment or disabled switch)', () {
      // Ad duration > 40% of total (15s ad / 35s total = 42.8%)
      const tooLongRatio = '''
#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:10.0,
https://cdn-main.example.com/v1/main1.ts
#EXT-X-DISCONTINUITY
#EXTINF:15.0,
https://ad-node.example.net/ads/big.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
https://cdn-main.example.com/v1/main2.ts
''';
      final capped = LocalMediaLease.stripHlsAdsIfVod(
        tooLongRatio,
        Uri.parse('https://cdn-main.example.com/v1/index.m3u8'),
      );
      expect(capped.removedSegments, 0);

      // Single ad segment > 60s
      const over60s = '''
#EXTM3U
#EXT-X-ENDLIST
#EXTINF:200.0,
https://cdn-main.example.com/v1/main1.ts
#EXT-X-DISCONTINUITY
#EXTINF:65.0,
https://ad-node.example.net/ads/long.ts
''';
      final longSeg = LocalMediaLease.stripHlsAdsIfVod(
        over60s,
        Uri.parse('https://cdn-main.example.com/v1/index.m3u8'),
      );
      expect(longSeg.removedSegments, 0);

      // Switch disabled
      const vodWithAd = '''
#EXTM3U
#EXT-X-ENDLIST
#EXTINF:20.0,
https://cdn-main.example.com/v1/main1.ts
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
https://ad-node.example.net/ads/spot.ts
''';
      final disabled = LocalMediaLease.stripHlsAdsIfVod(
        vodWithAd,
        Uri.parse('https://cdn-main.example.com/v1/index.m3u8'),
        enabled: false,
      );
      expect(disabled.removedSegments, 0);
      expect(disabled.playlist, contains('ad-node.example.net'));
    });

    test('LocalMediaLease HTTP proxy strips VOD discontinuity ads and records stats', () async {
      const m3u8 = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
https://video.example.com/part1.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.0,
https://video.example.com/gg/ad1.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
https://video.example.com/part2.ts
#EXT-X-ENDLIST
''';
      final mockClient = MockClient((req) async {
        return http.Response(
          m3u8,
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        );
      });
      final lease = await LocalMediaLease.open(
        target: Uri.parse('https://video.example.com/index.m3u8'),
        isCancelled: () => false,
        client: mockClient,
        removeHlsAds: true,
        adHosts: const ['gg.ad-host.test'],
      );
      addTearDown(lease.close);

      final ioClient = HttpClient();
      addTearDown(() => ioClient.close(force: true));
      final req = await ioClient.getUrl(lease.url);
      final res = await req.close();
      final body = await utf8.decodeStream(res);

      expect(res.statusCode, 200);
      expect(body, isNot(contains('/gg/ad1.ts')));
      expect(lease.removedHlsAdSegments, 1);
      expect(lease.removedHlsAdDurationSec, closeTo(4.0, 0.001));
    });
  });

  group('DiskBlockCache 256 KiB Range cache (/kcache/<sid>)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('marco_kcache_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Uint8List makeDeterministicPayload(int size) {
      final out = Uint8List(size);
      for (var i = 0; i < size; i++) {
        out[i] = (i * 31 + 7) & 0xFF;
      }
      return out;
    }

    test(
      'aligns 256 KiB blocks, serves HTTP 206, deduplicates concurrent block reads, evicts LRU, and clears',
      () async {
        // 600 KiB => 3 blocks (256 KiB + 256 KiB + 88 KiB)
        const totalSize = 600 * 1024;
        final payload = makeDeterministicPayload(totalSize);
        var upstreamCalls = 0;
        final upstreamRanges = <String>[];

        final upstreamClient = MockClient((http.Request request) async {
          upstreamCalls++;
          final range = request.headers['range'] ?? request.headers['Range'] ?? '';
          upstreamRanges.add(range);
          if (range.startsWith('bytes=')) {
            final spec = range.substring(6).split('-');
            final start = int.parse(spec[0]);
            final end = (spec.length > 1 && spec[1].isNotEmpty)
                ? int.parse(spec[1]).clamp(start, totalSize - 1)
                : totalSize - 1;
            final slice = payload.sublist(start, end + 1);
            return http.Response.bytes(
              slice,
              HttpStatus.partialContent,
              headers: {
                'content-type': 'video/mp4',
                'accept-ranges': 'bytes',
                'content-range': 'bytes $start-$end/$totalSize',
                'content-length': '${slice.length}',
              },
            );
          }
          return http.Response.bytes(
            payload,
            HttpStatus.ok,
            headers: {
              'content-type': 'video/mp4',
              'content-length': '${payload.length}',
            },
          );
        });

        final cache = DiskBlockCache(
          directory: tempDir,
          maxBytes: 256 * 1024 * 1024,
        );

        final lease = await LocalMediaLease.open(
          target: Uri.parse('https://cdn.example.com/movie.mp4'),
          isCancelled: () => false,
          client: upstreamClient,
          enableDiskCache: true,
          diskCache: cache,
        );
        addTearDown(lease.close);

        expect(lease.url.path, startsWith('/kcache/'));

        final ioClient = HttpClient();
        addTearDown(() => ioClient.close(force: true));

        // 1. Concurrent unaligned reads inside block 1 (262144..524287) should
        // single-flight deduplicate upstream fetch for block 1.
        Future<({int status, String? contentRange, Uint8List body})> fetchRange(
            int start, int end) async {
          final req = await ioClient.getUrl(lease.url);
          req.headers.set('range', 'bytes=$start-$end');
          final resp = await req.close();
          final bytes = await resp.fold<BytesBuilder>(
            BytesBuilder(),
            (b, chunk) => b..add(chunk),
          );
          return (
            status: resp.statusCode,
            contentRange: resp.headers.value('content-range'),
            body: bytes.toBytes(),
          );
        }

        final r1Future = fetchRange(270000, 275000);
        final r2Future = fetchRange(280000, 285000);
        final responses = await Future.wait([r1Future, r2Future]);

        expect(responses[0].status, 206);
        expect(responses[0].contentRange, 'bytes 270000-275000/$totalSize');
        expect(responses[0].body, payload.sublist(270000, 275001));
        expect(responses[1].status, 206);
        expect(responses[1].body, payload.sublist(280000, 285001));
        expect(upstreamCalls, 1);
        expect(upstreamRanges.single, 'bytes=262144-524287');

        // 2. Subsequent hit inside block 1 should serve entirely from disk cache.
        final hit = await fetchRange(262144, 263000);
        expect(hit.body, payload.sublist(262144, 263001));
        expect(upstreamCalls, 1);

        // 3. Read across block 0 and block 2 so all 3 blocks (~600 KiB) are cached.
        final headHit = await fetchRange(0, 1023);
        expect(headHit.body, payload.sublist(0, 1024));
        final tailHit = await fetchRange(524288, totalSize - 1);
        expect(tailHit.body, payload.sublist(524288, totalSize));
        expect(cache.cachedBlockCount, 3);
        expect(cache.currentBytes, totalSize);

        // 4. Lower capacity cap dynamically to 384 KiB => oldest blocks evicted
        await cache.setCapacityBytes(384 * 1024);
        expect(cache.currentBytes, lessThanOrEqualTo(384 * 1024));
        expect(cache.cachedBlockCount, lessThan(3));

        // 5. One-click clear deletes all .blk files and resets accounting.
        await cache.clear();
        expect(cache.currentBytes, 0);
        expect(cache.cachedBlockCount, 0);
        final remainingFiles =
            await tempDir.list().where((e) => e is File).toList();
        expect(remainingFiles, isEmpty);
      },
    );

    test('auto-retries without Range when upstream responds 416', () async {
      final payload = makeDeterministicPayload(128 * 1024);
      final seenRanges = <String?>[];
      final upstreamClient = MockClient((http.Request request) async {
        final range = request.headers['range'] ?? request.headers['Range'];
        seenRanges.add(range);
        if (range != null) {
          return http.Response(
            '',
            HttpStatus.requestedRangeNotSatisfiable,
          );
        }
        return http.Response.bytes(
          payload,
          HttpStatus.ok,
          headers: {
            'content-type': 'video/mp4',
            'content-length': '${payload.length}',
          },
        );
      });

      final cache = DiskBlockCache(directory: tempDir);
      final lease = await LocalMediaLease.open(
        target: Uri.parse('https://cdn.example.com/no-range.mp4'),
        isCancelled: () => false,
        client: upstreamClient,
        enableDiskCache: true,
        diskCache: cache,
      );
      addTearDown(lease.close);

      final ioClient = HttpClient();
      addTearDown(() => ioClient.close(force: true));
      final req = await ioClient.getUrl(lease.url);
      req.headers.set('range', 'bytes=100-599');
      final res = await req.close();
      final body = await res.fold<BytesBuilder>(
        BytesBuilder(),
        (b, c) => b..add(c),
      );

      expect(res.statusCode, 206);
      expect(body.toBytes(), payload.sublist(100, 600));
      expect(seenRanges, ['bytes=0-262143', null]);
    });
  });
}

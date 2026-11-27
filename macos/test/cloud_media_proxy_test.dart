// Local loopback + synthetic upstream only; no account or external media calls.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';

class _InfiniteRangeClient extends http.BaseClient {
  _InfiniteRangeClient({required this.onStart, required this.onCancel});

  final void Function() onStart;
  final void Function() onCancel;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onStart();
    late final StreamController<List<int>> controller;
    Timer? pump;
    controller = StreamController<List<int>>(
      onListen: () {
        controller.add(List<int>.filled(32768, 7));
        pump = Timer.periodic(const Duration(milliseconds: 5), (_) {
          if (!controller.isClosed && !controller.isPaused) {
            controller.add(List<int>.filled(32768, 7));
          }
        });
      },
      onCancel: () {
        pump?.cancel();
        onCancel();
      },
    );
    return http.StreamedResponse(
      controller.stream,
      206,
      contentLength: 4 * 1024 * 1024 * 1024,
      headers: {
        'content-type': 'video/mp4',
        'accept-ranges': 'bytes',
        'content-range': 'bytes 0-4294967295/4294967296',
      },
    );
  }
}

void main() {
  test('a six minute pause preserves the player-owned media lease', () async {
    var now = DateTime.utc(2026, 11, 10);
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        clock: () => now,
        client: MockClient((request) async {
          calls++;
          expect(request.headers['cookie'], '__pus=synthetic');
          expect(request.headers['range'], 'bytes=1-3');
          return http.Response.bytes([1, 2, 3], 206,
              headers: {
                'content-type': 'video/x-matroska',
                'content-range': 'bytes 1-3/8589934592'
              });
        }));
    final url = lease.url;
    try {
      expect((await http.get(url, headers: {'Range': 'bytes=1-3'})).statusCode,
          206);
      now = now.add(const Duration(minutes: 6));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      final resumed = await http.get(url, headers: {'Range': 'bytes=1-3'});
      expect(resumed.statusCode, 206);
      expect(resumed.bodyBytes, [1, 2, 3]);
      expect(resumed.headers['content-range'], 'bytes 1-3/8589934592');
      expect(calls, 2);
    } finally {
      await lease.close();
    }
  });

  test('a player-owned lease still expires after twelve hours', () async {
    var now = DateTime.utc(2026, 11, 10);
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        clock: () => now,
        client: MockClient((request) async {
          calls++;
          return http.Response('movie', 200);
        }));
    final url = lease.url;
    try {
      now = now.add(const Duration(hours: 12, seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await expectLater(http.get(url), throwsA(isA<http.ClientException>()));
      expect(calls, 0);
    } finally {
      await lease.close();
    }
  });

  test('proxy never follows cross-origin redirects or exposes credentials',
      () async {
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          return http.Response('', 302, headers: {
            'location': 'https://evil.test/steal',
            'set-cookie': '__pus=secret'
          });
        }));
    try {
      final result = await http.get(lease.url);
      expect(result.statusCode, 502);
      expect(result.headers.containsKey('location'), isFalse);
      expect(result.headers.containsKey('set-cookie'), isFalse);
      expect(calls, 1);
    } finally {
      await lease.close();
    }
  });

  test('cancel during upstream response prevents delivering the old movie',
      () async {
    var cancelled = false;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => cancelled,
        isCurrent: () async => true,
        client: MockClient((request) async {
          cancelled = true;
          return http.Response('movie', 200,
              headers: {'content-type': 'video/mp4'});
        }));
    try {
      final result = await http.get(lease.url);
      expect(result.statusCode, 410);
      expect(result.body, isNot(contains('movie')));
    } finally {
      await lease.close();
    }
  });

  test('host boundary and capability path cannot be changed by the player',
      () async {
    expect(
        CloudMediaLease.isTrustedUcMedia(
            Uri.parse('https://uc.cn.evil.test/movie')),
        isFalse);
    expect(
        CloudMediaLease.isTrustedUcMedia(
            Uri.parse('https://video.uc.cn:444/movie')),
        isFalse);
    expect(
        CloudMediaLease.isTrustedUcMedia(Uri.parse('http://video.uc.cn/movie')),
        isFalse);
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          calls++;
          return http.Response('movie', 200);
        }));
    try {
      final result = await http.get(
          lease.url.replace(queryParameters: {'url': 'https://evil.test'}));
      expect(result.statusCode, 404);
      expect(calls, 0);
    } finally {
      await lease.close();
    }
  });

  test('identity encoding is required for correct media byte ranges', () async {
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          expect(request.headers['accept-encoding'], 'identity');
          return http.Response('compressed', 206, headers: {
            'content-type': 'video/mp4',
            'content-encoding': 'gzip'
          });
        }));
    try {
      final result = await http.get(lease.url, headers: {'Range': 'bytes=0-9'});
      expect(result.statusCode, 502);
      expect(result.body, isNot(contains('compressed')));
    } finally {
      await lease.close();
    }
  });

  test('account switch after resolution automatically releases the idle lease',
      () async {
    var current = true;
    var calls = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://video.uc.cn/movie.mkv'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => current,
        client: MockClient((request) async {
          calls++;
          return http.Response('movie', 200,
              headers: {'content-type': 'video/mp4'});
        }));
    final url = lease.url;
    try {
      current = false;
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      await expectLater(http.get(url), throwsA(isA<http.ClientException>()));
      expect(calls, 0);
    } finally {
      await lease.close();
    }
  });

  test(
      'aborted loopback Range probes cancel upstream streams and allow rapid MP4 Range seeks without 429',
      () async {
    var activeUpstreams = 0;
    var cancelledUpstreams = 0;
    final lease = await CloudMediaLease.open(
      target: Uri.parse('https://video.uc.cn/E01.mp4'),
      headers: {'Cookie': '__pus=synthetic'},
      isCancelled: () => false,
      isCurrent: () async => true,
      client: _InfiniteRangeClient(
        onStart: () => activeUpstreams++,
        onCancel: () {
          activeUpstreams--;
          cancelledUpstreams++;
        },
      ),
    );
    try {
      // Simulate 8 sequential/overlapping FFmpeg Range probes (ftyp, moov,
      // video mdat, audio mdat, sidx, seeks) that read 32 KB and close early.
      for (var i = 0; i < 8; i++) {
        final ioClient = HttpClient();
        final req = await ioClient.getUrl(lease.url);
        req.headers.set('Range', 'bytes=${i * 1048576}-');
        final res = await req.close();
        expect(res.statusCode, 206, reason: 'Range seek #$i must not hit 429');
        final firstChunk = await res.first;
        expect(firstChunk, isNotEmpty);
        ioClient.close(force: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(activeUpstreams, 0);
      expect(cancelledUpstreams, 8);
    } finally {
      await lease.close();
    }
  });

  test('UC and Baidu HLS m3u8 transcode playlists rewrite provider segments and strip Range on manifests',
      () async {
    for (final providerCase in [
      (
        provider: CloudMediaProvider.uc,
        playlistUrl: 'https://video.uc.cn/hls/master.m3u8',
        cookie: '__pus=uc_token',
      ),
      (
        provider: CloudMediaProvider.baidu,
        playlistUrl: 'https://pan.baidu.com/rest/2.0/xpan/file?method=streaming&type=M3U8_AUTO_1080',
        cookie: 'BDUSS=baidu_token',
      ),
    ]) {
      final lease = await CloudMediaLease.open(
        target: Uri.parse(providerCase.playlistUrl),
        provider: providerCase.provider,
        headers: {'Cookie': providerCase.cookie},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          expect(request.headers['cookie'], providerCase.cookie);
          if (request.url.path.endsWith('.ts')) {
            return http.Response.bytes([0x47, 1, 2, 3], 200,
                headers: {'content-type': 'video/mp2t'});
          }
          expect(request.headers.containsKey('range'), isFalse,
              reason: 'Range header must be stripped on HLS playlist fetches');
          return http.Response(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.0,\nseg01.ts\n#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }),
      );
      try {
        final manifest = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=0-'},
        );
        expect(manifest.statusCode, 200);
        final segUrl = manifest.body
            .split('\n')
            .firstWhere((l) => l.startsWith('http://127.0.0.1:'));
        final seg = await http.get(Uri.parse(segUrl));
        expect(seg.statusCode, 200);
        expect(seg.bodyBytes, [0x47, 1, 2, 3]);
      } finally {
        await lease.close();
      }
    }
  });
}

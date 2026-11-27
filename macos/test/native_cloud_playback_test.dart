// Run after the desktop build with MARCOMOVIE_TEST_MPV pointing at the bundled
// library. Synthetic HEVC/AAC MKV + authenticated HTTP fixture, no user account.
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/core/local_media_proxy.dart';

void main() {
  final library = Platform.environment['MARCOMOVIE_TEST_MPV'];
  test('bundled native decoder advances and seeks authenticated HEVC MKV',
      () async {
    MediaKit.ensureInitialized(libmpv: library);
    final bytes = await File('test/fixtures/cloud-playback.mkv').readAsBytes();
    final requests = <String>[];
    final transport = await CloudMediaLease.open(
      target: Uri.parse('https://media.quark.cn/original.mkv'),
      provider: CloudMediaProvider.quark,
      headers: {'Cookie': '__pus=synthetic-native-test'},
      isCancelled: () => false,
      isCurrent: () async => true,
      client: MockClient((request) async {
        expect(request.headers['cookie'], '__pus=synthetic-native-test');
        final range = request.headers['range'];
        requests.add(range ?? 'full');
        var start = 0, end = bytes.length - 1;
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) end = math.min(end, int.parse(match[2]!));
        }
        if (start > end)
          return http.Response('', 416,
              headers: {'content-range': 'bytes */${bytes.length}'});
        return http.Response.bytes(
            bytes.sublist(start, end + 1), range == null ? 200 : 206,
            headers: {
              'content-type': 'video/x-matroska',
              'accept-ranges': 'bytes',
              if (range != null)
                'content-range': 'bytes $start-$end/${bytes.length}'
            });
      }),
    );
    final player = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true));
    try {
      await (player.platform as dynamic).setProperty('ao', 'null');
      final progressed = player.stream.position
          .firstWhere((p) => p.inMilliseconds >= 1000)
          .timeout(const Duration(seconds: 15));
      await player.open(Media(transport.url.toString()));
      await progressed;
      expect(player.state.duration.inSeconds, greaterThanOrEqualTo(5));
      await player.pause();
      final seeked = player.stream.position
          .firstWhere((p) => p.inMilliseconds >= 4000)
          .timeout(const Duration(seconds: 10));
      await player.seek(const Duration(seconds: 4));
      await player.play();
      await seeked;
      expect(requests, isNotEmpty);
      expect(requests.any((r) => r.startsWith('bytes=')), isTrue);
    } finally {
      await player.dispose();
      await transport.close();
    }
  },
      skip: library == null
          ? 'Set MARCOMOVIE_TEST_MPV to the built desktop library'
          : false);

  test(
      'Windows mpv RAM cache + preserved lavf options play Quark HLS and MP4 without file-cache errors',
      () async {
    MediaKit.ensureInitialized(libmpv: library);
    final bytes = await File('test/fixtures/cloud-playback.mkv').readAsBytes();
    final errors = <String>[];
    final transport = await CloudMediaLease.open(
      target: Uri.parse('https://media.quark.cn/play/master.m3u8'),
      provider: CloudMediaProvider.quark,
      headers: {'Cookie': '__pus=synthetic-native-hls'},
      isCancelled: () => false,
      isCurrent: () async => true,
      client: MockClient((request) async {
        expect(request.headers['cookie'], '__pus=synthetic-native-hls');
        if (request.url.path.endsWith('.m3u8')) {
          return http.Response(
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:5.0,\n'
            'segment.mkv\n'
            '#EXT-X-ENDLIST\n',
            200,
            headers: {'content-type': 'application/vnd.apple.mpegurl'},
          );
        }
        return http.Response.bytes(bytes, 200, headers: {
          'content-type': 'video/mp2t',
        });
      }),
    );
    final player = Player(
      configuration: const PlayerConfiguration(
        vo: 'null',
        muted: true,
        logLevel: MPVLogLevel.error,
      ),
    );
    try {
      final dyn = player.platform as dynamic;
      await dyn.setProperty('ao', 'null');
      await dyn.setProperty('cache', 'yes');
      await dyn.setProperty('cache-on-disk', 'no');
      await dyn.setProperty('cache-pause-wait', '1');
      await dyn.setProperty('demuxer-max-bytes', '134217728');
      await dyn.setProperty('demuxer-readahead-secs', '30');
      await dyn.setProperty(
        'demuxer-lavf-o',
        'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
            'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],'
            'reconnect=1,reconnect_delay_max=4',
      );
      player.stream.log.listen((log) {
        if (log.text.contains('Failed to create file cache')) {
          errors.add(log.text);
        }
      });
      final progressed = player.stream.position
          .firstWhere((p) => p.inMilliseconds >= 1000)
          .timeout(const Duration(seconds: 15));
      await player.open(Media(transport.url.toString()));
      await progressed;
      expect(errors, isEmpty);
    } finally {
      await player.dispose();
      await transport.close();
    }
  },
      skip: library == null
          ? 'Set MARCOMOVIE_TEST_MPV to the built desktop library'
          : false);

  test(
      'LocalMediaLease plays cross-domain 302 anti-leech extensionless HLS with dynamic Set-Cookie in native libmpv',
      () async {
    MediaKit.ensureInitialized(libmpv: library);
    final bytes = await File('test/fixtures/cloud-playback.mkv').readAsBytes();
    var segmentVerifiedCookieAndReferer = false;

    final transport = await LocalMediaLease.open(
      target: Uri.parse('https://portal.stream.test/entry/play'),
      headers: {
        'Referer': 'https://portal.stream.test/watch/1',
        'Authorization': 'Bearer portal-only-secret',
      },
      isCancelled: () => false,
      client: MockClient((request) async {
        if (request.url.toString() == 'https://portal.stream.test/entry/play') {
          expect(request.headers['authorization'], 'Bearer portal-only-secret');
          return http.Response(
            '',
            302,
            headers: {
              'location': 'https://cdn-node.stream.test/hls/manifest_stream',
            },
          );
        }
        if (request.url.toString() ==
            'https://cdn-node.stream.test/hls/manifest_stream') {
          expect(request.headers['authorization'], isNull);
          expect(request.headers['referer'], 'https://portal.stream.test/watch/1');
          return http.Response(
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:5.0,\n'
            'segment.mkv\n'
            '#EXT-X-ENDLIST\n',
            200,
            headers: {
              'content-type': 'text/plain',
              'set-cookie': 'edge_token=mpv_ok; Path=/hls',
            },
          );
        }
        if (request.url.toString() ==
            'https://cdn-node.stream.test/hls/segment.mkv') {
          expect(request.headers['authorization'], isNull);
          expect(request.headers['referer'], 'https://portal.stream.test/watch/1');
          expect(request.headers['cookie'], 'edge_token=mpv_ok');
          segmentVerifiedCookieAndReferer = true;
          return http.Response.bytes(bytes, 200, headers: {
            'content-type': 'video/mp2t',
          });
        }
        return http.Response('missing', 404);
      }),
    );

    final player = Player(
      configuration: const PlayerConfiguration(vo: 'null', muted: true),
    );
    try {
      final dyn = player.platform as dynamic;
      await dyn.setProperty('ao', 'null');
      await dyn.setProperty(
        'demuxer-lavf-o',
        'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
            'protocol_whitelist=[udp,rtp,tcp,tls,data,file,http,https,crypto],'
            'reconnect=1,reconnect_delay_max=4',
      );
      final progressed = player.stream.position
          .firstWhere((p) => p.inMilliseconds >= 1000)
          .timeout(const Duration(seconds: 15));
      await player.open(Media(transport.url.toString()));
      await progressed;
      expect(segmentVerifiedCookieAndReferer, isTrue);
    } finally {
      await player.dispose();
      await transport.close();
    }
  },
      skip: library == null
          ? 'Set MARCOMOVIE_TEST_MPV to the built desktop library'
          : false);
}

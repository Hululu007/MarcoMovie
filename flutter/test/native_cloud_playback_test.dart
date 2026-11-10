// Run after the desktop build with MARCOMOVIE_TEST_MPV pointing at the bundled
// library. Synthetic HEVC/AAC MKV + authenticated HTTP fixture, no user account.
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';

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
}

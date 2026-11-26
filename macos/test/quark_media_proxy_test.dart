import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';

Future<CloudMediaLease> lease(http.Client client) => CloudMediaLease.open(
    provider: CloudMediaProvider.quark,
    target: Uri.parse('https://media.quark.cn/file/master.m3u8'),
    headers: {'Cookie': '__pus=synthetic', 'Referer': 'https://pan.quark.cn/'},
    isCancelled: () => false,
    isCurrent: () async => true,
    client: client);

void main() {
  test(
      'HLS variants, keys and segments retain auth; external CDN stays anonymous',
      () async {
    final paths = <String>[];
    final transport = await lease(MockClient((request) async {
      paths.add(request.url.path);
      expect(request.url.host, 'media.quark.cn');
      expect(request.headers['cookie'], '__pus=synthetic');
      switch (request.url.path) {
        case '/file/master.m3u8':
          return http.Response(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nquality.m3u8\n', 200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'});
        case '/file/quality.m3u8':
          return http.Response(
              '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
              '#EXTINF:2,\nsegment.ts\n#EXTINF:2,\nhttps://signed-cdn.example/anonymous.ts\n#EXT-X-ENDLIST\n',
              200,
              headers: {'content-type': 'application/vnd.apple.mpegurl'});
        default:
          return http.Response.bytes([10, 20, 30], 200);
      }
    }));
    addTearDown(transport.close);
    final master = await http.get(transport.url);
    expect(master.body, isNot(contains('quark.cn')));
    expect(master.body, isNot(contains('synthetic')));
    final child = Uri.parse(
        master.body.split('\n').firstWhere((s) => s.startsWith('http')));
    final playlist = await http.get(child);
    expect(playlist.contentLength, playlist.bodyBytes.length);
    final key =
        Uri.parse(RegExp(r'URI="([^"]+)"').firstMatch(playlist.body)![1]!);
    final segment = Uri.parse(playlist.body
        .split('\n')
        .firstWhere((s) => s.startsWith('http://127.0.0.1')));
    expect((await http.get(key)).bodyBytes, [10, 20, 30]);
    expect((await http.get(segment)).bodyBytes, [10, 20, 30]);
    expect(playlist.body, contains('https://signed-cdn.example/anonymous.ts'));
    expect(paths, [
      '/file/master.m3u8',
      '/file/quality.m3u8',
      '/file/key.bin',
      '/file/segment.ts'
    ]);
  });

  test('Quark redirects check each destination before sending account headers',
      () async {
    final hosts = <String>[];
    final transport = await lease(MockClient((request) async {
      hosts.add(request.url.host);
      expect(request.followRedirects, isFalse);
      return http.Response('', 302, headers: {
        'location': hosts.length == 1
            ? 'https://next.quark.cn/play.m3u8'
            : 'https://quark.cn.evil.test/steal'
      });
    }));
    addTearDown(transport.close);
    expect((await http.get(transport.url)).statusCode, 502);
    expect(hosts, ['media.quark.cn', 'next.quark.cn']);
  });

  test('provider scopes cannot be mixed or downgraded', () {
    for (final value in [
      'http://media.quark.cn/video',
      'https://quark.cn.evil.test/video',
      'https://media.quark.cn:444/video',
      'https://user@media.quark.cn/video',
      'https://media.uc.cn/video'
    ]) {
      expect(CloudMediaLease.isTrustedQuarkMedia(Uri.parse(value)), isFalse);
    }
    expect(
        CloudMediaLease.isTrustedQuarkMedia(
            Uri.parse('https://media.quark.cn/video')),
        isTrue);
  });
}

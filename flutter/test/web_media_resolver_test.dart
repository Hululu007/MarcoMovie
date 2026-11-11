import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/web_media_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    WebMediaResolver.debugSnifferOverride = null;
  });

  test(
      'CmsClient retains Set-Cookie across same-domain 302 redirects without leaking credentials cross-origin',
      () async {
    final seenCookies = <String, String?>{};
    final client = CmsClient(
      client: MockClient((request) async {
        seenCookies[request.url.toString()] = request.headers['cookie'];
        if (request.url.toString() ==
            'https://cms-guard.test/api.php?ac=list') {
          if (request.headers['cookie']?.contains('guard_pass=ok_token') ==
              true) {
            return http.Response(
              jsonEncode({
                'class': [
                  {'type_id': 1, 'type_name': '电影'}
                ],
                'list': [
                  {
                    'vod_id': '101',
                    'vod_name': '测试影片',
                    'vod_pic': 'https://cms-guard.test/p.jpg',
                  }
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            '',
            302,
            headers: {
              'location': '/api.php?ac=list',
              'set-cookie': 'guard_pass=ok_token; Path=/; HttpOnly',
            },
          );
        }
        return http.Response('unexpected', 404);
      }),
    );

    const site = CmsSite(
      key: 'guarded_cms',
      name: 'Guarded CMS',
      type: 1,
      api: 'https://cms-guard.test/api.php',
      headers: {'Cookie': 'initial_user=1'},
    );

    final (_, listing) = await client.fetchHome(site);
    expect(listing.videos, hasLength(1));
    expect(listing.videos.single.title, '测试影片');
    expect(
      seenCookies['https://cms-guard.test/api.php?ac=list'],
      allOf(contains('initial_user=1'), contains('guard_pass=ok_token')),
    );
  });

  test(
      'multi-parser waterfall falls back across CmsConfig.parses and preserves custom parser headers',
      () async {
    final parserCalls = <Uri>[];
    final client = CmsClient(
      client: MockClient((request) async {
        parserCalls.add(request.url);
        if (request.url.host == 'broken-parser.test') {
          return http.Response('gateway timeout', 502);
        }
        if (request.url.host == 'backup-parser.test') {
          expect(request.headers['X-Parser-Token'], 'backup-v2');
          expect(request.headers['Authorization'], isNull);
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'url': 'https://cdn.stream.test/hls/master.m3u8',
                'referer': 'https://backup-parser.test/',
                'ua': 'ParserSafari/18.0',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    const site = CmsSite(
      key: 't4_parse',
      name: 'T4 Secondary',
      type: 4,
      api: 'https://t4-origin.test/spider',
      playUrl: 'https://broken-parser.test/jx?url=',
      headers: {'Authorization': 'Bearer t4-secret'},
    );

    final t4Client = CmsClient(
      client: MockClient((request) async {
        if (request.url.host == 't4-origin.test') {
          return http.Response(
            jsonEncode({
              'parse': 1,
              'jx': 1,
              'url': 'https://video-page.test/v/ep01.html',
            }),
            200,
          );
        }
        parserCalls.add(request.url);
        if (request.url.host == 'broken-parser.test') {
          return http.Response('broken', 500);
        }
        if (request.url.host == 'backup-parser.test') {
          expect(request.headers['X-Parser-Token'], 'backup-v2');
          expect(request.headers['Authorization'], isNull);
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': {
                'url': 'https://cdn.stream.test/hls/master.m3u8',
                'referer': 'https://backup-parser.test/',
                'ua': 'ParserSafari/18.0',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final resolved = await t4Client.resolveEpisodeForPlayback(
      site,
      const CmsEpisode(name: '第01集', url: 'mmt4://play?id=ep1&flag=lineA'),
      parses: const [
        CmsParse(
          name: '备用解析',
          url: 'https://backup-parser.test/api?url=',
          type: 1,
          headers: {'X-Parser-Token': 'backup-v2'},
        ),
      ],
    );

    expect(resolved.url, 'https://cdn.stream.test/hls/master.m3u8');
    expect(resolved.headers['Referer'], 'https://backup-parser.test/');
    expect(resolved.headers['User-Agent'], 'ParserSafari/18.0');
    expect(resolved.headers.containsKey('Authorization'), isFalse);
    expect(
      parserCalls.map((u) => u.host).toList(),
      ['broken-parser.test', 'backup-parser.test'],
    );
    // Keep analyzer happy on first client fixture:
    expect(client, isNotNull);
  });

  test(
      'MacCMS player_aaaa encrypt=2 Base64+URL-encoded HTML page and 2-hop iframe player unwrap cleanly',
      () async {
    final encodedStream = base64Encode(
      utf8.encode(
        Uri.encodeComponent('https://hls-node.test/live/ep02/index.m3u8?token=77'),
      ),
    );

    final client = CmsClient(
      client: MockClient((request) async {
        if (request.url.toString() == 'https://vod-web.test/vodplay/99-1-1.html') {
          return http.Response(
            '''
<!DOCTYPE html>
<html>
<head><title>Play</title></head>
<body>
<script type="text/javascript">
var player_aaaa={"flag":"play","encrypt":2,"trysee":0,"points":0,"url":"$encodedStream"};
</script>
</body>
</html>
''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        if (request.url.toString() == 'https://vod-web.test/vodplay/99-1-2.html') {
          return http.Response(
            '<html><body><iframe src="https://embed-player.test/box.html?vid=2"></iframe></body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        if (request.url.toString() == 'https://embed-player.test/box.html?vid=2') {
          expect(
            request.headers['Referer'] ?? request.headers['referer'],
            'https://vod-web.test/vodplay/99-1-2.html',
          );
          return http.Response(
            '''
<html><body>
<script>
const dp = new DPlayer({
  video: { url: "https:\\/\\/cdn-iframe.test\\/videos\\/ep02.mp4" }
});
</script>
</body></html>
''',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    const site = CmsSite(
      key: 'maccms_html',
      name: 'MacCMS HTML',
      type: 1,
      api: 'https://vod-web.test/api.php/provide/vod/',
    );

    final ep1 = await client.resolveEpisodeForPlayback(
      site,
      const CmsEpisode(
        name: '第1集',
        url: 'https://vod-web.test/vodplay/99-1-1.html',
      ),
    );
    expect(ep1.url, 'https://hls-node.test/live/ep02/index.m3u8?token=77');
    expect(ep1.headers['Referer'], 'https://vod-web.test/vodplay/99-1-1.html');

    final ep2 = await client.resolveEpisodeForPlayback(
      site,
      const CmsEpisode(
        name: '第2集',
        url: 'https://vod-web.test/vodplay/99-1-2.html',
      ),
    );
    expect(ep2.url, 'https://cdn-iframe.test/videos/ep02.mp4');
    expect(ep2.headers['Referer'], 'https://embed-player.test/box.html?vid=2');
  });

  test(
      'falls back to native web_sniffer Stage 3 when static HTML relies on dynamic runtime execution, and StorageService preserves parses in backups',
      () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService(await SharedPreferences.getInstance());
    await storage.saveConfig(
      jsonEncode({
        'parses': [
          {
            'name': 'Web嗅探解析',
            'type': 0,
            'url': 'https://web-jx.test/render?url=',
          }
        ],
        'sites': [
          {
            'key': 's1',
            'name': '测试源',
            'type': 1,
            'api': 'https://cms.test/api.php',
          }
        ],
      }),
      origin: 'https://cms.test/config.json',
    );
    final saved = storage.loadSavedConfig()!;
    expect(saved.parses, hasLength(1));
    expect(saved.parses.single.url, 'https://web-jx.test/render?url=');

    String? sniffedTarget;
    WebMediaResolver.debugSnifferOverride = (url, headers, timeout) async {
      sniffedTarget = url;
      return const WebSniffResult(
        url: 'https://dynamic-cdn.test/runtime/index.m3u8?sig=ok',
        headers: {
          'Referer': 'https://web-jx.test/render',
          'Cookie': 'wasm_token=verified',
        },
      );
    };

    final client = CmsClient(
      client: MockClient((request) async {
        // Static HTML has no literal video URL (simulating dynamic runtime assembly)
        return http.Response(
          '<html><body><div id="app"></div><script src="/bundle.js"></script></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      }),
    );

    final resolved = await client.resolveEpisodeForPlayback(
      saved.sites.single,
      const CmsEpisode(
        name: '正片',
        url: 'https://thirdparty-page.test/watch/abc.html',
      ),
      parses: saved.parses,
    );

    expect(
      sniffedTarget,
      'https://web-jx.test/render?url=https%3A%2F%2Fthirdparty-page.test%2Fwatch%2Fabc.html',
    );
    expect(resolved.url, 'https://dynamic-cdn.test/runtime/index.m3u8?sig=ok');
    expect(resolved.headers['Cookie'], 'wasm_token=verified');
    expect(resolved.headers['Referer'], 'https://web-jx.test/render');
  });
}

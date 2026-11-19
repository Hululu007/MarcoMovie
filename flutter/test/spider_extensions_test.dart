import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/spider_gateway.dart';
import 'package:marco_movie/core/spider_plugin_registry.dart';
import 'package:marco_movie/ui/spider_extensions_panel.dart';
import 'test_storage_helper.dart';

void main() {
  tearDown(() {
    SpiderPluginRegistry.instance.resetForTesting();
  });

  group('SpiderAdapterPack & Local-First Registry', () {
    test('parses valid marco-adapter-pack-v1 and matches exact + wildcard APIs', () {
      final pack = SpiderAdapterPack.parseJsonString(
        SpiderPluginRegistry.samplePackTemplateJson(),
      );
      expect(pack.id, 'community-sample-pack');
      expect(pack.rules.length, 2);

      const jsSite = CmsSite(
        key: 'ex_js',
        name: '示例蜘蛛',
        type: 3,
        api: 'csp_ExampleSpiderGuard',
      );
      const t4Site = CmsSite(
        key: 'ex_t4',
        name: '示例T4',
        type: 3,
        api: 'csp_ExampleT4Extra',
      );
      expect(pack.rules[0].matchesSite(jsSite), isTrue);
      expect(pack.rules[1].matchesSite(t4Site), isTrue);

      final materializedJs = pack.rules[0].materializeSite(jsSite);
      expect(materializedJs.type, 3);
      expect(
        materializedJs.api,
        'https://plugins.example/adapters/example_spider.js',
      );

      final materializedT4 = pack.rules[1].materializeSite(t4Site);
      expect(materializedT4.type, 4);
      expect(materializedT4.api, 'https://plugins.example/t4/example');
    });

    test('rejects invalid schema, non-HTTP URLs, and missing rules', () {
      expect(
        () => SpiderAdapterPack.parseJsonString(
          '{"schema":"wrong-v9","name":"Bad","rules":[{"matchApis":["csp_A"],"kind":"js","scriptUrl":"https://plugins.example/a.js"}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => SpiderAdapterPack.parseJsonString(
          '{"schema":"marco-adapter-pack-v1","name":"Bad","rules":[{"matchApis":["csp_A"],"kind":"js","scriptUrl":"file:///etc/passwd"}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => SpiderAdapterPack.parseJsonString(
          '{"schema":"marco-adapter-pack-v1","name":"Empty","rules":[]}',
        ),
        throwsFormatException,
      );
    });

    test('enforces strict Local-First priority (nativeLocal > adapterPack > gateway > unsupported)', () {
      const soSite = CmsSite(
        key: 'so_anime',
        name: '漫剧测试',
        type: 3,
        api: 'csp_ManjuAiDemo',
      );

      // 1. Default state: unadapted .so site is unsupported.
      expect(soSite.supported, isFalse);
      expect(soSite.usesAdapterPack, isFalse);
      expect(soSite.usesSpiderGateway, isFalse);

      // 2. Enabling BYO gateway makes .so site supported via gateway fallback.
      SpiderPluginRegistry.instance.setGatewayConfig(
        const SpiderGatewayConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:9981',
          token: 'secret-token',
        ),
      );
      expect(soSite.supported, isTrue);
      expect(soSite.usesSpiderGateway, isTrue);
      expect(soSite.usesAdapterPack, isFalse);

      // 3. Installing an Adapter Pack overrides gateway (Local-First!).
      final pack = SpiderAdapterPack.parseJsonString(jsonEncode({
        'schema': SpiderAdapterPack.schemaId,
        'id': 'manju-pack',
        'name': '漫剧本地插件',
        'rules': [
          {
            'id': 'manju-t4',
            'matchApis': ['csp_manjuai*'],
            'kind': 't4',
            'scriptUrl': 'https://plugins.example/t4/manju',
          },
        ],
      }));
      SpiderPluginRegistry.instance.setPacks([pack]);
      expect(soSite.supported, isTrue);
      expect(soSite.usesAdapterPack, isTrue);
      expect(soSite.usesSpiderGateway, isFalse);

      // 4. Native built-in sites NEVER downgrade to adapter pack or gateway.
      const nativeHttpSite = CmsSite(
        key: 'maccms',
        name: '直连站点',
        type: 1,
        api: 'https://source.example/api.php/provide/vod/',
      );
      expect(nativeHttpSite.supported, isTrue);
      expect(nativeHttpSite.usesAdapterPack, isFalse);
      expect(nativeHttpSite.usesSpiderGateway, isFalse);

      // 5. P2P / Emby templates remain excluded from gateway.
      const p2pSite = CmsSite(
        key: 'sixv',
        name: '磁力源',
        type: 3,
        api: 'csp_SixV',
      );
      expect(p2pSite.usesSpiderGateway, isFalse);
    });
  });

  group('StorageService persistence & secure token isolation', () {
    test('persists adapter packs & gateway config with token isolated in secure store', () async {
      final storage = await initTestStorage();
      final pack = await storage.importSpiderAdapterPackJson(
        SpiderPluginRegistry.samplePackTemplateJson(),
      );
      expect(storage.spiderAdapterPacks.length, 1);
      expect(SpiderPluginRegistry.instance.enabledPackCount, 1);

      await storage.setSpiderAdapterPackEnabled(pack.id, false);
      expect(SpiderPluginRegistry.instance.enabledPackCount, 0);

      await storage.saveSpiderGatewayConfig(
        const SpiderGatewayConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:9981/',
          token: 'my-super-secret-token',
          deviceName: '客厅 Android TV',
        ),
      );
      expect(storage.spiderGatewayConfig.isActive, isTrue);
      expect(storage.spiderGatewayConfig.normalizedBaseUrl, 'http://127.0.0.1:9981');
      expect(storage.spiderGatewayConfig.token, 'my-super-secret-token');
      expect(
        await storage.secureStoreForTesting.read('spider_gateway_token'),
        'my-super-secret-token',
      );
    });
  });

  group('CmsClient Adapter Pack & BYO Spider Gateway execution', () {
    test('executes unadapted .so site through Adapter Pack (T4) transparently', () async {
      const soSite = CmsSite(
        key: 'music_so',
        name: '音乐测试',
        type: 3,
        api: 'csp_MusicAiDemo',
      );
      SpiderPluginRegistry.instance.setPacks([
        SpiderAdapterPack.parseJsonString(jsonEncode({
          'schema': SpiderAdapterPack.schemaId,
          'id': 'music-pack',
          'name': '音乐扩展包',
          'rules': [
            {
              'id': 'music-t4',
              'matchApis': ['csp_MusicAiDemo'],
              'kind': 't4',
              'scriptUrl': 'https://plugins.example/t4/music',
            },
          ],
        })),
      ]);

      http.Response jsonResp(Object body, [int status = 200]) =>
          http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            status,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );

      final client = CmsClient(
        client: MockClient((req) async {
          expect(req.url.host, 'plugins.example');
          if (req.url.queryParameters['play'] == 'ep_1') {
            return jsonResp({'parse': 0, 'url': 'https://cdn.example/song.m3u8'});
          }
          if (req.url.queryParameters['ids'] == 'v1') {
            return jsonResp({
              'list': [
                {
                  'vod_id': 'v1',
                  'vod_name': '夜曲 MV',
                  'vod_play_from': '高清线路',
                  'vod_play_url': '第1集\$ep_1',
                },
              ],
            });
          }
          return jsonResp({
            'class': [
              {'type_id': '1', 'type_name': '热门'},
            ],
            'list': [
              {'vod_id': 'v1', 'vod_name': '夜曲 MV', 'vod_pic': ''},
            ],
          });
        }),
      );

      final (cats, home) = await client.fetchHome(soSite);
      expect(cats.single.name, '热门');
      expect(home.videos.single.title, '夜曲 MV');

      final detail = await client.fetchDetail(soSite, home.videos.single);
      final ep = detail.lines.single.episodes.single;
      expect(ep.url, startsWith('mmt4://play?'));

      final playable = await client.resolveEpisodeForPlayback(soSite, ep);
      expect(playable.url, 'https://cdn.example/song.m3u8');
    });

    test('executes unadapted .so site through BYO Spider Gateway (home/category/search/detail/play)', () async {
      const soSite = CmsSite(
        key: 'so_sport',
        name: '体育加密源',
        type: 3,
        api: 'csp_SportAiCustomSo',
        jar: 'https://source.example/spider.jar',
      );
      SpiderPluginRegistry.instance.setGatewayConfig(
        const SpiderGatewayConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:9981',
          token: 'lan-token-42',
          deviceName: '卧室盒子',
        ),
      );

      http.Response jsonResp(Object body, [int status = 200]) =>
          http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            status,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );

      final actions = <String>[];
      final mockClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer lan-token-42');
        if (req.url.path == '/marco-gateway/v1/health') {
          return jsonResp({
            'ok': true,
            'protocol': SpiderGatewayClient.protocolId,
            'deviceName': '卧室盒子',
            'engine': 'android-csp',
            'supportsNativeSo': true,
          });
        }
        expect(req.url.path, '/marco-gateway/v1/invoke');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final action = body['action'] as String;
        actions.add(action);
        if (action == 'home') {
          return jsonResp({
            'ok': true,
            'data': {
              'class': [
                {'type_id': 'live', 'type_name': '赛事直播'},
              ],
              'list': [
                {'vod_id': 'match_1', 'vod_name': '总决赛 G7'},
              ],
            },
          });
        }
        if (action == 'category') {
          return jsonResp({
            'ok': true,
            'data': {
              'page': 1,
              'pagecount': 2,
              'list': [
                {'vod_id': 'match_2', 'vod_name': '半决赛'},
              ],
            },
          });
        }
        if (action == 'search') {
          return jsonResp({
            'ok': true,
            'data': {
              'list': [
                {'vod_id': 'match_1', 'vod_name': '总决赛 G7'},
              ],
            },
          });
        }
        if (action == 'detail') {
          return jsonResp({
            'ok': true,
            'data': {
              'list': [
                {
                  'vod_id': 'match_1',
                  'vod_name': '总决赛 G7',
                  'vod_play_from': '高清蓝光',
                  'vod_play_url': '全场回放\$stream_id_77',
                },
              ],
            },
          });
        }
        if (action == 'play') {
          expect(body['params']['id'], 'stream_id_77');
          return jsonResp({
            'ok': true,
            'data': {
              'parse': 0,
              'url': 'https://stream.example/g7.m3u8',
            },
          });
        }
        return jsonResp({'ok': false, 'error': 'unknown'}, 400);
      });

      final health = await SpiderGatewayClient.checkHealth(
        SpiderPluginRegistry.instance.gatewayConfig,
        client: mockClient,
      );
      expect(health.ok, isTrue);
      expect(health.supportsNativeSo, isTrue);
      expect(health.deviceName, '卧室盒子');

      final client = CmsClient(client: mockClient);
      final (cats, home) = await client.fetchHome(soSite);
      expect(cats.single.id, 'live');
      expect(home.videos.single.id, 'match_1');

      final catList = await client.fetchCategory(soSite, 'live', 1);
      expect(catList.videos.single.id, 'match_2');

      final searchList = await client.fetchSearch(soSite, '总决赛');
      expect(searchList.videos.single.id, 'match_1');

      final detail = await client.fetchDetail(soSite, home.videos.single);
      final ep = detail.lines.single.episodes.single;
      expect(ep.isGatewayEpisode, isTrue);
      expect(ep.needsSourceResolution, isTrue);

      final resolved = await client.resolveEpisodeForPlayback(soSite, ep);
      expect(resolved.url, 'https://stream.example/g7.m3u8');
      expect(actions, ['home', 'category', 'search', 'detail', 'play']);
    });

    test('gateway 401 auth error never leaks Bearer token', () async {
      final mockClient = MockClient(
        (_) async => http.Response('{"ok":false,"error":"Unauthorized"}', 401),
      );
      final health = await SpiderGatewayClient.checkHealth(
        const SpiderGatewayConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:9981',
          token: 'top-secret-9999',
        ),
        client: mockClient,
      );
      expect(health.ok, isFalse);
      expect(health.message, contains('401'));
      expect(health.message, isNot(contains('top-secret-9999')));
    });
  });

  testWidgets(
    'SpiderExtensionsPanel displays live coverage and saves BYO gateway config',
    (tester) async {
      final storage = await initTestStorage();
      final client = CmsClient(
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      const sites = [
        CmsSite(
          key: 'http_ok',
          name: '正常站',
          type: 1,
          api: 'https://source.example/api',
        ),
        CmsSite(
          key: 'so_only',
          name: '加密漫剧',
          type: 3,
          api: 'csp_ManjuAiLocked',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SpiderExtensionsPanel(
                storage: storage,
                client: client,
                sites: sites,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本机原生已适配'), findsOneWidget);
      expect(find.text('1 条'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('spider-import-pack-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('spider-gateway-discover-btn')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('spider-gateway-url-input')),
        'http://127.0.0.1:9981',
      );
      await tester.enterText(
        find.byKey(const ValueKey('spider-gateway-token-input')),
        'demo-token',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('spider-gateway-save-btn')),
      );
      await tester.tap(find.byKey(const ValueKey('spider-gateway-save-btn')));
      await tester.pumpAndSettle();

      expect(storage.spiderGatewayConfig.normalizedBaseUrl, 'http://127.0.0.1:9981');
      expect(storage.spiderGatewayConfig.token, 'demo-token');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

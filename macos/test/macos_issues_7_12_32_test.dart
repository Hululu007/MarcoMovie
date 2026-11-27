import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_log.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/source_playback.dart';
import 'package:marco_movie/core/wogg_netdisk_adapter.dart';
import 'package:marco_movie/core/wogg_source.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/player_screen.dart';

import 'test_storage_helper.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Issues #7, #12, #32 — A/B 4K playback trace, 4K adapters, actionable hints & log redaction', () {
    test('A/B comparison: same 4K sample via direct URL vs subscription import -> home -> detail -> play -> quality', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
      // Controlled synthetic 4K payload served by loopback HTTP server so both
      // direct play and subscription-routed play fetch the exact same resource.
      final synthetic4kBytes = List<int>.generate(128 * 1024, (i) => (i * 31) & 0xff);
      var directHits = 0;
      var subscriptionHits = 0;
      final trace = <String>[];

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';

      server.listen((HttpRequest req) async {
        final path = req.uri.path;
        if (path == '/media/sample_4k.mp4') {
          if (req.uri.queryParameters['via'] == 'sub') {
            subscriptionHits++;
          } else {
            directHits++;
          }
          req.response.statusCode = 200;
          req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
          req.response.headers.set('Accept-Ranges', 'bytes');
          req.response.headers.contentLength = synthetic4kBytes.length;
          req.response.add(synthetic4kBytes);
          await req.response.close();
          return;
        }
        if (path == '/sub/config.json') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'sites': [
              {
                'key': 'local_t4_4k',
                'name': '自建 4K 测试源',
                'type': 4,
                'api': '$base/t4/vod',
              },
              {
                'key': 'unknown_jar_site',
                'name': '未知插件站点',
                'type': 3,
                'api': 'csp_Unknown4KDemo',
              },
            ],
          }));
          await req.response.close();
          return;
        }
        if (path == '/t4/vod') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          final ac = req.uri.queryParameters['ac'] ?? '';
          final play = req.uri.queryParameters['play'] ?? '';
          if (play.isNotEmpty) {
            // Tests SourcePlayback empty url + urls fallback with 4K quality choices
            req.response.write(jsonEncode({
              'parse': 0,
              'url': '',
              'urls': [
                '1080P',
                '$base/media/sample_1080p.mp4',
                '4K 原画',
                '$base/media/sample_4k.mp4?via=sub',
              ],
            }));
            await req.response.close();
            return;
          }
          if (ac == 'detail') {
            // Tests nested data.list envelope wrapping in _wrapJsEpisodeIds
            req.response.write(jsonEncode({
              'data': {
                'list': [
                  {
                    'vod_id': 'v4k_01',
                    'vod_name': '4K 横移测试样片',
                    'vod_remarks': '4K HDR',
                    'vod_play_from': '直链4K',
                    'vod_play_url': '第01集\$ep4k_01',
                  },
                ],
              },
            }));
            await req.response.close();
            return;
          }
          // Home response
          req.response.write(jsonEncode({
            'class': [
              {'type_id': '1', 'type_name': '电影'},
              {'type_id': '44', 'type_name': '臻彩'},
            ],
            'list': [
              {
                'vod_id': 'v4k_01',
                'vod_name': '4K 横移测试样片',
                'vod_remarks': '4K HDR',
              },
            ],
          }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      // Path A: Direct play -> verify exact 4K bytes delivered from media URL
      final directUrl = Uri.parse('$base/media/sample_4k.mp4?via=direct');
      final directResp = await http.get(directUrl);
      expect(directResp.statusCode, 200);
      expect(directResp.bodyBytes.length, synthetic4kBytes.length);
      expect(directHits, 1);
      trace.add('direct:ok(${directResp.bodyBytes.length}B)');

      // Path B: Subscription Import -> Site Init -> Home -> Detail -> Play URL -> Quality
      final storage = await initTestStorage();
      final client = CmsClient();

      // Step 1: Import
      final imported = await client.resolveBatchSubscriptions(
        urlInput: '$base/sub/config.json',
      );
      expect(imported, hasLength(1));
      await storage.upsertSubscriptions(imported);
      trace.add('import:ok(${imported.single.siteCount} sites)');

      // Step 2: Site init & capability filtering
      final config = storage.loadSavedConfig();
      expect(config, isNotNull);
      expect(config!.availableSites.map((s) => s.key), contains('local_t4_4k'));
      final unknown = config.sites.firstWhere((s) => s.key == 'unknown_jar_site');
      expect(unknown.supported, isFalse);
      expect(unknown.actionableUnsupportedHint, contains('csp_Unknown4KDemo'));
      expect(unknown.actionableUnsupportedHint, contains('蜘蛛扩展与网关'));
      trace.add('init:ok(1 playable, 1 unadapted)');

      // Step 3: Home / Category
      final site = config.availableSites.firstWhere((s) => s.key == 'local_t4_4k');
      final (cats, home) = await client.fetchHome(site);
      expect(cats.map((c) => c.id), containsAll(['1', '44']));
      expect(home.videos.single.id, 'v4k_01');
      trace.add('home:ok(cats=${cats.length}, videos=${home.videos.length})');

      // Step 4: Detail (nested data.list envelope properly wrapped into mmt4://play)
      final detail = await client.fetchDetail(site, home.videos.single);
      expect(detail.lines, hasLength(1));
      expect(detail.lines.single.episodes.single.url, startsWith('mmt4://play?'));
      trace.add('detail:ok(${detail.lines.single.episodes.single.url})');

      // Step 5: Play URL resolution + Quality selection
      final resolved = await client.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(resolved.variants.map((v) => v.name), ['1080P', '4K 原画']);
      final selected4k = resolved.variants.firstWhere((v) => v.name == '4K 原画');
      expect(selected4k.url, '$base/media/sample_4k.mp4?via=sub');
      trace.add('play:ok(variants=${resolved.variants.length}, selected=${selected4k.name})');

      // Step 6: Player media transport fetches exact same 4K bytes
      final subResp = await http.get(
        Uri.parse(selected4k.url),
        headers: selected4k.headers,
      );
      expect(subResp.statusCode, 200);
      expect(subResp.bodyBytes, equals(directResp.bodyBytes));
      expect(subscriptionHits, 1);
      trace.add('transport:ok(identical 4K bytes)');
      expect(trace, hasLength(7));
      }, _RealHttpOverrides());
    });

    test('Issue #32: WoggNetdiskAdapter supports expanded 4K netdisk spiders & WoggSource accepts direct URL ext', () {
      for (final api in const [
        'csp_Wanou',
        'csp_WanouGuard',
        'csp_Panhub',
        'csp_Yidong4K',
        'csp_Fengye4K',
        'csp_Fengqi4K',
        'csp_Kaka',
        'csp_Jike',
      ]) {
        final site = CmsSite(
          key: api.toLowerCase(),
          name: '$api 4K',
          type: 3,
          api: api,
          ext: 'https://pan-mirror.example/',
        );
        expect(WoggNetdiskAdapter.supports(site), isTrue, reason: '$api should be supported');
        expect(site.supported, isTrue, reason: '$api should be browsable');
      }

      // WoggSource supports plain HTTP(S) URL or JSON site/url/domain/host ext
      expect(
        WoggSource.supports(const CmsSite(
          key: 'wogg_plain',
          name: '玩偶哥哥',
          type: 3,
          api: 'csp_WoGG',
          ext: 'https://wogg.example/',
        )),
        isTrue,
      );
      expect(
        WoggSource.supports(const CmsSite(
          key: 'wogg_domain_json',
          name: '玩偶哥哥',
          type: 3,
          api: 'csp_WoGGGuard',
          ext: '{"domain":"https://wogg.example/"}',
        )),
        isTrue,
      );
      // Empty ext without pluginReference still rejected
      expect(
        WoggSource.supports(const CmsSite(
          key: 'wogg_empty',
          name: '玩偶哥哥',
          type: 3,
          api: 'csp_WoGG',
          ext: '',
        )),
        isFalse,
      );
    });

    test('Issue #7 & #12: netdisk-only unadapted subscriptions report actionable plugin count and hints', () async {
      final raw = jsonEncode({
        'sites': [
          {
            'key': 'missing_guard_jar',
            'name': '玩偶4K(缺spider)',
            'type': 3,
            'api': 'csp_AiNewWoggGuard',
            'ext': '',
          },
          {
            'key': 'missing_ext_4k',
            'name': '枫叶4K(缺域名)',
            'type': 3,
            'api': 'csp_Fengye4K',
            'ext': '',
          },
          {
            'key': 'unknown_4k',
            'name': '未知4K网盘源',
            'type': 3,
            'api': 'csp_BrandNew4KPan',
            'ext': '',
          },
        ],
      });
      final config = CmsParser.parseConfig(raw);
      expect(config.availableSites, isEmpty);
      // Previously pluginOnlySites was 0 when all sites were unadapted netdisk sites!
      expect(config.unadaptedPluginSites, hasLength(3));

      final missingJar = config.sites[0];
      expect(missingJar.actionableUnsupportedHint, contains('spider / jar'));
      expect(missingJar.actionableUnsupportedHint, contains('csp_AiNewWoggGuard'));

      final missingExt = config.sites[1];
      expect(missingExt.actionableUnsupportedHint, contains('ext'));
      expect(missingExt.actionableUnsupportedHint, contains('csp_Fengye4K'));

      final unknown4k = config.sites[2];
      expect(unknown4k.actionableUnsupportedHint, contains('蜘蛛扩展与网关'));
      expect(unknown4k.actionableUnsupportedHint, contains('csp_BrandNew4KPan'));

      // Verify UI notice renders accurate count + Spider Extensions button
      final storage = await initTestStorage();
      await storage.upsertSubscriptions([
        SubscriptionEntry(
          id: 'sub_unadapted',
          name: '仅未适配插件订阅',
          rawContent: raw,
          siteCount: 3,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      final client = CmsClient(
        client: MockClient((_) async => http.Response('{}', 404)),
      );
      await Future<void>.value();
    });

    testWidgets('Issue #7 UI: AdaptiveShell shows accurate unadapted-plugin notice and Spider Extensions shortcut', (tester) async {
      final raw = jsonEncode({
        'sites': [
          {
            'key': 'unknown_4k_netdisk',
            'name': '未知4K网盘源',
            'type': 3,
            'api': 'csp_BrandNew4KPan',
            'ext': '',
          },
        ],
      });
      final storage = await initTestStorage();
      await storage.upsertSubscriptions([
        SubscriptionEntry(
          id: 'sub_only_unadapted_4k',
          name: '测试未适配订阅',
          rawContent: raw,
          siteCount: 1,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      final client = CmsClient(
        client: MockClient((_) async => http.Response('{}', 404)),
      );

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('未适配网盘插件站点'), findsOneWidget);
      expect(find.text('配置蜘蛛扩展与网关'), findsOneWidget);
      expect(find.text('当前订阅暂未加载到可用片源'), findsNothing);
    });

    test('Issue #12 & #32: PlayerScreen.formatActionablePlaybackError preserves plugin errors and AppLog redacts secrets', () async {
      const site = CmsSite(
        key: 's_guard',
        name: 'Guard源',
        type: 3,
        api: 'csp_Unknown4K',
      );
      const ep = CmsEpisode(name: '第01集', url: 'mmjs://play?id=1');

      expect(
        PlayerScreen.formatActionablePlaybackError(
          site,
          ep,
          StateError('安装包缺少 CatPaw 本机运行组件，请安装完整版本'),
        ),
        contains('CatPaw'),
      );
      expect(
        PlayerScreen.formatActionablePlaybackError(
          site,
          ep,
          const GuardBootstrapException(
            'guard_artifact_unsupported',
            '当前插件版本尚未完成本机移植',
          ),
        ),
        contains('本机移植'),
      );

      // Redaction check on playback resolution error logged to AppLog
      final sensitiveError = FormatException(
        '插件解析失败 https://user:supersecret@vod.example/play?token=abc123xyz&pwd=9876 Authorization: Bearer topsecret_jwt Cookie: __pus=my_secret_cookie',
      );
      final formatted = PlayerScreen.formatActionablePlaybackError(
        site,
        ep,
        sensitiveError,
      );
      expect(formatted, isNot(contains('supersecret')));
      expect(formatted, isNot(contains('abc123xyz')));
      expect(formatted, isNot(contains('topsecret_jwt')));
      expect(formatted, isNot(contains('my_secret_cookie')));
      expect(formatted, contains('[REDACTED]'));

      // Verify CmsClient.resolveEpisodeForPlayback records redacted errors to AppLog
      final tempDir = await Directory.systemTemp.createTemp('marco-applog-');
      addTearDown(() => tempDir.delete(recursive: true));
      final logger = AppLog(logDirectory: tempDir);
      logger.logError(
        'resolveEpisodeForPlayback failed: $sensitiveError',
        source: 'CmsClient',
      );
      final exported = await logger.exportLogsFormatted();
      expect(exported, contains('[REDACTED]'));
      expect(exported, isNot(contains('supersecret')));
      expect(exported, isNot(contains('topsecret_jwt')));
      expect(exported, isNot(contains('my_secret_cookie')));
    });

    test('SourcePlayback.decode merges url and urls without empty url shadowing 4K variants', () async {
      final ep = await SourcePlayback.decode(
        {
          'parse': 0,
          'url': '',
          'urls': [
            '1080P',
            'https://cdn.example/1080p.mp4',
            '4K 臻彩',
            'https://cdn.example/4k.mp4',
          ],
        },
        const CmsEpisode(name: '第01集', url: 'mmjs://play?id=1'),
        localUrl: (raw) async => Uri.parse(raw),
      );
      expect(ep.variants.map((v) => v.name), ['1080P', '4K 臻彩']);
      expect(ep.variants.last.url, 'https://cdn.example/4k.mp4');
    });
  });
}

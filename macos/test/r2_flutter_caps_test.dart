import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/web_media_resolver.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exact baseline (`7b8a54a`) `CmsSite.canBrowse` predicate prior to Round 1.
bool _baseline7b8a54aCanBrowse(CmsSite s) {
  return s.key != 'mydrive' &&
      (s.isEmby ||
          s.isCatPaw ||
          (s.type == 4 && s.isHttpApi) ||
          (s.isScriptOrJarApi
              ? CspBridge.hasAdapter(s)
              : s.isM3uVodApi ||
                    ((s.isHttpApi || s.isScriptOrJarApi) &&
                        (s.type == 0 ||
                            s.type == 1 ||
                            s.type == 4 ||
                            s.type == 3 ||
                            s.type == -1))));
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}${Platform.pathSeparator}shared${Platform.pathSeparator}conformance')
        .existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError('Cannot locate repository root from ${Directory.current.path}');
}

File _findFixtureFile(String name) {
  final candidates = [
    File('test/fixtures/$name'),
    File('flutter/test/fixtures/$name'),
    File('${_findRepoRoot().path}/flutter/test/fixtures/$name'),
  ];
  for (final f in candidates) {
    if (f.existsSync()) return f;
  }
  throw StateError('Fixture not found: $name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B4: capabilityStatus order, jar tolerance, playbackHint & baseline parity', () {
    test('Case 1: csp_ adapted sites carrying jar / spider return ok', () {
      const woggWithJar = CmsSite(
        key: 'wogg',
        name: '玩偶哥哥┃4K弹幕',
        type: 3,
        api: 'csp_WoGGGuard',
        jar: 'https://cdn.fixture.invalid/jars/fan.jar;md5;abcd',
        ext: '{"Cloud-drive":"tvfan/Cloud-drive.txt"}',
      );
      expect(CspBridge.hasAdapter(woggWithJar), isTrue);
      expect(woggWithJar.capabilityStatus, CmsSite.statusOk);
      expect(woggWithJar.supported, isTrue);

      const muouWithJar = CmsSite(
        key: 'muou',
        name: '木偶4K',
        type: 3,
        api: 'csp_AINewMuouGuard',
        jar: 'https://cdn.fixture.invalid/jars/muou.jar',
      );
      expect(CspBridge.hasAdapter(muouWithJar), isTrue);
      expect(muouWithJar.capabilityStatus, CmsSite.statusOk);
      expect(muouWithJar.supported, isTrue);

      const czWithJar = CmsSite(
        key: 'cz',
        name: '厂长┃不卡',
        type: 3,
        api: 'csp_NewCzGuard',
        jar: 'https://cdn.fixture.invalid/jars/cz.jar',
      );
      expect(CspBridge.hasAdapter(czWithJar), isTrue);
      expect(czWithJar.capabilityStatus, CmsSite.statusOk);
      expect(czWithJar.supported, isTrue);
    });

    test('Case 2: ordinary type 0/1/4 HTTP CMS sites with jar (and 4K/观影 names) return ok', () {
      const cmsJsonWithJar = CmsSite(
        key: 'lz_cms',
        name: '量子4K资源CMS',
        type: 1,
        api: 'https://lz.fixture.invalid/api.php/provide/vod/',
        jar: 'https://cdn.fixture.invalid/jars/spider.jar',
      );
      expect(cmsJsonWithJar.capabilityStatus, CmsSite.statusOk);
      expect(cmsJsonWithJar.supported, isTrue);

      const cmsXmlWithJar = CmsSite(
        key: 'ff_xml',
        name: '非凡观影XML',
        type: 0,
        api: 'https://ff.fixture.invalid/inc/api.php',
        jar: './jars/helper.jar',
      );
      expect(cmsXmlWithJar.capabilityStatus, CmsSite.statusOk);
      expect(cmsXmlWithJar.supported, isTrue);

      const t4HttpWithJar = CmsSite(
        key: 't4_http',
        name: '远程T4节点',
        type: 4,
        api: 'https://t4.fixture.invalid/spider',
        jar: 'https://cdn.fixture.invalid/jars/t4.jar',
      );
      expect(t4HttpWithJar.capabilityStatus, CmsSite.statusOk);
      expect(t4HttpWithJar.supported, isTrue);
    });

    testWidgets('Case 3: parse:1 CMS site stays supported (ok) and exposes non-blocking playbackHint on DetailScreen',
        (tester) async {
      final parsed = CmsParser.parseConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'guan_cms',
              'name': '官源CMS',
              'type': 1,
              'api': 'https://guan.fixture.invalid/api.php/provide/vod/',
              'parse': 1,
              'playUrl': '',
            },
          ],
        }),
        origin: 'https://guan.fixture.invalid/cfg.json',
      );
      final site = parsed.sites.single;
      expect(site.requiresParser, isTrue);
      expect(site.capabilityStatus, CmsSite.statusOk);
      expect(site.supported, isTrue);
      expect(site.playbackHint, '需要解析器，当前环境缺少可用解析配置');

      SharedPreferences.setMockInitialValues({
        StorageService.keyRawConfig: jsonEncode({
          'sites': [
            {
              'key': 'guan_cms',
              'name': '官源CMS',
              'type': 1,
              'api': 'https://guan.fixture.invalid/api.php/provide/vod/',
              'parse': 1,
              'playUrl': '',
            },
          ],
        }),
      });
      final storage = StorageService(await SharedPreferences.getInstance());
      final client = CmsClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'list': [
                {
                  'vod_id': '88',
                  'vod_name': '官源测试片',
                  'vod_play_from': '直链线路',
                  'vod_play_url': '第1集\$https://cdn.fixture.invalid/88.m3u8',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            site: site,
            initialVideo: const CmsVideo(id: '88', title: '官源测试片'),
            client: client,
            storage: storage,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('detail-playback-hint-banner')), findsOneWidget);
      expect(find.text('需要解析器，当前环境缺少可用解析配置'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    test('Site-by-site comparison: baseline (7b8a54a canBrowse) vs new supported across fixtures & conformance', () {
      final fixtureNames = [
        'fty_spider_49_sites.json',
        'moyuer_mixed_spider_cms.json',
        'cms_aggregate_parse_matrix.json',
      ];
      final summaryRows = <String>[];

      for (final name in fixtureNames) {
        final raw = _findFixtureFile(name).readAsStringSync();
        final cfg = CmsParser.parseConfig(
          raw,
          origin: 'https://fixture.invalid/$name',
        );
        expect(cfg.sites, isNotEmpty, reason: name);
        var baselineAvail = 0;
        var newAvail = 0;
        for (final site in cfg.sites) {
          final baseOk = _baseline7b8a54aCanBrowse(site);
          final newOk = site.supported;
          if (baseOk) baselineAvail++;
          if (newOk) newAvail++;
          if (!site.isExtTooLarge && baseOk) {
            expect(
              newOk,
              isTrue,
              reason:
                  'Regression in $name for site "${site.key}" (${site.name}, api=${site.api}, jar=${site.jar}): baseline canBrowse=true but new supported=false (${site.capabilityStatus})',
            );
          }
        }
        summaryRows.add(
          '$name: baseline=$baselineAvail/${cfg.sites.length}, new=$newAvail/${cfg.sites.length}',
        );
      }

      // Also verify every config-bearing case in shared/conformance/case_*
      final conformanceRoot =
          Directory('${_findRepoRoot().path}/shared/conformance');
      final caseDirs = conformanceRoot
          .listSync()
          .whereType<Directory>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      var conformanceTotal = 0;
      var conformanceBaselineAvail = 0;
      var conformanceNewAvail = 0;
      for (final dir in caseDirs) {
        final caseName = dir.path.split(RegExp(r'[\\/]')).last;
        if (!caseName.startsWith('case_')) continue;
        final metaFile = File('${dir.path}/meta.json');
        final inputFile = File('${dir.path}/input.bin');
        if (!metaFile.existsSync() || !inputFile.existsSync()) continue;
        final meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
        final entrypoint =
            (meta['entrypoint'] ?? meta['type'] ?? 'config').toString().toLowerCase();
        if (entrypoint == 'listing' || entrypoint == 'lines') continue;
        final origin = (meta['origin'] ?? '').toString();
        final unpacked = CmsParser.decodeConfigDocument(inputFile.readAsBytesSync());
        final cfg = CmsParser.parseConfig(unpacked, origin: origin);
        for (final site in cfg.sites) {
          conformanceTotal++;
          final baseOk = _baseline7b8a54aCanBrowse(site);
          final newOk = site.supported;
          if (baseOk) conformanceBaselineAvail++;
          if (newOk) conformanceNewAvail++;
          if (!site.isExtTooLarge && baseOk) {
            expect(
              newOk,
              isTrue,
              reason:
                  'Conformance regression in ${dir.uri.pathSegments.where((s) => s.isNotEmpty).last} for site "${site.key}": baseline canBrowse=true but new supported=false (${site.capabilityStatus})',
            );
          }
        }
      }
      summaryRows.add(
        'shared/conformance (config cases): baseline=$conformanceBaselineAvail/$conformanceTotal, new=$conformanceNewAvail/$conformanceTotal',
      );
      // Print deterministic summary for acceptance verification.
      // ignore: avoid_print
      print('SITE_PARITY_SUMMARY => ${summaryRows.join(' | ')}');
      expect(conformanceTotal, greaterThan(0));
    });
  });

  group('M-F1: webpage lines enter resolveEpisodeForPlayback; unresolvable lines grayed out with reason', () {
    test('webpage episodes enter resolveEpisodeForPlayback when playUrl, parses, or WebMediaResolver handles them',
        () async {
      const siteNoPlayUrl = CmsSite(
        key: 'web_cms',
        name: '网页CMS',
        type: 1,
        api: 'https://web.fixture.invalid/api.php/provide/vod/',
      );
      const htmlEp = CmsEpisode(
        name: '第1集',
        url: 'https://web.fixture.invalid/vodplay/10-1-1.html',
      );
      const shareEp = CmsEpisode(
        name: '第2集',
        url: 'https://web.fixture.invalid/share/abc123xyz',
      );
      const tokenEp = CmsEpisode(
        name: '第3集',
        url: 'NBY-token-998811',
      );

      expect(htmlEp.isDirectPlayable, isFalse);
      expect(shareEp.isDirectPlayable, isFalse);
      expect(tokenEp.isDirectPlayable, isFalse);

      // HTML & /share/ pages can be handled by WebMediaResolver even without playUrl/parses:
      expect(
        WebMediaResolver.episodeUnavailableReason(htmlEp, site: siteNoPlayUrl),
        isNull,
      );
      expect(
        WebMediaResolver.episodeUnavailableReason(shareEp, site: siteNoPlayUrl),
        isNull,
      );

      // Opaque parser token WITHOUT playUrl/parses is flagged with clear reason:
      expect(
        WebMediaResolver.episodeUnavailableReason(tokenEp, site: siteNoPlayUrl),
        contains('缺少可用解析配置'),
      );

      // Opaque parser token WITH site.playUrl or CmsConfig.parses becomes resolvable:
      expect(
        WebMediaResolver.episodeUnavailableReason(
          tokenEp,
          site: siteNoPlayUrl.copyWith(playUrl: 'https://jx.fixture.invalid/?url='),
        ),
        isNull,
      );
      expect(
        WebMediaResolver.episodeUnavailableReason(
          tokenEp,
          site: siteNoPlayUrl,
          parses: const [
            CmsParse(name: '全局解析', url: 'https://jx.fixture.invalid/?url=', type: 1),
          ],
        ),
        isNull,
      );

      // End-to-end CmsClient.resolveEpisodeForPlayback unwraps /share/ webpage and token via parses:
      final client = CmsClient(
        client: MockClient((req) async {
          if (req.url.toString() == 'https://web.fixture.invalid/share/abc123xyz') {
            return http.Response(
              '<html><script>var player_aaaa={"encrypt":0,"url":"https://cdn.fixture.invalid/hls/ep2.m3u8"};</script></html>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          if (req.url.toString().startsWith('https://jx.fixture.invalid/?url=')) {
            return http.Response(
              jsonEncode({'code': 200, 'url': 'https://cdn.fixture.invalid/hls/ep3.m3u8'}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final resolvedShare = await client.resolveEpisodeForPlayback(siteNoPlayUrl, shareEp);
      expect(resolvedShare.url, 'https://cdn.fixture.invalid/hls/ep2.m3u8');

      final resolvedToken = await client.resolveEpisodeForPlayback(
        siteNoPlayUrl,
        tokenEp,
        parses: const [
          CmsParse(name: '全局解析', url: 'https://jx.fixture.invalid/?url=', type: 1),
        ],
      );
      expect(resolvedToken.url, 'https://cdn.fixture.invalid/hls/ep3.m3u8');
    });

    testWidgets('unresolvable episode line is grayed out on DetailScreen with reason and does not open PlayerScreen',
        (tester) async {
      const site = CmsSite(
        key: 'token_only_cms',
        name: '专用解析站',
        type: 1,
        api: 'https://token.fixture.invalid/api.php/provide/vod/',
      );
      SharedPreferences.setMockInitialValues({});
      final storage = StorageService(await SharedPreferences.getInstance());
      final client = CmsClient(
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'list': [
                {
                  'vod_id': '501',
                  'vod_name': '无解析配置测试片',
                  'vod_play_from': 'NBY专用线',
                  'vod_play_url': '第1集\$NBY-opaque-001',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            site: site,
            initialVideo: const CmsVideo(id: '501', title: '无解析配置测试片'),
            client: client,
            storage: storage,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // Banner and card show reason & grayed-out Opacity before tapping:
      expect(find.byKey(const ValueKey('detail-line-unavailable-banner')), findsOneWidget);
      expect(find.textContaining('缺少可用解析配置'), findsWidgets);
      final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(opacities.any((o) => (o.opacity - 0.48).abs() < 0.02 || (o.opacity - 0.45).abs() < 0.02), isTrue);

      // Tapping episode card shows toast/reason and does NOT navigate to PlayerScreen:
      final epCardFinder = find.byKey(const ValueKey('ep_card_0_0'));
      await tester.ensureVisible(epCardFinder);
      await tester.pumpAndSettle();
      await tester.tap(epCardFinder);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.textContaining('需要专用插件解析'), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('M-F2: default site fallback, unavailable history/favorite prompt & sibling .take(6) filtering', () {
    testWidgets('Case 4: default site unavailable falls back to available site in AdaptiveShell._reloadSavedConfig',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final rawCfg = jsonEncode({
        'sites': [
          {
            'key': 'bad_default',
            'name': '不可用默认Jar源',
            'type': 3,
            'api': 'https://bad.fixture.invalid/spider.jar',
          },
          {
            'key': 'good_fallback',
            'name': '可用回退CMS源',
            'type': 1,
            'api': 'https://good.fixture.invalid/api.php/provide/vod/',
          },
        ],
      });

      // Even if SharedPreferences had saved bad_default as selected & preferred:
      SharedPreferences.setMockInitialValues({
        StorageService.keyRawConfig: rawCfg,
        StorageService.keySelectedSite: 'bad_default',
        StorageService.keyPreferredSite: 'bad_default',
      });
      final storage = StorageService(await SharedPreferences.getInstance());
      final requestedHosts = <String>[];
      final client = CmsClient(
        client: MockClient((req) async {
          requestedHosts.add(req.url.host);
          return http.Response(
            jsonEncode({
              'class': [
                {'type_id': 1, 'type_name': '电影'},
              ],
              'list': [
                {
                  'vod_id': '1',
                  'vod_name': '可用源首页影片',
                  'vod_remarks': 'HD',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(requestedHosts, isNot(contains('bad.fixture.invalid')));
      expect(requestedHosts, contains('good.fixture.invalid'));
      expect(find.text('可用回退CMS源'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Case 5: tapping watch history (or favorite) of an unavailable site shows reason dialog and does NOT enter loading',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final rawCfg = jsonEncode({
        'sites': [
          {
            'key': 'bad_hist_site',
            'name': '失效插件源',
            'type': 3,
            'api': 'https://bad-hist.fixture.invalid/spider.jar',
          },
          {
            'key': 'active_ok_site',
            'name': '当前正常源',
            'type': 1,
            'api': 'https://ok.fixture.invalid/api.php/provide/vod/',
          },
        ],
      });

      final seededHistory = jsonEncode([
        const WatchHistoryEntry(
          site: 'bad_hist_site',
          id: 'vid_999',
          title: '旧插件源历史影片',
          episode: '第03集',
          position: 90000,
          duration: 300000,
          updated: 1700000000000,
        ).toJson(),
      ]);
      final seededFavorites = jsonEncode([
        const FavoriteEntry(
          site: 'bad_hist_site',
          id: 'vid_999',
          title: '旧插件源收藏影片',
          updated: 1700000000000,
        ).toJson(),
      ]);

      SharedPreferences.setMockInitialValues({
        StorageService.keyRawConfig: rawCfg,
        StorageService.keySelectedSite: 'active_ok_site',
        StorageService.keyWatchHistory: seededHistory,
        StorageService.keyFavorites: seededFavorites,
      });
      final storage = StorageService(await SharedPreferences.getInstance());
      final detailRequests = <Uri>[];
      final client = CmsClient(
        client: MockClient((req) async {
          if (req.url.host == 'bad-hist.fixture.invalid' ||
              req.url.queryParameters.containsKey('ids') ||
              req.url.queryParameters.containsKey('wd')) {
            detailRequests.add(req.url);
          }
          return http.Response(
            '{"class":[],"list":[]}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Tap watch history card on Home shelf:
      expect(find.text('旧插件源历史影片'), findsOneWidget);
      await tester.tap(find.text('旧插件源历史影片'));
      await tester.pumpAndSettle();

      // Diagnostic dialog pops up with exact unsupportedReason; DetailScreen is NOT pushed:
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('失效插件源'), findsOneWidget);
      expect(find.text('此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持'), findsOneWidget);
      expect(find.byType(DetailScreen), findsNothing);
      expect(detailRequests, isEmpty);

      // Dismiss dialog:
      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();

      // Also verify opening Watch History full sheet ("查看全部") and tapping the item:
      await tester.tap(find.text('查看全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sheet_hist_bad_hist_site_vid_999')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持'), findsOneWidget);
      expect(find.byType(DetailScreen), findsNothing);
      expect(detailRequests, isEmpty);

      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();

      // Also verify tapping Favorite card on Library ("片库") tab:
      await tester.tap(find.text('片库'));
      await tester.pumpAndSettle();
      expect(find.text('旧插件源收藏影片'), findsOneWidget);
      await tester.tap(find.text('旧插件源收藏影片'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持'), findsOneWidget);
      expect(find.byType(DetailScreen), findsNothing);
      expect(detailRequests, isEmpty);

      await tester.tap(find.text('好'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    test('DetailScreen.selectRelatedSeasonSiblings filters out unavailable sites before .take(6)', () {
      const active = CmsSite(
        key: 'active',
        name: '当前站',
        type: 1,
        api: 'https://active.fixture.invalid/vod',
      );
      final sites = <CmsSite>[
        active,
        for (var i = 0; i < 8; i++)
          CmsSite(
            key: 'unsupp_$i',
            name: '不可用源$i',
            type: 3,
            api: 'https://bad.fixture.invalid/$i.jar',
          ),
        for (var i = 0; i < 8; i++)
          CmsSite(
            key: 'avail_$i',
            name: '可用源$i',
            type: 1,
            api: 'https://good$i.fixture.invalid/vod',
          ),
      ];

      final picked = DetailScreen.selectRelatedSeasonSiblings(active, sites);
      expect(picked, hasLength(6));
      expect(picked.every((s) => s.supported), isTrue);
      expect(
        picked.map((s) => s.key).toList(),
        ['avail_0', 'avail_1', 'avail_2', 'avail_3', 'avail_4', 'avail_5'],
      );
    });
  });
}

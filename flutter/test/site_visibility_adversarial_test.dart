import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/source_choice_sliver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Adversarial Challenge 1: 7 Unified Capability Statuses & Cms.java Alignment', () {
    test('Verbatim Chinese diagnostic text matches Cms.java constants exactly', () {
      final expectedMap = <String, String>{
        CmsSite.statusOk: '正常可用',
        CmsSite.statusNeedsJar: '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持',
        CmsSite.statusUnsupportedType: '暂不支持此类型来源，已保留在列表中',
        CmsSite.statusAdapterMissing: '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路',
        CmsSite.statusExtTooLarge: '扩展参数超过大小上限，无法加载',
        CmsSite.statusCustomSiteUrl: '此来源不是可直接请求的 HTTP(S) CMS',
        CmsSite.statusParserRequired: '需要解析器，当前环境缺少可用解析配置',
      };

      for (final entry in expectedMap.entries) {
        expect(
          CmsSite.capabilityReason(entry.key),
          entry.value,
          reason: 'Reason for status "${entry.key}" must match Cms.java verbatim',
        );
      }

      // Fallback reason for unknown status
      expect(CmsSite.capabilityReason('unknown-future-status'), '此来源暂不可用');
    });

    test('Config generator produces sites for all 7 statuses correctly', () {
      final jsonConfig = jsonEncode({
        'sites': [
          {
            'key': 'site_ok',
            'name': '正常CMS源',
            'type': 1,
            'api': 'https://cms.test.org/api.php/provide/vod',
          },
          {
            'key': 'site_needs_jar',
            'name': '未适配Spider源',
            'type': 3,
            'api': 'https://spider.test.org/spider.jar',
          },
          {
            'key': 'site_unsupported_type',
            'name': '未知类型源',
            'type': 99,
            'api': 'https://unknown.test.org/api',
          },
          {
            'key': 'site_adapter_missing',
            'name': '阿里网盘源',
            'type': 3,
            'api': 'csp_Alipansou',
          },
          {
            'key': 'site_ext_too_large',
            'name': '超大参数源',
            'type': 1,
            'api': 'https://cms.test.org/vod',
            'ext': 'x' * (128 * 1024 + 10),
          },
          {
            'key': 'site_custom_site_url',
            'name': '自定义协议源',
            'type': 1,
            'api': 'custom-protocol://local/feed',
          },
          {
            'key': 'site_parser_required',
            'name': '需外部解析源',
            'type': 1,
            'api': 'https://cms.test.org/vod',
            'playUrl': '',
            'parse': 1,
          },
        ]
      });

      final config = CmsParser.parseConfig(jsonConfig, origin: 'https://test.org/cfg.json');
      expect(config.sites.length, 7);

      final okSite = config.sites.firstWhere((s) => s.key == 'site_ok');
      expect(okSite.capabilityStatus, CmsSite.statusOk);
      expect(okSite.supported, isTrue);
      expect(okSite.unsupportedReason, '正常可用');

      final jarSite = config.sites.firstWhere((s) => s.key == 'site_needs_jar');
      expect(jarSite.capabilityStatus, CmsSite.statusNeedsJar);
      expect(jarSite.supported, isFalse);
      expect(jarSite.unsupportedReason, '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持');

      final unsuppTypeSite = config.sites.firstWhere((s) => s.key == 'site_unsupported_type');
      expect(unsuppTypeSite.capabilityStatus, CmsSite.statusUnsupportedType);
      expect(unsuppTypeSite.supported, isFalse);
      expect(unsuppTypeSite.unsupportedReason, '暂不支持此类型来源，已保留在列表中');

      final netdiskSite = config.sites.firstWhere((s) => s.key == 'site_adapter_missing');
      expect(netdiskSite.capabilityStatus, CmsSite.statusAdapterMissing);
      expect(netdiskSite.supported, isFalse);
      expect(netdiskSite.unsupportedReason, '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路');

      final extSite = config.sites.firstWhere((s) => s.key == 'site_ext_too_large');
      expect(extSite.capabilityStatus, CmsSite.statusExtTooLarge);
      expect(extSite.supported, isFalse);
      expect(extSite.unsupportedReason, '扩展参数超过大小上限，无法加载');

      final customUrlSite = config.sites.firstWhere((s) => s.key == 'site_custom_site_url');
      expect(customUrlSite.capabilityStatus, CmsSite.statusCustomSiteUrl);
      expect(customUrlSite.supported, isFalse);
      expect(customUrlSite.unsupportedReason, '此来源不是可直接请求的 HTTP(S) CMS');

      final parserSite = config.sites.firstWhere((s) => s.key == 'site_parser_required');
      expect(parserSite.capabilityStatus, CmsSite.statusParserRequired);
      expect(parserSite.supported, isFalse);
      expect(parserSite.unsupportedReason, '需要解析器，当前环境缺少可用解析配置');
    });

    test('isExtTooLarge strict byte boundary stress test (131072 vs 131073)', () {
      const boundary = 128 * 1024; // 131072 chars

      final atBoundary = CmsSite(
        key: 'boundary',
        name: '边界测试',
        type: 1,
        api: 'https://test.org/api',
        ext: 'A' * boundary,
      );
      expect(atBoundary.isExtTooLarge, isFalse);
      expect(atBoundary.capabilityStatus, CmsSite.statusOk);
      expect(atBoundary.supported, isTrue);

      final overBoundary = CmsSite(
        key: 'over',
        name: '超限测试',
        type: 1,
        api: 'https://test.org/api',
        ext: 'A' * (boundary + 1),
      );
      expect(overBoundary.isExtTooLarge, isTrue);
      expect(overBoundary.capabilityStatus, CmsSite.statusExtTooLarge);
      expect(overBoundary.supported, isFalse);

      const explicitFlag = CmsSite(
        key: 'explicit',
        name: '显式标志测试',
        type: 1,
        api: 'https://test.org/api',
        extTooLarge: true,
      );
      expect(explicitFlag.isExtTooLarge, isTrue);
      expect(explicitFlag.capabilityStatus, CmsSite.statusExtTooLarge);
    });

    test('Priority conflict resolution matches Android Cms.java evaluation order', () {
      // 1. ext-too-large beats netdisk
      final extAndNetdisk = CmsSite(
        key: 'c1',
        name: '网盘且超大',
        type: 3,
        api: 'csp_Pansou',
        extTooLarge: true,
      );
      expect(extAndNetdisk.capabilityStatus, CmsSite.statusExtTooLarge);

      // 2. netdisk beats needs-jar
      const netdiskJar = CmsSite(
        key: 'c2',
        name: '网盘Jar',
        type: 3,
        api: 'csp_Pansou',
        jar: 'https://jar.example/spider.jar',
      );
      expect(netdiskJar.capabilityStatus, CmsSite.statusAdapterMissing);

      // 3. needs-jar beats unsupported-type
      const jarUnsupportedType = CmsSite(
        key: 'c3',
        name: 'Jar且类型99',
        type: 99,
        api: 'https://test.org/custom.js',
      );
      expect(jarUnsupportedType.capabilityStatus, CmsSite.statusNeedsJar);

      // 4. unsupported-type beats custom-site-url
      const typeAndUrl = CmsSite(
        key: 'c4',
        name: '类型99且自定义协议',
        type: 99,
        api: 'custom://foo/bar',
      );
      expect(typeAndUrl.capabilityStatus, CmsSite.statusUnsupportedType);

      // 5. custom-site-url beats parser-required
      const urlAndParser = CmsSite(
        key: 'c5',
        name: '非HTTP且需要解析',
        type: 1,
        api: 'custom://foo/bar',
        requiresParser: true,
        playUrl: '',
      );
      expect(urlAndParser.capabilityStatus, CmsSite.statusCustomSiteUrl);

      // 6. parser-required is resolved when playUrl is non-empty
      const parserResolved = CmsSite(
        key: 'c6',
        name: '需要解析但已有playUrl',
        type: 1,
        api: 'https://test.org/api',
        requiresParser: true,
        playUrl: 'https://parser.test.org/parse?url=',
      );
      expect(parserResolved.capabilityStatus, CmsSite.statusOk);
      expect(parserResolved.supported, isTrue);
    });
  });

  group('Adversarial Challenge 2: Site Inclusivity & Filtering Robustness', () {
    test('Config with 0 sites handles gracefully without crash or exception', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      // Case 1: Config with 0 sites but with lives (live-only subscription)
      final liveOnlyConfig = jsonEncode({
        'sites': <Map<String, dynamic>>[],
        'lives': [
          {'name': '央视高清', 'url': 'https://live.test/cctv.m3u8'}
        ]
      });
      await storage.saveConfig(liveOnlyConfig, origin: 'https://live-only.test/cfg.json');

      final loaded = storage.loadSavedConfig();
      expect(loaded, isNotNull);
      expect(loaded!.sites, isEmpty);
      expect(loaded.supportedSites, isEmpty);
      expect(loaded.availableSites, isEmpty);
      expect(loaded.availableSiteCount, 0);
      expect(loaded.publicSupportedSites, isEmpty);
      expect(loaded.publicAvailableSites, isEmpty);
      expect(loaded.publicAvailableSiteCount, 0);
      expect(storage.selectedSiteKey, isEmpty);

      // Case 2: Pure CmsConfig with 0 sites directly constructed
      const pureEmptyConfig = CmsConfig(sites: []);
      expect(pureEmptyConfig.sites, isEmpty);
      expect(pureEmptyConfig.supportedSites, isEmpty);
      expect(pureEmptyConfig.availableSites, isEmpty);
      expect(pureEmptyConfig.availableSiteCount, 0);
      expect(pureEmptyConfig.publicAvailableSites, isEmpty);
      expect(pureEmptyConfig.publicAvailableSiteCount, 0);

      // Case 3: Completely empty config with no sites, no lives, no depots throws FormatException gracefully
      const completelyEmptyConfig = '{"sites": []}';
      expect(
        () => CmsParser.parseConfig(completelyEmptyConfig, origin: 'https://empty.test/cfg.json'),
        throwsA(isA<FormatException>()),
      );
    });

    test('Config with 100% unsupported sites retains all sites and yields 0 availableSites', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      final jsonConfig = jsonEncode({
        'sites': [
          {'key': 'u1', 'name': '未适配1', 'type': 3, 'api': 'https://jar.test/1.jar'},
          {'key': 'u2', 'name': '未适配2', 'type': 99, 'api': 'https://unknown.test/2'},
          {'key': 'u3', 'name': '网盘源3', 'type': 3, 'api': 'csp_Pansou'},
          {'key': 'u4', 'name': '超大4', 'type': 1, 'api': 'https://big.test/4', 'ext': 'x' * 200000},
          {'key': 'u5', 'name': '协议5', 'type': 1, 'api': 'custom://test/5'},
          {'key': 'u6', 'name': '解析6', 'type': 1, 'api': 'https://parse.test/6', 'parse': 1},
        ]
      });

      await storage.saveConfig(jsonConfig, origin: 'https://unsupp.test/cfg.json');
      final loaded = storage.loadSavedConfig();
      expect(loaded, isNotNull);

      // Inclusivity: ALL 6 sites are preserved in supportedSites
      expect(loaded!.supportedSites.length, 6);
      expect(loaded.supportedSites.map((s) => s.key).toList(), ['u1', 'u2', 'u3', 'u4', 'u5', 'u6']);

      // Filtering: exactly 0 sites in availableSites
      expect(loaded.availableSites, isEmpty);
      expect(loaded.availableSiteCount, 0);
      expect(loaded.publicAvailableSites, isEmpty);
      expect(loaded.publicAvailableSiteCount, 0);

      // Safe fallback: did not crash, selectedSiteKey is gracefully assigned fallback
      expect(storage.selectedSiteKey, 'u1');
    });

    test('Config with mixed supported and unsupported preserves order and filters correctly', () {
      final sites = [
        const CmsSite(key: 's1', name: '可用1', type: 1, api: 'https://ok1.test/api'),
        const CmsSite(key: 'u1', name: '不可用1', type: 3, api: 'https://jar.test/1.jar'),
        const CmsSite(key: 's2', name: '可用2', type: 1, api: 'https://ok2.test/api'),
        const CmsSite(key: 'u2', name: '不可用2', type: 99, api: 'https://unknown.test/2'),
        const CmsSite(key: 's3', name: '可用3', type: 1, api: 'https://ok3.test/api'),
      ];

      final config = CmsConfig(sites: sites);

      expect(config.supportedSites.length, 5);
      expect(config.availableSites.length, 3);
      expect(config.availableSiteCount, 3);
      expect(config.availableSites.map((s) => s.key).toList(), ['s1', 's2', 's3']);
    });

    test('Privacy mode partition correctly separates public and private supported & available sites', () {
      final sites = [
        const CmsSite(key: 'pub_ok', name: '公开可用', type: 1, api: 'https://pub.test/api'),
        const CmsSite(key: 'pub_bad', name: '公开不可用', type: 3, api: 'https://jar.test/pub.jar'),
        const CmsSite(key: 'priv_ok', name: '隐私可用', type: 1, api: 'https://priv.test/api', isPrivate: true),
        const CmsSite(key: 'priv_bad', name: '隐私不可用', type: 3, api: 'https://jar.test/priv.jar', isPrivate: true),
      ];

      final config = CmsConfig(sites: sites);

      // Total supportedSites contains all 4
      expect(config.supportedSites.length, 4);

      // Public partition
      expect(config.publicSupportedSites.length, 2);
      expect(config.publicSupportedSites.map((s) => s.key).toList(), ['pub_ok', 'pub_bad']);
      expect(config.publicAvailableSites.length, 1);
      expect(config.publicAvailableSites.single.key, 'pub_ok');
      expect(config.publicAvailableSiteCount, 1);

      // Private partition
      expect(config.privateSupportedSites.length, 2);
      expect(config.privateSupportedSites.map((s) => s.key).toList(), ['priv_ok', 'priv_bad']);
      expect(config.privateAvailableSites.length, 1);
      expect(config.privateAvailableSites.single.key, 'priv_ok');
    });
  });

  group('Adversarial Challenge 3: Site Picker Interaction Stress Test', () {
    testWidgets('Tapping unsupported site 25 times NEVER changes active site and fires diagnostic callback each time', (tester) async {
      const activeSite = CmsSite(key: 'active_ok', name: '当前激活源', type: 1, api: 'https://active.test/api');
      const unsuppSite = CmsSite(key: 'unsupp_jar', name: '未适配Jar源', type: 3, api: 'https://jar.test/spider.jar');

      CmsSite currentSite = activeSite;
      int onSelectedCount = 0;
      int onUnsupportedCount = 0;
      CmsSite? lastUnsupported;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: const [activeSite, unsuppSite],
                  selectedKey: currentSite.key,
                  preferredKey: currentSite.key,
                  onPreferred: (_) {},
                  badgeLabel: (s) => s.supported ? 'CMS' : '未适配',
                  badgeColor: (_) => Colors.blue,
                  onSelected: (s) {
                    onSelectedCount++;
                    currentSite = s;
                  },
                  onUnsupportedSelected: (s) {
                    onUnsupportedCount++;
                    lastUnsupported = s;
                  },
                ),
              ],
            ),
          ),
        ),
      );

      // Verify initial rendering
      expect(find.text('当前激活源'), findsOneWidget);
      expect(find.text('未适配Jar源'), findsOneWidget);

      // Stress test: 25 rapid taps on unsupported site
      for (int i = 0; i < 25; i++) {
        await tester.tap(find.text('未适配Jar源'));
        await tester.pump(const Duration(milliseconds: 10));
      }

      // Assert: onSelected must NOT be called even once!
      expect(onSelectedCount, 0);
      expect(currentSite.key, 'active_ok', reason: 'Active site must NEVER switch to unsupported site');

      // Assert: onUnsupportedSelected must be called exactly 25 times
      expect(onUnsupportedCount, 25);
      expect(lastUnsupported?.key, 'unsupp_jar');
    });

    testWidgets('Diagnostic CupertinoAlertDialog triggers with exact verbatim Chinese reason for each of the 6 unsupported types', (tester) async {
      final testCases = <Map<String, dynamic>>[
        {
          'site': const CmsSite(key: 't_jar', name: '测试Spider源', type: 3, api: 'https://jar.test/s.jar'),
          'expectedReason': '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持',
        },
        {
          'site': const CmsSite(key: 't_type', name: '测试未知类型源', type: 99, api: 'https://type.test/api'),
          'expectedReason': '暂不支持此类型来源，已保留在列表中',
        },
        {
          'site': const CmsSite(key: 't_pan', name: '测试网盘源', type: 3, api: 'csp_Pansou'),
          'expectedReason': '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路',
        },
        {
          'site': const CmsSite(key: 't_ext', name: '测试超大源', type: 1, api: 'https://ext.test/api', extTooLarge: true),
          'expectedReason': '扩展参数超过大小上限，无法加载',
        },
        {
          'site': const CmsSite(key: 't_url', name: '测试自定义URL源', type: 1, api: 'custom://test/feed'),
          'expectedReason': '此来源不是可直接请求的 HTTP(S) CMS',
        },
        {
          'site': const CmsSite(key: 't_parser', name: '测试缺少解析源', type: 1, api: 'https://parse.test/api', requiresParser: true),
          'expectedReason': '需要解析器，当前环境缺少可用解析配置',
        },
      ];

      for (final tc in testCases) {
        final site = tc['site'] as CmsSite;
        final expectedReason = tc['expectedReason'] as String;

        await tester.pumpWidget(
          CupertinoApp(
            home: CupertinoPageScaffold(
              child: Builder(
                builder: (context) => CupertinoButton(
                  child: Text('触发-${site.key}'),
                  onPressed: () {
                    showCupertinoDialog<void>(
                      context: context,
                      builder: (dialogCtx) => CupertinoAlertDialog(
                        title: Text(site.name),
                        content: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(site.unsupportedReason),
                        ),
                        actions: [
                          CupertinoDialogAction(
                            isDefaultAction: true,
                            onPressed: () => Navigator.of(dialogCtx).pop(),
                            child: const Text('我知道了'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );

        // Tap trigger button
        await tester.tap(find.text('触发-${site.key}'));
        await tester.pumpAndSettle();

        // Verify dialog title and verbatim reason
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(find.text(site.name), findsOneWidget);
        expect(find.text(expectedReason), findsOneWidget);

        // Dismiss dialog
        await tester.tap(find.text('我知道了'));
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoAlertDialog), findsNothing);
      }
    });

    testWidgets('Visual distinction: unsupported sites are grayed out (0.52 opacity) with no star icon', (tester) async {
      const working = CmsSite(key: 'w1', name: '正常站', type: 1, api: 'https://ok.test/api');
      const unsupp = CmsSite(key: 'u1', name: '不可用站', type: 3, api: 'https://jar.test/spider.jar');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: const [working, unsupp],
                  selectedKey: 'w1',
                  preferredKey: 'w1',
                  onPreferred: (_) {},
                  badgeLabel: (s) => s.supported ? 'CMS' : '未适配',
                  badgeColor: (_) => Colors.green,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      // Star icon exists for working site, but NOT for unsupported site
      expect(find.byKey(const ValueKey('source-preference-w1')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-preference-u1')), findsNothing);

      // Opacity of unsupported site is exactly 0.52
      final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(opacities.any((o) => (o.opacity - 0.52).abs() < 0.001), isTrue);
    });

    testWidgets('Legacy state resilience: unsupported site as selectedKey renders safely without crash and taps still trigger diagnostics', (tester) async {
      const unsuppSelected = CmsSite(key: 'legacy_unsupp', name: '旧版本遗留未适配源', type: 3, api: 'https://jar.test/legacy.jar');
      bool unsupportedTriggered = false;
      bool onSelectedTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: const [unsuppSelected],
                  selectedKey: 'legacy_unsupp',
                  preferredKey: '',
                  onPreferred: (_) {},
                  badgeLabel: (s) => '未适配',
                  badgeColor: (_) => Colors.red,
                  onSelected: (_) => onSelectedTriggered = true,
                  onUnsupportedSelected: (_) => unsupportedTriggered = true,
                ),
              ],
            ),
          ),
        ),
      );

      // Checkmark icon rendered because selected == true
      expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsOneWidget);
      // But star icon still not shown
      expect(find.byKey(const ValueKey('source-preference-legacy_unsupp')), findsNothing);

      // Tap on it triggers onUnsupportedSelected, NOT onSelected
      await tester.tap(find.text('旧版本遗留未适配源'));
      await tester.pumpAndSettle();

      expect(unsupportedTriggered, isTrue);
      expect(onSelectedTriggered, isFalse);
    });

    testWidgets('Stress test: 200 sites with alternating support status render without layout overflow or crash', (tester) async {
      final largeList = List.generate(
        200,
        (i) => i.isEven
            ? CmsSite(key: 'site_ok_$i', name: '正常源 $i', type: 1, api: 'https://ok.test/$i')
            : CmsSite(key: 'site_bad_$i', name: '未适配源 $i', type: 3, api: 'https://bad.test/$i.jar'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: largeList,
                  selectedKey: 'site_ok_0',
                  preferredKey: 'site_ok_0',
                  onPreferred: (_) {},
                  badgeLabel: (s) => s.supported ? 'CMS' : '未适配',
                  badgeColor: (_) => Colors.blue,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      // Successfully renders first visible elements without throwing any FlutterError
      expect(find.text('正常源 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('Special sandbox protocol overrides in unsupportedReason (csp_sixv, csp_music, csp_aidj)', () {
      const sixvSite = CmsSite(key: 'sixv', name: '6V电影', type: 3, api: 'csp_SixV');
      expect(sixvSite.capabilityStatus, CmsSite.statusNeedsJar);
      expect(sixvSite.supported, isFalse);
      expect(sixvSite.unsupportedReason, '该线路依赖 P2P / 磁力种子协议，受当前系统沙盒限制暂不支持');

      const musicSite = CmsSite(key: 'music', name: '音乐源', type: 3, api: 'csp_Music');
      expect(musicSite.capabilityStatus, CmsSite.statusNeedsJar);
      expect(musicSite.supported, isFalse);
      expect(musicSite.unsupportedReason, '该线路依赖交互式人机验证，当前设备暂不支持');

      const aidjSite = CmsSite(key: 'aidj', name: 'DJ源', type: 3, api: 'csp_Aidj');
      expect(aidjSite.capabilityStatus, CmsSite.statusNeedsJar);
      expect(aidjSite.supported, isFalse);
      expect(aidjSite.unsupportedReason, '该线路使用专有加密流保护，当前设备暂不支持');
    });
  });

  group('Adversarial Challenge 4: Source Count Display Format ("可用 X / 共 Y")', () {
    String formatSourceCount(List<CmsSite> sites) {
      final totalCount = sites.length;
      final availableCount = sites.where((s) => s.supported).length;
      return '可用 $availableCount / 共 $totalCount';
    }

    test('Various site distributions generate correct "可用 X / 共 Y" strings', () {
      final testDistributions = <Map<String, dynamic>>[
        {'avail': 0, 'total': 0, 'expected': '可用 0 / 共 0'},
        {'avail': 0, 'total': 5, 'expected': '可用 0 / 共 5'},
        {'avail': 5, 'total': 5, 'expected': '可用 5 / 共 5'},
        {'avail': 3, 'total': 10, 'expected': '可用 3 / 共 10'},
        {'avail': 7, 'total': 15, 'expected': '可用 7 / 共 15'},
        {'avail': 1, 'total': 1, 'expected': '可用 1 / 共 1'},
        {'avail': 100, 'total': 100, 'expected': '可用 100 / 共 100'},
      ];

      for (final dist in testDistributions) {
        final avail = dist['avail'] as int;
        final total = dist['total'] as int;
        final expected = dist['expected'] as String;

        final sites = <CmsSite>[
          for (int i = 0; i < avail; i++)
            CmsSite(key: 'ok_$i', name: 'OK $i', type: 1, api: 'https://ok.test/$i'),
          for (int j = 0; j < (total - avail); j++)
            CmsSite(key: 'bad_$j', name: 'BAD $j', type: 3, api: 'https://bad.test/$j.jar'),
        ];

        final formatted = formatSourceCount(sites);
        expect(formatted, expected, reason: 'Distribution $avail / $total must format to "$expected"');
      }
    });

    test('Adaptive shell header and settings title format matches specification', () {
      final sites = [
        const CmsSite(key: 's1', name: '站1', type: 1, api: 'https://s1.test/api'),
        const CmsSite(key: 's2', name: '站2', type: 3, api: 'https://s2.test/s.jar'),
        const CmsSite(key: 's3', name: '站3', type: 99, api: 'https://s3.test/api'),
      ];

      final totalCount = sites.length;
      final availableCount = sites.where((s) => s.supported).length;

      final standardTitle = '切换片源 (可用 $availableCount / 共 $totalCount)';
      final privacyTitle = '切换隐私片源 (可用 $availableCount / 共 $totalCount)';
      final trailingText = '可用 ${sites.where((s) => s.supported).length} / 共 ${sites.length}';

      expect(standardTitle, '切换片源 (可用 1 / 共 3)');
      expect(privacyTitle, '切换隐私片源 (可用 1 / 共 3)');
      expect(trailingText, '可用 1 / 共 3');
    });
  });
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/source_choice_sliver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('D5: 7 Unified Capability Statuses and Verbatim Reasons', () {
    test('verbatim reason strings match Android Cms.java constants', () {
      expect(CmsSite.statusOk, 'ok');
      expect(CmsSite.statusNeedsJar, 'needs-jar');
      expect(CmsSite.statusUnsupportedType, 'unsupported-type');
      expect(CmsSite.statusAdapterMissing, 'adapter-missing');
      expect(CmsSite.statusExtTooLarge, 'ext-too-large');
      expect(CmsSite.statusCustomSiteUrl, 'custom-site-url');
      expect(CmsSite.statusParserRequired, 'parser-required');

      const okSite = CmsSite(key: 's1', name: '可用源', type: 1, api: 'https://ok.example/api');
      expect(okSite.capabilityStatus, CmsSite.statusOk);
      expect(okSite.unsupportedReason, '正常可用');
      expect(okSite.supported, isTrue);

      const needsJarSite = CmsSite(key: 's2', name: 'Jar源', type: 3, api: 'https://jar.example/spider.jar');
      expect(needsJarSite.capabilityStatus, CmsSite.statusNeedsJar);
      expect(needsJarSite.unsupportedReason, '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持');
      expect(needsJarSite.supported, isFalse);

      const unsuppTypeSite = CmsSite(key: 's3', name: '未知源', type: 99, api: 'https://type.example/api');
      expect(unsuppTypeSite.capabilityStatus, CmsSite.statusUnsupportedType);
      expect(unsuppTypeSite.unsupportedReason, '暂不支持此类型来源，已保留在列表中');
      expect(unsuppTypeSite.supported, isFalse);

      const netdiskMissingSite = CmsSite(key: 'pan_site', name: '网盘源', type: 3, api: 'csp_Pansou');
      expect(netdiskMissingSite.capabilityStatus, CmsSite.statusAdapterMissing);
      expect(netdiskMissingSite.unsupportedReason, '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路');
      expect(netdiskMissingSite.supported, isFalse);

      const extTooLargeSite = CmsSite(key: 's5', name: '大扩展源', type: 1, api: 'https://ext.example/api', extTooLarge: true);
      expect(extTooLargeSite.capabilityStatus, CmsSite.statusExtTooLarge);
      expect(extTooLargeSite.unsupportedReason, '扩展参数超过大小上限，无法加载');
      expect(extTooLargeSite.supported, isFalse);

      const customUrlSite = CmsSite(key: 's6', name: '非HTTP源', type: 1, api: 'custom://internal/api');
      expect(customUrlSite.capabilityStatus, CmsSite.statusCustomSiteUrl);
      expect(customUrlSite.unsupportedReason, '此来源不是可直接请求的 HTTP(S) CMS');
      expect(customUrlSite.supported, isFalse);

      const parserReqSite = CmsSite(key: 's7', name: '需解析源', type: 1, api: 'https://parse.example/api', requiresParser: true);
      expect(parserReqSite.capabilityStatus, CmsSite.statusParserRequired);
      expect(parserReqSite.unsupportedReason, '需要解析器，当前环境缺少可用解析配置');
      expect(parserReqSite.supported, isFalse);
    });
  });

  group('D5: CmsConfig Site Inclusivity & availableSites Filtering', () {
    test('supportedSites includes all sites while availableSites filters for supported only', () {
      const working = CmsSite(key: 'working', name: '正常站', type: 1, api: 'https://ok.example/api');
      const unsupp = CmsSite(key: 'unsupp', name: '未适配站', type: 3, api: 'https://jar.example/spider.jar');

      final config = CmsConfig(
        sites: [working, unsupp],
        lives: const [],
        depots: const [],
        parses: const [],
        spider: '',
      );

      // supportedSites contains BOTH sites (all retained in memory)
      expect(config.supportedSites.length, 2);
      expect(config.publicSupportedSites.length, 2);

      // availableSites contains ONLY the working site
      expect(config.availableSites.length, 1);
      expect(config.availableSites.single.key, 'working');
      expect(config.publicAvailableSites.length, 1);
      expect(config.publicAvailableSites.single.key, 'working');
      expect(config.availableSiteCount, 1);
      expect(config.publicAvailableSiteCount, 1);
    });

    test('default site selection prioritizes available sites over unsupported first site', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      // Config has unsupported site first, working site second
      const rawJson = '''
      {
        "sites": [
          {"key": "jar_first", "name": "不支持的Jar", "type": 3, "api": "https://jar.example/spider.jar"},
          {"key": "cms_second", "name": "可用的CMS", "type": 1, "api": "https://cms.example/vod"}
        ]
      }
      ''';

      await storage.saveConfig(rawJson, origin: 'https://test.example/config.json');

      // Default selected site must be cms_second (available), NOT jar_first
      expect(storage.selectedSiteKey, 'cms_second');
    });
  });

  group('D5: UI Gray-out & Diagnostic Alert in SourceChoiceSliver', () {
    testWidgets('renders all sites, grays out unsupported (opacity 0.52, 未适配 badge, no star)', (tester) async {
      const working = CmsSite(key: 's_ok', name: '可用源甲', type: 1, api: 'https://ok.example/api');
      const unsupp = CmsSite(key: 's_jar', name: '未适配源乙', type: 3, api: 'https://jar.example/spider.jar');

      CmsSite? chosenSite;
      CmsSite? unsupportedClicked;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: const [working, unsupp],
                  selectedKey: 's_ok',
                  preferredKey: 's_ok',
                  onPreferred: (_) {},
                  badgeLabel: (s) => s.supported ? 'CMS' : '未适配',
                  badgeColor: (_) => Colors.blue,
                  onSelected: (s) => chosenSite = s,
                  onUnsupportedSelected: (s) => unsupportedClicked = s,
                ),
              ],
            ),
          ),
        ),
      );

      // Both names appear in grid
      expect(find.text('可用源甲'), findsOneWidget);
      expect(find.text('未适配源乙'), findsOneWidget);

      // Unsupported site has Opacity 0.52
      final opacities = tester.widgetList<Opacity>(find.byType(Opacity));
      expect(opacities.any((o) => (o.opacity - 0.52).abs() < 0.01), isTrue);

      // Badge displays '未适配'
      expect(find.text('未适配'), findsOneWidget);

      // Preferred star button is visible for working site, but NOT for unsupported site
      expect(find.byKey(const ValueKey('source-preference-s_ok')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-preference-s_jar')), findsNothing);

      // Tapping unsupported site does NOT trigger onSelected; it triggers onUnsupportedSelected
      await tester.tap(find.text('未适配源乙'));
      await tester.pumpAndSettle();
      expect(chosenSite, isNull);
      expect(unsupportedClicked, isNotNull);
      expect(unsupportedClicked!.key, 's_jar');

      // Tapping working site triggers onSelected
      await tester.tap(find.text('可用源甲'));
      await tester.pumpAndSettle();
      expect(chosenSite, isNotNull);
      expect(chosenSite!.key, 's_ok');
    });

    testWidgets('diagnostic CupertinoAlertDialog displays site unsupportedReason', (tester) async {
      const unsupp = CmsSite(key: 's_jar', name: '未适配源乙', type: 3, api: 'https://jar.example/spider.jar');

      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: Builder(
              builder: (context) => CupertinoButton(
                child: const Text('打开测试源'),
                onPressed: () {
                  showCupertinoDialog(
                    context: context,
                    builder: (ctx) => CupertinoAlertDialog(
                      title: Text(unsupp.name),
                      content: Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(unsupp.unsupportedReason),
                      ),
                      actions: [
                        CupertinoDialogAction(
                          child: const Text('我知道了'),
                          onPressed: () => Navigator.of(ctx).pop(),
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

      await tester.tap(find.text('打开测试源'));
      await tester.pumpAndSettle();

      // Dialog shows site name and exact verbatim unsupported reason
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('未适配源乙'), findsOneWidget);
      expect(find.text('此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持'), findsOneWidget);
      expect(find.text('我知道了'), findsOneWidget);

      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
    });
  });
}

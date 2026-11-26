import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/add_resource_library_sheet.dart';
import 'package:marco_movie/ui/ios_filter_sheet.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FilteringFixtureClient extends CmsClient {
  _FilteringFixtureClient()
      : super(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

  final List<({String catId, int page, CmsFilter? filter})> requests = [];

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const <CmsCategory>[
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '11', name: '动作片'),
        CmsCategory(id: '12', name: '超长分类名称测试自动换行展示'),
        CmsCategory(id: '2', name: '剧集'),
      ],
      const CmsListing(
        page: 1,
        pageCount: 2,
        videos: [
          CmsVideo(id: 'home1', title: '初始推荐电影', year: '2024'),
        ],
      ),
    );
  }

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    requests.add((catId: categoryId, page: page, filter: filter));
    if (filter?.categoryId == '11' &&
        filter?.area == '日本' &&
        filter?.year == '2024') {
      return const CmsListing(
        page: 1,
        pageCount: 1,
        sourceFiltered: true,
        videos: [
          CmsVideo(
            id: 'filtered_jp_2024',
            title: '实测筛选命中的动作电影',
            area: '日本',
            year: '2024',
          ),
        ],
      );
    }
    return const CmsListing(
      page: 1,
      pageCount: 1,
      sourceFiltered: true,
      videos: [
        CmsVideo(id: 'base1', title: '基础片库影片', year: '2023'),
      ],
    );
  }
}

Future<StorageService> _initStorage({bool empty = false}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'onboarding_done_version': 1,
  });
  final storage = await StorageService.init();
  if (!empty) {
    await storage.saveConfig(
      '{"sites":['
      '{"key":"s1","name":"主力源A","type":1,"api":"https://a.example/api","group":"主分组"},'
      '{"key":"s2","name":"主力源B","type":1,"api":"https://b.example/api","group":"主分组"},'
      '{"key":"s3","name":"备用源C","type":1,"api":"https://c.example/api","group":"备分组"}'
      '],"urls":['
      '{"name":"一号仓","url":"https://d1.example/tv.json"},'
      '{"name":"二号仓","url":"https://d2.example/tv.json"}'
      ']}',
    );
  }
  return storage;
}

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('Req 3 — Redesigned iOS Home catalog filter sheet', () {
    testWidgets(
      'Flutter fallback filter sheet shows 1 dimension at a time, draft/reset/cancel without reload, apply-once with real videos, and responsive column reduction on narrow & iPad Split View',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        // Narrow iPhone SE width (320x568)
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _initStorage();
        final client = _FilteringFixtureClient();
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Scroll past immersive hero & curated shelf to reveal 电影 tab & 筛选 button on 320x568
        final homeScroll = find.byType(CustomScrollView).first;
        for (var i = 0; i < 24 && find.byKey(const ValueKey('home-filter-button')).evaluate().isEmpty; i++) {
          await tester.drag(homeScroll, const Offset(0, -240));
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tester.ensureVisible(find.text('电影').first);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.text('电影').first);
        await tester.pump(const Duration(milliseconds: 400));
        client.requests.clear();

        // Open filter modal
        await tester.ensureVisible(find.byKey(const ValueKey('home-filter-button')));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byKey(const ValueKey('home-filter-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        // Top row has ONLY title "片库筛选" and Close button
        expect(find.byKey(const ValueKey('ios-catalog-filter-sheet')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-filter-title')), findsOneWidget);
        expect(find.text('片库筛选'), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-filter-close-button')), findsOneWidget);

        // Narrow 320px phone automatically uses 2 equal-width columns
        expect(find.byKey(const ValueKey('ios-filter-grid-cols-2')), findsOneWidget);

        // Only 类别 options are visible initially (地区/年份 options are not visible)
        expect(find.text('动作片'), findsOneWidget);
        expect(find.text('日本'), findsNothing);
        expect(find.text('2024'), findsNothing);

        // Select real category 动作片 -> draft updates summary, ZERO reload yet
        await tester.tap(find.text('动作片'));
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '动作片',
        );
        // Selected tile shows checkmark icon
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('ios-filter-option-cat:cat:11:动作片')),
            matching: find.byIcon(CupertinoIcons.checkmark),
          ),
          findsOneWidget,
        );
        expect(client.requests, isEmpty);

        // Switch to 地区 -> only 地区 options shown (category option gone; summary still shows 动作片) -> pick 日本
        await tester.tap(find.byKey(const ValueKey('ios-filter-dim-1')));
        await tester.pump();
        expect(find.byKey(const ValueKey('ios-filter-option-cat:cat:11:动作片')), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '动作片',
        );
        expect(find.text('日本'), findsOneWidget);
        await tester.tap(find.text('日本'));
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '动作片 · 日本',
        );

        // Switch to 年份 -> pick 2024
        await tester.tap(find.byKey(const ValueKey('ios-filter-dim-2')));
        await tester.pump();
        await tester.tap(find.text('2024'));
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '动作片 · 日本 · 2024',
        );

        // Tap 重置 -> clears ONLY draft, sheet remains open, ZERO reload
        await tester.tap(find.byKey(const ValueKey('ios-filter-reset-button')));
        await tester.pump();
        expect(find.byKey(const ValueKey('ios-catalog-filter-sheet')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '全部',
        );
        expect(client.requests, isEmpty);

        // Close via × -> cancels cleanly with ZERO reload
        await tester.tap(find.byKey(const ValueKey('ios-filter-close-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byKey(const ValueKey('ios-catalog-filter-sheet')), findsNothing);
        expect(client.requests, isEmpty);

        // Re-open, select 动作片 + 日本 + 2024, tap 应用 -> reloads ONCE with page 1
        await tester.tap(find.byKey(const ValueKey('home-filter-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('动作片'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ios-filter-dim-1')));
        await tester.pump();
        await tester.tap(find.text('日本'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ios-filter-dim-2')));
        await tester.pump();
        await tester.tap(find.text('2024'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ios-filter-apply-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(client.requests.length, 1);
        expect(client.requests.single.page, 1);
        expect(client.requests.single.filter?.categoryId, '11');
        expect(client.requests.single.filter?.genreLabel, isEmpty);
        expect(client.requests.single.filter?.area, '日本');
        expect(client.requests.single.filter?.year, '2024');
        expect(find.text('实测筛选命中的动作电影'), findsWidgets);

        // Re-open filter sheet: echoes current selection; tap 应用 unchanged -> ZERO reload
        client.requests.clear();
        await tester.tap(find.byKey(const ValueKey('home-filter-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '动作片 · 日本 · 2024',
        );
        await tester.tap(find.byKey(const ValueKey('ios-filter-apply-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(client.requests, isEmpty);

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test('computeIosFilterColumnCount reduces columns on narrow phone, large text scale & iPad Split View', () {
      expect(computeIosFilterColumnCount(availableWidth: 288, textScale: 1.0), 2);
      expect(computeIosFilterColumnCount(availableWidth: 360, textScale: 1.0), 3);
      expect(computeIosFilterColumnCount(availableWidth: 360, textScale: 1.4), 2);
      expect(computeIosFilterColumnCount(availableWidth: 500, textScale: 1.0), 4);
      expect(computeIosFilterColumnCount(availableWidth: 220, textScale: 1.5), 1);
    });
  });

  group('Req 4 — Bottom Dock & Home top-right menu division + >=44pt targets & VoiceOver', () {
    testWidgets(
      'Flutter fallback: top-right buttons tap opens picker/config-center, long-press opens scoped menus, and hit targets >= 44x44pt',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _initStorage();
        final client = _FilteringFixtureClient();
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        final sourceBtn = find.byKey(const ValueKey('home-source-button'));
        final depotBtn = find.byKey(const ValueKey('home-depot-button'));
        final configBtn = find.byKey(const ValueKey('home-netdisk-button'));
        expect(sourceBtn, findsOneWidget);
        expect(depotBtn, findsOneWidget);
        expect(configBtn, findsOneWidget);

        // Verify >= 44x44 pt hit targets
        for (final f in [sourceBtn, depotBtn, configBtn]) {
          final size = tester.getSize(f);
          expect(size.width, greaterThanOrEqualTo(44.0));
          expect(size.height, greaterThanOrEqualTo(44.0));
        }

        // Long-press 切换片源 -> shows current group sites (主分组) + 管理片源, NOT 备用源C
        await tester.longPress(sourceBtn);
        await tester.pump(const Duration(milliseconds: 200));
        final sourceMenu = find.byKey(const ValueKey('home-source-longpress-menu'));
        expect(sourceMenu, findsOneWidget);
        expect(find.descendant(of: sourceMenu, matching: find.text('管理片源')), findsOneWidget);
        expect(find.descendant(of: sourceMenu, matching: find.text('主力源B')), findsOneWidget);
        expect(find.descendant(of: sourceMenu, matching: find.text('备用源C')), findsNothing);
        // Dismiss menu by tapping barrier
        await tester.tapAt(const Offset(10, 700));
        await tester.pump(const Duration(milliseconds: 150));
        expect(sourceMenu, findsNothing);

        // Long-press 配置中心 -> shows exact 3 direct shortcuts
        await tester.longPress(configBtn);
        await tester.pump(const Duration(milliseconds: 200));
        final cfgMenu = find.byKey(const ValueKey('home-config-center-longpress-menu'));
        expect(cfgMenu, findsOneWidget);
        expect(find.descendant(of: cfgMenu, matching: find.text('添加资源库')), findsOneWidget);
        expect(find.descendant(of: cfgMenu, matching: find.text('管理订阅')), findsOneWidget);
        expect(find.descendant(of: cfgMenu, matching: find.text('网盘账号')), findsOneWidget);
        await tester.tapAt(const Offset(10, 700));
        await tester.pump(const Duration(milliseconds: 150));

        // Tap 配置中心 -> opens unified Config Center page with Resource Library & Sub entries
        await tester.tap(configBtn);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('config-center-unified-management-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('config-center-add-library-btn')), findsOneWidget);
        expect(find.byKey(const ValueKey('config-center-manage-subs-btn')), findsOneWidget);
        expect(find.byKey(const ValueKey('config-center-sync-all-btn')), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('Req 6 — Zero iOS clipboard quick-import UI or proactive reads', () {
    testWidgets(
      'Home empty state, Add Resource Library, Manual Import, and Subscription Manager have zero clipboard quick import and never call Clipboard.getData on iOS',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var clipboardReadCount = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            clipboardReadCount++;
            return const <String, dynamic>{'text': 'https://clipboard.example/tv.json'};
          }
          return null;
        });

        final storage = await _initStorage(empty: true);
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: _FilteringFixtureClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Home empty state must NOT show 一键粘贴剪贴板并导入
        expect(find.text('一键粘贴剪贴板并导入'), findsNothing);
        expect(clipboardReadCount, 0);

        // Open Add Resource Library from empty Home
        await tester.ensureVisible(find.text('导入配置地址或 JSON'));
        await tester.pump();
        await tester.tap(find.text('导入配置地址或 JSON'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const ValueKey('add-resource-library-hub')), findsOneWidget);
        expect(find.text('剪贴板快导'), findsNothing);
        expect(clipboardReadCount, 0);

        // Open Manual Import form: zero programmatic 粘贴 button reading Clipboard.getData
        await tester.ensureVisible(find.byKey(const ValueKey('add-lib-tile-manualInput')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('add-lib-tile-manualInput')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('粘贴'), findsNothing);
        expect(clipboardReadCount, 0);

        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('Req 7 — Add Resource Library 4-group layout & alignment', () {
    testWidgets(
      'Single title, zero slogan/scatter, exact 4 groups, aligned left edges, 64pt icons, responsive columns across narrow phone & iPad Split View',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();

        for (final size in <Size>[const Size(320, 568), const Size(507, 900)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            MaterialApp(
              home: IosSettingsScaffold(
                title: '添加资源库',
                body: AddResourceLibraryView(
                  storage: storage,
                  client: _FilteringFixtureClient(),
                  onLibraryAdded: () {},
                ),
              ),
            ),
          );
          await tester.pump();

          // Strictly ONE title, NO slogan, NO 配置中心 tile, NO 剪贴板快导 tile
          expect(find.text('添加资源库'), findsOneWidget);
          expect(find.textContaining('自动识别并管理'), findsNothing);
          expect(find.text('配置中心'), findsNothing);
          expect(find.text('剪贴板快导'), findsNothing);

          // Exact 4 groups in top-to-bottom order
          final g0 = tester.getTopLeft(find.text('媒体服务器'));
          final g1 = tester.getTopLeft(find.text('网络存储'));
          final g2 = tester.getTopLeft(find.text('个人网盘'));
          final g3 = tester.getTopLeft(find.text('本机与订阅'));
          expect(g0.dy, lessThan(g1.dy));
          expect(g1.dy, lessThan(g2.dy));
          expect(g2.dy, lessThan(g3.dy));

          // Left edges of all 4 groups align strictly
          expect((g0.dx - g1.dx).abs(), lessThan(0.5));
          expect((g1.dx - g2.dx).abs(), lessThan(0.5));
          expect((g2.dx - g3.dx).abs(), lessThan(0.5));

          // Leftmost tile of every group aligns with the group header left edge
          final embyLeft = tester.getTopLeft(find.byKey(const ValueKey('add-lib-tile-emby'))).dx;
          final davLeft = tester.getTopLeft(find.byKey(const ValueKey('add-lib-tile-webdav'))).dx;
          final quarkLeft = tester.getTopLeft(find.byKey(const ValueKey('add-lib-tile-quarkDrive'))).dx;
          final localLeft = tester.getTopLeft(find.byKey(const ValueKey('add-lib-tile-localDevice'))).dx;
          expect((embyLeft - g0.dx).abs(), lessThan(0.5));
          expect((davLeft - g1.dx).abs(), lessThan(0.5));
          expect((quarkLeft - g2.dx).abs(), lessThan(0.5));
          expect((localLeft - g3.dx).abs(), lessThan(0.5));

          // Responsive column count check
          final expectedCols = size.width < 360 ? 2 : 3;
          expect(
            find.byKey(ValueKey('add-lib-section-0-cols-$expectedCols')),
            findsOneWidget,
          );

          // Zero overflow exceptions
          expect(tester.takeException(), isNull);
        }

        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

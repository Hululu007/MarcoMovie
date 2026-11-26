import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_settings.dart';

/// 0.7.9 iOS Settings information architecture:
/// 内容与来源 → 播放 → 外观与主页 → 数据与存储 → 通用, with exactly one entry
/// per function / page inside Settings and a search index that resolves to
/// that single canonical entry.
void main() {
  const expectedRootIds = [
    'sources',
    'netdisk',
    'extensions',
    'picture',
    'episodes',
    'skip',
    'danmu',
    'hud',
    'appearance',
    'cards',
    'home',
    'sync',
    'backup',
    'cache',
    'about',
  ];
  const expectedGroups = [
    'ia-content',
    'ia-playback',
    'ia-display',
    'ia-data',
    'ia-general',
  ];
  const expectedHeaders = ['内容与来源', '播放', '外观与主页', '数据与存储', '通用'];

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Marco Movie',
      packageName: 'test',
      version: '0.7.9',
      buildNumber: '79',
      buildSignature: '',
    );
  });

  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.saveConfig(
      '{"sites":[{"key":"test","name":"测试片源","type":1,"api":"https://source.example/api"}]}',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.fromLTRB(0, 44, 0, 34),
          ),
          child: child!,
        ),
        home: AdaptiveShell(
          storage: storage,
          client: CmsClient(
            client: MockClient(
              (_) async => http.Response('{"class":[],"list":[]}', 200),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  List<SettingsPane> rootPanes(WidgetTester tester) =>
      tester.widget<IosSettingsPage>(find.byType(IosSettingsPage)).pages(() {});

  Finder searchField() => find.descendant(
        of: find.byKey(const ValueKey('ios-settings-search')),
        matching: find.byType(EditableText),
      );

  testWidgets(
    'iOS Settings root shows the IA groups in order with one row per canonical entry',
    (tester) async {
      await openSettings(tester);

      final roots = rootPanes(tester);
      expect(roots.map((p) => p.id).toList(), expectedRootIds);

      final groups = <String>[];
      for (final pane in roots) {
        if (groups.isEmpty || groups.last != pane.sectionGroup) {
          groups.add(pane.sectionGroup);
        }
      }
      expect(groups, expectedGroups,
          reason: 'each IA group must be contiguous and appear once');

      // No title (function / page) is listed twice anywhere in the pane tree.
      final titles = <String>[];
      void collect(List<SettingsPane> panes) {
        for (final p in panes) {
          titles.add(p.title);
          collect(p.children);
        }
      }

      collect(roots);
      expect(titles.toSet().length, titles.length);

      // Every root row is rendered exactly once, top-to-bottom in IA order.
      final root = find.byKey(const ValueKey('ios-settings-root'));
      var lastY = double.negativeInfinity;
      for (final id in expectedRootIds) {
        final row = find.byKey(ValueKey('settings-category-$id'));
        expect(row, findsOneWidget, reason: 'root row $id');
        final y = tester.getTopLeft(row).dy;
        expect(y, greaterThan(lastY), reason: 'root row $id order');
        lastY = y;
      }

      // Group headers render once each, in order.
      lastY = double.negativeInfinity;
      for (final header in expectedHeaders) {
        final text = find.descendant(of: root, matching: find.text(header));
        expect(text, findsOneWidget, reason: 'header $header');
        final y = tester.getTopLeft(text).dy;
        expect(y, greaterThan(lastY), reason: 'header $header order');
        lastY = y;
      }

      // Removed duplicate/legacy root containers.
      for (final legacy in const ['browsing', 'playback', 'data']) {
        expect(find.byKey(ValueKey('settings-category-$legacy')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'each function has exactly one entry across every Settings sub-page',
    (tester) async {
      await openSettings(tester);

      const textProbes = [
        '重新查看新手引导',
        '添加资源库',
        '订阅与分组管理',
        '导出诊断日志包',
        '官网交流群',
        '官方渠道安全声明',
        '清理缓存与搜索记录',
      ];
      const keyProbes = [
        'ios-check-update-row',
        'ios-replay-onboarding',
        'ios-open-import-subscription',
        'ios-open-subscriptions',
        'ios-about-version',
      ];
      const removedKeys = [
        'ios-open-cloud-sync-shortcut',
        'ios-open-netdisk',
      ];
      final textCounts = {for (final t in textProbes) t: 0};
      final keyCounts = {for (final k in keyProbes) k: 0};

      for (final pane in rootPanes(tester)) {
        if (pane.onOpen != null) continue; // standalone page, checked below
        await tapKey(tester, 'settings-category-${pane.id}');
        final page = find.byKey(ValueKey('settings-page-${pane.id}'));
        expect(page, findsOneWidget, reason: 'sub-page ${pane.id}');
        for (final t in textProbes) {
          textCounts[t] = textCounts[t]! +
              find.descendant(of: page, matching: find.text(t)).evaluate().length;
        }
        for (final k in keyProbes) {
          keyCounts[k] = keyCounts[k]! +
              find
                  .descendant(of: page, matching: find.byKey(ValueKey(k)))
                  .evaluate()
                  .length;
        }
        for (final k in removedKeys) {
          expect(find.descendant(of: page, matching: find.byKey(ValueKey(k))),
              findsNothing,
              reason: '$k must not exist (duplicate entry) in ${pane.id}');
        }
        // Root-level destinations must not be re-listed inside other pages.
        for (final rootTitle in const ['多端同步', '配置中心', '备份与恢复']) {
          expect(
            find.descendant(of: page, matching: find.text(rootTitle)),
            findsNothing,
            reason: '$rootTitle duplicated inside ${pane.id}',
          );
        }
        await tapKey(tester, 'settings-drawer-back');
        expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);
      }

      for (final entry in textCounts.entries) {
        expect(entry.value, 1, reason: '「${entry.key}」 entry count');
      }
      for (final entry in keyCounts.entries) {
        expect(entry.value, 1, reason: '${entry.key} entry count');
      }

      // 重新查看新手引导 / 检查更新 live under 通用 › 关于与更新.
      await tapKey(tester, 'settings-category-about');
      expect(find.byKey(const ValueKey('ios-replay-onboarding')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-check-update-row')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'search resolves keywords to the single canonical entry and navigates to it',
    (tester) async {
      await openSettings(tester);

      await tester.enterText(searchField(), '新手引导');
      await tester.pumpAndSettle();
      expect(find.text('搜索结果 (1)'), findsOneWidget);
      await tapKey(tester, 'settings-search-hit-about');
      expect(find.byKey(const ValueKey('settings-page-about')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-replay-onboarding')), findsOneWidget);
      await tapKey(tester, 'settings-drawer-back');

      await tester.enterText(searchField(), 'WebDAV');
      await tester.pumpAndSettle();
      expect(find.text('搜索结果 (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-search-hit-sync')),
          findsOneWidget);

      await tester.enterText(searchField(), '检查更新');
      await tester.pumpAndSettle();
      expect(find.text('搜索结果 (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-search-hit-about')),
          findsOneWidget);

      await tester.enterText(searchField(), '添加资源库');
      await tester.pumpAndSettle();
      expect(find.text('搜索结果 (1)'), findsOneWidget);
      await tapKey(tester, 'settings-search-hit-sources');
      expect(find.byKey(const ValueKey('settings-page-sources')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios-open-import-subscription')),
          findsOneWidget);
      // Opening 订阅与分组管理 from Settings › 资源库与订阅 must not duplicate 添加资源库.
      await tapKey(tester, 'ios-open-subscriptions');
      expect(find.text('订阅管理'), findsOneWidget);
      expect(find.text('添加'), findsNothing);
      expect(find.text('添加订阅'), findsNothing);
      await tapKey(tester, 'settings-drawer-back');
      await tapKey(tester, 'settings-drawer-back');

      for (final (query, expectedHitKey) in const [
        ('管理订阅', 'settings-search-hit-sources'),
        ('直播源', 'settings-search-hit-sources'),
        ('多端同步', 'settings-search-hit-sync'),
        ('联系反馈作者', 'settings-search-hit-about'),
        ('联系与反馈作者', 'settings-search-hit-about'),
      ]) {
        await tester.enterText(searchField(), query);
        await tester.pumpAndSettle();
        expect(find.text('搜索结果 (1)'), findsOneWidget, reason: 'query=$query');
        expect(find.byKey(ValueKey(expectedHitKey)), findsOneWidget,
            reason: 'query=$query -> $expectedHitKey');
      }

      // 配置中心 is a standalone page opened from its single canonical entry,
      // without re-exposing 添加资源库 / 订阅管理 / CatPaw (owned elsewhere).
      await tester.enterText(searchField(), '扫码');
      await tester.pumpAndSettle();
      expect(find.text('搜索结果 (1)'), findsOneWidget);
      await tapKey(tester, 'settings-search-hit-netdisk');
      expect(find.byKey(const ValueKey('netdisk-account-sheet')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('config-center-unified-management-card')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('config-center-open-catpaw-btn')),
          findsNothing);
      await tapKey(tester, 'settings-drawer-back');
      expect(find.byKey(const ValueKey('ios-settings-root')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

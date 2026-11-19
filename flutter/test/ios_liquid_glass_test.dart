import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'test_storage_helper.dart';

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  testWidgets(
    'portrait Dock renders left 4-tab capsule + right detached circular search button and removes top search icon',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage();
      await storage.saveConfig(
        '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final dockFinder = find.byType(AppleLiquidGlassDock);
      final searchFinder = find.byKey(const ValueKey('home-search-button'));
      expect(dockFinder, findsOneWidget);
      expect(searchFinder, findsOneWidget);

      // Search button lives inside the bottom Dock, to the right of the 4 tabs (not in the top bar).
      final dockRect = tester.getRect(dockFinder);
      final searchRect = tester.getRect(searchFinder);
      final settingsTabRect = tester.getRect(find.text('设置').last);
      expect(searchRect.top, greaterThanOrEqualTo(dockRect.top));
      expect(searchRect.bottom, lessThanOrEqualTo(dockRect.bottom));
      expect(searchRect.left, greaterThan(settingsTabRect.right));
      expect(searchRect.width, closeTo(searchRect.height, 0.5));

      // Verify all 4 tab labels exist inside the Dock.
      for (final label in ['主页', '直播', '片库', '设置']) {
        expect(
          find.descendant(of: dockFinder, matching: find.text(label)),
          findsOneWidget,
        );
      }

      // Tapping the detached circular search button opens Global Search.
      await tester.tap(searchFinder);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppleSearchField), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS 26 native mode mounts UiKitView for Dock, SegmentedControl, and Settings back button',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const dockItems = <(IconData, IconData, String)>[
        (CupertinoIcons.play_rectangle, CupertinoIcons.play_rectangle_fill, '主页'),
        (CupertinoIcons.dot_radiowaves_left_right, CupertinoIcons.dot_radiowaves_left_right, '直播'),
        (CupertinoIcons.square_stack_3d_up, CupertinoIcons.square_stack_3d_up_fill, '片库'),
        (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
      ];
      const nativeItems = <IosNativeDockItem>[
        IosNativeDockItem(label: '主页', symbol: 'play.rectangle', selectedSymbol: 'play.rectangle.fill'),
        IosNativeDockItem(label: '直播', symbol: 'dot.radiowaves.left.and.right'),
        IosNativeDockItem(label: '片库', symbol: 'square.stack.3d.up', selectedSymbol: 'square.stack.3d.up.fill'),
        IosNativeDockItem(label: '设置', symbol: 'gearshape', selectedSymbol: 'gearshape.fill'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                IosNativeSegmentedControl(
                  segments: const ['收藏片单', '观看历史', '离线下载'],
                  selectedIndex: 1,
                  onChanged: (_) {},
                  fallback: const SizedBox.shrink(),
                ),
                IosNativeGlassButton(
                  style: 'circle',
                  symbol: 'chevron.backward',
                  onTap: () {},
                  fallback: const SizedBox.shrink(),
                ),
                IosNativeGlassPill(
                  actions: [
                    IosNativeGlassPillAction(
                      symbol: 'qrcode.viewfinder',
                      accessibilityLabel: '网盘扫码',
                      onTap: () {},
                    ),
                    IosNativeGlassPillAction(
                      symbol: 'heart.fill',
                      color: AppleColors.systemRed,
                      accessibilityLabel: '取消收藏',
                      onTap: () {},
                    ),
                  ],
                  fallback: const SizedBox.shrink(),
                ),
                Expanded(
                  child: IosSettingsScaffold(
                    title: '播放设置',
                    body: const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: AppleLiquidGlassDock(
              selectedIndex: 0,
              onSelect: (_) {},
              isLandscape: false,
              items: dockItems,
              nativeItems: nativeItems,
              onSearch: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final views = tester.widgetList<UiKitView>(find.byType(UiKitView)).toList();
      final types = views.map((v) => v.viewType).toList();
      expect(types, contains('marco_movie/ios26_dock'));
      expect(types, contains('marco_movie/ios26_segmented_control'));
      expect(types, contains('marco_movie/ios26_glass_button'));
      expect(types, contains('marco_movie/ios26_glass_pill'));

      final dockView = views.firstWhere((v) => v.viewType == 'marco_movie/ios26_dock');
      final dockParams = dockView.creationParams as Map<dynamic, dynamic>;
      expect(dockParams['showSearch'], isTrue);
      expect((dockParams['items'] as List).length, 4);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'showAppleNativeAlert and showAppleNativeActionSheet dispatch to UIAlertController channel on iOS 26+',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'showAlert') return 'delete';
        if (call.method == 'showActionSheet') return '1';
        return null;
      });

      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              captured = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final alertRes = await showAppleNativeAlert(
        captured,
        title: '删除确认',
        message: '确定要删除吗？',
        actions: const [
          AppleNativeAlertAction(id: 'cancel', title: '取消', isCancel: true),
          AppleNativeAlertAction(id: 'delete', title: '删除', isDestructive: true),
        ],
      );
      expect(alertRes, 'delete');

      final sheetRes = await showAppleNativeActionSheet<String>(
        captured,
        title: '切换画质',
        options: const [
          AppleNativeSheetOption(value: '1080p', title: '1080P'),
          AppleNativeSheetOption(value: '4k', title: '4K 原画', isDefault: true),
        ],
      );
      expect(sheetRes, '4k');
      expect(calls.map((c) => c.method).toList(), ['showAlert', 'showActionSheet']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

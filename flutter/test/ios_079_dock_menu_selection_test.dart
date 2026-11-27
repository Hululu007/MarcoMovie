import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.7.9 user feedback: "dock 长按某个按钮弹出气泡后，按钮不用悬浮起来；长按气泡
/// 切换了页面后 dock 的选中态也需要对应切换过去。"
class _DockMenuFixtureClient extends CmsClient {
  _DockMenuFixtureClient()
      : super(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const <CmsCategory>[CmsCategory(id: '1', name: '电影')],
      CmsListing(
        page: 1,
        pageCount: 1,
        videos: [
          for (var i = 0; i < 8; i++)
            CmsVideo(id: 'v$i', title: '首页样片 $i', remarks: 'HD', year: '2024'),
        ],
      ),
    );
  }
}

Future<StorageService> _makeStorage() async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'onboarding_done_version': 1,
  });
  final storage = await StorageService.init();
  await storage.saveConfig(
    '{"sites":[{"key":"s1","name":"测试影源","type":1,"api":"https://fixture.example/api"}],'
    '"lives":[{"name":"示例直播","url":"https://live.example/channels.m3u"}]}',
  );
  return storage;
}

Future<void> _sendNativeMenuAction(
  WidgetTester tester,
  int tabIndex,
  String actionId,
) async {
  const codec = StandardMethodCodec();
  final envelope = codec.encodeMethodCall(
    MethodCall('rootTabMenuAction', <String, dynamic>{
      'tabIndex': tabIndex,
      'actionId': actionId,
    }),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(IosLiquidGlassBridge.channel.name, envelope, (_) {});
}

List<Map<String, dynamic>> _selectedIndexCalls(List<MethodCall> calls) => calls
    .where((c) => c.method == 'setRootTabSelectedIndex')
    .map((c) => Map<String, dynamic>.from(c.arguments as Map))
    .toList();

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(false);
    IosRootTabNavigatorObserver.secondaryRouteDepth.value = 0;
    IosRootTabNavigatorObserver.topRouteIsCurated.value = false;
    IosRootTabNavigatorObserver.curatedRouteDepth.value = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  testWidgets(
    'Native iOS 26+ dock: rootTabMenuAction switches page AND pushes setRootTabSelectedIndex with a fresh monotonic epoch',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'configureRootTabChrome') return true;
        return null;
      });

      final storage = await _makeStorage();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [IosRootTabNavigatorObserver()],
          home: AdaptiveShell(storage: storage, client: _DockMenuFixtureClient()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 450));
      expect(calls.any((c) => c.method == 'configureRootTabChrome'), isTrue);
      // Root native chrome owns the Dock: no Flutter fallback Dock is mounted.
      expect(find.byType(AppleLiquidGlassDock), findsNothing);
      expect(find.byKey(const ValueKey('library-open-cloud-sync')), findsNothing);

      // 片库 -> 收藏
      calls.clear();
      await _sendNativeMenuAction(tester, 2, 'favorites');
      await tester.pump(const Duration(milliseconds: 400));
      var sel = _selectedIndexCalls(calls);
      expect(sel, isNotEmpty, reason: 'menu action must sync native dock highlight');
      expect(sel.last['index'], 2);
      expect(sel.last['epoch'], isA<int>());
      final favoritesEpoch = sel.last['epoch'] as int;
      expect(find.byKey(const ValueKey('library-open-cloud-sync')), findsOneWidget);

      // 片库 -> 观看历史 (same owning tab, still re-asserted with newer epoch)
      calls.clear();
      await _sendNativeMenuAction(tester, 2, 'history');
      await tester.pump(const Duration(milliseconds: 400));
      sel = _selectedIndexCalls(calls);
      expect(sel, isNotEmpty);
      expect(sel.last['index'], 2);
      final historyEpoch = sel.last['epoch'] as int;
      expect(historyEpoch, greaterThan(favoritesEpoch));

      // 直播 -> 管理直播源: selection follows to tab 1 before the sheet opens.
      calls.clear();
      await _sendNativeMenuAction(tester, 1, 'manage_live');
      await tester.pump(const Duration(milliseconds: 400));
      sel = _selectedIndexCalls(calls);
      expect(sel, isNotEmpty);
      expect(sel.last['index'], 1);
      expect(sel.last['epoch'] as int, greaterThan(historyEpoch));
      expect(
        find.byKey(const ValueKey('library-open-cloud-sync'), skipOffstage: false),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Flutter fallback dock (iOS 14-25): long-press tab menu never scales the pressed tab up and the Dock selection follows the menu-triggered page',
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(false);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await _makeStorage();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [IosRootTabNavigatorObserver()],
          home: AdaptiveShell(storage: storage, client: _DockMenuFixtureClient()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      AppleLiquidGlassDock dock() =>
          tester.widget<AppleLiquidGlassDock>(find.byType(AppleLiquidGlassDock));
      expect(find.byType(UiKitView), findsNothing);
      expect(dock().selectedIndex, 0);

      // Press & hold the 片库 tab: the pressed tab must never float / swell.
      final anchor2 = find.byKey(const ValueKey('dock-tab-menu-anchor-2'));
      expect(anchor2, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(anchor2));
      await tester.pump(const Duration(milliseconds: 150));
      for (final scale in tester.widgetList<AnimatedScale>(
        find.descendant(of: anchor2, matching: find.byType(AnimatedScale)),
      )) {
        expect(scale.scale, lessThanOrEqualTo(1.0));
      }
      await tester.pump(const Duration(milliseconds: 500));
      for (final scale in tester.widgetList<AnimatedScale>(
        find.descendant(of: anchor2, matching: find.byType(AnimatedScale)),
      )) {
        expect(scale.scale, 1.0, reason: 'dock tab must not lift while the menu is open');
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      final menu2 = find.byKey(const ValueKey('dock-tab-menu-2'));
      expect(menu2, findsOneWidget);

      await tester.tap(find.descendant(of: menu2, matching: find.text('观看历史')));
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byKey(const ValueKey('dock-tab-menu-2')), findsNothing);
      expect(dock().selectedIndex, 2, reason: 'Dock selection must follow 观看历史');
      expect(find.byKey(const ValueKey('library-open-cloud-sync')), findsOneWidget);

      // 主页 -> 回到顶部 from the library tab switches selection back to 主页.
      final anchor0 = find.byKey(const ValueKey('dock-tab-menu-anchor-0'));
      await tester.longPress(anchor0);
      await tester.pump(const Duration(milliseconds: 300));
      final menu0 = find.byKey(const ValueKey('dock-tab-menu-0'));
      expect(menu0, findsOneWidget);
      await tester.tap(find.descendant(of: menu0, matching: find.text('回到顶部')));
      await tester.pump(const Duration(milliseconds: 450));
      expect(dock().selectedIndex, 0, reason: 'Dock selection must follow 回到顶部');

      // Plain tap still selects normally after aborted / completed long-presses.
      await tester.tap(find.byKey(const ValueKey('dock-tab-menu-anchor-1')));
      await tester.pump(const Duration(milliseconds: 450));
      expect(dock().selectedIndex, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

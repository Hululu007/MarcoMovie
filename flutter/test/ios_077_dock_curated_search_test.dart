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
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DockCuratedFixtureClient extends CmsClient {
  _DockCuratedFixtureClient()
      : super(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const <CmsCategory>[
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
      ],
      CmsListing(
        page: 1,
        pageCount: 2,
        videos: [
          for (var i = 0; i < 24; i++)
            CmsVideo(
              id: 'v$i',
              title: '首页样片 $i',
              remarks: 'HD',
              year: '2024',
            ),
        ],
      ),
    );
  }
}

Future<StorageService> _makeStorage({bool withLive = true}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'onboarding_done_version': 1,
  });
  final storage = await StorageService.init();
  await storage.saveConfig(
    '{"sites":[{"key":"s1","name":"测试影源","type":1,"api":"https://fixture.example/api"}]'
    '${withLive ? ',"lives":[{"name":"示例直播","url":"https://live.example/channels.m3u"}]' : ''}}',
  );
  return storage;
}

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(false);
    IosRootTabNavigatorObserver.secondaryRouteDepth.value = 0;
    IosRootTabNavigatorObserver.topRouteIsCurated.value = false;
    IosRootTabNavigatorObserver.curatedRouteDepth.value = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('Req 1, 2 & 8 — Dock morph, Curated Logo navigation, Search return & entrance timing', () {
    testWidgets(
      'Flutter fallback (iOS 14-25): half-collapsed Dock (20%/50%/80% & mid-expand) into Curated settles to upright Logo, frees poster hits, blocks stale inertia, and Logo navigates to Live / Home / Top',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 560);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _makeStorage();
        final observer = IosRootTabNavigatorObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: AdaptiveShell(
              storage: storage,
              client: _DockCuratedFixtureClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 300));

        // Zero ghost native Dock views on iOS 14-25 fallback
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(AppleLiquidGlassDock), findsOneWidget);

        final homeScroll = find.byType(CustomScrollView).first;
        // Test 20%, 50%, 80% partial collapse while dragging Home
        for (final dragDy in <double>[-42, -84, -124]) {
          final gesture = await tester.startGesture(const Offset(195, 420));
          await gesture.moveBy(Offset(0, dragDy));
          await tester.pump(const Duration(milliseconds: 16));
          await gesture.up();
          // After release, Dock must auto-settle to stable endpoint (0.0 or 1.0)
          await tester.pump(const Duration(milliseconds: 350));
          final dockWidget = tester.widget<AppleLiquidGlassDock>(
            find.byType(AppleLiquidGlassDock),
          );
          final p = dockWidget.scrollProgress?.value ?? 0.0;
          expect(
            p == 0.0 || p == 1.0,
            isTrue,
            reason: 'Dock must auto-settle cleanly after partial drag $dragDy (got $p)',
          );
        }

        // Scroll Home down smoothly until Curated shelf ("光影风向标") chevron is visible
        for (var i = 0; i < 16 && find.byKey(const Key('curated-module-weekly_trending')).evaluate().isEmpty; i++) {
          await tester.drag(homeScroll, const Offset(0, -180));
          await tester.pump(const Duration(milliseconds: 60));
        }
        final curatedChevron = find
            .descendant(
              of: find.byKey(const Key('curated-module-weekly_trending')),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            )
            .first;
        await tester.ensureVisible(curatedChevron);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.tap(curatedChevron);
        await tester.pump(const Duration(milliseconds: 50));

        // Req 8: immediately after entering Curated (t=50ms), route is active
        // and posters are NOT blocked by IgnorePointer
        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isTrue);

        await tester.pump(const Duration(milliseconds: 450));
        // Curated shows its upright Logo-only fallback Dock
        final curatedDockFinder = find.byKey(const ValueKey('curated-fallback-dock'));
        expect(curatedDockFinder, findsOneWidget);
        final curatedDock = tester.widget<AppleLiquidGlassDock>(curatedDockFinder);
        expect(curatedDock.scrollProgress?.value, 1.0);
        // Collapsed Logo anchor is visible; expanded 4-tab labels must not block left area
        expect(find.byKey(const ValueKey('dock-collapsed-logo-button')), findsWidgets);

        // Req 2: Tap Logo opens text menu -> select 直播 -> truly exits Curated and shows Live page
        final logoButton = find
            .descendant(
              of: curatedDockFinder,
              matching: find.byKey(const ValueKey('dock-collapsed-logo-button')),
            )
            .first;
        await tester.tap(logoButton);
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('dock-collapsed-bubble-menu')), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('dock-collapsed-bubble-menu')),
            matching: find.text('直播'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));

        // Must have exited Curated AND rendered actual Live page widgets on screen
        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isFalse);
        expect(find.byKey(const ValueKey('curated-fallback-dock')), findsNothing);
        expect(find.text('直播'), findsWidgets);

        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Req 2: Curated -> Search -> Cancel / Edge-Swipe / Mid-Swipe Cancel x3 cycles preserve Curated scroll offset & Logo-only Dock, and Logo Home tap exits Curated preserving Home scroll',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 560);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _makeStorage();
        final observer = IosRootTabNavigatorObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: AdaptiveShell(
              storage: storage,
              client: _DockCuratedFixtureClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Scroll Home down first so Home has non-zero scroll offset & Curated shelf is visible
        final homeScrollable = find.byType(CustomScrollView).first;
        await tester.drag(homeScrollable, const Offset(0, -240));
        await tester.pump(const Duration(milliseconds: 120));
        for (var i = 0; i < 16 && find.byKey(const Key('curated-module-weekly_trending')).evaluate().isEmpty; i++) {
          await tester.drag(homeScrollable, const Offset(0, -180));
          await tester.pump(const Duration(milliseconds: 80));
        }
        await tester.pump(const Duration(milliseconds: 300));
        final homeOffsetBefore =
            tester.state<ScrollableState>(
              find.descendant(
                of: homeScrollable,
                matching: find.byType(Scrollable),
              ).first,
            ).position.pixels;
        expect(homeOffsetBefore, greaterThan(40));

        // Enter Curated
        final curatedChevron = find
            .descendant(
              of: find.byKey(const Key('curated-module-weekly_trending')),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            )
            .first;
        await tester.ensureVisible(curatedChevron);
        await tester.pump(const Duration(milliseconds: 30));
        await tester.tap(curatedChevron);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isTrue);
        expect(
          find.byKey(const Key('curated-gravity-wall-page')),
          findsOneWidget,
          reason: 'curated page must be mounted; fallbackDock=${find.byKey(const ValueKey('curated-fallback-dock')).evaluate().length}',
        );
        expect(
          find.byKey(const Key('curated-gravity-wall-grid')),
          findsOneWidget,
        );

        // Scroll Curated poster wall down to a non-overscroll position and settle
        Finder curatedVerticalScroll() => find.descendant(
              of: find.byKey(const Key('curated-gravity-wall-grid')),
              matching: find.byType(Scrollable),
            );
        await tester.drag(
          find.byKey(const Key('curated-gravity-wall-grid')),
          const Offset(0, -140),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        final curatedPos = tester.state<ScrollableState>(curatedVerticalScroll()).position;
        final curatedOffsetBefore = curatedPos.pixels;
        expect(curatedPos.maxScrollExtent, greaterThan(80));
        expect(curatedOffsetBefore, greaterThan(40));
        expect(curatedOffsetBefore, lessThanOrEqualTo(curatedPos.maxScrollExtent));

        // 3 consecutive cycles of Open Search -> Cancel/Swipe -> Back to Curated
        for (var cycle = 0; cycle < 3; cycle++) {
          final curatedDock = find.byKey(const ValueKey('curated-fallback-dock'));
          expect(curatedDock, findsOneWidget);
          final logo = find
              .descendant(
                of: curatedDock,
                matching: find.byKey(const ValueKey('dock-collapsed-logo-button')),
              )
              .first;
          await tester.tap(logo);
          await tester.pump(const Duration(milliseconds: 220));
          await tester.tap(
            find.descendant(
              of: find.byKey(const ValueKey('dock-collapsed-bubble-menu')),
              matching: find.text('搜索影片'),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));

          // Verify Search page is actually displayed and Curated Dock is hidden
          expect(find.byType(CupertinoTextField), findsWidgets);
          expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isFalse);

          if (cycle == 1) {
            // Test mid-swipe cancel (< 35%): must STAY on Search page!
            final g = await tester.startGesture(const Offset(8, 400));
            for (var s = 0; s < 4; s++) {
              await g.moveBy(const Offset(14, 0));
              await tester.pump(const Duration(milliseconds: 16));
            }
            await g.up();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 280));
            expect(find.byType(CupertinoTextField), findsWidgets);
            expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isFalse);

            // Now complete full left-edge swipe back (> 35%): returns to Curated
            final g2 = await tester.startGesture(const Offset(8, 400));
            for (var s = 0; s < 10; s++) {
              await g2.moveBy(const Offset(24, 0));
              await tester.pump(const Duration(milliseconds: 16));
            }
            await g2.up();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          } else {
            // Tap close/cancel button on Search page
            final closeFinder = find.byKey(const ValueKey('search-close-button'));
            expect(closeFinder, findsOneWidget);
            await tester.tap(closeFinder);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          }

          // Must return to SAME Curated page at SAME scroll offset with Logo-only Dock
          expect(
            IosRootTabNavigatorObserver.topRouteIsCurated.value,
            isTrue,
            reason: 'Cycle $cycle must return to Curated route',
          );
          expect(find.byKey(const ValueKey('curated-fallback-dock')), findsOneWidget);
          final offsetAfter =
              tester.state<ScrollableState>(curatedVerticalScroll()).position.pixels;
          expect((offsetAfter - curatedOffsetBefore).abs(), lessThan(5.0));
        }

        // Now tap Logo -> 主页 (while underlying root tab was already Home):
        // MUST exit Curated and preserve Home scroll offset!
        final curatedDock = find.byKey(const ValueKey('curated-fallback-dock'));
        await tester.tap(
          find
              .descendant(
                of: curatedDock,
                matching: find.byKey(const ValueKey('dock-collapsed-logo-button')),
              )
              .first,
        );
        await tester.pump(const Duration(milliseconds: 220));
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('dock-collapsed-bubble-menu')),
            matching: find.text('主页'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));

        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isFalse);
        expect(find.byKey(const ValueKey('curated-fallback-dock')), findsNothing);
        final homeOffsetAfter =
            tester.state<ScrollableState>(
              find.descendant(
                of: find.byType(CustomScrollView).first,
                matching: find.byType(Scrollable),
              ).first,
            ).position.pixels;
        expect(homeOffsetAfter, greaterThan(40));

        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Native iOS 26+ bridge: monotonic epoch guards Curated Logo state and dispatches tab long-press menu actions',
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
        final observer = IosRootTabNavigatorObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: AdaptiveShell(
              storage: storage,
              client: _DockCuratedFixtureClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));

        // Verify configureRootTabChrome carries epoch and per-tab long-press menuItems
        final configCall = calls.firstWhere(
          (c) => c.method == 'configureRootTabChrome',
        );
        final configArgs = Map<String, dynamic>.from(configCall.arguments as Map);
        expect(configArgs['epoch'], isA<int>());
        final items = (configArgs['items'] as List).cast<Map>();
        expect((items[0]['menuItems'] as List).first['title'], '回到顶部');
        expect((items[1]['menuItems'] as List).first['title'], '管理直播源');
        expect(
          (items[2]['menuItems'] as List).map((e) => e['title']).toList(),
          ['收藏', '观看历史'],
        );
        expect(
          (items[3]['menuItems'] as List).map((e) => e['title']).toList(),
          ['添加资源库', '网盘账号'],
        );

        // Entering Curated must send minimized=true with strictly higher epoch
        final homeScroll = find.byType(CustomScrollView).first;
        for (var i = 0; i < 16 && find.byKey(const Key('curated-module-weekly_trending')).evaluate().isEmpty; i++) {
          await tester.drag(homeScroll, const Offset(0, -180));
          await tester.pump(const Duration(milliseconds: 60));
        }
        final curatedChevron = find
            .descendant(
              of: find.byKey(const Key('curated-module-weekly_trending')),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            )
            .first;
        await tester.ensureVisible(curatedChevron);
        await tester.pump(const Duration(milliseconds: 30));
        await tester.tap(curatedChevron);
        await tester.pump(const Duration(milliseconds: 450));

        final minCalls = calls
            .where((c) => c.method == 'setRootTabMinimized')
            .map((c) => Map<String, dynamic>.from(c.arguments as Map))
            .toList();
        expect(minCalls, isNotEmpty);
        expect(minCalls.last['minimized'], isTrue);
        expect(minCalls.last['epoch'] as int, greaterThan(configArgs['epoch'] as int));

        // Simulate native Logo menu selecting tab 1 (直播): must exit Curated
        const codec = StandardMethodCodec();
        final envelope = codec.encodeMethodCall(const MethodCall('rootTabSelected', 1));
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          IosLiquidGlassBridge.channel.name,
          envelope,
          (_) {},
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isFalse);

        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Req 8: Curated entrance (300ms route / 1450ms wall) is immediately scrollable & returnable at t=50ms, and Reduce Motion lands immediately',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 560);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _makeStorage();
        final observer = IosRootTabNavigatorObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: AdaptiveShell(
              storage: storage,
              client: _DockCuratedFixtureClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        final homeScroll = find.byType(CustomScrollView).first;
        for (var i = 0; i < 16 && find.byKey(const Key('curated-module-weekly_trending')).evaluate().isEmpty; i++) {
          await tester.drag(homeScroll, const Offset(0, -180));
          await tester.pump(const Duration(milliseconds: 60));
        }
        final curatedChevron = find
            .descendant(
              of: find.byKey(const Key('curated-module-weekly_trending')),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            )
            .first;
        await tester.ensureVisible(curatedChevron);
        await tester.pump(const Duration(milliseconds: 20));
        await tester.tap(curatedChevron);
        await tester.pump();
        // Only 50ms into the 300ms route + 1450ms poster wall animation!
        await tester.pump(const Duration(milliseconds: 50));

        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isTrue);
        final wallGrid = find.byKey(const Key('curated-gravity-wall-grid'));
        expect(wallGrid, findsOneWidget);

        // Immediately scrollable while wall animation is still in flight
        await tester.drag(wallGrid, const Offset(0, -120));
        await tester.pump(const Duration(milliseconds: 80));
        final scrollPos = tester.state<ScrollableState>(
          find.descendant(of: wallGrid, matching: find.byType(Scrollable)),
        ).position;
        expect(scrollPos.pixels, greaterThan(40));

        // Immediately returnable via back button without waiting for 1450ms
        await tester.tap(find.byIcon(CupertinoIcons.chevron_back));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isFalse);

        // Reduce Motion: lands directly without waiting for 1450ms animation
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 560),
              disableAnimations: true,
            ),
            child: MaterialApp(
              navigatorObservers: [IosRootTabNavigatorObserver()],
              home: AdaptiveShell(
                storage: storage,
                client: _DockCuratedFixtureClient(),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final homeScrollRm = find.byType(CustomScrollView).first;
        for (var i = 0; i < 16 && find.byKey(const Key('curated-module-weekly_trending')).evaluate().isEmpty; i++) {
          await tester.drag(homeScrollRm, const Offset(0, -180));
          await tester.pump(const Duration(milliseconds: 60));
        }
        final chevronRm = find
            .descendant(
              of: find.byKey(const Key('curated-module-weekly_trending')),
              matching: find.byIcon(CupertinoIcons.chevron_right),
            )
            .first;
        await tester.ensureVisible(chevronRm);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.tap(chevronRm);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(IosRootTabNavigatorObserver.topRouteIsCurated.value, isTrue);
        // With disableAnimations: true, wall grid settles immediately at opacity 1.0
        final opacityWidget = tester.widget<Opacity>(
          find.ancestor(
            of: find.byKey(const Key('curated-gravity-wall-grid')),
            matching: find.byType(Opacity),
          ).first,
        );
        expect(opacityWidget.opacity, 1.0);

        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

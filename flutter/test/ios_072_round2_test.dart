import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/config_center_bridge.dart';
import 'package:marco_movie/core/device_quality_profiler.dart';
import 'package:marco_movie/core/ios_mpv_profile.dart';
import 'package:marco_movie/core/media_library_connectors.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/add_resource_library_sheet.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/cloud_sync_panel.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:marco_movie/ui/netdisk_sheet.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/windows_appearance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DeviceQualityProfiler.testSnapshotOverride = null;
  });

  group('iOS Round 2 Optimization Regression Tests', () {
    testWidgets(
      '#1 Ios27PageRoute left-edge swipe-back settles monotonically without mid-gesture backward jump',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Center(child: Text('Root Settings'))),
          ),
        );

        final route = Ios27PageRoute<void>(
          builder: (_) => const Scaffold(
            key: ValueKey('pushed-secondary-settings'),
            body: Center(child: Text('Secondary Page')),
          ),
        );
        navKey.currentState!.push(route);
        await tester.pumpAndSettle();

        final gesture = await tester.startGesture(const Offset(8, 400));
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(28, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        final leftBeforeRelease =
            tester.getTopLeft(find.byKey(const ValueKey('pushed-secondary-settings'))).dx;
        expect(leftBeforeRelease, greaterThan(120));

        await gesture.up();
        // Sample the first 8 frames right after finger lift: the page X offset
        // MUST continue gliding rightward (never teleporting backward).
        var prevLeft = leftBeforeRelease;
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final finder = find.byKey(const ValueKey('pushed-secondary-settings'));
          if (finder.evaluate().isEmpty) break;
          final currentLeft = tester.getTopLeft(finder).dx;
          expect(
            currentLeft,
            greaterThanOrEqualTo(prevLeft - 1.5),
            reason: 'Frame $frame jumped backward from $prevLeft to $currentLeft',
          );
          prevLeft = currentLeft;
        }

        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('pushed-secondary-settings')), findsNothing);
        expect(navKey.currentState!.userGestureInProgress, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      '#2 & #9 AppleLiquidGlassDock absorbs taps and morphs Search->Logo linearly with scrollProgress',
      (tester) async {
        var backgroundTapped = false;
        var selectedTab = 0;
        var searchTapped = false;
        final progress = ValueNotifier<double>(0.0);
        addTearDown(progress.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    key: const ValueKey('bg-item'),
                    onTap: () => backgroundTapped = true,
                    child: const ColoredBox(color: Colors.black),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: AppleLiquidGlassDock(
                      selectedIndex: selectedTab,
                      onSelect: (i) => selectedTab = i,
                      isLandscape: false,
                      items: const [
                        (CupertinoIcons.house, CupertinoIcons.house_fill, '主页'),
                        (CupertinoIcons.tv, CupertinoIcons.tv_fill, '直播'),
                        (CupertinoIcons.square_stack_3d_up, CupertinoIcons.square_stack_3d_up_fill, '片库'),
                        (CupertinoIcons.gear, CupertinoIcons.gear_solid, '设置'),
                      ],
                      onSearch: () => searchTapped = true,
                      scrollProgress: progress,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        // Tapping a Dock item must NOT leak through to the background item.
        await tester.tap(find.text('直播'));
        await tester.pump();
        expect(selectedTab, 1);
        expect(backgroundTapped, isFalse);

        // At progress=0.0, Search button is active, Logo button is not.
        expect(find.byKey(const ValueKey('home-search-button')), findsOneWidget);
        expect(find.byKey(const ValueKey('dock-collapsed-logo-button')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('home-search-button')));
        await tester.pump();
        expect(searchTapped, isTrue);

        // Mid-scroll progress=0.45: both icons cross-fading while rotating.
        progress.value = 0.45;
        await tester.pump();
        expect(find.byKey(const ValueKey('home-search-button')), findsOneWidget);

        // Full scroll progress=1.0: Search rotated into Marco Logo, 4-tab capsule rolled in.
        progress.value = 1.0;
        await tester.pump();
        expect(find.byKey(const ValueKey('dock-collapsed-logo-button')), findsOneWidget);
        expect(find.byKey(const ValueKey('home-search-button')), findsNothing);

        // Scrolling back up progress=0.0 reverses cleanly.
        progress.value = 0.0;
        await tester.pump();
        expect(find.byKey(const ValueKey('home-search-button')), findsOneWidget);
        expect(find.byKey(const ValueKey('dock-collapsed-logo-button')), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      '#5 Settings secondary page hides row subtitles, uses larger 20pt title, and WebDAV/LAN inputs use dark ink in Light Mode',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService(await SharedPreferences.getInstance());
        final rev = ValueNotifier<int>(0);
        addTearDown(rev.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: IosSettingsSubPage(
              parentTitle: '设置',
              pathIds: const ['playback'],
              revision: rev,
              onChanged: () {},
              pages: (_) => [
                SettingsPane(
                  'playback',
                  '播放',
                  '根页面介绍不应显示在二级子项下方',
                  CupertinoIcons.play_circle_fill,
                  AppleColors.systemOrange,
                  children: [
                    SettingsPane(
                      'picture',
                      '画质与画面',
                      '这段冗长二级介绍不应该显示出来',
                      CupertinoIcons.tv_fill,
                      AppleColors.systemPurple,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Title font size >= 19.5pt
        final titleText = tester.widget<Text>(find.text('播放'));
        expect(titleText.style?.fontSize, greaterThanOrEqualTo(19.5));

        // Secondary child row shows name, omits verbose subtitle
        expect(find.text('画质与画面'), findsOneWidget);
        expect(find.text('这段冗长二级介绍不应该显示出来'), findsNothing);

        // Light-mode WebDAV & LAN Sync text fields must use dark readable ink (not white!)
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (ctx) {
                  // Verify settingsInk in Light Mode is dark ink, NOT white.
                  final ink = settingsInk(ctx);
                  expect(ink.computeLuminance(), lessThan(0.25));
                  return CloudSyncSettingsPanel(
                    storage: storage,
                    embeddedInList: false,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final webdavField = tester.widget<CupertinoTextField>(
          find.byKey(const ValueKey('sync-webdav-url')),
        );
        final lanField = tester.widget<CupertinoTextField>(
          find.byKey(const ValueKey('sync-lan-peer-input')),
        );
        expect(webdavField.style!.color!.computeLuminance(), lessThan(0.25));
        expect(lanField.style!.color!.computeLuminance(), lessThan(0.25));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      '#4 ConfigCenterBridge detects multiple source Config Centers and extracts/syncs credentials cross-source',
      () async {
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService(await SharedPreferences.getInstance());

        final sites = <CmsSite>[
          CmsSite(
            key: 'wex_cfg',
            name: 'WEX配置中心',
            type: 3,
            api: 'csp_WexConfigGuard',
            ext: jsonEncode({
              'pan': {
                'uc': {'cookie': '__pus=abc1234567890; __puus=xyz9876543210'},
                'ali': {'token': 'abcdef0123456789abcdef0123456789'},
              },
              'order': ['uc', 'quark', 'ali', 'baidu'],
            }),
          ),
          const CmsSite(
            key: 'fty_mydrive',
            name: '🗂我的云盘┃配置',
            type: 3,
            api: 'csp_MyDriveGuard',
          ),
          const CmsSite(
            key: 'catpaw_base',
            name: 'CatPaw 配置中心',
            type: 3,
            api: 'catpaw://demo.local/api/baseset',
          ),
          const CmsSite(
            key: 'regular_vod',
            name: '普通片源',
            type: 1,
            api: 'https://vod.example/api.php/provide/vod/',
          ),
        ];

        final detected = ConfigCenterBridge.detectConfigCenters(sites);
        expect(detected.length, 3);
        expect(detected.map((d) => d.kind), contains(ConfigCenterKind.wexOk));
        expect(detected.map((d) => d.kind), contains(ConfigCenterKind.ftyMyDrive));
        expect(detected.map((d) => d.kind), contains(ConfigCenterKind.catPaw));

        final report = await ConfigCenterBridge.syncAll(
          storage: storage,
          sites: sites,
          pullFromExternal: true,
          pushToExternal: false,
        );
        expect(report.importedDrives, containsAll(['uc', 'ali']));
        expect(report.updatedDriveOrder, isTrue);
        expect(storage.isNetdiskLoggedIn('uc'), isTrue);
        expect(storage.isNetdiskLoggedIn('ali'), isTrue);
        expect(storage.driveOrder.first, 'uc');
      },
    );

    testWidgets(
      '#4 Netdisk page renders as 配置中心 with multi-source sync button',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService(await SharedPreferences.getInstance());

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => CupertinoButton(
                onPressed: () => showNetdiskAccountSheet(
                  ctx,
                  storage,
                  sites: const [
                    CmsSite(
                      key: 'wex_cfg',
                      name: 'WEX配置中心',
                      type: 3,
                      api: 'csp_WexConfigGuard',
                    ),
                  ],
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        expect(find.text('配置中心'), findsOneWidget);
        expect(find.byKey(const ValueKey('config-center-sync-all-btn')), findsOneWidget);
        expect(find.text('WEX配置中心'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      '#6 AddResourceLibraryView renders Rex-style categorized grid with animated entrance & clean manual group pills',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService(await SharedPreferences.getInstance());

        await tester.pumpWidget(
          MaterialApp(
            home: IosSettingsScaffold(
              title: '添加资源库',
              body: AddResourceLibraryView(
                storage: storage,
                client: CmsClient(),
                onLibraryAdded: () {},
              ),
            ),
          ),
        );
        // Pump partway through scatter->grid entrance and then settle cleanly.
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 900));

        expect(find.byKey(const ValueKey('add-resource-library-hub')), findsOneWidget);
        expect(find.text('媒体服务器'), findsOneWidget);
        expect(find.text('网络存储'), findsOneWidget);
        expect(find.text('个人网盘'), findsOneWidget);
        expect(find.text('本机与订阅'), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-webdav')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-smb')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-emby')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-jellyfin')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-plex')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-alistNas')), findsOneWidget);
        expect(find.byKey(const ValueKey('add-lib-tile-manualInput')), findsOneWidget);
        expect(find.text('剪贴板快导'), findsNothing);

        // Open manual subscription form and verify crisp group pill buttons
        await tester.tap(find.byKey(const ValueKey('add-lib-tile-manualInput')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const ValueKey('import-group-pill-主力影视')), findsOneWidget);
        final pillText = tester.widget<Text>(find.text('主力影视'));
        expect(pillText.style?.fontSize, greaterThanOrEqualTo(13.0));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      '#6 ExternalMediaLibrary parses WebDAV PROPFIND XML and resolves local/SMB/Jellyfin/Plex sites as browseable',
      () {
        const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/video/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/video/Movies/</D:href>
    <D:propstat><D:prop><D:displayname>电影</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/video/Inception.2010.4K.mkv</D:href>
    <D:propstat><D:prop><D:displayname>Inception.2010.4K.mkv</D:displayname></D:prop></D:propstat>
  </D:response>
</D:multistatus>
''';
        final items = WebDavMediaLibrary.parsePropfindXml(
          xml,
          Uri.parse('https://dav.example/video/'),
        );
        expect(items.length, 2);
        expect(items.first.isDir, isTrue);
        expect(items.first.displayName, '电影');
        expect(items.last.isDir, isFalse);
        expect(ExternalMediaLibrary.isVideoFileName(items.last.displayName), isTrue);
        expect(ExternalMediaLibrary.cleanMediaTitle(items.last.displayName), 'Inception.2010.4K');

        for (final api in const [
          'jellyfin://account/abc',
          'plex://account/abc',
          'webdavlib://account/abc',
          'alist://account/abc',
          'smbnas://account/abc',
          'localfile://account/abc',
        ]) {
          final site = CmsSite(key: 'k', name: 'Test', type: 1, api: api);
          expect(site.isExternalMediaLibrary, isTrue);
          expect(site.canBrowse, isTrue);
          expect(site.capabilityStatus, CmsSite.statusOk);
        }
      },
    );

    test(
      '#7 DeviceQualityProfiler selects optimal settings for flagship, balanced, and legacy iOS hardware',
      () async {
        SharedPreferences.setMockInitialValues({});
        final storage = StorageService(await SharedPreferences.getInstance());

        // Flagship iPhone 16 Pro (8 GB RAM, XDR screen)
        const flagship = DeviceHardwareSnapshot(
          machineIdentifier: 'iPhone17,1',
          modelName: 'iPhone 16 Pro',
          physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
          processorCount: 6,
          supportsHdrDisplay: true,
          potentialEdrHeadroom: 2.0,
        );
        DeviceQualityProfiler.testSnapshotOverride = flagship;
        final recFlagship = await DeviceQualityProfiler.detectAndApply(storage);
        expect(recFlagship.tier, DeviceHardwareTier.flagship);
        expect(storage.iosLargeBufferEnabled, isTrue);
        expect(storage.iosAnime4kLightweightEnabled, isFalse);
        expect(storage.preferredQuality, '4k_netdisk');
        expect(storage.iosHdrToneMappingMode, IosHdrToneMappingMode.auto.id);

        // Legacy iPhone 11 / 3 GB RAM
        const legacy = DeviceHardwareSnapshot(
          machineIdentifier: 'iPhone12,1',
          modelName: 'iPhone 11',
          physicalMemoryBytes: 3 * 1024 * 1024 * 1024,
          processorCount: 6,
          supportsHdrDisplay: false,
          potentialEdrHeadroom: 1.0,
        );
        DeviceQualityProfiler.testSnapshotOverride = legacy;
        final recLegacy = await DeviceQualityProfiler.detectAndApply(storage, force: true);
        expect(recLegacy.tier, DeviceHardwareTier.efficiency);
        expect(storage.iosLargeBufferEnabled, isFalse);
        expect(storage.iosAnime4kLightweightEnabled, isFalse);
        expect(storage.preferredQuality, '1080p_direct');
        expect(storage.iosHdrToneMappingMode, IosHdrToneMappingMode.hable.id);
      },
    );

    test(
      'Hero HD poster upgrade parses Douban mobile search /movie/subject/, matches prefix variants & upgrades to uncropped /view/photo/l/',
      () {
        // 1. Uncropped original-large Douban poster upgrade for full-bleed Hero
        expect(
          PosterLoader.upgradeDoubanToOriginalLarge(
            'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2935488630.webp',
          ),
          'https://img1.doubanio.com/view/photo/l/public/p2935488630.jpg',
        );
        expect(
          PosterLoader.upgradeDoubanToOriginalLarge(
            'https://img2.doubanio.com/view/photo/l_ratio_poster/public/p2937593221.jpg',
          ),
          'https://img2.doubanio.com/view/photo/l/public/p2937593221.jpg',
        );
        // 2. Bangumi /r/400/ thumbnail path stripped to original 2K /pic/cover/l/
        expect(
          PosterLoader.upgradeUrlToHd(
            'https://lain.bgm.tv/r/400/pic/cover/l/0f/0f/623249_zCdly.jpg',
          ),
          'https://lain.bgm.tv/pic/cover/l/0f/0f/623249_zCdly.jpg',
        );
        // 3. Douban mobile search parser extracts strictly /movie/subject/ items
        //    (ignoring /book/subject/ and /group/) and matches prefix variants
        //    like 七龙珠超：比鲁斯 <-> 龙珠超：比鲁斯.
        const sampleHtml = '''
          <ul class="search_results_subjects">
            <li><a href="/book/subject/35080870/"><img src="https://img3.doubanio.com/view/subject/l/public/s33682883.jpg"><span class="subject-title">两京十五日</span></a></li>
            <li><a href="/group/765151/"><img src="https://img1.doubanio.com/view/group/sqxs/public/919498ef7f7c754.jpg"><span class="subject-title">龙珠超：比鲁斯</span></a></li>
            <li><a href="/movie/subject/38221205/"><img src="https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2935478803.jpg"><span class="subject-title">七龙珠超：比鲁斯</span></a></li>
            <li><a href="/movie/subject/35235320/"><img src="https://img2.doubanio.com/view/photo/s_ratio_poster/public/p2937593221.jpg"><span class="subject-title">两京十五日</span></a></li>
          </ul>
        ''';
        final dragonBall = PosterLoader.parseDoubanMobileSearchEntries(
          sampleHtml,
          '龙珠超：比鲁斯',
        );
        expect(dragonBall, hasLength(1));
        expect(dragonBall.first.id, '38221205');
        expect(
          dragonBall.first.coverUrl,
          'https://img3.doubanio.com/view/photo/l/public/p2935478803.jpg',
        );

        final twoCapitals = PosterLoader.parseDoubanMobileSearchEntries(
          sampleHtml,
          '两京十五日',
        );
        expect(twoCapitals, hasLength(1));
        expect(twoCapitals.first.id, '35235320');
        expect(
          twoCapitals.first.coverUrl,
          'https://img2.doubanio.com/view/photo/l/public/p2937593221.jpg',
        );
      },
    );

    testWidgets(
      'Detail PosterExpandRoute disables vertical pull-down dismiss by default and only pops on left-edge swipe or Back button',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (ctx) => GestureDetector(
                    key: const ValueKey('detail-source-card'),
                    onTap: () {
                      Navigator.of(ctx).push(
                        PosterExpandRoute<void>(
                          initialSourceRect: PosterExpandRoute.captureRect(ctx)!,
                          sourceCardId: 'detail-card-no-pull',
                          builder: (_) => const Scaffold(
                            key: ValueKey('detail-no-pull-page'),
                            body: Center(child: Text('Detail Page')),
                          ),
                        ),
                      );
                    },
                    child: const SizedBox(
                      width: 120,
                      height: 180,
                      child: ColoredBox(color: Colors.indigo),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('detail-source-card')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('detail-no-pull-page')), findsOneWidget);

        // Strong downward fling must NOT dismiss Detail route (reserved for pull-to-refresh).
        await tester.fling(
          find.byKey(const ValueKey('detail-no-pull-page')),
          const Offset(0, 280),
          1200.0,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('detail-no-pull-page')), findsOneWidget);

        // Left-edge inward swipe from x = 10 pops cleanly.
        await tester.flingFrom(
          const Offset(10, 420),
          const Offset(240, 0),
          1100.0,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('detail-no-pull-page')), findsNothing);
        expect(PosterExpandRegistry.activeCardId.value, isNull);
      },
    );
  });
}

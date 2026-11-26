import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_filter_sheet.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_press_slide_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AuditCmsClient extends CmsClient {
  _AuditCmsClient({required this.detailVideo})
      : super(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

  final CmsVideo detailVideo;

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const <CmsCategory>[
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
      ],
      const CmsListing(
        page: 1,
        pageCount: 1,
        videos: [
          CmsVideo(id: 'v1', title: '长剧测试片', year: '2025'),
        ],
      ),
    );
  }

  @override
  Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo fallback, {
    bool forceRefresh = false,
  }) async {
    return detailVideo;
  }
}

CmsVideo _buildLongSeriesVideo(int episodeCount) {
  final eps = [
    for (var i = 1; i <= episodeCount; i++)
      CmsEpisode(
        name: '第$i集',
        url: 'https://cdn.example/show/ep$i.m3u8?token=sig_$i',
      ),
  ];
  return CmsVideo(
    id: 'series_long_1',
    title: '百集审查测试剧',
    year: '2025',
    remarks: '全$episodeCount集',
    lines: [
      CmsLine(id: 'main_line_id', name: '主线', episodes: eps),
    ],
  );
}

Future<StorageService> _createStorageWithSub({
  List<WatchHistoryEntry> history = const [],
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'onboarding_done_version': 1,
  });
  final storage = await StorageService.init();
  await storage.saveConfig(
    '{"sites":['
    '{"key":"s1","name":"测试源A","type":1,"api":"https://a.example/api","group":"默认"}'
    ']}',
  );
  for (final h in history) {
    await storage.upsertWatchHistory(h);
  }
  return storage;
}

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('iOS UX & Motion Audit — Filter Sheet indicators, accessibility & Dynamic Type', () {
    testWidgets(
      'active dimension dots update with selection/reset and 320pt + 1.8x text scale + Reduce Motion has zero overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 620);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        IosNativeFilterResult? applied;
        const categories = [
          IosNativeFilterCategory(id: '', label: '全部', kind: 'all'),
          IosNativeFilterCategory(id: '11', label: '动作科幻冒险长分类名', kind: 'cat'),
          IosNativeFilterCategory(id: '12', label: '悬疑', kind: 'cat'),
        ];

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 620),
              textScaler: TextScaler.linear(1.8),
              disableAnimations: true,
            ),
            child: MaterialApp(
              home: Builder(
                builder: (ctx) => Scaffold(
                  body: Center(
                    child: CupertinoButton(
                      onPressed: () async {
                        applied = await showIosCatalogFilterSheet(
                          context: ctx,
                          title: '片库筛选',
                          categories: categories,
                          selectedCategoryId: '',
                          selectedGenreLabel: '',
                          areas: const ['全部', '中国大陆', '日本', '美国'],
                          selectedArea: '',
                          years: const ['全部', '2025', '2024', '2023'],
                          selectedYear: '',
                        );
                      },
                      child: const Text('打开筛选'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开筛选'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-0')), findsNothing);
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-1')), findsNothing);
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-2')), findsNothing);

        // Select category -> dimension 0 dot appears
        await tester.tap(find.text('动作科幻冒险长分类名'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-0')), findsOneWidget);

        // Switch to Area tab & select 日本 -> dimension 1 dot appears
        await tester.tap(find.byKey(const ValueKey('ios-filter-dim-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('日本'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-1')), findsOneWidget);

        // Switch to Year tab & select 2024 -> dimension 2 dot appears
        await tester.tap(find.byKey(const ValueKey('ios-filter-dim-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('2024'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-2')), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Reset clears all three dots
        await tester.tap(find.byKey(const ValueKey('ios-filter-reset-button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-0')), findsNothing);
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-1')), findsNothing);
        expect(find.byKey(const ValueKey('ios-filter-dim-dot-2')), findsNothing);

        // Apply returns clean empty selection
        await tester.tap(find.byKey(const ValueKey('ios-filter-apply-button')));
        await tester.pumpAndSettle();
        expect(applied, isNotNull);
        expect(applied!.categoryId, isEmpty);
        expect(applied!.area, isEmpty);
        expect(applied!.year, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS UX & Motion Audit — IosPressSlideMenuAnchor accessibility & metric dismissal', () {
    testWidgets(
      'exposes VoiceOver custom action when !openOnTap, respects Reduce Motion, and dismisses on window resize',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final semHandle = tester.ensureSemantics();

        String? picked;
        var tapped = 0;

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              disableAnimations: true,
            ),
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: IosPressSlideMenuAnchor(
                    menuKey: const ValueKey('audit-slide-menu'),
                    openOnTap: false,
                    accessibilityLabel: '片源菜单',
                    onTap: () => tapped++,
                    onSelected: (id) => picked = id,
                    itemsBuilder: () => const [
                      IosSlideMenuAction(id: 'a', title: '选项一'),
                      IosSlideMenuAction(id: 'b', title: '选项二'),
                    ],
                    child: const Text('触发按钮'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // VoiceOver semantics include custom action '更多操作' & onLongPress
        final node = tester.getSemantics(find.bySemanticsLabel('片源菜单'));
        final data = node.getSemanticsData();
        expect(data.hasAction(SemanticsAction.longPress), isTrue);
        expect(data.hasAction(SemanticsAction.tap), isTrue);

        // Tap fires onTap without opening menu
        await tester.tap(find.text('触发按钮'));
        await tester.pumpAndSettle();
        expect(tapped, 1);
        expect(find.byKey(const ValueKey('audit-slide-menu')), findsNothing);

        // Long-press opens menu cleanly
        await tester.longPress(find.text('触发按钮'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('audit-slide-menu')), findsOneWidget);

        // Window metric change (e.g. iPad Split View resize) auto-dismisses menu cleanly
        tester.view.physicalSize = const Size(507, 844);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('audit-slide-menu')), findsNothing);
        expect(picked, isNull);
        expect(tester.takeException(), isNull);
        semHandle.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS UX & Motion Audit — Destructive confirmations & Undo restore', () {
    testWidgets(
      'watch history clear-all asks confirmation and single-item delete offers 3s Undo that restores entry',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const epUrl = 'https://cdn.example/show/ep3.m3u8?token=rotatable';
        final seed = WatchHistoryEntry(
          site: 's1',
          id: 'vid_undo_1',
          title: '可撤销测试剧',
          episode: '第3集',
          index: 2,
          lineId: 'main_line_id',
          line: '主线',
          episodeMediaId: WatchHistoryEntry.mediaIdentityForUrl(epUrl),
          position: 125000,
          duration: 2400000,
          updated: 1732500000000,
        );
        final storage = await _createStorageWithSub(history: [seed]);
        final client = _AuditCmsClient(detailVideo: _buildLongSeriesVideo(10));

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Navigate to 片库 tab -> 观看历史 segment
        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('观看历史').first);
        await tester.pumpAndSettle();

        expect(find.text('可撤销测试剧'), findsOneWidget);
        expect(find.text('清空记录'), findsOneWidget);

        // Tap 清空记录 -> shows confirmation dialog; cancel preserves history
        await tester.tap(find.text('清空记录'));
        await tester.pumpAndSettle();
        expect(find.text('清空全部观看历史？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(storage.getWatchHistory().length, 1);

        // Long-press poster card to delete single item -> Undo banner appears
        await tester.longPress(find.text('可撤销测试剧'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除记录'));
        await tester.pumpAndSettle();
        expect(storage.getWatchHistory(), isEmpty);
        expect(find.byKey(const ValueKey('ios-undo-history-banner')), findsOneWidget);

        // Tap 撤销 -> restores entry with exact episodeMediaId & progress
        await tester.tap(find.byKey(const ValueKey('ios-undo-history-action')));
        await tester.pumpAndSettle();
        final restored = storage.getWatchHistory();
        expect(restored.length, 1);
        expect(restored.first.id, 'vid_undo_1');
        expect(restored.first.position, 125000);
        expect(restored.first.episodeMediaId, seed.episodeMediaId);

        // Confirm 清空记录 -> actually clears all history
        await tester.tap(find.text('清空记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清空记录').last);
        await tester.pumpAndSettle();
        expect(storage.getWatchHistory(), isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'iOS Subscription Manager uses 添加订阅 header and confirms before deleting a subscription',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _createStorageWithSub();
        final client = _AuditCmsClient(detailVideo: _buildLongSeriesVideo(5));

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Open Home top-right 配置中心 -> 管理订阅
        await tester.tap(find.byKey(const ValueKey('home-netdisk-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('config-center-manage-subs-btn')));
        await tester.pumpAndSettle();

        expect(find.text('添加订阅'), findsOneWidget);
        expect(find.text('快捷导入'), findsNothing);

        // Tap trash icon -> confirmation dialog appears; cancel keeps subscription
        expect(storage.getSubscriptions().length, 1);
        await tester.tap(find.byIcon(CupertinoIcons.trash).first);
        await tester.pumpAndSettle();
        expect(find.textContaining('删除订阅'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(storage.getSubscriptions().length, 1);

        // Tap trash icon again -> confirm deletes subscription
        await tester.tap(find.byIcon(CupertinoIcons.trash).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(storage.getSubscriptions(), isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS UX & Motion Audit — DetailScreen localized browsing & sort-after-circle anchor', () {
    testWidgets(
      'tapping an episode circle highlights locally and immediately anchors sort inversion to that episode',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(820, 1180);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final video = _buildLongSeriesVideo(120);
        final storage = await _createStorageWithSub();
        final client = _AuditCmsClient(detailVideo: video);
        const site = CmsSite(
          key: 's1',
          name: '测试源A',
          type: 1,
          api: 'https://a.example/api',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: site,
              initialVideo: video,
              client: client,
              storage: storage,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap circle 10 (index 9) on page 1 (1..50)
        final circle10 = find.byKey(const ValueKey('ep_circle_0_9'));
        await tester.ensureVisible(circle10);
        await tester.tap(circle10);
        await tester.pumpAndSettle();

        // Circle 10 box should now show browsing white border while Ep 1 stays unplayed
        final box10 = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('ep_circle_box_0_9')),
        );
        final dec10 = box10.decoration! as BoxDecoration;
        expect(dec10.border?.top.color, Colors.white);
        expect(dec10.color, isNot(Colors.white));

        // Immediately toggle sort to descending: must land on page containing Ep 10 (page 3 of 120..1)
        await tester.tap(find.byKey(const ValueKey('detail-episode-sort-toggle')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ep_circle_0_9')), findsOneWidget);
        expect(find.byKey(const ValueKey('ep_card_0_9')), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS UX & Motion Audit — Watch history token sanitization across legacy migration & backup/sync', () {
    test('legacy signed episodeUrl migrates to mid:v1:, survives backup/sync without leaking raw tokens, and matches rotated tokens', () async {
      final legacyJson = <String, dynamic>{
        'site': 's1',
        'id': 'vid_tok_1',
        'title': '加密签名测试剧',
        'episode': '第5集',
        'index': 4,
        'lineId': 'line_a',
        'line': '主线',
        'episodeUrl': 'https://user:pass@cdn.example/vod/ep5.m3u8?token=topsecret999&expires=999999#frag',
        'position': 88000,
        'duration': 1800000,
        'updated': 1732500000000,
      };
      final parsed = WatchHistoryEntry.fromJson(legacyJson);
      expect(parsed.episodeMediaId, startsWith(WatchHistoryEntry.mediaIdPrefix));
      expect(parsed.episodeMediaId, isNot(contains('topsecret999')));
      expect(parsed.episodeMediaId, isNot(contains('user:pass')));

      final reEncoded = jsonEncode(parsed.toJson());
      expect(reEncoded, isNot(contains('topsecret999')));
      expect(reEncoded, isNot(contains('episodeUrl')));

      // Matches rotated token on same media asset, rejects different path
      expect(
        WatchHistoryEntry.matchesEpisodeUrl(
          parsed.effectiveMediaId,
          'https://cdn.example/vod/ep5.m3u8?token=brandnewtoken777',
        ),
        isTrue,
      );
      expect(
        WatchHistoryEntry.matchesEpisodeUrl(
          parsed.effectiveMediaId,
          'https://cdn.example/vod/ep6.m3u8?token=brandnewtoken777',
        ),
        isFalse,
      );

      // Survives full storage backup export + import + sync export + merge
      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageService.keyWatchHistory: jsonEncode([legacyJson]),
      });
      final storage = await StorageService.init();
      final backup = storage.exportBackupJson();
      expect(backup, isNot(contains('topsecret999')));
      expect(backup, contains(WatchHistoryEntry.mediaIdPrefix));

      final syncJson = jsonEncode(storage.exportSyncPayload());
      expect(syncJson, isNot(contains('topsecret999')));
      expect(syncJson, contains(WatchHistoryEntry.mediaIdPrefix));

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final restoredStorage = await StorageService.init();
      await restoredStorage.importBackupJson(backup);
      final restored = restoredStorage.getWatchHistory();
      expect(restored.length, 1);
      expect(
        WatchHistoryEntry.matchesEpisodeUrl(
          restored.first.effectiveMediaId,
          'https://cdn.example/vod/ep5.m3u8?token=rotated_after_restore',
        ),
        isTrue,
      );
    });
  });
}

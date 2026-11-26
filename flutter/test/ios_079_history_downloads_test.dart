import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_download_groups_view.dart';
import 'package:marco_movie/ui/ios_history_poster_wall.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'test_storage_helper.dart';

class _TestDownloadPaths extends PathProviderPlatform {
  final Directory root;
  _TestDownloadPaths(this.root);
  @override
  Future<String?> getDownloadsPath() async => '${root.path}/downloads';
  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

CmsClient _buildFixtureCmsClient({List<String>? openedIds}) {
  return CmsClient(
    client: MockClient((request) async {
      final id = request.url.queryParameters['ids'];
      if (id != null) {
        openedIds?.add(id);
        return http.Response(
          jsonEncode({
            'list': [
              {
                'vod_id': id,
                'vod_name': '测试剧集 $id',
                'vod_play_from': '主线路',
                'vod_play_url': '第1集\$https://media.example/$id/ep1.mp4#'
                    '第2集\$https://media.example/$id/ep2.mp4',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        '{"class":[{"type_id":"1","type_name":"剧集"}],"list":[]}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

Future<StorageService> _prepareLibraryStorage({
  List<WatchHistoryEntry> history = const [],
  List<(CmsSite, CmsVideo)> favorites = const [],
}) async {
  final storage = await initTestStorage(
    initialPrefs: const <String, Object>{'onboarding_done_version': 1},
  );
  await storage.saveConfig(
    '{"sites":['
    '{"key":"s1","name":"主力源","type":1,"api":"https://a.example/api"}'
    ']}',
  );
  for (final fav in favorites) {
    await storage.toggleFavorite(fav.$1, fav.$2);
  }
  for (final h in history) {
    await storage.upsertWatchHistory(h);
  }
  return storage;
}

DownloadTask _makeTask({
  required String id,
  String siteKey = 's1',
  String videoId = 'vid1',
  String title = '漫长的季节',
  String poster = '',
  String lineName = '蓝光主线',
  String episodeName = '第1集',
  int episodeIndex = 0,
  int createdAt = 1000,
  DownloadStatus status = DownloadStatus.queued,
  double progress = 0.0,
  int receivedBytes = 0,
  int totalBytes = 0,
  double speed = 0.0,
  String filePath = '',
  String error = '',
}) {
  final t = DownloadTask(
    id: id,
    siteKey: siteKey,
    siteName: '主力源',
    siteApi: 'https://a.example/api',
    siteType: 1,
    videoId: videoId,
    title: title,
    poster: poster,
    lineName: lineName,
    episodeName: episodeName,
    episodeIndex: episodeIndex,
    sourceUrl: 'https://cdn.example/$videoId/$episodeIndex.mp4',
    headers: const {},
    createdAt: createdAt,
    status: status,
    progress: progress,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    filePath: filePath,
    error: error,
  );
  t.speed = speed;
  return t;
}

class _ObserverCollector extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempRoot;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('marco-ios079-ui-');
    PathProviderPlatform.instance = _TestDownloadPaths(tempRoot);
  });

  setUp(() {
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(false);
    IosDownloadGroupsView.resetExpandedForTest();
  });

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosDownloadGroupsView.resetExpandedForTest();
    messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    DownloadService.instance.resetForTesting();
  });

  tearDownAll(() async {
    try {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Item 3 — iOS History Poster Wall & Long-Press Context Menu', () {
    test('iosHistoryFormatClock and iosHistoryCardSubtitle format cleanly', () {
      expect(iosHistoryFormatClock(0), '0:00');
      expect(iosHistoryFormatClock(125000), '2:05');
      expect(iosHistoryFormatClock(3723000), '1:02:03');

      expect(
        iosHistoryCardSubtitle(
          const WatchHistoryEntry(
            site: 's1',
            id: 'v1',
            title: '测试剧',
            episode: '第3集',
            position: 754000,
            duration: 2400000,
          ),
        ),
        '第3集 · 看到 12:34',
      );
      expect(
        iosHistoryCardSubtitle(
          const WatchHistoryEntry(
            site: 's1',
            id: 'v2',
            title: '已看完剧',
            episode: '第12集',
            position: 2380000,
            duration: 2400000,
          ),
        ),
        '第12集 · 已看完',
      );
      expect(
        iosHistoryCardSubtitle(
          const WatchHistoryEntry(
            site: 's1',
            id: 'v3',
            title: '无集名剧',
            index: 4,
            position: 0,
            duration: 0,
          ),
        ),
        '第 5 集',
      );
    });

    testWidgets(
      'iOS 观看历史 renders poster wall matching 收藏片单 grid, shows progress bars, hides swipe hint, keeps 清空记录, and opens with PosterExpandRoute',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _prepareLibraryStorage(
          favorites: const [
            (
              CmsSite(
                key: 's1',
                name: '主力源',
                type: 1,
                api: 'https://a.example/api',
              ),
              CmsVideo(
                id: 'fav_1',
                title: '收藏参考片',
                remarks: 'HD',
              ),
            ),
          ],
          history: const [
            WatchHistoryEntry(
              site: 's1',
              id: 'hist_active',
              title: '繁花',
              episode: '第2集',
              position: 125000,
              duration: 500000,
              updated: 3000,
            ),
            WatchHistoryEntry(
              site: 's1',
              id: 'hist_done',
              title: '漫长的季节',
              episode: '第12集',
              position: 2390000,
              duration: 2400000,
              updated: 2000,
            ),
            WatchHistoryEntry(
              site: 's1',
              id: 'hist_zero',
              title: '三体',
              episode: '第1集',
              position: 0,
              duration: 0,
              updated: 1000,
            ),
          ],
        );
        final openedIds = <String>[];
        final observer = _ObserverCollector();
        final client = _buildFixtureCmsClient(openedIds: openedIds);

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Open 片库 -> starts on 收藏片单
        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        final favGrid = tester.widget<GridView>(find.byType(GridView).first);
        final favDelegate =
            favGrid.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent;

        // Switch to 观看历史
        await tester.tap(find.text('观看历史').first);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ios-history-poster-wall')),
          findsOneWidget,
        );
        // Old swipe-to-delete hint is removed on iOS, while 清空记录 remains
        expect(find.textContaining('向左滑动单条记录'), findsNothing);
        expect(find.text('清空记录'), findsOneWidget);

        // Grid rhythm matches 收藏片单
        final histGrid = tester.widget<GridView>(
          find.byKey(const ValueKey('ios-history-poster-wall')),
        );
        final histDelegate =
            histGrid.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent;
        expect(
          histDelegate.maxCrossAxisExtent,
          favDelegate.maxCrossAxisExtent,
        );
        expect(histDelegate.mainAxisSpacing, favDelegate.mainAxisSpacing);
        expect(histDelegate.crossAxisSpacing, favDelegate.crossAxisSpacing);
        expect(histDelegate.childAspectRatio, favDelegate.childAspectRatio);

        // Titles, episode/time subtitles, and progress bars (2 with progress, 1 without)
        expect(find.text('繁花'), findsOneWidget);
        expect(find.text('第2集 · 看到 2:05'), findsOneWidget);
        expect(find.text('漫长的季节'), findsOneWidget);
        expect(find.text('第12集 · 已看完'), findsOneWidget);
        expect(find.text('三体'), findsOneWidget);
        expect(find.text('第1集'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ios-history-progress')),
          findsNWidgets(2),
        );

        // Tap card -> pushes PosterExpandRoute via _openSyncedMediaEntry
        observer.pushed.clear();
        await tester.tap(find.byKey(const ValueKey('lib_hist_s1_hist_active')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(observer.pushed.whereType<PosterExpandRoute<void>>(), isNotEmpty);
        expect(openedIds, contains('hist_active'));

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'non-iOS 观看历史 preserves original swipe-to-delete list and hint unchanged',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _prepareLibraryStorage(
          history: const [
            WatchHistoryEntry(
              site: 's1',
              id: 'mac_h1',
              title: '桌面端历史记录',
              episode: '第1集',
              position: 60000,
              duration: 600000,
              updated: 1000,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: _buildFixtureCmsClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('观看历史').first);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ios-history-poster-wall')),
          findsNothing,
        );
        expect(find.textContaining('向左滑动单条记录'), findsOneWidget);
        expect(find.text('桌面端历史记录'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'iOS 14–25 fallback: long-press opens clean glass context menu, 删除记录 deletes with undo banner, and 撤销 restores',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _prepareLibraryStorage(
          history: const [
            WatchHistoryEntry(
              site: 's1',
              id: 'fallback_del_1',
              title: '狂飙',
              episode: '第8集',
              position: 300000,
              duration: 2700000,
              updated: 5000,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: _buildFixtureCmsClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('观看历史').first);
        await tester.pumpAndSettle();

        final card = find.byKey(const ValueKey('lib_hist_s1_fallback_del_1'));
        expect(card, findsOneWidget);

        await tester.longPress(card);
        await tester.pumpAndSettle();

        // Flutter fallback glass menu opens with 继续播放 and 删除记录
        final menu = find.byKey(const ValueKey('ios-history-longpress-menu'));
        expect(menu, findsOneWidget);
        expect(
          find.descendant(of: menu, matching: find.text('继续播放')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: menu, matching: find.text('删除记录')),
          findsOneWidget,
        );

        await tester.tap(find.descendant(of: menu, matching: find.text('删除记录')));
        await tester.pumpAndSettle();

        expect(storage.getWatchHistory(), isEmpty);
        expect(card, findsNothing);
        expect(
          find.byKey(const ValueKey('ios-undo-history-banner')),
          findsOneWidget,
        );
        expect(find.text('已删除「狂飙」'), findsOneWidget);

        // Undo restores the item into storage and the poster wall
        await tester.tap(find.byKey(const ValueKey('ios-undo-history-action')));
        await tester.pumpAndSettle();
        expect(storage.getWatchHistory().length, 1);
        expect(card, findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'iOS 26+ native channel: long-press invokes showMenuAtRect and 删除记录 triggers undoable removal',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Map<String, dynamic>? capturedMenuCall;
        String? nextMenuSelection = kIosHistoryMenuDelete;
        messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, (
          call,
        ) async {
          if (call.method == 'showMenuAtRect') {
            capturedMenuCall = Map<String, dynamic>.from(call.arguments as Map);
            return nextMenuSelection;
          }
          return null;
        });

        final storage = await _prepareLibraryStorage(
          history: const [
            WatchHistoryEntry(
              site: 's1',
              id: 'native_del_1',
              title: '觉醒年代',
              episode: '第6集',
              position: 600000,
              duration: 2400000,
              updated: 9000,
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: _buildFixtureCmsClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('观看历史').first);
        await tester.pumpAndSettle();

        // Activate iOS 26+ native bridge and rebuild poster card
        IosLiquidGlassBridge.setAvailableForTest(true);
        await storage.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 's1',
            id: 'native_del_1',
            title: '觉醒年代',
            episode: '第6集',
            position: 610000,
            duration: 2400000,
            updated: 9001,
          ),
        );
        await tester.pump();

        final card = find.byKey(const ValueKey('lib_hist_s1_native_del_1'));
        expect(card, findsOneWidget);

        await tester.longPress(card);
        await tester.pumpAndSettle();

        expect(capturedMenuCall, isNotNull);
        final rect = Map<String, dynamic>.from(
          capturedMenuCall!['anchorRect'] as Map,
        );
        expect((rect['width'] as num).toDouble(), greaterThan(50));
        expect((rect['height'] as num).toDouble(), greaterThan(80));
        final items = (capturedMenuCall!['items'] as List).cast<Map>();
        expect(items.map((e) => e['id']).toList(), [
          kIosHistoryMenuResume,
          kIosHistoryMenuDelete,
        ]);
        expect(items.last['title'], '删除记录');
        expect(items.last['destructive'], isTrue);

        // Deleted & undo banner visible
        expect(storage.getWatchHistory(), isEmpty);
        expect(
          find.byKey(const ValueKey('ios-undo-history-banner')),
          findsOneWidget,
        );

        // Undo brings it right back
        await tester.tap(find.byKey(const ValueKey('ios-undo-history-action')));
        await tester.pumpAndSettle();
        expect(storage.getWatchHistory().length, 1);
        expect(card, findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('Item 4a — Grouped Collapsible Series Downloads on iOS', () {
    test(
      'groupDownloadTasks groups by siteKey+videoId (fallback title), sorts episodes, and computes aggregate metrics',
      () {
        final tasks = [
          _makeTask(
            id: 'ep3',
            siteKey: 's1',
            videoId: 'v100',
            title: '庆余年',
            lineName: '线路A',
            episodeName: '第3集',
            episodeIndex: 2,
            createdAt: 300,
            status: DownloadStatus.queued,
            progress: 0.0,
          ),
          _makeTask(
            id: 'ep1',
            siteKey: 's1',
            videoId: 'v100',
            title: '庆余年',
            poster: 'https://img.example/qyn.jpg',
            lineName: '线路A',
            episodeName: '第1集',
            episodeIndex: 0,
            createdAt: 100,
            status: DownloadStatus.completed,
            progress: 1.0,
            totalBytes: 100 * 1024 * 1024,
          ),
          _makeTask(
            id: 'ep2',
            siteKey: 's1',
            videoId: 'v100',
            title: '庆余年',
            lineName: '线路A',
            episodeName: '第2集',
            episodeIndex: 1,
            createdAt: 200,
            status: DownloadStatus.downloading,
            progress: 0.5,
            speed: 4 * 1024 * 1024,
          ),
          // Same title on a DIFFERENT siteKey stays in its own group
          _makeTask(
            id: 'other_site',
            siteKey: 's2',
            videoId: 'v100',
            title: '庆余年',
            episodeName: '第1集',
            episodeIndex: 0,
            createdAt: 250,
          ),
          // Empty videoId falls back to title
          _makeTask(
            id: 'fallback_b',
            siteKey: 's1',
            videoId: '',
            title: '无ID合集',
            episodeName: '下集',
            episodeIndex: 1,
            createdAt: 90,
          ),
          _makeTask(
            id: 'fallback_a',
            siteKey: 's2',
            videoId: '',
            title: '无ID合集',
            episodeName: '上集',
            episodeIndex: 0,
            createdAt: 80,
          ),
        ];

        final groups = groupDownloadTasks(tasks);
        expect(groups.length, 3);

        final qyn = groups[0];
        expect(qyn.title, '庆余年');
        expect(qyn.poster, 'https://img.example/qyn.jpg');
        expect(qyn.episodeCount, 3);
        expect(qyn.isSingle, isFalse);
        expect(qyn.tasks.map((t) => t.id).toList(), ['ep1', 'ep2', 'ep3']);
        expect(qyn.completedCount, 1);
        expect(qyn.downloadingCount, 1);
        expect(qyn.queuedCount, 1);
        expect(qyn.progress, closeTo(0.5, 1e-6));
        expect(qyn.speed, 4 * 1024 * 1024);
        final status = downloadGroupStatusLabel(qyn);
        expect(status, contains('下载中'));
        expect(status, contains('已完成 1/3 集'));
        expect(status, contains('50%'));
        expect(status, contains('4.0 MB/s'));

        expect(groups[1].isSingle, isTrue);
        expect(groups[1].lead.id, 'other_site');

        final fallbackGroup = groups[2];
        expect(fallbackGroup.episodeCount, 2);
        expect(fallbackGroup.tasks.map((t) => t.id).toList(), [
          'fallback_a',
          'fallback_b',
        ]);
      },
    );

    testWidgets(
      'IosDownloadGroupsView collapses multi-episode series, expands/collapses remembering state, renders single episode without nesting, and dispatches per-episode & group actions',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final ep1 = _makeTask(
          id: 's_ep1',
          videoId: 'series_1',
          title: '漫长的季节',
          episodeName: '第1集',
          episodeIndex: 0,
          createdAt: 100,
          status: DownloadStatus.completed,
          progress: 1.0,
          totalBytes: 200 * 1024 * 1024,
        );
        final ep2 = _makeTask(
          id: 's_ep2',
          videoId: 'series_1',
          title: '漫长的季节',
          episodeName: '第2集',
          episodeIndex: 1,
          createdAt: 101,
          status: DownloadStatus.downloading,
          progress: 0.4,
          speed: 2 * 1024 * 1024,
        );
        final ep3 = _makeTask(
          id: 's_ep3',
          videoId: 'series_1',
          title: '漫长的季节',
          episodeName: '第3集',
          episodeIndex: 2,
          createdAt: 102,
          status: DownloadStatus.paused,
          progress: 0.2,
        );
        final movie = _makeTask(
          id: 'm_single',
          videoId: 'movie_99',
          title: '流浪地球2',
          episodeName: '正片',
          episodeIndex: 0,
          createdAt: 90,
          status: DownloadStatus.queued,
          progress: 0.0,
        );

        final played = <String>[];
        final paused = <String>[];
        final resumed = <String>[];
        final deletedTasks = <String>[];
        final pausedGroups = <String>[];
        final resumedGroups = <String>[];
        final deletedGroups = <String>[];

        Widget buildSubject(List<DownloadTask> list) {
          return MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  IosDownloadGroupsView(
                    tasks: list,
                    singleRowBuilder: (t) =>
                        ListTile(title: Text('SINGLE:${t.title}')),
                    onPlay: (t) => played.add(t.id),
                    onPause: (t) => paused.add(t.id),
                    onResume: (t) => resumed.add(t.id),
                    onDeleteTask: (t) => deletedTasks.add(t.id),
                    onPauseGroup: (g) => pausedGroups.add(g.key),
                    onResumeGroup: (g) => resumedGroups.add(g.key),
                    onDeleteGroup: (g) => deletedGroups.add(g.key),
                  ),
                ],
              ),
            ),
          );
        }

        await tester.pumpWidget(buildSubject([ep3, ep2, ep1, movie]));
        // Must settle cleanly (zero infinite/continuous animations)
        await tester.pumpAndSettle();

        const groupKey = 'v\u0001s1\u0001series_1';
        expect(
          find.byKey(const ValueKey('ios-dl-group-$groupKey')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ios-dl-group-progress-$groupKey')),
          findsOneWidget,
        );
        expect(find.textContaining('已完成 1/3 集'), findsOneWidget);
        expect(find.textContaining('2.0 MB/s'), findsOneWidget);
        // Single-episode movie renders cleanly via singleRowBuilder without group header
        expect(
          find.byKey(const ValueKey('ios-dl-single-m_single')),
          findsOneWidget,
        );
        expect(find.text('SINGLE:流浪地球2'), findsOneWidget);
        // Collapsed initially: individual episode rows hidden
        expect(find.byKey(const ValueKey('ios-dl-ep-s_ep1')), findsNothing);

        // Tap series header -> expands to show all 3 episodes in order
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-header-$groupKey')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-dl-ep-s_ep1')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-dl-ep-s_ep2')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-dl-ep-s_ep3')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ios-dl-ep-progress-s_ep2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ios-dl-ep-progress-s_ep3')),
          findsOneWidget,
        );

        // Per-episode play (ep1 completed), pause (ep2 downloading), resume (ep3 paused), delete
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-ep-action-s_ep1')),
        );
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-ep-action-s_ep2')),
        );
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-ep-action-s_ep3')),
        );
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-ep-delete-s_ep2')),
        );
        expect(played, ['s_ep1']);
        expect(paused, ['s_ep2']);
        expect(resumed, ['s_ep3']);
        expect(deletedTasks, ['s_ep2']);

        // Group-level pause all (while ep2 is active) & delete group
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-toggle-$groupKey')),
        );
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-delete-$groupKey')),
        );
        expect(pausedGroups, [groupKey]);
        expect(deletedGroups, [groupKey]);

        // Unmount & remount (simulating tab switch / progress rebuild): remembers expanded state!
        ep2.status = DownloadStatus.paused;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(buildSubject([ep3, ep2, ep1, movie]));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-dl-ep-s_ep1')), findsOneWidget);

        // Now no active tasks in series -> group toggle triggers onResumeGroup
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-toggle-$groupKey')),
        );
        expect(resumedGroups, [groupKey]);

        // Tap header again -> collapses cleanly
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-header-$groupKey')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-dl-ep-s_ep1')), findsNothing);
      },
    );

    testWidgets(
      'AdaptiveShell iOS 离线下载 integrates grouped view and confirms whole-series deletion via showAppleNativeAlert',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await _prepareLibraryStorage();
        final client = _buildFixtureCmsClient();
        final service = DownloadService.instance;
        late File d1File1;
        late File d1File2;
        late File soloFile;
        await tester.runAsync(() async {
          service.resetForTesting();
          await service.init(client);
          final rootDir = Directory(service.rootPath);
          await rootDir.create(recursive: true);
          d1File1 = File('${rootDir.path}/d1_ep1.mp4');
          d1File2 = File('${rootDir.path}/d1_ep2.mp4');
          soloFile = File('${rootDir.path}/solo_ep1.mp4');
          await d1File1.writeAsBytes(List<int>.filled(2048, 0x47));
          await d1File2.writeAsBytes(List<int>.filled(2048, 0x47));
          await soloFile.writeAsBytes(List<int>.filled(4096, 0x47));

          service.resetForTesting();
          final supportDir = Directory('${tempRoot.path}/support');
          await supportDir.create(recursive: true);
          final indexFile = File('${supportDir.path}/marco_downloads.json');
          final seeded = [
            _makeTask(
              id: 'drama_1_ep1',
              siteKey: 's1',
              videoId: 'drama_1',
              title: '沉默的真相',
              lineName: '主线',
              episodeName: '第1集',
              episodeIndex: 0,
              createdAt: 200,
              status: DownloadStatus.completed,
              progress: 1.0,
              receivedBytes: 2048,
              totalBytes: 2048,
              filePath: d1File1.path,
            ).toJson(),
            _makeTask(
              id: 'drama_1_ep2',
              siteKey: 's1',
              videoId: 'drama_1',
              title: '沉默的真相',
              lineName: '主线',
              episodeName: '第2集',
              episodeIndex: 1,
              createdAt: 201,
              status: DownloadStatus.completed,
              progress: 1.0,
              receivedBytes: 2048,
              totalBytes: 2048,
              filePath: d1File2.path,
            ).toJson(),
            _makeTask(
              id: 'solo_1_ep1',
              siteKey: 's1',
              videoId: 'solo_1',
              title: '独行月球',
              lineName: '主线',
              episodeName: '正片',
              episodeIndex: 0,
              createdAt: 100,
              status: DownloadStatus.completed,
              progress: 1.0,
              receivedBytes: 4096,
              totalBytes: 4096,
              filePath: soloFile.path,
            ).toJson(),
          ];
          await indexFile.writeAsString(jsonEncode(seeded));
          await service.init(client);
        });

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('离线下载').first);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ios-download-groups-view')),
          findsOneWidget,
        );
        const dramaGroupKey = 'v\u0001s1\u0001drama_1';
        expect(
          find.byKey(const ValueKey('ios-dl-group-$dramaGroupKey')),
          findsOneWidget,
        );
        expect(find.text('沉默的真相'), findsOneWidget);
        expect(find.textContaining('已完成 2/2 集'), findsOneWidget);
        expect(find.text('独行月球'), findsOneWidget);

        // Tap whole-series delete -> CupertinoAlertDialog confirmation -> Cancel keeps series
        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-delete-$dramaGroupKey')),
        );
        await tester.pumpAndSettle();
        expect(find.text('删除整部剧集下载？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(service.tasks.length, 3);

        // Confirm delete via iOS 26+ native showAlert channel -> removes only 沉默的真相 (2 eps)
        messenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async => null,
        );
        IosLiquidGlassBridge.setAvailableForTest(true);
        Map<String, dynamic>? alertArgs;
        messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, (
          call,
        ) async {
          if (call.method == 'showAlert') {
            alertArgs = Map<String, dynamic>.from(call.arguments as Map);
            return 'delete';
          }
          return null;
        });

        await tester.tap(
          find.byKey(const ValueKey('ios-dl-group-delete-$dramaGroupKey')),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        }
        await tester.pumpAndSettle();

        expect(alertArgs, isNotNull);
        expect(alertArgs!['title'], '删除整部剧集下载？');
        expect(service.tasks.length, 1);
        expect(service.tasks.single.videoId, 'solo_1');
        expect(await tester.runAsync(() => d1File1.exists()), isFalse);
        expect(await tester.runAsync(() => d1File2.exists()), isFalse);
        expect(await tester.runAsync(() => soloFile.exists()), isTrue);
        expect(find.text('沉默的真相'), findsNothing);
        expect(find.text('独行月球'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

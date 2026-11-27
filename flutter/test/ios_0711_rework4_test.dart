import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_features.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/cast_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/favorite_postcard_animation.dart';
import 'package:marco_movie/ui/ios_ai_lab_sheets.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_download_groups_view.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_search_page.dart';
import 'package:marco_movie/ui/media_folder_browser_page.dart';
import 'package:marco_movie/ui/player/ios_cast_panel.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

final Uint8List _valid1x1Png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Controllable [SecureStorageBackend] that can pause a specific write so
/// serialization across rapid BYO key edits/clears is deterministically tested.
class _RecordingBlockedHttpOverrides extends HttpOverrides {
  final List<Uri> recorded;
  _RecordingBlockedHttpOverrides(this.recorded);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RecordingBlockedHttpClient(recorded);
}

class _RecordingBlockedHttpClient extends Fake implements HttpClient {
  final List<Uri> recorded;
  _RecordingBlockedHttpClient(this.recorded);

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    recorded.add(url);
    throw const SocketException('blocked in private poster test');
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    recorded.add(url);
    throw const SocketException('blocked in private poster test');
  }
}

class _ControllableSecureBackend implements SecureStorageBackend {
  final Map<String, String> store = <String, String>{};
  final List<String> ops = <String>[];
  String? holdWriteValue;
  Completer<void>? writeHoldEntered;
  Completer<void>? writeHoldRelease;

  @override
  Future<String?> read(String key) async => store[key];

  @override
  Future<void> write(String key, String value) async {
    ops.add('write:$key=$value');
    if (holdWriteValue != null && value == holdWriteValue) {
      holdWriteValue = null;
      writeHoldEntered?.complete();
      await writeHoldRelease?.future;
    }
    store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    ops.add('delete:$key');
    store.remove(key);
  }
}

DownloadTask _makeOfflineTask({
  required String id,
  required String siteKey,
  required String siteApi,
  int siteType = 1,
  String videoId = 'v1',
  String title = '示例影片',
  String lineName = '线路1',
  String episodeName = '第1集',
  int episodeIndex = 0,
  CmsSite? sourceSite,
  String filePath = '/tmp/ep.mp4',
}) {
  return DownloadTask(
    id: id,
    siteKey: siteKey,
    siteName: sourceSite?.name ?? siteKey,
    siteApi: siteApi,
    siteType: siteType,
    videoId: videoId,
    title: title,
    poster: '',
    lineName: lineName,
    episodeName: episodeName,
    episodeIndex: episodeIndex,
    sourceUrl: 'https://cdn.example/$id.mp4',
    headers: const <String, String>{},
    createdAt: 1000 + episodeIndex,
    sourceSite: sourceSite,
    status: DownloadStatus.completed,
    progress: 1.0,
    filePath: filePath,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AiService.instance.resetForTest();
    AiService.instance.setPrivacySessionActive(false);
    PosterLoader.clearPrivateCache();
    PosterLoader.resetDiskCacheConfigForTest();
    IosLiquidGlassBridge.setAvailableForTest(false);
  });

  // =========================================================================
  // P0-1: Offline privacy re-verification across privacy flip + API override + disabled sub
  // =========================================================================
  group('P0-1: Offline privacy checks subscriptionId (including disabled) & original source identity', () {
    test('converting public sub to private then editing API or disabling sub hides old downloads while still-public downloads play', () async {
      final storage = await initTestStorage();
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'vod_flip',
              'name': '将转私密源',
              'type': 1,
              'api': 'https://flip-origin.example/api',
            },
          ],
        }),
        origin: 'https://flip-sub.example/config.json',
        customName: '订阅A',
      );
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'vod_pub',
              'name': '常驻公开源',
              'type': 1,
              'api': 'https://pub-origin.example/api',
            },
          ],
        }),
        origin: 'https://pub-sub.example/config.json',
        customName: '订阅B',
      );

      final initialCfg = storage.loadSavedConfig()!;
      final flipSite = initialCfg.sites.firstWhere((s) => s.key == 'vod_flip');
      final pubSite = initialCfg.sites.firstWhere((s) => s.key == 'vod_pub');

      // Download while BOTH subscriptions are public.
      final taskFlip = _makeOfflineTask(
        id: 't_flip',
        siteKey: flipSite.key,
        siteApi: flipSite.api,
        siteType: flipSite.type,
        videoId: 'v100',
        title: '曾经公开的片',
        sourceSite: flipSite,
        filePath: '/tmp/flip.mp4',
      );
      final taskPub = _makeOfflineTask(
        id: 't_pub',
        siteKey: pubSite.key,
        siteApi: pubSite.api,
        siteType: pubSite.type,
        videoId: 'v200',
        title: '一直公开的片',
        sourceSite: pubSite,
        filePath: '/tmp/pub.mp4',
      );

      // Baseline: both are visible & playable offline when locked.
      expect(
        AdaptiveShell.filterVisibleOfflineTasks(
          [taskFlip, taskPub],
          currentConfig: initialCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ).map((t) => t.id),
        equals(['t_flip', 't_pub']),
      );

      // Step 1: Turn sub A private, then override its site API (preserving originalApi).
      await storage.toggleSubscriptionPrivacy(flipSite.subscriptionId, true);
      final afterPrivateCfg = storage.loadSavedConfig()!;
      final flipNowPrivate =
          afterPrivateCfg.sites.firstWhere((s) => s.key == 'vod_flip');
      await storage.saveSiteOverride(
        flipNowPrivate,
        const SiteOverride(api: 'https://flip-overridden.example/v2'),
      );
      final afterOverrideCfg = storage.loadSavedConfig()!;

      // Locked: old task from sub A MUST NOT appear in public list or queue!
      expect(
        AdaptiveShell.isOfflineTaskPrivate(
          taskFlip,
          currentConfig: afterOverrideCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ),
        isTrue,
      );
      expect(
        AdaptiveShell.filterVisibleOfflineTasks(
          [taskFlip, taskPub],
          currentConfig: afterOverrideCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ).map((t) => t.id),
        equals(['t_pub']),
      );
      final blockedQueueAfterApiEdit = AdaptiveShell.buildOfflinePlaybackQueue(
        taskFlip,
        [taskFlip, taskPub],
        currentConfig: afterOverrideCfg,
        storage: storage,
        privacySessionUnlocked: false,
      );
      expect(blockedQueueAfterApiEdit.queue, isEmpty);

      // Step 2: Also test direct API override when ONLY currentConfig (without storage)
      // has the overridden private site carrying `originalApi`.
      expect(
        AdaptiveShell.isOfflineTaskPrivate(
          taskFlip,
          currentConfig: afterOverrideCfg,
          privacySessionUnlocked: false,
        ),
        isTrue,
      );

      // Step 3: Disable the private subscription so loadSavedConfig() omits its sites!
      await storage.toggleSubscriptionEnabled(flipSite.subscriptionId, false);
      final afterDisableCfg = storage.loadSavedConfig()!;
      expect(
        afterDisableCfg.sites.where((s) => s.key == 'vod_flip'),
        isEmpty,
      );

      // Locked: disabled private subscription's old task MUST STILL be hidden & blocked!
      expect(
        AdaptiveShell.isOfflineTaskPrivate(
          taskFlip,
          currentConfig: afterDisableCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ),
        isTrue,
      );
      expect(
        AdaptiveShell.filterVisibleOfflineTasks(
          [taskFlip, taskPub],
          currentConfig: afterDisableCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ).map((t) => t.id),
        equals(['t_pub']),
      );
      expect(
        AdaptiveShell.buildOfflinePlaybackQueue(
          taskFlip,
          [taskFlip, taskPub],
          currentConfig: afterDisableCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ).queue,
        isEmpty,
      );

      // Step 4: Still-public subscription B (even if its API is overridden OR disabled)
      // MUST STILL allow offline playback!
      await storage.saveSiteOverride(
        pubSite,
        const SiteOverride(api: 'https://pub-new-mirror.example/api'),
      );
      final pubOverrideCfg = storage.loadSavedConfig()!;
      final pubQueueOverridden = AdaptiveShell.buildOfflinePlaybackQueue(
        taskPub,
        [taskFlip, taskPub],
        currentConfig: pubOverrideCfg,
        storage: storage,
        privacySessionUnlocked: false,
      );
      expect(pubQueueOverridden.site.isEffectivelyPrivate, isFalse);
      expect(pubQueueOverridden.queue.map((t) => t.id), equals(['t_pub']));

      await storage.toggleSubscriptionEnabled(pubSite.subscriptionId, false);
      final pubDisabledCfg = storage.loadSavedConfig();
      final pubQueueDisabled = AdaptiveShell.buildOfflinePlaybackQueue(
        taskPub,
        [taskFlip, taskPub],
        currentConfig: pubDisabledCfg,
        storage: storage,
        privacySessionUnlocked: false,
      );
      expect(pubQueueDisabled.site.isEffectivelyPrivate, isFalse);
      expect(pubQueueDisabled.queue.map((t) => t.id), equals(['t_pub']));

      // Step 5: An orphaned/unmatched sourceSite task with no matching current site
      // fails closed instead of blindly trusting stale `sourceSite.isPrivate == false`.
      final orphanTask = _makeOfflineTask(
        id: 't_orphan',
        siteKey: 'removed_site',
        siteApi: 'https://gone.example/api',
        sourceSite: const CmsSite(
          key: 'removed_site',
          name: '已删除源',
          type: 1,
          api: 'https://gone.example/api',
          subscriptionId: 'sub_deleted',
          isPrivate: false,
        ),
      );
      expect(
        AdaptiveShell.isOfflineTaskPrivate(
          orphanTask,
          currentConfig: pubOverrideCfg,
          storage: storage,
          privacySessionUnlocked: false,
        ),
        isTrue,
      );
    });
  });

  // =========================================================================
  // P1-2: Preserve non-root trailing slash & reuse exact list group key in playback queue
  // =========================================================================
  group('P1-2: Non-root trailing slash preservation & queue reusing list group key', () {
    test('/media vs /media/, empty videoId across movies, and same videoId across siteTypes stay isolated while multi-episode series plays continuously', () {
      const siteNoSlash = CmsSite(
        key: 'vod',
        name: '端点无斜杠',
        type: 1,
        api: 'https://host.example/media',
        subscriptionId: 'sub_1',
        isPrivate: false,
      );
      const siteWithSlash = CmsSite(
        key: 'vod',
        name: '端点有斜杠',
        type: 1,
        api: 'https://host.example/media/',
        subscriptionId: 'sub_1',
        isPrivate: false,
      );
      const siteType3 = CmsSite(
        key: 'vod',
        name: '类型3端点',
        type: 3,
        api: 'https://host.example/media',
        subscriptionId: 'sub_1',
        isPrivate: false,
      );
      const cfg = CmsConfig(
        sites: <CmsSite>[siteNoSlash, siteWithSlash, siteType3],
      );

      // 1. /media vs /media/
      final epNoSlash1 = _makeOfflineTask(
        id: 'ns_1',
        siteKey: 'vod',
        siteApi: 'https://host.example/media',
        videoId: 'vid_shared',
        title: '无斜杠剧',
        episodeName: '第1集',
        episodeIndex: 0,
        sourceSite: siteNoSlash,
        filePath: '/tmp/ns1.mp4',
      );
      final epNoSlash2 = _makeOfflineTask(
        id: 'ns_2',
        siteKey: 'vod',
        siteApi: 'https://host.example/media',
        videoId: 'vid_shared',
        title: '无斜杠剧',
        episodeName: '第2集',
        episodeIndex: 1,
        sourceSite: siteNoSlash,
        filePath: '/tmp/ns2.mp4',
      );
      final epWithSlash1 = _makeOfflineTask(
        id: 'ws_1',
        siteKey: 'vod',
        siteApi: 'https://host.example/media/',
        videoId: 'vid_shared',
        title: '有斜杠剧',
        episodeName: '第1集',
        episodeIndex: 0,
        sourceSite: siteWithSlash,
        filePath: '/tmp/ws1.mp4',
      );

      // 2. Same videoId, different siteType (type=3 vs type=1)
      final epType3 = _makeOfflineTask(
        id: 't3_1',
        siteKey: 'vod',
        siteApi: 'https://host.example/media',
        siteType: 3,
        videoId: 'vid_shared',
        title: '爬虫版剧',
        episodeName: '第1集',
        episodeIndex: 0,
        sourceSite: siteType3,
        filePath: '/tmp/t3_1.mp4',
      );

      // 3. Empty videoId for two different movies (Movie A has 2 episodes, Movie B has 1)
      final emptyIdMovieA1 = _makeOfflineTask(
        id: 'empty_a1',
        siteKey: 'vod',
        siteApi: 'https://host.example/media',
        videoId: '',
        title: '电影甲',
        episodeName: '上集',
        episodeIndex: 0,
        sourceSite: siteNoSlash,
        filePath: '/tmp/a1.mp4',
      );
      final emptyIdMovieA2 = _makeOfflineTask(
        id: 'empty_a2',
        siteKey: 'vod',
        siteApi: 'https://host.example/media',
        videoId: '',
        title: '电影甲',
        episodeName: '下集',
        episodeIndex: 1,
        sourceSite: siteNoSlash,
        filePath: '/tmp/a2.mp4',
      );
      final emptyIdMovieB1 = _makeOfflineTask(
        id: 'empty_b1',
        siteKey: 'vod',
        siteApi: 'https://host.example/media',
        videoId: '',
        title: '电影乙',
        episodeName: '正片',
        episodeIndex: 0,
        sourceSite: siteNoSlash,
        filePath: '/tmp/b1.mp4',
      );

      final allTasks = <DownloadTask>[
        epNoSlash1,
        epNoSlash2,
        epWithSlash1,
        epType3,
        emptyIdMovieA1,
        emptyIdMovieA2,
        emptyIdMovieB1,
      ];

      // List grouping separates into 5 exact groups (both via AdaptiveShell and default builder).
      final groups = groupDownloadTasks(
        allTasks,
        groupKeyBuilder: (t) => AdaptiveShell.offlineTaskGroupDomainKey(
          t,
          currentConfig: cfg,
        ),
      );
      expect(groups, hasLength(5));
      final defaultGroups = groupDownloadTasks(allTasks);
      expect(defaultGroups, hasLength(5));

      // Queue for /media plays [ns_1, ns_2] ONLY (multi-episode continuous playback).
      final qNoSlash = AdaptiveShell.buildOfflinePlaybackQueue(
        epNoSlash1,
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(qNoSlash.queue.map((t) => t.id), equals(['ns_1', 'ns_2']));
      expect(qNoSlash.startIndex, 0);

      // Queue for /media/ plays [ws_1] ONLY.
      final qWithSlash = AdaptiveShell.buildOfflinePlaybackQueue(
        epWithSlash1,
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(qWithSlash.queue.map((t) => t.id), equals(['ws_1']));

      // Queue for type=3 plays [t3_1] ONLY.
      final qType3 = AdaptiveShell.buildOfflinePlaybackQueue(
        epType3,
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(qType3.queue.map((t) => t.id), equals(['t3_1']));

      // Queue for empty videoId Movie A plays [empty_a1, empty_a2] ONLY (never Movie B).
      final qMovieA = AdaptiveShell.buildOfflinePlaybackQueue(
        emptyIdMovieA1,
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(qMovieA.queue.map((t) => t.id), equals(['empty_a1', 'empty_a2']));

      // Queue for empty videoId Movie B plays [empty_b1] ONLY.
      final qMovieB = AdaptiveShell.buildOfflinePlaybackQueue(
        emptyIdMovieB1,
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(qMovieB.queue.map((t) => t.id), equals(['empty_b1']));
    });
  });

  // =========================================================================
  // P1-3: Private poster isolation across all 6 UI entry points & postcard pre-read
  // =========================================================================
  group('P1-3: Private posters never write public disk or leak titles to public services', () {
    testWidgets(
      'Private search, favorite postcard pre-read/fallback, media folder browser, poster expand route, and cast remote stage isolate private covers',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('marco_r4_p3_');
        PosterLoader.resetDiskCacheConfigForTest();
        PosterLoader.debugDiskDirOverride = tempDir;
        await tester.runAsync(() => PosterLoader.clearCache());

        final fetchedPrivateUrls = <String>[];
        PosterLoader.debugPrivateFetcherOverride = (url) async {
          fetchedPrivateUrls.add(url);
          if (url.contains('fail')) {
            throw const SocketException('simulated 404');
          }
          return _valid1x1Png;
        };

        final storage = await tester.runAsync(() => initTestStorage());
        final publicHttpUris = <Uri>[];
        final prevHttp = HttpOverrides.current;
        HttpOverrides.global = _RecordingBlockedHttpOverrides(publicHttpUris);

        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, (
          call,
        ) async {
          if (call.method == 'triggerFavoriteDynamicIslandFeedback') {
            return <String, dynamic>{
              'hasDynamicIsland': true,
              'islandWidth': 126.0,
              'islandHeight': 37.0,
              'islandTop': 11.0,
            };
          }
          return null;
        });

        addTearDown(() async {
          messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
          HttpOverrides.global = prevHttp;
          PosterLoader.clearPrivateCache();
          PosterLoader.resetDiskCacheConfigForTest();
          try {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          } catch (_) {}
        });

        int diskFileCount() =>
            tempDir.listSync().whereType<File>().length;

        // 0. Private Search (`IosGlobalSearchPage` -> `_AggregatedSearchCard` line 3227):
        // Live poster loads strictly via private fetcher; missing/failed poster makes 0
        // public metadata requests.
        const privSearchSite = CmsSite(
          key: 'priv_search',
          name: '私密搜索源',
          type: 1,
          api: 'https://priv-search.example/api',
          isPrivate: true,
        );
        final searchCtrl = TextEditingController(text: '机密');
        final searchRev = ValueNotifier<int>(0);
        addTearDown(() {
          searchCtrl.dispose();
          searchRev.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IosGlobalSearchPage(
                controller: searchCtrl,
                storage: storage!,
                client: CmsClient(
                  client: MockClient((_) async => http.Response('{}', 200)),
                ),
                stateRevision: searchRev,
                readSnapshot: () => const GlobalSearchSnapshot(
                  isPrivate: true,
                  searching: false,
                  searchPerformed: true,
                  searchKeyword: '机密',
                  siteFilterKey: '',
                  searchEpoch: 1,
                  results: <(CmsSite, CmsVideo)>[
                    (
                      privSearchSite,
                      CmsVideo(
                        id: 'ps1',
                        title: '机密搜索影片甲',
                        poster: 'https://priv-search.example/ok.png',
                        year: '2026',
                      ),
                    ),
                    (
                      privSearchSite,
                      CmsVideo(
                        id: 'ps2',
                        title: '机密无图影片乙',
                        poster: '',
                        year: '2026',
                      ),
                    ),
                    (
                      privSearchSite,
                      CmsVideo(
                        id: 'ps3',
                        title: '机密坏图影片丙',
                        poster: 'https://priv-search.example/fail.png',
                        year: '2026',
                      ),
                    ),
                  ],
                  notices: <String, String>{},
                  verificationSites: <String, CmsSite>{},
                  visibleSupportedSites: <CmsSite>[privSearchSite],
                  activeSite: privSearchSite,
                  homeHotVideos: <CmsVideo>[],
                ),
                sourceLabelOf: (s) => s.name,
                onSearch: (_) {},
                onResetSearch: () {},
                onSiteFilterChanged: (_) {},
                onRetryVerifiedSearch: (_) async {},
                onOpenVideoDetail: (_, __) {},
                buildVideoCard: (_, __, {badge, onTap}) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        final searchPosters = tester
            .widgetList<PosterImage>(find.byType(PosterImage))
            .toList();
        expect(searchPosters, isNotEmpty);
        for (final p in searchPosters) {
          expect(p.isPrivate, isTrue);
          expect(p.title, isEmpty);
        }
        expect(fetchedPrivateUrls, contains('https://priv-search.example/ok.png'));
        expect(PosterLoader.publicMemoryCount, 0);
        expect(diskFileCount(), 0);
        expect(publicHttpUris, isEmpty);

        // 1. FavoritePostcardFlightOverlay.show pre-read MUST use private memory
        // partition (NOT public title cache) and keep uncached/failed private posters
        // strictly off public disk & public metadata services.
        await tester.runAsync(
          () => PosterLoader.load(
            'https://priv-post.example/card_cached.png',
            isPrivate: true,
          ),
        );
        expect(
          PosterLoader.peekMemory(
            'https://priv-post.example/card_cached.png',
            isPrivate: true,
          ),
          isNotNull,
        );
        expect(
          PosterLoader.peekMemory(
            'https://priv-post.example/card_cached.png',
            isPrivate: false,
          ),
          isNull,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () {
                      unawaited(
                        FavoritePostcardFlightOverlay.show(
                          ctx,
                          title: '机密收藏片名',
                          posterUrl: 'https://priv-post.example/card_new.png',
                          year: '2026',
                          isPrivate: true,
                          styleOverride: FavoritePostcardStyle.cinemaTicketStub,
                        ),
                      );
                    },
                    child: const Text('TRIGGER_POSTCARD'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('TRIGGER_POSTCARD'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byKey(const Key('favorite-postcard-card')), findsOneWidget);
        final postcardPosters = tester
            .widgetList<PosterImage>(find.byType(PosterImage))
            .toList();
        expect(postcardPosters, isNotEmpty);
        for (final p in postcardPosters) {
          expect(p.isPrivate, isTrue);
          expect(p.title, isEmpty);
        }
        await tester.pump(const Duration(milliseconds: 900));
        expect(
          find.byKey(const Key('favorite-dynamic-island-feedback')),
          findsOneWidget,
        );
        expect(fetchedPrivateUrls, contains('https://priv-post.example/card_new.png'));
        expect(PosterLoader.publicMemoryCount, 0);
        expect(diskFileCount(), 0);
        expect(publicHttpUris, isEmpty);

        // Also test missing/failing poster in FavoritePostcardFlightOverlay: 0 public lookups!
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () {
                      unawaited(
                        FavoritePostcardFlightOverlay.show(
                          ctx,
                          title: '机密缺图收藏',
                          posterUrl: 'https://priv-post.example/card_fail.png',
                          year: '2026',
                          isPrivate: true,
                          styleOverride: FavoritePostcardStyle.filmFrameCard,
                        ),
                      );
                    },
                    child: const Text('TRIGGER_POSTCARD_FAIL'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('TRIGGER_POSTCARD_FAIL'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pump(const Duration(milliseconds: 1500));
        expect(fetchedPrivateUrls, contains('https://priv-post.example/card_fail.png'));
        expect(PosterLoader.publicMemoryCount, 0);
        expect(diskFileCount(), 0);
        expect(publicHttpUris, isEmpty);

        // 2. MediaFolderBrowserPage passes isPrivate & blanks title on private site.
        const privFolderSite = CmsSite(
          key: 'priv_drive',
          name: '私密网盘',
          type: 1,
          api: 'https://priv-drive.example/api',
          isPrivate: true,
        );
        final fakeCms = CmsClient(
          client: MockClient((_) async {
            return http.Response(
              jsonEncode({
                'list': [
                  {
                    'vod_id': 'f1',
                    'vod_name': '私密目录影片',
                    'vod_pic': 'https://priv-drive.example/thumb_ok.png',
                  },
                  {
                    'vod_id': 'f2',
                    'vod_name': '私密坏图影片',
                    'vod_pic': 'https://priv-drive.example/thumb_fail.png',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        await tester.pumpWidget(
          CupertinoApp(
            home: MediaFolderBrowserPage(
              site: privFolderSite,
              client: fakeCms,
              storage: storage,
              folderId: 'root',
              folderTitle: '私密目录',
              onOpenVideo: (_, __) {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          fetchedPrivateUrls,
          contains('https://priv-drive.example/thumb_ok.png'),
        );
        final folderPosters = tester
            .widgetList<PosterImage>(find.byType(PosterImage))
            .toList();
        expect(folderPosters, isNotEmpty);
        for (final p in folderPosters) {
          expect(p.isPrivate, isTrue);
          expect(p.title, isEmpty);
        }
        expect(PosterLoader.publicMemoryCount, 0);
        expect(diskFileCount(), 0);
        expect(publicHttpUris, isEmpty);

        // 3. PosterExpandRoute passes isPrivate & skips title-only shared poster when empty.
        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Column(
                  children: [
                    CupertinoButton(
                      onPressed: () {
                        Navigator.of(ctx).push(
                          PosterExpandRoute<void>(
                            initialSourceRect: const Rect.fromLTWH(20, 80, 120, 180),
                            posterUrl: 'https://priv-expand.example/hero.png',
                            title: '私密转场标题',
                            year: '2026',
                            isPrivate: true,
                            builder: (_) => const SizedBox.expand(),
                          ),
                        );
                      },
                      child: const Text('PUSH_EXPAND'),
                    ),
                    CupertinoButton(
                      onPressed: () {
                        Navigator.of(ctx).push(
                          PosterExpandRoute<void>(
                            initialSourceRect: const Rect.fromLTWH(20, 80, 120, 180),
                            posterUrl: '',
                            title: '私密无图转场标题',
                            year: '2026',
                            isPrivate: true,
                            builder: (_) => const SizedBox.expand(),
                          ),
                        );
                      },
                      child: const Text('PUSH_EXPAND_EMPTY'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('PUSH_EXPAND'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final expandPosters = tester
            .widgetList<PosterImage>(find.byType(PosterImage))
            .toList();
        expect(expandPosters, isNotEmpty);
        for (final p in expandPosters) {
          expect(p.isPrivate, isTrue);
          expect(p.title, isEmpty);
        }
        await tester.pump(const Duration(milliseconds: 500));
        navKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        await tester.tap(find.text('PUSH_EXPAND_EMPTY'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        // Empty posterUrl + isPrivate:true must NOT mount any PosterImage at all.
        expect(find.byType(PosterImage), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(PosterLoader.publicMemoryCount, 0);
        expect(diskFileCount(), 0);
        expect(publicHttpUris, isEmpty);

        // 4. IosCastingRemoteStage passes isPrivate to its background PosterImage.
        final castCtrl = CastController();
        addTearDown(castCtrl.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: IosCastingRemoteStage(
                  controller: castCtrl,
                  episodeLabel: '第1集',
                  posterUrl: 'https://priv-cast.example/bg.png',
                  isPrivate: true,
                  onBack: () {},
                  onSwitchDevice: () {},
                  onExitCast: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        final castPoster = tester.widget<PosterImage>(find.byType(PosterImage));
        expect(castPoster.isPrivate, isTrue);
        expect(fetchedPrivateUrls, contains('https://priv-cast.example/bg.png'));
        expect(PosterLoader.publicMemoryCount, 0);
        expect(diskFileCount(), 0);
        expect(publicHttpUris, isEmpty);

        // 5. Verify detail_screen.dart:5429 & player_screen.dart:5742 pass isPrivate.
        final detailSrc = File('lib/ui/detail_screen.dart').readAsStringSync();
        expect(
          detailSrc,
          contains('isPrivate: _activeSite.isEffectivelyPrivate'),
        );
        final playerSrc = File('lib/ui/player_screen.dart').readAsStringSync();
        expect(playerSrc, contains('isPrivate: _isPrivateBackdrop,'));
      },
    );
  });

  // =========================================================================
  // P1-4: BYO model fetch & picker binding + BYO Keychain slot serialization
  // =========================================================================
  group('P1-4: BYO model fetch/picker config binding & BYO Keychain serialization', () {
    test('in-flight BYO model fetch A aborts and does not write discoveredModels when config switches to B', () async {
      SharedPreferences.setMockInitialValues({});
      final firstEntered = Completer<void>();
      final firstRelease = Completer<void>();

      final client = MockClient((req) async {
        if (req.url.host == 'provider-a.example') {
          if (!firstEntered.isCompleted) firstEntered.complete();
          await firstRelease.future;
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'model-from-a'},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'model-from-b'},
            ],
          }),
          200,
        );
      });

      final sec = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: sec,
        labUnlockedForTest: true,
        resetState: true,
      );
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://provider-a.example/v1',
          model: 'init-a',
        ),
      );
      await AiService.instance.setApiKey('sk-a');

      final fetchA = AiService.instance.fetchAvailableModelOptions();
      await firstEntered.future;

      // Switch config to B while A is still in flight.
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://provider-b.example/v1',
          model: 'keep-b',
        ),
      );
      await AiService.instance.setApiKey('sk-b');
      firstRelease.complete();

      await expectLater(fetchA, throwsA(isA<AiServiceException>()));
      expect(AiService.instance.discoveredModels, isEmpty);
      expect(AiService.instance.config.model, 'keep-b');
    });

    testWidgets(
      'open model picker for A cannot overwrite B when config switches while picker is open',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(430, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final client = MockClient((req) async {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'model-a-picked'},
              ],
            }),
            200,
          );
        });
        final sec = InMemorySecureCredentialStore();
        AiService.instance.configureForTest(
          httpClient: client,
          secureStorage: sec,
          labUnlockedForTest: true,
          resetState: true,
        );
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            baseUrl: 'https://provider-a.example/v1',
            model: 'init-a',
          ),
        );
        await AiService.instance.setApiKey('sk-a');

        await tester.pumpWidget(
          const CupertinoApp(
            home: IosAiSettingsPage(),
          ),
        );
        await tester.pumpAndSettle();

        // Tap "拉取模型列表" (first chip = primary model) -> opens A's picker.
        final fetchBtn = find.text('拉取模型列表').first;
        await tester.ensureVisible(fetchBtn);
        await tester.tap(fetchBtn);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ios-ai-model-picker-sheet')),
          findsOneWidget,
        );
        expect(find.text('model-a-picked'), findsOneWidget);

        // While A's picker modal is open, switch underlying config to B!
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            baseUrl: 'https://provider-b.example/v1',
            model: 'model-b-must-stay',
          ),
        );
        await AiService.instance.setApiKey('sk-b');
        await tester.pump();

        // Now tap A's model inside the stale picker -> MUST NOT save to B!
        await tester.tap(find.text('model-a-picked'));
        await tester.pumpAndSettle();

        expect(AiService.instance.config.baseUrl, 'https://provider-b.example/v1');
        expect(AiService.instance.config.model, 'model-b-must-stay');
      },
    );

    test('rapid BYO API key edit then clear commits strictly in order on cold start', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _ControllableSecureBackend();
      backend.holdWriteValue = 'sk-slow-old';
      backend.writeHoldEntered = Completer<void>();
      backend.writeHoldRelease = Completer<void>();

      AiService.instance.configureForTest(
        secureStorage: backend,
        labUnlockedForTest: true,
        resetState: true,
      );
      await AiService.instance.ensureLoaded();

      // Fire slow write A, then rapidly overwrite B and clear to empty!
      final f1 = AiService.instance.setApiKey('sk-slow-old');
      await backend.writeHoldEntered!.future;
      final f2 = AiService.instance.setApiKey('sk-intermediate');
      final f3 = AiService.instance.setApiKey('');

      backend.writeHoldRelease!.complete();
      await Future.wait([f1, f2, f3]);

      // Cold start reload MUST read empty key (never resurrected 'sk-slow-old')!
      await AiService.instance.reload();
      expect(await AiService.instance.readApiKey(), isEmpty);
      expect(backend.store.containsKey(AiService.secureApiKeySlot), isFalse);

      // Now test rapid clear -> final key -> cold start reads final key!
      backend.holdWriteValue = 'sk-temp-1';
      backend.writeHoldEntered = Completer<void>();
      backend.writeHoldRelease = Completer<void>();
      final g1 = AiService.instance.setApiKey('sk-temp-1');
      await backend.writeHoldEntered!.future;
      final g2 = AiService.instance.setApiKey('');
      final g3 = AiService.instance.setApiKey('sk-final-winner');
      backend.writeHoldRelease!.complete();
      await Future.wait([g1, g2, g3]);

      await AiService.instance.reload();
      expect(await AiService.instance.readApiKey(), 'sk-final-winner');
    });
  });

  // =========================================================================
  // P1-5: Recommended switch resume matching (media ID -> season+ep -> unique name)
  // =========================================================================
  group('P1-5: Recommended switch resume matching', () {
    test('S01E09 42:00 does NOT resume on S02E09; reordered duplicate video.mkv matches by media ID; ambiguous duplicates start at 0', () {
      const fortyTwoMinMs = 42 * 60 * 1000;

      // 1. S01E09 MUST NOT match S02E09!
      const season2Only = <CmsLine>[
        CmsLine(
          id: 'l1',
          name: '主线',
          episodes: <CmsEpisode>[
            CmsEpisode(name: 'S02E09', url: 'https://cdn.example/s02e09.mp4'),
          ],
        ),
      ];
      const histS01E09 = WatchHistoryEntry(
        site: 's1',
        id: 'show1',
        title: '多季剧',
        line: '主线',
        lineId: 'l1',
        episode: 'S01E09',
        index: 0,
        position: fortyTwoMinMs,
        duration: 3600000,
        updated: 1000,
      );
      final crossSeasonRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: season2Only,
        recommendedLineIndex: 0,
        historyEntry: histS01E09,
      );
      expect(crossSeasonRes.resumeMs, 0);

      // Exact S01E09 among [S02E09, S01E09] matches index 1!
      const bothSeasons = <CmsLine>[
        CmsLine(
          id: 'l1',
          name: '主线',
          episodes: <CmsEpisode>[
            CmsEpisode(name: 'S02E09', url: 'https://cdn.example/s02e09.mp4'),
            CmsEpisode(name: 'S01E09', url: 'https://cdn.example/s01e09.mp4'),
          ],
        ),
      ];
      final sameSeasonRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: bothSeasons,
        recommendedLineIndex: 0,
        historyEntry: histS01E09,
      );
      expect(sameSeasonRes.episodeIndex, 1);
      expect(sameSeasonRes.resumeMs, fortyTwoMinMs);

      // 2. Two duplicate-named `video.mkv` reordered: stable mediaId finds exact file!
      final reorderedDuplicates = <CmsLine>[
        const CmsLine(
          id: 'pan1',
          name: '夸克原盘',
          episodes: <CmsEpisode>[
            CmsEpisode(
              name: 'video.mkv',
              url: 'https://cdn.example/folderB/video.mkv?token=new_tok_b',
            ),
            CmsEpisode(
              name: 'video.mkv',
              url: 'https://cdn.example/folderA/video.mkv?token=new_tok_a',
            ),
          ],
        ),
      ];
      final histFileA = WatchHistoryEntry(
        site: 's1',
        id: 'show2',
        title: '同名文件剧',
        line: '夸克原盘',
        lineId: 'pan1',
        episode: 'video.mkv',
        episodeMediaId: WatchHistoryEntry.mediaIdentityForUrl(
          'https://cdn.example/folderA/video.mkv?token=old_tok_a',
        ),
        index: 0,
        position: 900000,
        duration: 3600000,
        updated: 2000,
      );
      final reorderedRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: reorderedDuplicates,
        recommendedLineIndex: 0,
        historyEntry: histFileA,
      );
      expect(reorderedRes.episodeIndex, 1);
      expect(reorderedRes.resumeMs, 900000);

      // 3. Ambiguous duplicate `video.mkv` without mediaId -> starts from 0!
      const histNoMediaId = WatchHistoryEntry(
        site: 's1',
        id: 'show2',
        title: '同名文件剧',
        line: '夸克原盘',
        lineId: 'pan1',
        episode: 'video.mkv',
        index: 0,
        position: 900000,
        duration: 3600000,
        updated: 2000,
      );
      final ambiguousRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: reorderedDuplicates,
        recommendedLineIndex: 0,
        historyEntry: histNoMediaId,
      );
      expect(ambiguousRes.episodeIndex, 0);
      expect(ambiguousRes.resumeMs, 0);
    });
  });

  // =========================================================================
  // P1-6: AI Subtitle Studio language switch preserves mounted A & releases busy on cancel
  // =========================================================================
  group('P1-6: AI Subtitle Studio language switch & cancelled continuation busy release', () {
    testWidgets(
      'mount A, paste B, switch to Simplified Chinese keeps A on screen; switching language during #121 continuation releases busy state',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var clipboardText =
            '1\n00:00:10,000 --> 00:00:13,000\nDraft B Only\n';
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboardText};
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        });

        final cuesA = <AiSubtitleCue>[
          const AiSubtitleCue(
            index: 1,
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
            text: 'Mounted Track A',
            translatedText: '已挂载轨道甲',
          ),
        ];
        var screenCues = List<AiSubtitleCue>.of(cuesA);
        var screenBilingual = true;
        var mountGen = 0;

        await tester.pumpWidget(
          CupertinoApp(
            home: Builder(
              builder: (ctx) => CupertinoButton(
                onPressed: () {
                  unawaited(
                    showIosAiSubtitleStudioSheet(
                      ctx,
                      seriesTitle: '测试片',
                      episodeLabel: '第1集',
                      skipIntroSeconds: 0,
                      initialSession: AiSubtitleSessionState(
                        cues: cuesA,
                        overlayActive: true,
                        bilingual: true,
                        draftCues: cuesA,
                        draftMatchesOverlay: true,
                      ),
                      getOverlayMountGen: () => mountGen,
                      hasActiveSubtitleOverlay: true,
                      onApplySubtitleOverlay: (
                        cues, {
                        required bilingual,
                        required offset,
                        required label,
                      }) async {
                        mountGen++;
                        screenCues = List<AiSubtitleCue>.of(cues);
                        screenBilingual = bilingual;
                      },
                    ),
                  );
                },
                child: const Text('OPEN_A_B'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('OPEN_A_B'));
        await tester.pumpAndSettle();

        // Paste draft B -> screen stays A.
        final pasteBtn = find.byKey(const ValueKey('ai-sub-paste-btn'));
        await tester.ensureVisible(pasteBtn);
        await tester.tap(pasteBtn);
        await tester.pumpAndSettle();
        expect(screenCues.single.text, 'Mounted Track A');

        // Switch to "仅简体中文" -> adjusts mounted A only, NEVER mounts draft B!
        final zhOnlyBtn = find.text('仅简体中文');
        await tester.ensureVisible(zhOnlyBtn);
        await tester.tap(zhOnlyBtn);
        await tester.pumpAndSettle();
        expect(screenCues.single.text, 'Mounted Track A');
        expect(screenBilingual, isFalse);

        // Dismiss sheet.
        Navigator.of(tester.element(zhOnlyBtn)).pop();
        await tester.pumpAndSettle();

        // Part 2: Switch language during #121 continuation -> old response cancelled &
        // sheet releases busy so subsequent actions remain tappable!
        final cues130 = List<AiSubtitleCue>.generate(
          130,
          (i) => AiSubtitleCue(
            index: i + 1,
            start: Duration(seconds: i * 2),
            end: Duration(seconds: i * 2 + 1),
            text: 'Line ${i + 1}',
            translatedText: i < 120 ? '译文 ${i + 1}' : '',
          ),
        );
        final translateEntered = Completer<void>();
        final releaseTranslate = Completer<void>();
        final mockClient = MockClient((req) async {
          if (!translateEntered.isCompleted) translateEntered.complete();
          await releaseTranslate.future;
          final items = [
            for (var i = 121; i <= 130; i++)
              {'index': i, 'zh': '续译 $i'},
          ];
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({'glossary': {}, 'cues': items}),
                    },
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        AiService.instance.configureForTest(
          httpClient: mockClient,
          secureStorage: InMemorySecureCredentialStore(),
          labUnlockedForTest: true,
          resetState: true,
        );
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            baseUrl: 'https://api.example/v1',
            model: 'gpt-4.1',
          ),
        );
        await AiService.instance.setApiKey('sk-r4-sub');

        screenCues = List<AiSubtitleCue>.of(cues130);
        screenBilingual = true;
        await tester.pumpWidget(
          CupertinoApp(
            home: Builder(
              builder: (ctx) => CupertinoButton(
                onPressed: () {
                  unawaited(
                    showIosAiSubtitleStudioSheet(
                      ctx,
                      seriesTitle: '测试片',
                      episodeLabel: '第1集',
                      skipIntroSeconds: 0,
                      initialSession: AiSubtitleSessionState(
                        cues: cues130,
                        overlayActive: true,
                        bilingual: true,
                        draftCues: cues130,
                        draftMatchesOverlay: true,
                      ),
                      getOverlayMountGen: () => mountGen,
                      hasActiveSubtitleOverlay: true,
                      onApplySubtitleOverlay: (
                        cues, {
                        required bilingual,
                        required offset,
                        required label,
                      }) async {
                        mountGen++;
                        screenCues = List<AiSubtitleCue>.of(cues);
                        screenBilingual = bilingual;
                      },
                    ),
                  );
                },
                child: const Text('OPEN_121'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('OPEN_121'));
        await tester.pumpAndSettle();

        final contBtn = find.byKey(const ValueKey('ai-sub-continue-translate-btn'));
        await tester.ensureVisible(contBtn);
        await tester.tap(contBtn);
        await tester.pump();
        await translateEntered.future;

        // Switch language while #121 continuation is in flight!
        final zhBtn2 = find.text('仅简体中文');
        await tester.ensureVisible(zhBtn2);
        await tester.tap(zhBtn2);
        await tester.pump();

        // Release old continuation -> MUST NOT stay stuck busy and MUST NOT apply stale cues!
        releaseTranslate.complete();
        await tester.pumpAndSettle();

        expect(screenBilingual, isFalse);
        expect(screenCues[120].translatedText, isEmpty);
        final mainBtn = tester.widget<CupertinoButton>(
          find.byKey(const ValueKey('ai-sub-translate-mount-btn')),
        );
        expect(mainBtn.onPressed, isNotNull);
        final contBtnWidget = tester.widget<CupertinoButton>(contBtn);
        expect(contBtnWidget.onPressed, isNotNull);
      },
    );
  });

  // =========================================================================
  // P1-7 & P2-8: AVPlayer legible mode separation & LiquidGlass rotation baseline
  // =========================================================================
  group('P1-7 & P2-8: AVPlayer live-translate vs external SRT suppression & LiquidGlass coordinate baseline', () {
    test('IosAvPlayerController distinguishes liveTranslation vs externalOverlay suppression payloads and Swift guards match', () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('marco_movie/test_av_r4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'open') return true;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final ctrl = IosAvPlayerController(
        channelOverride: channel,
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      // 1. Live translation mode sends bool `true` (allowNonText=false -> preserves bitmap tracks).
      await ctrl.setSuppressNativeSubtitleRendering(true);
      // 2. Explicit external SRT overlay on bitmap track sends map with allowNonText=true.
      await ctrl.setSuppressNativeSubtitleRendering(true, allowNonText: true);
      // 3. Switching back from external overlay to live translation sends bool `true`.
      await ctrl.setSuppressNativeSubtitleRendering(true, allowNonText: false);
      // 4. Turning off suppression sends `false`.
      await ctrl.setSuppressNativeSubtitleRendering(false);

      final suppressArgs = calls
          .where((c) => c.method == 'setSuppressNativeSubtitleRendering')
          .map((c) => c.arguments)
          .toList();
      expect(suppressArgs, hasLength(4));
      expect(suppressArgs[0], isTrue);
      expect(
        suppressArgs[1],
        equals(<String, dynamic>{
          'suppress': true,
          'allowNonText': true,
          'mode': 'externalOverlay',
        }),
      );
      expect(suppressArgs[2], isTrue);
      expect(suppressArgs[3], isFalse);

      // Open forwards suppressNativeSubtitleAllowNonText.
      await ctrl.open(
        'https://media.example/movie.m3u8',
        suppressNativeSubtitleRendering: true,
        suppressNativeSubtitleAllowNonText: true,
      );
      final openCall = calls.lastWhere((c) => c.method == 'open');
      final openArgs = Map<String, dynamic>.from(openCall.arguments as Map);
      expect(openArgs['suppressNativeSubtitleRendering'], isTrue);
      expect(openArgs['suppressNativeSubtitleAllowNonText'], isTrue);

      // Static Swift checks for P1-7 & P2-8.
      final avSwift = File('ios_native/MarcoAvPlayerEngine.swift').readAsStringSync();
      expect(avSwift, contains('option.mediaSubTypes'));
      expect(avSwift, contains('enum LegibleTrackFormatKind'));
      expect(avSwift, contains('if sawBitmap && !sawText && !sawUnknown'));
      expect(
        avSwift,
        contains('(suppressNativeSubtitleAllowNonText || liveTextTrackReadyToSuppress)'),
      );
      final lgSwift = File('ios_native/MarcoLiquidGlass.swift').readAsStringSync();
      expect(lgSwift, contains('private let initialAnchorHostBounds: CGRect'));
      expect(
        lgSwift,
        contains('private func remappedAnchorRect(for targetHostBounds: CGRect) -> CGRect?'),
      );
      expect(lgSwift, contains('self.transitionSheetBackToPopoverIfNeeded()'));
      final fbStart =
          lgSwift.indexOf('private func transitionPopoverToSheetFallbackIfNeeded()');
      final fbEnd =
          lgSwift.indexOf('private func transitionSheetBackToPopoverIfNeeded()', fbStart);
      final fbBody = lgSwift.substring(fbStart, fbEnd);
      expect(fbBody, contains('anchorRect: remappedAnchor'));
      expect(fbBody, isNot(contains('anchorRect: rawAnchorRect')));
    });
  });
}

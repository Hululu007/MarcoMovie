import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_download_groups_view.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _R5FakePlayerState extends Fake implements PlayerState {
  @override
  Playlist get playlist => const Playlist([]);
  @override
  bool get playing => true;
  @override
  bool get completed => false;
  @override
  Duration get position => const Duration(seconds: 5);
  @override
  Duration get duration => const Duration(minutes: 20);
  @override
  double get volume => 100.0;
  @override
  double get rate => 1.0;
  @override
  bool get buffering => false;
  @override
  Tracks get tracks => const Tracks();
  @override
  Track get track => const Track();
  @override
  List<String> get subtitle => const <String>[];
}

class _R5FakePlayerStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast();
  final heightCtrl = StreamController<int?>.broadcast();
  final trackCtrl = StreamController<Track>.broadcast();
  final tracksCtrl = StreamController<Tracks>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final bufferingCtrl = StreamController<bool>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();
  final volumeCtrl = StreamController<double>.broadcast();
  final subtitleCtrl = StreamController<List<String>>.broadcast();

  @override
  Stream<int?> get width => widthCtrl.stream;
  @override
  Stream<int?> get height => heightCtrl.stream;
  @override
  Stream<Track> get track => trackCtrl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtrl.stream;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<bool> get buffering => bufferingCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;
  @override
  Stream<double> get volume => volumeCtrl.stream;
  @override
  Stream<List<String>> get subtitle => subtitleCtrl.stream;

  void close() {
    widthCtrl.close();
    heightCtrl.close();
    trackCtrl.close();
    tracksCtrl.close();
    positionCtrl.close();
    durationCtrl.close();
    playingCtrl.close();
    bufferingCtrl.close();
    completedCtrl.close();
    errorCtrl.close();
    volumeCtrl.close();
    subtitleCtrl.close();
  }
}

class _R5FakePlayer extends Fake implements Player {
  @override
  final PlayerState state = _R5FakePlayerState();
  @override
  final _R5FakePlayerStream stream = _R5FakePlayerStream();
  @override
  final NativePlayer? platform = null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration duration) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async => stream.close();
}

/// Valid 1x1 red PNG (distinguishable byte-for-byte from [_blue1x1Png]).
final Uint8List _red1x1Png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Valid 1x1 blue PNG (distinguishable byte-for-byte from [_red1x1Png]).
final Uint8List _blue1x1Png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0x60, 0x60, 0xF8, 0x0F,
  0x00, 0x01, 0x04, 0x01, 0x00, 0xC2, 0xD6, 0xF6, 0xF3, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _RealLoopbackHttpOverrides extends HttpOverrides {}

class _TestDownloadPathProvider extends PathProviderPlatform {
  final Directory root;
  _TestDownloadPathProvider(this.root);

  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';

  @override
  Future<String?> getApplicationDocumentsPath() async => '${root.path}/docs';

  @override
  Future<String?> getTemporaryPath() async => '${root.path}/tmp';
}

DownloadTask _makeTask({
  required String id,
  required String siteKey,
  required String siteApi,
  int siteType = 1,
  String videoId = 'v1',
  String title = '演示剧集',
  String lineName = '主线路',
  String episodeName = '第1集',
  int episodeIndex = 0,
  CmsSite? sourceSite,
  String filePath = '/tmp/ep.mp4',
  int? createdAt,
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
    sourceUrl: 'https://cdn.invalid/$id.mp4',
    headers: const <String, String>{},
    createdAt: createdAt ?? (1000 + episodeIndex),
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
    DownloadService.instance.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  // =========================================================================
  // P1-1: Same series across API override stays 1 group & 1 ordered queue
  // =========================================================================
  group('P1-1: Canonical original source identity across API override', () {
    test(
      'episodes downloaded before and after API edit stay in 1 group & 2-episode ordered queue while distinct subs, types, and paths stay isolated',
      () async {
        final storage = await initTestStorage();
        final sub1Raw = jsonEncode({
          'sites': [
            {
              'key': 's1',
              'name': '公开源',
              'type': 1,
              'api': 'https://origin.invalid/media',
            },
            {
              'key': 's1_slash',
              'name': '尾斜杠源',
              'type': 1,
              'api': 'https://origin.invalid/media/',
            },
            {
              'key': 's1_type3',
              'name': '不同类型源',
              'type': 3,
              'api': 'https://origin.invalid/media',
            },
          ],
        });
        final sub2Raw = jsonEncode({
          'sites': [
            {
              'key': 's1',
              'name': '另一公开订阅',
              'type': 1,
              'api': 'https://origin.invalid/media',
            },
          ],
        });
        final sub1 = SubscriptionEntry(
          id: 'sub_pub_1',
          name: '订阅1',
          url: 'https://sub1.invalid/config.json',
          rawContent: sub1Raw,
          enabled: true,
          isPrivate: false,
        );
        final sub2 = SubscriptionEntry(
          id: 'sub_pub_2',
          name: '订阅2',
          url: 'https://sub2.invalid/config.json',
          rawContent: sub2Raw,
          enabled: true,
          isPrivate: false,
        );
        await storage.saveSubscriptions(<SubscriptionEntry>[sub1, sub2]);
        final cfgBefore = storage.loadSavedConfig()!;
        final siteBefore = cfgBefore.sites.firstWhere(
          (s) => s.subscriptionId == 'sub_pub_1' && s.sourceKey == 's1' && s.type == 1,
        );
        final siteSlash = cfgBefore.sites.firstWhere(
          (s) => s.subscriptionId == 'sub_pub_1' && s.sourceKey == 's1_slash',
        );
        final siteType3 = cfgBefore.sites.firstWhere(
          (s) => s.subscriptionId == 'sub_pub_1' && s.sourceKey == 's1_type3',
        );
        final siteSub2 = cfgBefore.sites.firstWhere(
          (s) => s.subscriptionId == 'sub_pub_2' && s.sourceKey == 's1',
        );

        // Download episode 1 BEFORE editing API.
        final ep1 = _makeTask(
          id: 'ep1_before',
          siteKey: siteBefore.key,
          siteApi: siteBefore.api,
          siteType: siteBefore.type,
          videoId: 'drama-42',
          title: '时空回响',
          episodeName: '第1集',
          episodeIndex: 0,
          sourceSite: siteBefore,
          filePath: '/tmp/ep1.mp4',
          createdAt: 1000,
        );

        // Edit API via SiteOverride on the same public subscription.
        await storage.saveSiteOverride(
          siteBefore,
          const SiteOverride(api: 'https://mirror-v2.invalid/api'),
        );
        final cfgAfter = storage.loadSavedConfig()!;
        final siteAfter = cfgAfter.sites.firstWhere(
          (s) => s.subscriptionId == 'sub_pub_1' && s.sourceKey == 's1',
        );
        expect(siteAfter.api, 'https://mirror-v2.invalid/api');
        expect(siteAfter.originalApi, 'https://origin.invalid/media');

        // Download episode 2 AFTER editing API.
        final ep2 = _makeTask(
          id: 'ep2_after',
          siteKey: siteAfter.key,
          siteApi: siteAfter.api,
          siteType: siteAfter.type,
          videoId: 'drama-42',
          title: '时空回响',
          episodeName: '第2集',
          episodeIndex: 1,
          sourceSite: siteAfter,
          filePath: '/tmp/ep2.mp4',
          createdAt: 2000,
        );

        // Distinct subscription, distinct type, distinct trailing-slash URL.
        final epOtherSub = _makeTask(
          id: 'ep_other_sub',
          siteKey: siteSub2.key,
          siteApi: siteSub2.api,
          siteType: siteSub2.type,
          videoId: 'drama-42',
          title: '时空回响',
          episodeName: '第1集',
          episodeIndex: 0,
          sourceSite: siteSub2,
          filePath: '/tmp/other_sub.mp4',
        );
        final epOtherSlash = _makeTask(
          id: 'ep_slash',
          siteKey: siteSlash.key,
          siteApi: siteSlash.api,
          siteType: siteSlash.type,
          videoId: 'drama-42',
          title: '时空回响',
          episodeName: '第1集',
          episodeIndex: 0,
          sourceSite: siteSlash,
          filePath: '/tmp/slash.mp4',
        );
        final epOtherType = _makeTask(
          id: 'ep_type3',
          siteKey: siteType3.key,
          siteApi: siteType3.api,
          siteType: siteType3.type,
          videoId: 'drama-42',
          title: '时空回响',
          episodeName: '第1集',
          episodeIndex: 0,
          sourceSite: siteType3,
          filePath: '/tmp/type3.mp4',
        );

        // Pass newest-first (ep2 before ep1) to match DownloadService.tasks order.
        final resolver = AdaptiveShell.createOfflineDownloadsResolver(
          currentConfig: cfgAfter,
          storage: storage,
          privacySessionUnlocked: false,
        );
        final visible = resolver.filterVisible(<DownloadTask>[
          ep2,
          ep1,
          epOtherSub,
          epOtherSlash,
          epOtherType,
        ]);
        expect(visible.length, 5);

        final groups = groupDownloadTasks(
          visible,
          groupKeyBuilder: resolver.groupKeyOf,
          isTaskPrivate: resolver.isPrivate,
        );
        // 4 groups total: (ep1+ep2 merged), epOtherSub, epOtherSlash, epOtherType.
        expect(groups.length, 4);
        final mergedGroup = groups.firstWhere(
          (g) => g.tasks.any((t) => t.id == 'ep1_before'),
        );
        expect(
          mergedGroup.tasks.map((t) => t.id).toList(),
          equals(<String>['ep1_before', 'ep2_after']),
        );

        // Tapping ep1 yields a 2-episode ordered queue [ep1, ep2] starting at 0.
        final q = AdaptiveShell.buildOfflinePlaybackQueue(
          ep1,
          <DownloadTask>[ep2, ep1, epOtherSub, epOtherSlash, epOtherType],
          currentConfig: cfgAfter,
          storage: storage,
          privacySessionUnlocked: false,
        );
        expect(
          q.queue.map((t) => t.id).toList(),
          equals(<String>['ep1_before', 'ep2_after']),
        );
        expect(q.startIndex, 0);
        expect(q.site.isEffectivelyPrivate, isFalse);

        // Turning sub1 private must immediately hide BOTH ep1 and ep2 when locked.
        await storage.toggleSubscriptionPrivacy('sub_pub_1', true);
        final cfgPrivate = storage.loadSavedConfig();
        final visibleAfterPrivate = AdaptiveShell.filterVisibleOfflineTasks(
          <DownloadTask>[ep2, ep1, epOtherSub],
          currentConfig: cfgPrivate,
          storage: storage,
          privacySessionUnlocked: false,
        );
        expect(
          visibleAfterPrivate.map((t) => t.id).toList(),
          equals(<String>['ep_other_sub']),
        );
        final blockedQ = AdaptiveShell.buildOfflinePlaybackQueue(
          ep1,
          <DownloadTask>[ep2, ep1],
          currentConfig: cfgPrivate,
          storage: storage,
          privacySessionUnlocked: false,
        );
        expect(blockedQ.queue, isEmpty);
      },
    );
  });

  // =========================================================================
  // P1-2: Isolate completed model catalog by service & credentials
  // =========================================================================
  group('P1-2: Service & credential isolation for completed model catalog', () {
    test(
      'Service A catalog mapping demo-model -> id-at-a never rewrites Service B testConnection or inference payloads without refreshing B catalog',
      () async {
        SharedPreferences.setMockInitialValues({});
        final sentBodies = <({Uri url, String auth, Map<String, dynamic> body})>[];

        final mockClient = MockClient((req) async {
          if (req.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'id-at-a',
                    'display_name': 'demo-model',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          final decoded = jsonDecode(req.body) as Map<String, dynamic>;
          sentBodies.add((
            url: req.url,
            auth: req.headers['Authorization'] ?? '',
            body: decoded,
          ));
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'OK'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final service = AiService.instance;
        service.configureForTest(
          httpClient: mockClient,
          secureStorage: InMemorySecureCredentialStore(),
          labUnlockedForTest: true,
          resetState: true,
        );

        // 1. Configure Service A and fetch A's completed model catalog.
        const cfgA = AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://service-a.invalid/v1',
          model: 'demo-model',
        );
        await service.saveConfig(cfgA);
        await service.setApiKey('sk-key-a');
        final aModels = await service.fetchAvailableModelOptions();
        expect(aModels.single.id, 'id-at-a');
        expect(aModels.single.displayName, 'demo-model');
        expect(service.discoveredModels, hasLength(1));

        // While on Service A with key A, display name resolves to id-at-a.
        await service.complete(
          feature: 'ping',
          userPrompt: 'hello A',
          useCache: false,
        );
        expect(sentBodies.last.body['model'], 'id-at-a');

        // 2. Test Service B via configOverride/apiKeyOverride (without refreshing B catalog).
        const cfgB = AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://service-b.invalid/v1',
          model: 'demo-model',
        );
        sentBodies.clear();
        final overridePing = await service.testConnection(
          configOverride: cfgB,
          apiKeyOverride: 'sk-key-b',
        );
        expect(overridePing.ok, isTrue);
        expect(sentBodies.last.url.host, 'service-b.invalid');
        expect(sentBodies.last.body['model'], 'demo-model');

        // 3. Switch saved config to Service B without refreshing B catalog -> both testConnection and inference send demo-model.
        await service.saveConfig(cfgB);
        await service.setApiKey('sk-key-b');
        expect(service.discoveredModels, isEmpty);

        sentBodies.clear();
        final bPing = await service.testConnection();
        expect(bPing.ok, isTrue);
        expect(sentBodies.last.body['model'], 'demo-model');

        await service.complete(
          feature: 'nl_search_v1',
          userPrompt: 'recommend a sci-fi film',
          useCache: false,
        );
        expect(sentBodies.last.body['model'], 'demo-model');

        // 4. Same URL as A, different API key -> still isolated!
        await service.saveConfig(cfgA);
        await service.setApiKey('sk-key-a');
        await service.fetchAvailableModelOptions();
        expect(service.discoveredModels, hasLength(1));

        await service.setApiKey('sk-key-a-other-tenant');
        expect(service.discoveredModels, isEmpty);
        sentBodies.clear();
        await service.testConnection();
        expect(sentBodies.last.body['model'], 'demo-model');
        await service.complete(
          feature: 'ai_work_qa_v1',
          userPrompt: 'same url different key',
          useCache: false,
        );
        expect(sentBodies.last.body['model'], 'demo-model');
      },
    );
  });

  // =========================================================================
  // P1-3: Recommended switch checks unique global media ID before name fallback
  // =========================================================================
  group('P1-3: Recommended switch global stable media ID precedence', () {
    test(
      'old line removed: finds unique historical file on another playable line instead of wrong same-named video.mkv on recommended line, and starts from 0 when ambiguous',
      () {
        const resume42m = 42 * 60 * 1000;
        const history = WatchHistoryEntry(
          site: 's1',
          id: 'm1',
          title: '测试影片',
          poster: '',
          line: '已下架旧线路',
          lineId: 'removed_line',
          episode: 'video.mkv',
          episodeUrl: 'https://cdn.invalid/files/orig-movie-999.mkv',
          index: 0,
          position: resume42m,
          duration: 7200000,
          updated: 1000,
        );

        const linesWithOrigOnLine1 = <CmsLine>[
          CmsLine(
            id: 'rec_line',
            name: '推荐线路',
            episodes: <CmsEpisode>[
              CmsEpisode(
                name: 'video.mkv',
                url: 'https://cdn.invalid/files/wrong-movie-111.mkv',
              ),
            ],
          ),
          CmsLine(
            id: 'backup_line',
            name: '备用线路',
            episodes: <CmsEpisode>[
              CmsEpisode(
                name: 'extra.mkv',
                url: 'https://cdn.invalid/files/extra-000.mkv',
              ),
              CmsEpisode(
                name: 'video.mkv',
                url: 'https://cdn.invalid/files/orig-movie-999.mkv',
              ),
            ],
          ),
        ];

        final resolved = PlayerScreen.resolveRecommendedSwitchTarget(
          playableLines: linesWithOrigOnLine1,
          recommendedLineIndex: 0,
          historyEntry: history,
        );
        expect(resolved.lineIndex, 1);
        expect(resolved.episodeIndex, 1);
        expect(resolved.resumeMs, resume42m);

        // Ambiguous: two playable lines both contain the same media ID -> start from 0.
        const ambiguousMediaIdLines = <CmsLine>[
          CmsLine(
            id: 'l0',
            name: '线路A',
            episodes: <CmsEpisode>[
              CmsEpisode(
                name: 'video.mkv',
                url: 'https://cdn.invalid/files/orig-movie-999.mkv',
              ),
            ],
          ),
          CmsLine(
            id: 'l1',
            name: '线路B',
            episodes: <CmsEpisode>[
              CmsEpisode(
                name: 'video.mkv',
                url: 'https://cdn.invalid/files/orig-movie-999.mkv',
              ),
            ],
          ),
        ];
        final ambigMedia = PlayerScreen.resolveRecommendedSwitchTarget(
          playableLines: ambiguousMediaIdLines,
          recommendedLineIndex: 0,
          historyEntry: history,
        );
        expect(ambigMedia.lineIndex, 0);
        expect(ambigMedia.episodeIndex, 0);
        expect(ambigMedia.resumeMs, 0);

        // Ambiguous duplicate names without media ID match -> start from 0.
        const ambiguousNamesOnRec = <CmsLine>[
          CmsLine(
            id: 'rec_dup',
            name: '推荐线路',
            episodes: <CmsEpisode>[
              CmsEpisode(
                name: 'video.mkv',
                url: 'https://cdn.invalid/files/other-1.mkv',
              ),
              CmsEpisode(
                name: 'video.mkv',
                url: 'https://cdn.invalid/files/other-2.mkv',
              ),
            ],
          ),
        ];
        final ambigName = PlayerScreen.resolveRecommendedSwitchTarget(
          playableLines: ambiguousNamesOnRec,
          recommendedLineIndex: 0,
          historyEntry: history,
        );
        expect(ambigName.lineIndex, 0);
        expect(ambigName.episodeIndex, 0);
        expect(ambigName.resumeMs, 0);
      },
    );
  });

  // =========================================================================
  // P1-4: AVPlayer 3-state subtitle format (text / bitmap / unknown)
  // =========================================================================
  group('P1-4: AVPlayer 3-state subtitle format & unknown-track deferral', () {
    test('IosAvPlayerTrack preserves text, bitmap, and unknown states cleanly', () {
      final textTrack = IosAvPlayerTrack.fromMap(const {
        'id': '0',
        'title': 'English WebVTT',
        'language': 'en',
        'selected': true,
        'subtitleFormat': 'text',
        'isBitmap': false,
        'isTextExtractable': true,
      });
      expect(textTrack.subtitleFormat, IosAvSubtitleFormat.text);
      expect(textTrack.isBitmap, isFalse);
      expect(textTrack.isTextExtractable, isTrue);

      final bitmapTrack = IosAvPlayerTrack.fromMap(const {
        'id': '1',
        'title': 'English',
        'language': 'en',
        'selected': false,
        'subtitleFormat': 'bitmap',
        'isBitmap': true,
        'isTextExtractable': false,
      });
      expect(bitmapTrack.subtitleFormat, IosAvSubtitleFormat.bitmap);
      expect(bitmapTrack.isBitmap, isTrue);
      expect(bitmapTrack.isTextExtractable, isFalse);

      final unknownTrack = IosAvPlayerTrack.fromMap(const {
        'id': '2',
        'title': 'English',
        'language': 'en',
        'selected': false,
        'subtitleFormat': 'unknown',
        'isBitmap': false,
        'isTextExtractable': null,
      });
      expect(unknownTrack.subtitleFormat, IosAvSubtitleFormat.unknown);
      expect(unknownTrack.isBitmap, isFalse);
      expect(unknownTrack.isTextExtractable, isNull);

      // Swift static verification for 3-state enum, unknown preservation, and
      // suppression requiring either external SRT or confirmed text.
      final avSwift = File('ios_native/MarcoAvPlayerEngine.swift').readAsStringSync();
      expect(avSwift, contains('private enum LegibleTrackFormatKind: String'));
      expect(avSwift, contains('case unknown = "unknown"'));
      expect(avSwift, contains('private func classifyLegibleOption('));
      expect(avSwift, contains('entry["subtitleFormat"] = kind.rawValue'));
      expect(avSwift, contains('entry["isTextExtractable"] = NSNull()'));
      expect(avSwift, contains('let liveTextTrackReadyToSuppress ='));
      expect(
        avSwift,
        contains('(legibleTrackConfirmedText || selectedLegibleStaticFormat == .text)'),
      );
      expect(
        avSwift,
        contains('(suppressNativeSubtitleAllowNonText || liveTextTrackReadyToSuppress)'),
      );
    });

    testWidgets(
      'PlayerScreen live translation keeps unknown track native subtitle visible until text arrives, respects bitmap/text track switch, and enforces external SRT + PiP rules',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage();
        await storage.setIosPlaybackEngineMode('avplayer');
        final aiService = AiService.instance;
        aiService.configureForTest(
          httpClient: MockClient((req) async {
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '你好，世界'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
          secureStorage: InMemorySecureCredentialStore(),
          labUnlockedForTest: true,
          resetState: true,
        );
        await aiService.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            baseUrl: 'https://ai.invalid/v1',
            model: 'demo-model',
          ),
        );
        await aiService.setApiKey('sk-av-sub');

        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final suppressCalls = <Object?>[];
        int openedMediaId = 1;
        const sampleSrt =
            '1\n00:00:00,000 --> 00:00:10,000\nExternal SRT line\n';
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': sampleSrt};
          }
          return null;
        });
        messenger.setMockMethodCallHandler(IosAvPlayerController.defaultChannel, (call) async {
          if (call.method == 'open') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            openedMediaId = (args['mediaId'] as num?)?.toInt() ?? 1;
            return true;
          }
          if (call.method == 'setSuppressNativeSubtitleRendering') {
            suppressCalls.add(call.arguments);
            return null;
          }
          if (call.method == 'getTelemetry') {
            return <String, dynamic>{
              'thermalState': 'nominal',
              'physicalMemoryBytes': 4 * 1024 * 1024 * 1024,
              'isPipSupported': true,
              'isPipPossible': true,
              'isPipActive': false,
              'isAirPlayActive': false,
            };
          }
          return null;
        });

        const eventChannelName = 'marco_movie/ios_avplayer_events';
        messenger.setMockMessageHandler(eventChannelName, (ByteData? message) async {
          final call = const StandardMethodCodec().decodeMethodCall(message);
          if (call.method == 'listen' || call.method == 'cancel') {
            return const StandardMethodCodec().encodeSuccessEnvelope(null);
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
          messenger.setMockMethodCallHandler(IosAvPlayerController.defaultChannel, null);
          messenger.setMockMessageHandler(eventChannelName, null);
        });

        const video = CmsVideo(
          id: 'av-sub-v1',
          title: '混轨样片',
          lines: <CmsLine>[
            CmsLine(
              name: 'HLS主线',
              episodes: <CmsEpisode>[
                CmsEpisode(
                  name: '正片',
                  url: 'http://127.0.0.1:9999/media/stream.m3u8',
                ),
              ],
            ),
          ],
        );

        final fakePlayer = _R5FakePlayer();
        final hudPrefs = PlayerHudPrefs(
          isDesktop: false,
          initial: PlayerHudPrefsData.defaultsFor(isDesktop: false),
        );
        addTearDown(hudPrefs.dispose);
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );

        Future<void> emitAvEventDirect(Map<String, dynamic> event) async {
          avCtrl.handleNativeEvent(<Object?, Object?>{
            'mediaId': avCtrl.currentMediaId ?? openedMediaId,
            ...event,
          });
          await tester.pump();
        }

        Map<String, Object?> Function()? inspectState;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: const CmsSite(
                key: 's1',
                name: '测试源',
                type: 1,
                api: 'https://source.invalid/api',
              ),
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugOnBindStateInspectorForTest: (fn) => inspectState = fn,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(avCtrl.currentMediaId, isNotNull, reason: 'AVPlayer must have opened');

        // 1. Report AVPlayer ready with same-language mixed tracks: selected track 0 has
        // insufficient metadata (`unknown`, `isTextExtractable: null`), track 1 is `bitmap`,
        // track 2 is `text`.
        await emitAvEventDirect({
          'type': 'ready',
          'positionMs': 1000,
          'durationMs': 1200000,
          'playing': true,
          'subtitleTracks': [
            {
              'id': '0',
              'title': 'English',
              'language': 'en',
              'selected': true,
              'subtitleFormat': 'unknown',
              'isBitmap': false,
              'isTextExtractable': null,
            },
            {
              'id': '1',
              'title': 'English',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'bitmap',
              'isBitmap': true,
              'isTextExtractable': false,
            },
            {
              'id': '2',
              'title': 'English CC',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'text',
              'isBitmap': false,
              'isTextExtractable': true,
            },
          ],
        });

        // Open AI Assistant -> AI Subtitle Studio -> enable live embedded translate.
        suppressCalls.clear();
        final aiBtn = find.byKey(const Key('player-ai-assistant-button'));
        expect(aiBtn, findsOneWidget);
        await tester.tap(aiBtn);
        await tester.pumpAndSettle();
        final aiSubOption = find.text('AI 双语字幕（实时内封 / 外挂精译）');
        expect(aiSubOption, findsOneWidget);
        await tester.tap(aiSubOption);
        await tester.pumpAndSettle();

        final liveSwitch = find.byKey(const ValueKey('ai-sub-live-switch'));
        expect(liveSwitch, findsOneWidget);
        await tester.tap(liveSwitch);
        await tester.pump();
        Navigator.of(tester.element(find.byType(PlayerScreen))).pop();
        await tester.pumpAndSettle();

        expect(
          inspectState?.call()['aiLiveEnabled'],
          isTrue,
          reason: 'Live embedded translate toggle must be enabled',
        );
        // Unknown track MUST keep native subtitle rendering visible BEFORE real text arrives!
        expect(
          suppressCalls.where((arg) => arg == true),
          isEmpty,
          reason: 'Unknown track must not suppress native subtitle before text is actually emitted',
        );

        // 2. Current unknown track emits real text cue -> suppression MUST immediately flip to `true`!
        suppressCalls.clear();
        await emitAvEventDirect({
          'type': 'subtitleCue',
          'lines': ['Hello world'],
          'hasNativeSamples': false,
        });
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          suppressCalls,
          isNotEmpty,
          reason:
              'mediaId=${avCtrl.currentMediaId} tracks=${avCtrl.subtitleTracks.map((t) => '${t.id}:${t.selected}:${t.subtitleFormat}:${t.isTextExtractable}').toList()} activeLines=${avCtrl.activeSubtitleLines} ctrlSuppress=${avCtrl.suppressNativeSubtitleRendering} state=${inspectState?.call()}',
        );
        expect(suppressCalls.last, isTrue);

        // 3. Switch to same-language bitmap track (id='1') -> suppression MUST flip back to `false`!
        suppressCalls.clear();
        await emitAvEventDirect({
          'type': 'subtitleTracksChanged',
          'subtitleTracks': [
            {
              'id': '0',
              'title': 'English',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'unknown',
              'isBitmap': false,
              'isTextExtractable': null,
            },
            {
              'id': '1',
              'title': 'English',
              'language': 'en',
              'selected': true,
              'subtitleFormat': 'bitmap',
              'isBitmap': true,
              'isTextExtractable': false,
            },
            {
              'id': '2',
              'title': 'English CC',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'text',
              'isBitmap': false,
              'isTextExtractable': true,
            },
          ],
        });
        expect(suppressCalls, isNotEmpty);
        expect(suppressCalls.last, isFalse);

        // 4. Switch to same-language confirmed text track (id='2') -> suppression flips to `true`!
        suppressCalls.clear();
        await emitAvEventDirect({
          'type': 'subtitleTracksChanged',
          'subtitleTracks': [
            {
              'id': '0',
              'title': 'English',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'unknown',
              'isBitmap': false,
              'isTextExtractable': null,
            },
            {
              'id': '1',
              'title': 'English',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'bitmap',
              'isBitmap': true,
              'isTextExtractable': false,
            },
            {
              'id': '2',
              'title': 'English CC',
              'language': 'en',
              'selected': true,
              'subtitleFormat': 'text',
              'isBitmap': false,
              'isTextExtractable': true,
            },
          ],
        });
        expect(suppressCalls, isNotEmpty);
        expect(suppressCalls.last, isTrue);

        // 5. Switch back to bitmap track (id='1') and mount an external SRT overlay ->
        // external SRT MUST send `allowNonText: true` inline, release in PiP, and restore after PiP!
        await emitAvEventDirect({
          'type': 'subtitleTracksChanged',
          'subtitleTracks': [
            {
              'id': '0',
              'title': 'English',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'unknown',
              'isBitmap': false,
              'isTextExtractable': null,
            },
            {
              'id': '1',
              'title': 'English',
              'language': 'en',
              'selected': true,
              'subtitleFormat': 'bitmap',
              'isBitmap': true,
              'isTextExtractable': false,
            },
            {
              'id': '2',
              'title': 'English CC',
              'language': 'en',
              'selected': false,
              'subtitleFormat': 'text',
              'isBitmap': false,
              'isTextExtractable': true,
            },
          ],
        });

        suppressCalls.clear();
        await tester.tap(aiBtn);
        await tester.pumpAndSettle();
        await tester.tap(aiSubOption);
        await tester.pumpAndSettle();
        final pasteBtn = find.byKey(const ValueKey('ai-sub-paste-btn'));
        await tester.ensureVisible(pasteBtn);
        await tester.tap(pasteBtn);
        await tester.pumpAndSettle();
        final directMountBtn = find.byKey(const ValueKey('ai-sub-direct-mount-btn'));
        await tester.ensureVisible(directMountBtn);
        await tester.tap(directMountBtn);
        await tester.pumpAndSettle();

        expect(
          suppressCalls.last,
          equals(<String, dynamic>{
            'suppress': true,
            'allowNonText': true,
            'mode': 'externalOverlay',
          }),
        );

        // Enter PiP -> MUST restore native rendering (`false`)!
        suppressCalls.clear();
        await emitAvEventDirect({
          'type': 'pipStateChanged',
          'active': true,
          'supported': true,
          'possible': true,
          'phase': 'didStart',
        });
        expect(suppressCalls, isNotEmpty);
        expect(suppressCalls.last, isFalse);

        // Exit PiP -> MUST re-suppress with external SRT `allowNonText: true`!
        suppressCalls.clear();
        await emitAvEventDirect({
          'type': 'pipStateChanged',
          'active': false,
          'supported': true,
          'possible': true,
          'phase': 'didStop',
        });
        expect(suppressCalls, isNotEmpty);
        expect(
          suppressCalls.last,
          equals(<String, dynamic>{
            'suppress': true,
            'allowNonText': true,
            'mode': 'externalOverlay',
          }),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  // =========================================================================
  // P2-5: OAuth account switch while catalog is loading re-enables fetch button
  // =========================================================================
  group('P2-5: IosAiSettingsPage fetch button resets on OAuth sign-out / account switch', () {
    testWidgets(
      'signing out A and signing in B while A catalog is loading immediately re-enables fetch for B and ignores A late response',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final accountAFetchEntered = Completer<void>();
        final releaseAccountAFetch = Completer<void>();
        final accountBFetchEntered = Completer<void>();
        final releaseAccountBFetch = Completer<void>();

        final mockClient = MockClient((req) async {
          final auth = req.headers['Authorization'] ?? '';
          if (req.url.path.contains('/wham/usage')) {
            return http.Response(jsonEncode({'plan_type': 'plus'}), 200);
          }
          if (auth == 'Bearer tok-acct-a') {
            if (!accountAFetchEntered.isCompleted) {
              accountAFetchEntered.complete();
            }
            await releaseAccountAFetch.future;
            return http.Response(
              jsonEncode({
                'models': [
                  {'slug': 'model-from-a', 'display_name': 'Model A'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (auth == 'Bearer tok-acct-b') {
            if (!accountBFetchEntered.isCompleted) {
              accountBFetchEntered.complete();
            }
            await releaseAccountBFetch.future;
            return http.Response(
              jsonEncode({
                'models': [
                  {'slug': 'model-from-b', 'display_name': 'Model B'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 401);
        });

        final service = AiService.instance;
        service.configureForTest(
          httpClient: mockClient,
          secureStorage: InMemorySecureCredentialStore(),
          codexModelsEndpoint: 'https://codex.invalid/models',
          codexWebModelsEndpoint: 'https://codex.invalid/web-models',
          codexUsageEndpoint: 'https://codex.invalid/wham/usage',
          labUnlockedForTest: true,
          experimentalOAuthForTest: true,
          resetState: true,
        );
        await service.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'gpt-5.4',
          ),
        );
        await service.setOAuthSession(
          AiOAuthSession(
            accessToken: 'tok-acct-a',
            refreshToken: 'ref-a',
            accountId: 'acct-a',
            email: 'a@example.invalid',
            planType: 'plus',
            expiresAtEpochMs:
                DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
          ),
        );

        await tester.pumpWidget(
          CupertinoApp(
            home: IosAiSettingsPage(service: service),
          ),
        );
        await tester.pumpAndSettle();

        // Use a tall portrait surface so the OAuth fetch chip scrolls cleanly into hit-test bounds.
        tester.view.physicalSize = const Size(390, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpAndSettle();

        // 1. Start catalog fetch for Account A (stays in flight).
        final fetchBtn = find.byKey(const ValueKey('ios-ai-fetch-models-btn'));
        await tester.dragUntilVisible(
          fetchBtn,
          find.byType(Scrollable).first,
          const Offset(0, -180),
        );
        await tester.pumpAndSettle();
        await tester.tap(fetchBtn);
        await tester.pump();
        await accountAFetchEntered.future;
        expect(tester.widget<GestureDetector>(fetchBtn).onTap, isNull);

        // 2. Sign out A and sign in B on the SAME settings page.
        await service.signOutOAuth();
        await tester.pump();
        await service.setOAuthSession(
          AiOAuthSession(
            accessToken: 'tok-acct-b',
            refreshToken: 'ref-b',
            accountId: 'acct-b',
            email: 'b@example.invalid',
            planType: 'pro',
            expiresAtEpochMs:
                DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
          ),
        );
        await tester.pump();

        // Fetch button MUST be immediately re-enabled for Account B!
        expect(
          tester.widget<GestureDetector>(fetchBtn).onTap,
          isNotNull,
          reason: 'Fetch button must not remain disabled after switching OAuth accounts',
        );

        // 3. Tap fetch as B -> release A's late response first -> MUST NOT affect B!
        await tester.tap(fetchBtn);
        await tester.pump();
        await accountBFetchEntered.future;
        expect(tester.widget<GestureDetector>(fetchBtn).onTap, isNull);

        releaseAccountAFetch.complete();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.textContaining('Model A'), findsNothing);
        expect(tester.widget<GestureDetector>(fetchBtn).onTap, isNull);

        // 4. Complete B's fetch -> B's model picker opens cleanly with Model B.
        releaseAccountBFetch.complete();
        await tester.pumpAndSettle();
        expect(find.text('Model B (model-from-b)'), findsOneWidget);
        expect(find.textContaining('Model A'), findsNothing);
      },
    );
  });

  // =========================================================================
  // P2-6: Private DetailScreen & Favorite postcard never show public memory cover
  // =========================================================================
  group('P2-6: Private DetailScreen & Favorite postcard isolate same-URL memory cache', () {
    testWidgets(
      'when public and private covers share a URL and private load is delayed, private DetailScreen and Favorite postcard never render public bytes',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'triggerFavoriteDynamicIslandFeedback') {
            return <String, dynamic>{
              'hasDynamicIsland': true,
              'islandLeft': 130.0,
              'islandTop': 11.0,
              'islandWidth': 126.0,
              'islandHeight': 37.0,
            };
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
        });

        await tester.runAsync(() => PosterLoader.clearCache());
        final storage = await initTestStorage();
        late Completer<void> blueRelease;
        late HttpServer server;
        final realClient = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          _RealLoopbackHttpOverrides(),
        );
        PosterLoader.debugHttpClientFactory = () => realClient;
        await tester.runAsync(() async {
          blueRelease = Completer<void>();
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((req) async {
            await blueRelease.future;
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType('image', 'png');
            req.response.add(_blue1x1Png);
            await req.response.close();
          });
        });
        addTearDown(() async {
          PosterLoader.debugHttpClientFactory = null;
          await tester.runAsync(() async {
            if (!blueRelease.isCompleted) blueRelease.complete();
            realClient.close(force: true);
            await server.close(force: true);
          });
        });
        final sharedUrl = 'http://127.0.0.1:${server.port}/same-cover.png';

        // 1. Seed PUBLIC memory cache with RED bytes at the exact same URL.
        PosterLoader.seedMemoryForTest(
          sharedUrl,
          _red1x1Png,
          title: '公开影片',
          asHd: true,
        );
        expect(
          PosterLoader.peekMemory(sharedUrl, isPrivate: false),
          equals(_red1x1Png),
        );
        expect(
          PosterLoader.peekMemory(sharedUrl, isPrivate: true),
          isNull,
        );

        // 2. Open PRIVATE DetailScreen while private BLUE fetch at the same URL is delayed!
        await tester.pumpWidget(
          CupertinoApp(
            home: DetailScreen(
              site: const CmsSite(
                key: 'priv_s1',
                name: '私密源',
                type: 1,
                api: 'https://priv.invalid/api',
                isPrivate: true,
              ),
              initialVideo: CmsVideo(
                id: 'priv_v1',
                title: '私密片名',
                poster: sharedUrl,
                lines: const <CmsLine>[
                  CmsLine(
                    name: '主线',
                    episodes: <CmsEpisode>[
                      CmsEpisode(
                        name: '正片',
                        url: 'https://priv.invalid/play.m3u8',
                      ),
                    ],
                  ),
                ],
              ),
              client: CmsClient(),
              storage: storage,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        for (final img in tester.widgetList<Image>(find.byType(Image))) {
          final provider = img.image;
          if (provider is MemoryImage) {
            expect(
              provider.bytes,
              isNot(equals(_red1x1Png)),
              reason: 'Private DetailScreen must never show public cached bytes',
            );
          }
        }

        // 3. Tap Favorite while private image load is STILL delayed!
        final favIcon = find.byIcon(CupertinoIcons.heart);
        expect(favIcon, findsWidgets);
        await tester.tap(favIcon.first);
        await tester.pump(const Duration(milliseconds: 120));

        for (final img in tester.widgetList<Image>(find.byType(Image))) {
          final provider = img.image;
          if (provider is MemoryImage) {
            expect(
              provider.bytes,
              isNot(equals(_red1x1Png)),
              reason: 'Favorite postcard must show private image or placeholder, NEVER public bytes',
            );
          }
        }

        // 4. Release delayed private BLUE fetch -> private cache receives BLUE, public stays RED!
        await tester.runAsync(() async => blueRelease.complete());
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          if (PosterLoader.peekMemory(sharedUrl, isPrivate: true) != null) {
            break;
          }
        }
        await tester.pump(const Duration(milliseconds: 150));

        expect(
          PosterLoader.peekMemory(sharedUrl, isPrivate: true),
          equals(_blue1x1Png),
        );
        expect(
          PosterLoader.peekMemory(sharedUrl, isPrivate: false),
          equals(_red1x1Png),
        );

        // 5. Re-favorite now that private BLUE image loaded -> postcard renders private BLUE bytes!
        await tester.pump(const Duration(seconds: 3));
        final heartFill = find.byIcon(CupertinoIcons.heart_fill);
        if (heartFill.evaluate().isNotEmpty) {
          await tester.tap(heartFill.first);
          await tester.pump(const Duration(milliseconds: 80));
        }
        await tester.tap(find.byIcon(CupertinoIcons.heart).first);
        await tester.pump(const Duration(milliseconds: 120));
        final renderedMemBytes = <Uint8List>[
          for (final img in tester.widgetList<Image>(find.byType(Image)))
            if ((img.image is ResizeImage
                    ? (img.image as ResizeImage).imageProvider
                    : img.image)
                is MemoryImage)
              ((img.image is ResizeImage
                      ? (img.image as ResizeImage).imageProvider
                      : img.image) as MemoryImage)
                  .bytes,
        ];
        expect(renderedMemBytes.any((b) => listEquals(b, _red1x1Png)), isFalse);
        expect(renderedMemBytes.any((b) => listEquals(b, _blue1x1Png)), isTrue);

        realClient.close(force: true);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  // =========================================================================
  // P2-7: Linear-time shared index (100 tasks x 250 sites) & instant refresh
  // =========================================================================
  group('P2-7: Shared per-refresh offline site index & instant invalidation', () {
    testWidgets(
      '100 tasks x 250 sites uses linear site reads (far below 75,000) and immediately refreshes on privacy toggle, subscription disable, and API override',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final tempRoot = Directory.systemTemp.createTempSync('marco_r5_p7_');
        final prevProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _TestDownloadPathProvider(tempRoot);
        addTearDown(() {
          PathProviderPlatform.instance = prevProvider;
          DownloadService.instance.resetForTesting();
          try {
            if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
          } catch (_) {}
        });

        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage(initialPrefs: <String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });

        // Build 250 sites across 2 subscriptions (249 in sub_bulk + 1 in sub_target).
        final bulkSites = <Map<String, Object>>[
          for (var i = 0; i < 249; i++)
            <String, Object>{
              'key': 'bulk_$i',
              'name': '站点$i',
              'type': 1,
              'api': 'https://bulk-$i.invalid/api',
            },
        ];
        final targetSites = <Map<String, Object>>[
          <String, Object>{
            'key': 'target_s',
            'name': '目标公开源',
            'type': 1,
            'api': 'https://target-orig.invalid/api',
          },
        ];
        await storage.saveSubscriptions(<SubscriptionEntry>[
          SubscriptionEntry(
            id: 'sub_bulk',
            name: '大订阅',
            url: 'https://bulk.invalid/config.json',
            rawContent: jsonEncode({'sites': bulkSites}),
            enabled: true,
            isPrivate: false,
          ),
          SubscriptionEntry(
            id: 'sub_target',
            name: '目标订阅',
            url: 'https://target.invalid/config.json',
            rawContent: jsonEncode({'sites': targetSites}),
            enabled: true,
            isPrivate: false,
          ),
        ]);

        final cfg = storage.loadSavedConfig()!;
        expect(cfg.sites.length, 250);
        final targetSite = cfg.sites.firstWhere((s) => s.key == 'target_s');

        // Build 100 completed tasks (target_ep1 first so it's at the top of the viewport, plus 99 bulk tasks).
        final tasks = <DownloadTask>[
          _makeTask(
            id: 't_target_ep1',
            siteKey: targetSite.key,
            siteApi: targetSite.api,
            videoId: 'target_vid',
            title: '目标剧集',
            episodeName: '第1集',
            episodeIndex: 0,
            sourceSite: targetSite,
            createdAt: 99999,
          ),
          for (var i = 0; i < 99; i++)
            _makeTask(
              id: 't_bulk_$i',
              siteKey: 'bulk_$i',
              siteApi: 'https://bulk-$i.invalid/api',
              videoId: 'vid_$i',
              title: '影片$i',
              sourceSite: cfg.sites.firstWhere((s) => s.key == 'bulk_$i'),
              createdAt: 1000 + i,
            ),
        ];

        // 1. Direct shared-resolver traversal count for 100 tasks x 250 sites:
        final resolver = AdaptiveShell.createOfflineDownloadsResolver(
          currentConfig: cfg,
          storage: storage,
          privacySessionUnlocked: false,
        );
        final visible = resolver.filterVisible(tasks);
        final groups = groupDownloadTasks(
          visible,
          groupKeyBuilder: resolver.groupKeyOf,
          isTaskPrivate: resolver.isPrivate,
        );
        expect(visible.length, 100);
        expect(groups.length, 100);
        // Linear O(sites + tasks): ~600 site reads vs 75,000 naive scans.
        expect(resolver.siteReadCount, lessThan(1500));

        // 2. Live AdaptiveShell Downloads UI: verify linear reads AND instant UI rebuild on storage mutations!
        final client = CmsClient(
          client: MockClient((_) async => http.Response('{"list":[]}', 200)),
        );
        await tester.runAsync(() async {
          final service = DownloadService.instance;
          service.resetForTesting();
          final supportDir = Directory('${tempRoot.path}/support');
          await supportDir.create(recursive: true);
          await File('${supportDir.path}/marco_downloads.json').writeAsString(
            jsonEncode([for (final t in tasks) t.toJson()]),
          );
          await service.init(client);
        });

        AdaptiveShell.debugLastDownloadsRefreshSiteReads = 0;
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

        expect(find.text('目标剧集'), findsOneWidget);
        expect(AdaptiveShell.debugLastDownloadsRefreshSiteReads, greaterThan(0));
        expect(AdaptiveShell.debugLastDownloadsRefreshSiteReads, lessThan(1500));

        // 2a. Toggle sub_target private -> IMMEDIATELY disappears from visible Downloads UI!
        await tester.runAsync(() => storage.toggleSubscriptionPrivacy('sub_target', true));
        await tester.pump();
        expect(find.text('目标剧集'), findsNothing);

        // 2b. Disable sub_target while still private -> remains hidden!
        await tester.runAsync(() => storage.toggleSubscriptionEnabled('sub_target', false));
        await tester.pump();
        expect(find.text('目标剧集'), findsNothing);

        // 2c. Re-enable & turn public -> IMMEDIATELY reappears!
        await tester.runAsync(() => storage.toggleSubscriptionPrivacy('sub_target', false));
        await tester.runAsync(() => storage.toggleSubscriptionEnabled('sub_target', true));
        await tester.pump();
        expect(find.text('目标剧集'), findsOneWidget);

        // 2d. Apply API override -> site remains public & merges with post-override ep2!
        await tester.runAsync(
          () => storage.saveSiteOverride(
            targetSite,
            const SiteOverride(api: 'https://target-v2.invalid/api'),
          ),
        );
        await tester.pump();
        expect(find.text('目标剧集'), findsOneWidget);

        final updatedTargetSite = storage
            .loadSavedConfig()!
            .sites
            .firstWhere((s) => s.key == 'target_s');
        final ep2 = _makeTask(
          id: 't_target_ep2',
          siteKey: updatedTargetSite.key,
          siteApi: updatedTargetSite.api,
          videoId: 'target_vid',
          title: '目标剧集',
          episodeName: '第2集',
          episodeIndex: 1,
          sourceSite: updatedTargetSite,
          createdAt: 100000,
        );
        final postOverrideResolver = AdaptiveShell.createOfflineDownloadsResolver(
          currentConfig: storage.loadSavedConfig(),
          storage: storage,
          privacySessionUnlocked: false,
        );
        final mergedGroups = groupDownloadTasks(
          postOverrideResolver.filterVisible(<DownloadTask>[ep2, ...tasks]),
          groupKeyBuilder: postOverrideResolver.groupKeyOf,
          isTaskPrivate: postOverrideResolver.isPrivate,
        );
        final targetGroup = mergedGroups.firstWhere(
          (g) => g.tasks.any((t) => t.id == 't_target_ep1'),
        );
        expect(
          targetGroup.tasks.map((t) => t.id).toList(),
          equals(<String>['t_target_ep1', 't_target_ep2']),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

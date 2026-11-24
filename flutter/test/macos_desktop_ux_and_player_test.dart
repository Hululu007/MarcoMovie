import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/anime4k_controller.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/series_scraper.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/danmu/danmu_layer.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/player/desktop_player_hud.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/series_scrape_sheet.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

Future<Uint8List> _makeSolidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

ThemeData _macTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor:
        isDark ? AppleColors.background : ApplePalette.light.background,
    cupertinoOverrideTheme: CupertinoThemeData(brightness: brightness),
    useMaterial3: true,
  );
}

class _MacTestClient extends CmsClient {
  final List<CmsVideo> videos;
  _MacTestClient(this.videos);

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [
        CmsCategory(id: '1', name: '剧集'),
        CmsCategory(id: '2', name: '电影'),
      ],
      CmsListing(videos: videos, page: 1, pageCount: 1),
    );
  }

  @override
  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo fallback) async {
    for (final v in videos) {
      if (v.id == fallback.id) return v;
    }
    return fallback;
  }

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates,
  ) async {
    return (source, await fetchDetail(source, item));
  }
}

class _MacFakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = const Duration(minutes: 45);
  double volumeValue = 80.0;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();
  int? widthValue = 1920;
  int? heightValue = 1080;

  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => playingValue;
  @override
  bool get completed => completedValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => bufferingValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  Track get track => trackValue;
  @override
  int? get width => widthValue;
  @override
  int? get height => heightValue;
}

class _MacFakePlayerStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast(sync: true);
  final heightCtrl = StreamController<int?>.broadcast(sync: true);
  final trackCtrl = StreamController<Track>.broadcast(sync: true);
  final tracksCtrl = StreamController<Tracks>.broadcast(sync: true);
  final positionCtrl = StreamController<Duration>.broadcast(sync: true);
  final durationCtrl = StreamController<Duration>.broadcast(sync: true);
  final playingCtrl = StreamController<bool>.broadcast(sync: true);
  final bufferingCtrl = StreamController<bool>.broadcast(sync: true);
  final completedCtrl = StreamController<bool>.broadcast(sync: true);
  final errorCtrl = StreamController<String>.broadcast(sync: true);
  final volumeCtrl = StreamController<double>.broadcast(sync: true);

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

  Future<void> close() => Future.wait([
        widthCtrl.close(),
        heightCtrl.close(),
        trackCtrl.close(),
        tracksCtrl.close(),
        positionCtrl.close(),
        durationCtrl.close(),
        playingCtrl.close(),
        bufferingCtrl.close(),
        completedCtrl.close(),
        errorCtrl.close(),
        volumeCtrl.close(),
      ]);
}

class _MacFakePlatformPlayer extends Fake implements PlatformPlayer {
  final Map<String, String> properties = <String, String>{};
  Future<void> setProperty(String key, String value) async {
    properties[key] = value;
  }
}

class _MacFakePlayer extends Fake implements Player {
  final _MacFakePlayerState stateImpl = _MacFakePlayerState();
  final _MacFakePlayerStream streamImpl = _MacFakePlayerStream();
  final _MacFakePlatformPlayer platformImpl = _MacFakePlatformPlayer();
  final List<Duration> seeks = <Duration>[];
  final List<double> volumeChanges = <double>[];
  bool _disposed = false;

  @override
  PlatformPlayer? get platform => platformImpl;
  @override
  PlayerState get state => stateImpl;
  @override
  PlayerStream get stream => streamImpl;

  void emitPosition(Duration d) {
    stateImpl.positionValue = d;
    if (!_disposed) streamImpl.positionCtrl.add(d);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      stateImpl.playlistValue = Playlist([playable]);
    }
    stateImpl.playingValue = play;
    stateImpl.bufferingValue = false;
    stateImpl.durationValue = const Duration(minutes: 45);
    stateImpl.positionValue = const Duration(seconds: 5);
    if (!_disposed) {
      streamImpl.durationCtrl.add(stateImpl.durationValue);
      streamImpl.widthCtrl.add(1920);
      streamImpl.heightCtrl.add(1080);
      streamImpl.playingCtrl.add(play);
      streamImpl.bufferingCtrl.add(false);
      streamImpl.positionCtrl.add(stateImpl.positionValue);
    }
  }

  @override
  Future<void> play() async {
    stateImpl.playingValue = true;
    if (!_disposed) streamImpl.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    stateImpl.playingValue = false;
    if (!_disposed) streamImpl.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (stateImpl.playingValue) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration d) async {
    seeks.add(d);
    stateImpl.positionValue = d;
    if (!_disposed) streamImpl.positionCtrl.add(d);
  }

  @override
  Future<void> setVolume(double v) async {
    volumeChanges.add(v);
    stateImpl.volumeValue = v;
    if (!_disposed) streamImpl.volumeCtrl.add(v);
  }

  @override
  Future<void> setRate(double rate) async {
    stateImpl.rateValue = rate;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await streamImpl.close();
  }
}

class _FakeAnime4kController extends Anime4kController {
  @override
  bool isAvailableForPlayer(Player player) => true;
}

class _ObserverRouteSpy extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

class _RecordingDanmuProvider implements DanmuProvider {
  final List<DanmuMatchQuery> queries = <DanmuMatchQuery>[];

  @override
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    queries.add(query);
    return const <DanmuCandidate>[];
  }

  @override
  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuCandidate>[];

  @override
  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      DanmuEpisodeSession(boundEpisodeId: boundEpisodeId, segmented: false);

  @override
  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuItem>[];
}

Future<void> _tabUntilFocused(
  WidgetTester tester,
  Finder target, {
  int maxTabs = 80,
}) async {
  for (var i = 0; i < maxTabs; i++) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary.context != null) {
      final hit = find.descendant(
        of: target,
        matching: find.byElementPredicate((e) => e == primary.context),
        matchRoot: true,
      );
      if (hit.evaluate().isNotEmpty) {
        return;
      }
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail('Could not move keyboard focus to $target within $maxTabs Tab presses');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('window_manager');
  late Uint8List portraitPng;
  late Uint8List landscapePng;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      return null;
    });
    portraitPng = await _makeSolidPng(200, 300, const Color(0xFF334155));
    landscapePng = await _makeSolidPng(640, 360, const Color(0xFF0F766E));
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  const sampleSite = CmsSite(
    key: 'mac-vod',
    name: '星河影院',
    type: 1,
    api: 'https://vod.example/api.php/provide/vod',
  );
  const privateSite = CmsSite(
    key: 'mac-priv',
    name: '私密片源',
    type: 1,
    api: 'https://private.example/api',
    isPrivate: true,
  );

  List<CmsVideo> buildSampleVideos() => List.generate(
        10,
        (i) => CmsVideo(
          id: 'vid-${i + 1}',
          title: '星际奇航 ${i + 1}',
          poster: 'https://img.example/poster_${i + 1}.png',
          year: '2021',
          area: '美国',
          tag: '科幻',
          remarks: '更新至12集',
          description: '宽屏桌面端测试影片简介内容。',
          lines: const [
            CmsLine(
              name: '主线 4K',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://media.example/e1.mp4'),
                CmsEpisode(name: '第02集', url: 'https://media.example/e2.mp4'),
                CmsEpisode(
                  name: 'OVA 特别篇',
                  url: 'https://media.example/sp1.mp4',
                ),
                CmsEpisode(name: '第03集', url: 'https://media.example/e3.mp4'),
              ],
            ),
          ],
        ),
      );

  group('Item 5: macOS Home wide layout, traffic-light clearance & iOS PosterExpandRoute', () {
    testWidgets(
      'scales visible hero & grid cards with window width, docks Continue Watching on wide, keeps traffic-light clearance, and uses PosterExpandRoute on tap',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        PosterLoader.clearCache();
        final videos = buildSampleVideos();
        final storage = await initTestStorage();
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': sampleSite.key,
                'name': sampleSite.name,
                'type': sampleSite.type,
                'api': sampleSite.api,
              },
            ],
          }),
          origin: 'https://vod.example/config.json',
        );
        await storage.upsertWatchHistory(
          WatchHistoryEntry(
            site: sampleSite.key,
            id: videos.first.id,
            title: videos.first.title,
            poster: videos.first.poster,
            line: '主线 4K',
            episode: '第02集',
            index: 1,
            position: 620000,
            duration: 2700000,
            updated: DateTime.now().millisecondsSinceEpoch,
          ),
        );

        Future<({int heroCards, bool sideHistory, double logoTop})> measureAt(
          Size size, {
          bool light = false,
        }) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = size;
          await tester.binding.setSurfaceSize(size);
          final navSpy = _ObserverRouteSpy();
          await tester.pumpWidget(
            MaterialApp(
              theme: _macTheme(light ? Brightness.light : Brightness.dark),
              navigatorObservers: [navSpy],
              home: AdaptiveShell(
                storage: storage,
                client: _MacTestClient(videos),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          final heroCount = find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key as ValueKey<String>)
                        .value
                        .startsWith('mac-home-hero-card-'),
              )
              .evaluate()
              .length;
          final hasSideHistory = find
              .byKey(const ValueKey('mac-home-side-history'))
              .evaluate()
              .isNotEmpty;
          final logoTop = tester
              .getTopLeft(find.byKey(const ValueKey('home-brand-logo')))
              .dy;
          return (
            heroCards: heroCount,
            sideHistory: hasSideHistory,
            logoTop: logoTop,
          );
        }

        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final narrow = await measureAt(const Size(760, 680));
        expect(
          narrow.logoTop,
          greaterThanOrEqualTo(36.0),
          reason: 'macOS brand logo must stay below traffic lights',
        );
        expect(narrow.heroCards, 1);
        expect(narrow.sideHistory, isFalse);

        final wide = await measureAt(const Size(1560, 920), light: true);
        expect(wide.logoTop, greaterThanOrEqualTo(36.0));
        expect(
          wide.heroCards,
          greaterThan(narrow.heroCards),
          reason: 'Widening macOS window must increase visible hero cards',
        );
        expect(
          wide.sideHistory,
          isTrue,
          reason: 'Wide macOS Home docks Continue Watching beside hero',
        );

        // Verify tapping a hero card pushes iOS-style PosterExpandRoute on macOS.
        final navSpy = _ObserverRouteSpy();
        await tester.pumpWidget(
          MaterialApp(
            theme: _macTheme(Brightness.dark),
            navigatorObservers: [navSpy],
            home: AdaptiveShell(
              storage: storage,
              client: _MacTestClient(videos),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.byKey(const ValueKey('mac-home-hero-card-0')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(
          navSpy.pushed.any((r) => r is PosterExpandRoute),
          isTrue,
          reason: 'macOS detail navigation should reuse iOS PosterExpandRoute',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );

    testWidgets(
      'Continue Watching displays real zero/unknown progress (never 15%) and activates via Tab + Enter',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        PosterLoader.clearCache();
        final videos = buildSampleVideos();
        final storage = await initTestStorage();
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': sampleSite.key,
                'name': sampleSite.name,
                'type': sampleSite.type,
                'api': sampleSite.api,
              },
            ],
          }),
          origin: 'https://vod.example/config.json',
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        await storage.upsertWatchHistory(
          WatchHistoryEntry(
            site: sampleSite.key,
            id: videos[0].id,
            title: videos[0].title,
            poster: videos[0].poster,
            line: '主线 4K',
            episode: '第01集',
            index: 0,
            position: 0,
            duration: 2700000,
            updated: now + 2000,
          ),
        );
        await storage.upsertWatchHistory(
          WatchHistoryEntry(
            site: sampleSite.key,
            id: videos[1].id,
            title: videos[1].title,
            poster: videos[1].poster,
            line: '主线 4K',
            episode: '第02集',
            index: 1,
            position: 0,
            duration: 0,
            updated: now + 1000,
          ),
        );

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1560, 920);
        await tester.binding.setSurfaceSize(const Size(1560, 920));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final navSpy = _ObserverRouteSpy();
        await tester.pumpWidget(
          MaterialApp(
            theme: _macTheme(Brightness.dark),
            navigatorObservers: [navSpy],
            home: AdaptiveShell(
              storage: storage,
              client: _MacTestClient(videos),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        final zeroItem = find.byKey(
          ValueKey('mac-side-history-item-${sampleSite.key}-${videos[0].id}'),
        );
        final unknownItem = find.byKey(
          ValueKey('mac-side-history-item-${sampleSite.key}-${videos[1].id}'),
        );
        expect(zeroItem, findsOneWidget);
        expect(unknownItem, findsOneWidget);

        // Zero progress with known duration renders 0.0 (never fabricated 0.15).
        final zeroBar = find.descendant(
          of: zeroItem,
          matching: find.byType(LinearProgressIndicator),
        );
        expect(zeroBar, findsOneWidget);
        expect(tester.widget<LinearProgressIndicator>(zeroBar).value, 0.0);

        // Unknown duration omits the progress bar completely (never fabricated 0.15).
        final unknownBar = find.descendant(
          of: unknownItem,
          matching: find.byType(LinearProgressIndicator),
        );
        expect(unknownBar, findsNothing);

        // Keyboard Tab focuses Continue Watching item and Enter navigates into DetailScreen.
        final pushedBefore = navSpy.pushed.length;
        await _tabUntilFocused(tester, zeroItem, maxTabs: 120);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(navSpy.pushed.length, greaterThan(pushedBefore));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  });

  group('Item 5: macOS Wide & Narrow Detail, Landscape vs Portrait Poster & SeriesScrapeSheet', () {
    testWidgets(
      'portrait-only keeps uncropped 2:3 poster; true landscape uses backdrop; SeriesScrapeSheet calibrates, persists, syncs danmu, undoes, and respects private isolation',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        PosterLoader.clearCache();
        final video = buildSampleVideos().first;
        PosterLoader.seedMemoryForTest(video.poster, portraitPng);

        final storage = await initTestStorage();
        final candidate2024 = SeriesScrapeCandidate(
          source: 'douban',
          subjectId: 'db-2024',
          title: '星际奇航',
          year: '2024',
          mediaBadge: '剧集',
          rating: 8.9,
          posterUrl: video.poster,
          backdropUrl: 'https://img.example/backdrop_2024.png',
        );
        PosterLoader.seedLandscapeMemoryForTest(
          '星际奇航',
          landscapePng,
          year: '2024',
          preferredBackdropUrl: candidate2024.backdropUrl,
          preferredDoubanId: candidate2024.subjectId,
        );

        Future<void> mountDetail({
          required Size size,
          required CmsSite site,
          bool reduceMotion = false,
          bool light = false,
        }) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = size;
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: size,
                disableAnimations: reduceMotion,
              ),
              child: MaterialApp(
                theme: _macTheme(light ? Brightness.light : Brightness.dark),
                home: DetailScreen(
                  key: UniqueKey(),
                  site: site,
                  initialVideo: video,
                  client: _MacTestClient([video]),
                  storage: storage,
                  debugScrapeSearchFn: (q, form) async => [candidate2024],
                  debugScrapeHydrateFn: (c) async => c,
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 120));
        }

        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // 1. Wide Detail with portrait-only poster: full 2:3 poster card visible + scrape buttons visible.
        await mountDetail(size: const Size(1280, 820), site: sampleSite);
        expect(
          find.byKey(const ValueKey('mac-detail-portrait-poster-card')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('mac-detail-scrape-btn')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('mac-detail-calibrate-btn')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('mac-episodes-calibrate-btn')),
          findsOneWidget,
        );

        // 2. Narrow Detail (760px) with portrait-only poster: uncropped vertical poster card + scrape buttons visible.
        await mountDetail(
          size: const Size(760, 720),
          site: sampleSite,
          reduceMotion: true,
          light: true,
        );
        expect(
          find.byKey(const ValueKey('mac-detail-narrow-portrait-poster')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('mac-detail-scrape-btn')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('mac-detail-calibrate-btn')),
          findsOneWidget,
        );

        // 3. Open SeriesScrapeSheet from Mac Narrow Detail to verify real UI wiring.
        await tester.tap(find.byKey(const ValueKey('mac-detail-scrape-btn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.byType(SeriesScrapeSheet), findsOneWidget);
        await tester.tap(find.byIcon(CupertinoIcons.xmark).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // 4. Save calibration (same-name 2024 work + hide specials + episodeOffset +2)
        //    -> verify UI switches to true landscape hero, updates year & episode numbers,
        //    persists across restart, aligns with danmaku episode resolution, and can undo.
        final calibrated = SeriesScrapeOverride(
          matchedTitle: '星际奇航',
          matchedYear: '2024',
          source: 'douban',
          subjectId: 'db-2024',
          backdropUrl: candidate2024.backdropUrl,
          episodeOffset: 2,
          hideSpecials: true,
        );
        await storage.saveSeriesScrapeOverride(
          sampleSite.key,
          video.id,
          calibrated,
        );
        await mountDetail(size: const Size(1280, 820), site: sampleSite);
        expect(
          find.byKey(const ValueKey('mac-detail-portrait-poster-card')),
          findsNothing,
          reason:
              'Verified true landscape backdrop should render unobstructed without redundant vertical card',
        );
        expect(
          find.byKey(const ValueKey('mac-detail-scrape-status-badge')),
          findsOneWidget,
        );
        expect(find.textContaining('2024'), findsWidgets);
        expect(find.textContaining('偏移 +2'), findsOneWidget);
        expect(
          find.text('E03'),
          findsWidgets,
          reason: 'Episode 1 with +2 offset must display E03',
        );
        expect(
          find.text('OVA 特别篇'),
          findsNothing,
          reason: 'hideSpecials hides special episodes',
        );

        // Verify danmaku episode alignment uses the exact same persisted override.
        final storedOverride = storage.getSeriesScrapeOverride(
          sampleSite.key,
          video.id,
        );
        expect(storedOverride, isNotNull);
        final scraped = SeriesScraper.scrapeLineEpisodes(
          video.lines.first.episodes,
          seriesTitle: storedOverride!.matchedTitle,
          episodeOffset: storedOverride.episodeOffset,
          manualOverrides: storedOverride.episodeNumberOverrides,
        );
        expect(scraped.byOriginalIndex[0].resolvedEpisodeNumber, 3);
        expect(scraped.byOriginalIndex[2].isSpecial, isTrue);

        // Undo calibration -> reverts cleanly.
        await storage.clearSeriesScrapeOverride(sampleSite.key, video.id);
        expect(
          storage.getSeriesScrapeOverride(sampleSite.key, video.id),
          isNull,
        );
        await mountDetail(size: const Size(1280, 820), site: sampleSite);
        expect(
          find.byKey(const ValueKey('mac-detail-scrape-status-badge')),
          findsNothing,
        );
        expect(find.text('E01'), findsWidgets);

        // 5. Private source MUST keep all scrape/calibration controls hidden.
        await mountDetail(size: const Size(1280, 820), site: privateSite);
        expect(find.byKey(const ValueKey('mac-detail-scrape-btn')), findsNothing);
        expect(
          find.byKey(const ValueKey('mac-detail-calibrate-btn')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('mac-episodes-calibrate-btn')),
          findsNothing,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );

    testWidgets(
      'full page-driven keyboard Tab/Enter calibration: open, adjust offset + hide specials, save, restart, verify PlayerScreen danmu episode number, and undo',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        PosterLoader.clearCache();
        final video = buildSampleVideos().first;
        PosterLoader.seedMemoryForTest(video.poster, portraitPng);
        final storage = await initTestStorage();

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 820);
        await tester.binding.setSurfaceSize(const Size(1280, 820));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        Future<void> mountDetailFresh() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: _macTheme(Brightness.dark),
              home: DetailScreen(
                key: UniqueKey(),
                site: sampleSite,
                initialVideo: video,
                client: _MacTestClient([video]),
                storage: storage,
                debugScrapeSearchFn: (q, form) async => const [],
                debugScrapeHydrateFn: (c) async => c,
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 150));
        }

        await mountDetailFresh();
        expect(find.text('E01'), findsWidgets);
        expect(find.text('OVA 特别篇'), findsWidgets);

        // 1. Tab to the Mac Detail calibration button and press Enter to open SeriesScrapeSheet.
        final calibrateBtn = find.byKey(const ValueKey('mac-detail-calibrate-btn'));
        expect(calibrateBtn, findsOneWidget);
        await _tabUntilFocused(tester, calibrateBtn);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(SeriesScrapeSheet), findsOneWidget);

        // 2. Inside SeriesScrapeSheet, Tab to "隐藏预告 / 特别篇" and activate with Enter.
        final hideSpecialsChip =
            find.byKey(const ValueKey('scrape-toggle-hide-specials'));
        await _tabUntilFocused(tester, hideSpecialsChip);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        // 3. Tab to "+1" offset button and press Enter twice (+2).
        final plusOneBtn = find.widgetWithText(OutlinedButton, '+1');
        expect(plusOneBtn, findsOneWidget);
        await _tabUntilFocused(tester, plusOneBtn);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('scrape-offset-value'))).data,
          '+2',
        );

        // 4. Tab to "保存集数校准" and press Enter to save & close sheet.
        final saveBtn = find.byKey(const ValueKey('scrape-save-episodes-btn'));
        await _tabUntilFocused(tester, saveBtn);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SeriesScrapeSheet), findsNothing);

        // 5. Simulate app restart by remounting a fresh DetailScreen from StorageService.
        await mountDetailFresh();
        expect(find.textContaining('偏移 +2'), findsOneWidget);
        expect(find.text('E03'), findsWidgets);
        expect(find.text('OVA 特别篇'), findsNothing);

        // 6. Launch real PlayerScreen for episode 0 ("第01集") after restart and verify
        //    DanmuProvider actually receives calibrated episodeIndex == 3!
        final danmuSpy = _RecordingDanmuProvider();
        final fakePlayer = _MacFakePlayer();
        addTearDown(fakePlayer.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: _macTheme(Brightness.dark),
            home: PlayerScreen(
              site: sampleSite,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugDanmuProvider: danmuSpy,
              debugDanmuSettings: const DanmuSettings(enabled: true),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(danmuSpy.queries, isNotEmpty);
        expect(
          danmuSpy.queries.last.episodeIndex,
          3,
          reason: 'Danmu match query after restart must use calibrated episode number 3',
        );

        // 7. Re-open DetailScreen, Tab/Enter calibrate button -> Tab/Enter "恢复自动匹配" to undo!
        await mountDetailFresh();
        await _tabUntilFocused(
          tester,
          find.byKey(const ValueKey('mac-detail-calibrate-btn')),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(SeriesScrapeSheet), findsOneWidget);

        final resetBtn = find.byKey(const ValueKey('scrape-reset-auto'));
        expect(resetBtn, findsOneWidget);
        await _tabUntilFocused(tester, resetBtn);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SeriesScrapeSheet), findsNothing);

        // 8. Verify undo persisted across restart and DanmuProvider reverts to episodeIndex == 1.
        expect(storage.getSeriesScrapeOverride(sampleSite.key, video.id), isNull);
        await mountDetailFresh();
        expect(find.text('E01'), findsWidgets);
        expect(find.text('OVA 特别篇'), findsWidgets);

        final danmuSpyAfterUndo = _RecordingDanmuProvider();
        final fakePlayer2 = _MacFakePlayer();
        addTearDown(fakePlayer2.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: _macTheme(Brightness.dark),
            home: PlayerScreen(
              site: sampleSite,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer2,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugDanmuProvider: danmuSpyAfterUndo,
              debugDanmuSettings: const DanmuSettings(enabled: true),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(danmuSpyAfterUndo.queries, isNotEmpty);
        expect(danmuSpyAfterUndo.queries.last.episodeIndex, 1);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  });

  group('Item 6: macOS DesktopPlayerHud, Anime4K/More/Volume/Scrub & Independent Danmu Clock', () {
    testWidgets(
      'uses DesktopPlayerHud (no Windows HDR/vocal boost), keeps traffic-light clearance, supports compact More, Anime4K, wheel volume, keyboard scrub preview & hidden-HUD independent danmu clock',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.devicePixelRatio = 2.0;
        tester.view.physicalSize = const Size(2560, 1520);
        await tester.binding.setSurfaceSize(const Size(1280, 760));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final player = _MacFakePlayer();
        addTearDown(player.dispose);
        final anime4k = _FakeAnime4kController();
        addTearDown(anime4k.dispose);
        final hudPrefs = PlayerHudPrefs.inMemory(
          isDesktop: true,
          initial: PlayerHudPrefsData.defaultsFor(
            isDesktop: true,
          ).copyWith(slimProgress: false),
        );
        addTearDown(hudPrefs.dispose);
        const danmuSettings = DanmuSettings(enabled: true);

        await tester.pumpWidget(
          MaterialApp(
            theme: _macTheme(Brightness.dark),
            home: PlayerScreen(
              site: sampleSite,
              video: buildSampleVideos().first,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugHudPrefs: hudPrefs,
              debugAnime4kController: anime4k,
              debugDanmuSettings: danmuSettings,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));

        // 1. Actual Mac entry instantiates DesktopPlayerHud with windowed topSafeInset == 28.
        final hudFinder = find.byType(DesktopPlayerHud);
        expect(hudFinder, findsOneWidget);
        final hudWidget = tester.widget<DesktopPlayerHud>(hudFinder);
        expect(hudWidget.topSafeInset, 28.0);
        expect(hudWidget.videoQualityVisible, isFalse);
        expect(hudWidget.audioLoudnessVisible, isFalse);
        expect(
          find.byKey(const Key('desktop-video-quality-button')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('desktop-audio-loudness-button')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('desktop-anime4k-button')),
          findsOneWidget,
        );

        // 2. Compact "More" popover opens cleanly and excludes Windows-only engine/HDR/vocal items.
        await tester.tap(find.byKey(const Key('desktop-more-button')));
        await tester.pump();
        expect(find.byType(DesktopPlayerMorePopover), findsOneWidget);
        expect(find.text('画面比例'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('windows-more-engine-switch')),
          findsNothing,
        );
        expect(find.textContaining('人声响度'), findsNothing);

        // Close More with Esc.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byType(DesktopPlayerMorePopover), findsNothing);

        // 3. Mouse wheel volume works on macOS.
        final center = tester.getCenter(find.byType(PlayerScreen));
        final testPointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(testPointer.hover(center));
        await tester.sendEventToBinding(testPointer.scroll(const Offset(0, -120)));
        await tester.pump();
        expect(player.volumeChanges, isNotEmpty);

        // 4. Keyboard scrub preview capsule + Esc cancels without seeking.
        final seeksBeforeEsc = player.seeks.length;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 420));
        expect(
          find.byKey(const Key('desktop-scrub-preview-capsule')),
          findsOneWidget,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(
          find.byKey(const Key('desktop-scrub-preview-capsule')),
          findsNothing,
        );
        expect(player.seeks.length, seeksBeforeEsc);

        // 5. Let HUD auto-hide while slimProgress is OFF -> verify independent
        //    DanmuLayer clock keeps advancing, freezes on pause, and re-aligns on seek!
        await tester.pump(const Duration(seconds: 6));
        expect(
          find.byKey(const Key('slim-bottom-progress-bar')),
          findsNothing,
        );

        final danmuLayerFinder = find.byType(DanmuLayer);
        expect(danmuLayerFinder, findsOneWidget);
        final danmuLayer = tester.widget<DanmuLayer>(danmuLayerFinder);
        expect(danmuLayer.positionListenable, isNotNull);

        for (var ms = 12000; ms <= 15000; ms += 500) {
          player.emitPosition(Duration(milliseconds: ms));
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(danmuLayer.positionListenable!.value, 15000);
        final customPaintFinder = find.descendant(
          of: danmuLayerFinder,
          matching: find.byType(CustomPaint),
        );
        final painter =
            tester.widget<CustomPaint>(customPaintFinder).painter
                as DanmuLayerPainter;
        expect(painter.resolveRawPositionMs(), greaterThanOrEqualTo(14900));

        // Pause -> playing becomes false while position holds steady.
        await player.pause();
        await tester.pump();
        expect(tester.widget<DanmuLayer>(danmuLayerFinder).playing, isFalse);

        // Seek & resume -> danmu clock aligns immediately to sought timestamp.
        await player.seek(const Duration(milliseconds: 42000));
        await player.play();
        await tester.pump();
        expect(danmuLayer.positionListenable!.value, 42000);
        expect(tester.widget<DanmuLayer>(danmuLayerFinder).playing, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  });
}

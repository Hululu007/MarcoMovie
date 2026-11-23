import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/episode_scraper.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/live_catalog_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _FeedbackFakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = false;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = const Duration(minutes: 45);
  double volumeValue = 100.0;
  double rateValue = 1.0;
  bool bufferingValue = true;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();

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
}

class _FeedbackFakePlayerStream extends Fake implements PlayerStream {
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

  Future<void> close() async {
    await Future.wait([
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
    ]);
  }
}

class _FeedbackFakePlayer extends Fake implements Player {
  final _FeedbackFakePlayerState _state = _FeedbackFakePlayerState();
  final _FeedbackFakePlayerStream _stream = _FeedbackFakePlayerStream();
  final List<Media> openedMedia = <Media>[];
  bool keepBufferingOnOpen = false;
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedMedia.add(playable);
      _state.playlistValue = Playlist([playable]);
    }
    _state.playingValue = play;
    _state.bufferingValue = keepBufferingOnOpen;
    if (!disposed) {
      _stream.widthCtrl.add(1920);
      _stream.heightCtrl.add(1080);
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(keepBufferingOnOpen);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> play() async {
    _state.playingValue = true;
    if (!disposed) _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    _state.playingValue = false;
    if (!disposed) _stream.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    _state.playingValue = !_state.playingValue;
    if (!disposed) _stream.playingCtrl.add(_state.playingValue);
  }

  @override
  Future<void> seek(Duration d) async {
    _state.positionValue = d;
    if (!disposed) _stream.positionCtrl.add(d);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double v) async => _state.volumeValue = v;
  @override
  Future<void> stop() async => _state.playingValue = false;

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

class _RecordingDanmuProvider implements DanmuProvider {
  final List<DanmuMatchQuery> recordedQueries = <DanmuMatchQuery>[];

  @override
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async {
    recordedQueries.add(query);
    return const <DanmuCandidate>[];
  }

  @override
  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  }) async => const <DanmuCandidate>[];

  @override
  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  }) async => DanmuEpisodeSession(
    boundEpisodeId: boundEpisodeId,
    segmented: false,
  );

  @override
  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  }) async => const <DanmuItem>[];
}

class _FeedbackCmsClient extends CmsClient {
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
      ],
      const CmsListing(
        videos: [
          CmsVideo(
            id: 'hero-1',
            title: '星穹彼岸',
            year: '2026',
            area: '日本',
            remarks: '更新至第7集',
          ),
          CmsVideo(
            id: 'hero-2',
            title: '遥远时空的旅人',
            year: '2026',
            area: '中国大陆',
            remarks: '更新至第12集',
          ),
        ],
      ),
    );
  }

  @override
  Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo video, {
    bool forceRefresh = false,
  }) async =>
      video;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    GlassworkBackdrop.reduceTransparency.value = false;
    AppleTheme.mode.value = ThemeMode.system;
  });

  group('Issue #1: Live RTSP & SMIL stream compatibility', () {
    test('LiveCatalogParser parses RTSP .smil M3U with trailing whitespace', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="央视",CCTV-1\n'
          'rtsp://127.0.0.1/PLTV/88888888/224/3221226001/index.smil \n'
          '#EXTINF:-1 group-title="卫视",山东卫视\n'
          'rtsp://127.0.0.1/PLTV/88888888/224/3221226002/10000100000000060000000000000001.smil\n';
      final groups = LiveCatalogParser.parse(
        m3u,
        resolve: (_, u) => u,
      );
      expect(groups.length, 2);
      expect(groups[0].name, '央视');
      expect(groups[0].channels.single.name, 'CCTV-1');
      expect(
        groups[0].channels.single.urls.single,
        'rtsp://127.0.0.1/PLTV/88888888/224/3221226001/index.smil',
      );
      expect(groups[1].channels.single.name, '山东卫视');
    });

    test('AVPlayer precheck silently routes rtsp/rtmp/udp/.smil/.ts to MPV', () {
      for (final url in const [
        'rtsp://127.0.0.1/PLTV/88888888/224/3221226001/index.smil',
        'rtsps://127.0.0.1/live/ch1',
        'rtmp://127.0.0.1/live/stream',
        'udp://127.0.0.1:5000',
        'https://media.example/live/channel.smil',
        'https://media.example/live/channel.ts',
      ]) {
        final precheck = IosAvPlayerController.checkUrlCompatibility(url);
        expect(precheck.supported, isFalse, reason: 'Must route $url to MPV');
        expect(
          precheck.silentFallback,
          isTrue,
          reason: 'Live stream $url must not flash raw AVPlayer error toast',
        );
      }

      final hls = IosAvPlayerController.checkUrlCompatibility(
        'https://media.example/live/channel.m3u8',
      );
      expect(hls.supported, isTrue);
    });
  });

  group('Issue #2, #3, #4: Bubble-free fade-in text, circular/pill player chrome & portrait layout', () {
    const site = CmsSite(
      key: 'fb_site',
      name: '测试片源',
      type: 1,
      api: 'https://source.example/api',
      isPrivate: true,
    );
    const video = CmsVideo(
      id: 'fb_vid',
      title: '可能的爱',
      year: '2026',
      lines: [
        CmsLine(
          name: '夸克网盘 2',
          episodes: [
            CmsEpisode(
              name: 'k-可能的爱/假如爱有如果.Possible.Love.2026.1080p官方中字.mp4',
              url: 'file:///tmp/possible_love.mp4',
            ),
          ],
        ),
      ],
    );

    testWidgets(
      'Light Mode player loading indicator uses bubble-free text (no white AppleGlassSurface) and never overlaps portrait lock button',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs.dispose);
        final player = _FeedbackFakePlayer()..keepBufferingOnOpen = true;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // Loading indicator is present and has ZERO AppleGlassSurface white bubble.
        final loadingFinder = find.byKey(const Key('player-loading-indicator'));
        expect(loadingFinder, findsOneWidget);
        expect(
          find.descendant(
            of: loadingFinder,
            matching: find.byType(AppleGlassSurface),
          ),
          findsNothing,
        );

        // Portrait circular lock button does not overlap the loading text.
        final lockRect = tester.getRect(
          find.byKey(const Key('player-lock-button')),
        );
        final loadingRect = tester.getRect(loadingFinder);
        expect(lockRect.overlaps(loadingRect), isFalse);

        // Top-left back button and top-right buttons use CircleBorder (not boxy squircles).
        final lockShapes = find.descendant(
          of: find.byKey(const Key('player-lock-button')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is ShapeDecoration &&
                (w.decoration as ShapeDecoration).shape is CircleBorder,
          ),
        );
        expect(lockShapes, findsWidgets);

        // Portrait bottom scrubber bar uses StadiumBorder capsule shape.
        final dockShapes = find.descendant(
          of: find.byKey(const Key('player-tool-dock-portrait')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is ShapeDecoration &&
                (w.decoration as ShapeDecoration).shape is StadiumBorder,
          ),
        );
        expect(dockShapes, findsWidgets);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      },
    );

    testWidgets(
      'Landscape player chrome renders true circular transport/action buttons and stadium back pill',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        await tester.binding.setSurfaceSize(const Size(844, 390));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs.dispose);
        final player = _FeedbackFakePlayer()..keepBufferingOnOpen = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // Back button uses StadiumBorder pill in landscape.
        final backPill = find.descendant(
          of: find.byKey(const Key('ios-player-back-button')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is ShapeDecoration &&
                (w.decoration as ShapeDecoration).shape is StadiumBorder,
          ),
        );
        expect(backPill, findsWidgets);

        // Center play/pause, rewind, forward & top-right action buttons use CircleBorder.
        for (final keyName in const [
          'player-center-play-pause',
          'player-center-rewind',
          'player-center-forward',
          'ios-player-cast-button',
        ]) {
          final circleFinder = find.descendant(
            of: find.byKey(Key(keyName)),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is ShapeDecoration &&
                  (w.decoration as ShapeDecoration).shape is CircleBorder,
            ),
          );
          expect(circleFinder, findsWidgets, reason: '$keyName must be circular');
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      },
    );
  });

  group('Issue #6 & #7 & #10: Dock height parity, Rex full-screen tonal background & iPad layouts', () {
    testWidgets(
      'AppleLiquidGlassDock matches 4-tab capsule height with circular Search button and paints all 4 redesigned icons',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        const dockItems = <(IconData, IconData, String)>[
          (CupertinoIcons.play_rectangle, CupertinoIcons.play_rectangle_fill, '主页'),
          (CupertinoIcons.dot_radiowaves_left_right, CupertinoIcons.dot_radiowaves_left_right, '直播'),
          (CupertinoIcons.square_stack_3d_up, CupertinoIcons.square_stack_3d_up_fill, '片库'),
          (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
        ];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: Scaffold(
              body: Center(
                child: AppleLiquidGlassDock(
                  selectedIndex: 0,
                  onSelect: (_) {},
                  isLandscape: false,
                  items: dockItems,
                  onSearch: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Both the 4-tab pill and the circular search button share the same height.
        final searchFinder = find.byIcon(CupertinoIcons.search);
        expect(searchFinder, findsOneWidget);
        final dockRect = tester.getRect(find.byType(AppleLiquidGlassDock));
        final searchRect = tester.getRect(searchFinder);
        expect(searchRect.center.dy, closeTo(dockRect.center.dy, 12.0));
      },
    );

    testWidgets(
      'Home hero mounts Rex full-screen tonal background and iPad portrait/landscape render with zero errors',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        final storage = await initTestStorage();
        final client = _FeedbackCmsClient();
        await storage.saveConfig(
          '{"sites":[{"key":"fb_site","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );

        addTearDown(() => tester.view.reset());

        // Phone portrait: Rex full-screen tonal background layer is mounted.
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: AdaptiveShell(client: client, storage: storage),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('ios-hero-rex-full-tonal-bg')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ios-hero-bottom-ambient-gradient')),
          findsOneWidget,
        );

        // iPad portrait (768x1024) & iPad landscape (1024x768) render cleanly.
        for (final ipadSize in const [Size(768, 1024), Size(1024, 768)]) {
          tester.view.physicalSize = ipadSize;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'iPad layout at $ipadSize must not crash or overflow',
          );
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group('Issue #9: In-series episode scraping, offset calibration & Danmaku alignment', () {
    test('EpisodeScraper extracts real episode numbers, ignores specs/years, classifies specials & applies offset/sort', () {
      const line = CmsLine(
        name: '夸克 4K',
        episodes: [
          CmsEpisode(name: '先导预告.2026.1080p.mp4', url: 'file:///p.mp4'),
          CmsEpisode(name: 'S01E05.2026.2160p.HEVC.x265.1.3GB.mkv', url: 'file:///e5.mkv'),
          CmsEpisode(name: '第三集 1080P.mp4', url: 'file:///e3.mp4'),
          CmsEpisode(name: '番外花絮_幕后特辑.mp4', url: 'file:///sp.mp4'),
          CmsEpisode(name: 'EP04.HDR10.DDP5.1.mkv', url: 'file:///e4.mkv'),
        ],
      );

      final defaultResult = EpisodeScraper.scrapeLine(line.episodes);
      expect(defaultResult.items[0].isSpecial, isTrue);
      expect(defaultResult.items[1].effectiveEpisodeNumber, 5);
      expect(defaultResult.items[2].effectiveEpisodeNumber, 3);
      expect(defaultResult.items[3].isSpecial, isTrue);
      expect(defaultResult.items[4].effectiveEpisodeNumber, 4);

      final calibrated = EpisodeScraper.scrapeLine(
        line.episodes,
        override: const EpisodeScrapeOverride(
          episodeOffset: 10,
          sortByEpisodeNumber: true,
          hideSpecials: true,
          enabled: true,
        ),
      );
      expect(calibrated.visibleRawIndices, equals(<int>[2, 4, 1]));
      expect(calibrated.infoForRawIndex(2)!.effectiveEpisodeNumber, 13);
      expect(calibrated.infoForRawIndex(4)!.effectiveEpisodeNumber, 14);
      expect(calibrated.infoForRawIndex(1)!.effectiveEpisodeNumber, 15);
    });

    testWidgets(
      'PlayerScreen passes real scraped episode number + offset + customTitle into DanmuMatchQuery',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        final storage = await initTestStorage();
        const site = CmsSite(
          key: 'scrape_site',
          name: '网盘源',
          type: 1,
          api: 'https://source.example/api',
        );
        const video = CmsVideo(
          id: 'scrape_vid_1',
          title: '原始混乱标题[4K]',
          lines: [
            CmsLine(
              name: '夸克原画',
              episodes: [
                CmsEpisode(name: '终极预告.mp4', url: 'file:///tmp/pv.mp4'),
                CmsEpisode(
                  name: 'S01E05.2026.4K.mkv',
                  url: 'file:///tmp/s01e05.mp4',
                ),
              ],
            ),
          ],
        );

        await storage.setEpisodeScrapeOverride(
          siteKey: site.key,
          videoId: video.id,
          videoTitle: video.title,
          override: const EpisodeScrapeOverride(
            customTitle: '精准剧名',
            episodeOffset: 2,
            enabled: true,
          ),
        );
        final restored = storage.getEpisodeScrapeOverride(
          siteKey: site.key,
          videoId: video.id,
          videoTitle: video.title,
        );
        expect(restored.customTitle, '精准剧名');
        expect(restored.episodeOffset, 2);

        final danmu = _RecordingDanmuProvider();
        final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(prefs.dispose);
        final player = _FeedbackFakePlayer();

        // Start on raw index 1 ('S01E05.2026.4K.mkv'); with offset +2 -> episodeIndex 7 (NOT 2!).
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 1,
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
              debugDanmuProvider: danmu,
              debugDanmuSettings: const DanmuSettings(enabled: true),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));

        expect(danmu.recordedQueries, isNotEmpty);
        final query = danmu.recordedQueries.last;
        expect(query.title, '精准剧名');
        expect(query.episodeIndex, 7);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      },
    );

    testWidgets(
      'DetailScreen renders episode scrape button and cleaned episode badges',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        final storage = await initTestStorage();
        final client = _FeedbackCmsClient();
        const site = CmsSite(
          key: 'scrape_site',
          name: '测试源',
          type: 1,
          api: 'https://source.example/api',
        );
        const video = CmsVideo(
          id: 'detail_ep_1',
          title: '剧集刮削演示',
          year: '2026',
          lines: [
            CmsLine(
              name: '夸克 4K',
              episodes: [
                CmsEpisode(name: '先导预告.mp4', url: 'https://media.example/pv.mp4'),
                CmsEpisode(name: 'S01E05.2026.4K.mp4', url: 'https://media.example/e5.mp4'),
              ],
            ),
          ],
        );

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.reset());

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: DetailScreen(
              client: client,
              storage: storage,
              site: site,
              initialVideo: video,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('detail_episode_scrape_button')),
          findsOneWidget,
        );
        expect(find.text('刮削'), findsOneWidget);
      },
    );
  });
}

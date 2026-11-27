// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:marco_movie/core/work_aggregation.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';
import 'windows_v4_ui_test.dart' show WindowsFixtureClient;

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  Duration positionValue = Duration.zero;
  Duration durationValue = const Duration(minutes: 45);
  bool playingValue = false;
  bool bufferingValue = false;
  double rateValue = 1.0;
  double volumeValue = 100.0;
  Track trackValue = Track(
    audio: AudioTrack('1', 'zh', 'Chinese'),
    video: VideoTrack.auto(),
    subtitle: SubtitleTrack.auto(),
  );
  Tracks tracksValue = Tracks(
    audio: <AudioTrack>[
      AudioTrack.auto(),
      AudioTrack.no(),
      AudioTrack('1', 'zh', 'Chinese'),
      AudioTrack('2', 'en', 'English'),
    ],
  );

  @override
  Playlist get playlist => playlistValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  bool get playing => playingValue;
  @override
  bool get buffering => bufferingValue;
  @override
  double get rate => rateValue;
  @override
  double get volume => volumeValue;
  @override
  Track get track => trackValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  int? get width => 1920;
  @override
  int? get height => 1080;
}

class _FakePlayerStream extends Fake implements PlayerStream {
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
  final logCtrl = StreamController<PlayerLog>.broadcast();
  final volumeCtrl = StreamController<double>.broadcast();

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
  Stream<PlayerLog> get log => logCtrl.stream;
  @override
  Stream<double> get volume => volumeCtrl.stream;

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
      logCtrl.close(),
      volumeCtrl.close(),
    ]);
  }
}

class _RecordingMediaPlayer extends Fake implements Player {
  final _FakePlayerState _state = _FakePlayerState();
  final _FakePlayerStream _stream = _FakePlayerStream();
  final List<({String uri, int startMs, Map<String, String> headers})> opened =
      [];
  final Future<void> Function(_RecordingMediaPlayer self, Media media)? onOpen;
  bool disposed = false;

  _RecordingMediaPlayer({this.onOpen});

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  void emitPosition(Duration pos) {
    _state.positionValue = pos;
    if (!disposed) _stream.positionCtrl.add(pos);
  }

  void emitError(String message) {
    if (!disposed) _stream.errorCtrl.add(message);
  }

  void emitLog(PlayerLog entry) {
    if (!disposed) _stream.logCtrl.add(entry);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      opened.add((
        uri: playable.uri,
        startMs: playable.start?.inMilliseconds ?? 0,
        headers: Map<String, String>.from(playable.httpHeaders ?? const {}),
      ));
      _state.playlistValue = Playlist([playable]);
      if (onOpen != null) {
        await onOpen!(this, playable);
        return;
      }
      _state.durationValue = const Duration(minutes: 45);
      _state.positionValue = playable.start ?? const Duration(milliseconds: 500);
      _state.playingValue = play;
      _state.bufferingValue = false;
      if (!disposed) {
        _stream.durationCtrl.add(_state.durationValue);
        _stream.positionCtrl.add(_state.positionValue);
        _stream.bufferingCtrl.add(false);
        _stream.playingCtrl.add(play);
      }
    }
  }

  @override
  Future<void> stop() async => _state.playingValue = false;
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
  Future<void> seek(Duration pos) async {
    _state.positionValue = pos;
    if (!disposed) _stream.positionCtrl.add(pos);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double vol) async => _state.volumeValue = vol;
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

class _ThreeSiteMockClient extends CmsClient {
  static const siteA = CmsSite(
    key: 'site_a',
    name: 'A站',
    type: 1,
    api: 'https://site-a.invalid/api',
    subscriptionId: 'sub_a',
    playUrl: 'https://parse-a.invalid/?url=',
    headers: {'X-Site-Token': 'site-a-token', 'Referer': 'https://site-a.invalid/'},
  );
  static const siteB = CmsSite(
    key: 'site_b',
    name: 'B站',
    type: 1,
    api: 'https://site-b.invalid/api',
    subscriptionId: 'sub_b',
    playUrl: 'https://parse-b.invalid/?url=',
    headers: {'X-Site-Token': 'site-b-token', 'Referer': 'https://site-b.invalid/'},
  );
  static const siteC = CmsSite(
    key: 'site_c',
    name: 'C站',
    type: 1,
    api: 'https://site-c.invalid/api',
    subscriptionId: 'sub_c',
  );
  static const siteAmbiguous = CmsSite(
    key: 'site_ambig',
    name: '歧义站',
    type: 1,
    api: 'https://site-ambig.invalid/api',
    subscriptionId: 'sub_ambig',
  );
  static const siteDown = CmsSite(
    key: 'site_down',
    name: '断连站',
    type: 1,
    api: 'https://site-down.invalid/api',
    subscriptionId: 'sub_down',
  );
  static const siteResolveFail = CmsSite(
    key: 'site_parse_fail',
    name: '解析失败站',
    type: 1,
    api: 'https://site-parse-fail.invalid/api',
    subscriptionId: 'sub_pf',
  );
  static const siteStreamFail = CmsSite(
    key: 'site_stream_fail',
    name: '流失败站',
    type: 1,
    api: 'https://site-stream-fail.invalid/api',
    subscriptionId: 'sub_sf',
  );

  static const searchVideoA = CmsVideo(
    id: 'a_100',
    title: '暗夜追光',
    year: '2024',
    tag: '国产剧',
    remarks: '更新至2集',
  );
  static const searchVideoB = CmsVideo(
    id: 'b_200',
    title: '暗夜追光',
    year: '2024',
    tag: '电视剧',
    remarks: '更新至3集',
  );
  static const searchVideoC = CmsVideo(
    id: 'c_300',
    title: '暗夜追光',
    year: '2006',
    tag: '国产剧',
    remarks: '全24集',
  );

  static const detailVideoA = CmsVideo(
    id: 'a_100',
    title: '暗夜追光',
    year: '2024',
    tag: '国产剧',
    remarks: '更新至2集',
    lines: [
      CmsLine(
        name: 'A线',
        episodes: [
          CmsEpisode(
            name: '第01集',
            url: 'https://site-a.invalid/raw/a01',
            headers: {'X-Site-Token': 'site-a-token'},
          ),
          CmsEpisode(
            name: '第02集',
            url: 'https://site-a.invalid/raw/a02',
            headers: {'X-Site-Token': 'site-a-token'},
          ),
        ],
      ),
    ],
  );

  // Site B inserts a leading `预告` AND provides Ep 3 which Site A lacks!
  static const detailVideoB = CmsVideo(
    id: 'b_200',
    title: '暗夜追光',
    year: '2024',
    tag: '电视剧',
    remarks: '更新至3集',
    lines: [
      CmsLine(
        name: 'B线',
        episodes: [
          CmsEpisode(
            name: '预告',
            url: 'https://site-b.invalid/raw/b_pv',
          ),
          CmsEpisode(
            name: '第01集',
            url: 'https://site-b.invalid/raw/b01',
          ),
          CmsEpisode(
            name: '第02集',
            url: 'https://site-b.invalid/raw/b02',
          ),
          CmsEpisode(
            name: '第03集',
            url: 'https://site-b.invalid/raw/b03',
          ),
        ],
      ),
    ],
  );

  static const detailVideoC = CmsVideo(
    id: 'c_300',
    title: '暗夜追光',
    year: '2006',
    tag: '国产剧',
    remarks: '全24集',
    lines: [
      CmsLine(
        name: 'C经典线',
        episodes: [
          CmsEpisode(name: '第01集', url: 'https://site-c.invalid/c01.mp4'),
        ],
      ),
    ],
  );

  static const detailVideoAmbiguous = CmsVideo(
    id: 'ambig_1',
    title: '暗夜追光',
    year: '2024',
    tag: '国产剧',
    lines: [
      CmsLine(
        name: '歧义线',
        episodes: [
          CmsEpisode(name: '正片A', url: 'https://site-ambig.invalid/p1.mp4'),
          CmsEpisode(name: '正片B', url: 'https://site-ambig.invalid/p2.mp4'),
        ],
      ),
    ],
  );

  static const detailVideoResolveFail = CmsVideo(
    id: 'pf_1',
    title: '暗夜追光',
    year: '2024',
    tag: '国产剧',
    lines: [
      CmsLine(
        name: '解析线',
        episodes: [
          CmsEpisode(name: '第01集', url: 'https://site-parse-fail.invalid/ep1'),
          CmsEpisode(name: '第02集', url: 'https://site-parse-fail.invalid/ep2'),
        ],
      ),
    ],
  );

  static const detailVideoStreamFail = CmsVideo(
    id: 'sf_1',
    title: '暗夜追光',
    year: '2024',
    tag: '国产剧',
    lines: [
      CmsLine(
        name: '断流线',
        episodes: [
          CmsEpisode(name: '第01集', url: 'http://127.0.0.1:18083/ep1.mp4'),
          CmsEpisode(name: '第02集', url: 'http://127.0.0.1:18083/broken-ep2.mp4'),
        ],
      ),
    ],
  );

  final List<String> detailRequestedSites = [];
  final List<({String siteKey, String rawUrl})> resolvedCalls = [];

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const [CmsCategory(id: '1', name: '电视剧')],
        const CmsListing(videos: [searchVideoA]),
      );

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    switch (site.key) {
      case 'site_a':
        return const CmsListing(videos: [searchVideoA]);
      case 'site_b':
        return const CmsListing(videos: [searchVideoB]);
      case 'site_c':
        return const CmsListing(videos: [searchVideoC]);
      default:
        return const CmsListing(videos: []);
    }
  }

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates, {
    bool forceRefresh = false,
  }) async {
    detailRequestedSites.add(source.key);
    switch (source.key) {
      case 'site_a':
        return (source, detailVideoA);
      case 'site_b':
        return (source, detailVideoB);
      case 'site_c':
        return (source, detailVideoC);
      case 'site_ambig':
        return (source, detailVideoAmbiguous);
      case 'site_down':
        throw const SocketException('Connection refused by site_down');
      case 'site_parse_fail':
        return (source, detailVideoResolveFail);
      case 'site_stream_fail':
        return (source, detailVideoStreamFail);
      default:
        return (source, item);
    }
  }

  @override
  Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
  }) async {
    resolvedCalls.add((siteKey: site.key, rawUrl: episode.url));
    if (site.key == 'site_parse_fail') {
      throw const FormatException('解析接口无响应');
    }
    if (site.key == 'site_b') {
      final slug = episode.url.split('/').last;
      return CmsEpisode(
        name: episode.name,
        url: 'http://127.0.0.1:18082/parsed/$slug.mp4',
        headers: {
          'X-Site-Token': 'site-b-token',
          'Referer': 'https://site-b.invalid/',
          'X-Parser': site.playUrl,
        },
      );
    }
    if (site.key == 'site_a') {
      final slug = episode.url.split('/').last;
      return CmsEpisode(
        name: episode.name,
        url: 'http://127.0.0.1:18081/parsed/$slug.mp4',
        headers: {
          'X-Site-Token': 'site-a-token',
          'Referer': 'https://site-a.invalid/',
        },
      );
    }
    return episode;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Rework 2: WorkAggregation disambiguation rules', () {
    test('separates remakes, different seasons, 上篇/下篇, animation vs live-action, and motion comic', () {
      const sA = CmsSite(key: 'a', name: 'A站', type: 1, api: 'https://a.invalid', subscriptionId: 'sub1');
      const sB = CmsSite(key: 'b', name: 'B站', type: 1, api: 'https://b.invalid', subscriptionId: 'sub2');
      const sC = CmsSite(key: 'c', name: 'C站', type: 1, api: 'https://c.invalid', subscriptionId: 'sub3');

      // 1. Same work across A & B vs same-title remake on C (different year)
      final remakeGroups = WorkAggregation.aggregateSearchResults(
        results: const [
          (sA, CmsVideo(id: 'a1', title: '暗夜追光', year: '2024', tag: '国产剧')),
          (sB, CmsVideo(id: 'b1', title: '暗夜追光', year: '2024', tag: '电视剧')),
          (sC, CmsVideo(id: 'c1', title: '暗夜追光', year: '2006', tag: '国产剧')),
        ],
        query: '暗夜追光',
      );
      expect(remakeGroups, hasLength(2));
      expect(remakeGroups.first.sourceCount, 2);
      expect(remakeGroups.first.sourceBadgeText, '2 个来源');
      expect(
        remakeGroups.first.sources.map((s) => '${s.subscriptionId}:${s.site.key}:${s.videoId}'),
        containsAll(const ['sub1:a:a1', 'sub2:b:b1']),
      );
      expect(remakeGroups.last.year, '2006');
      expect(remakeGroups.last.sourceCount, 1);

      // 2. Different seasons (`第一季` vs `第二季`, unmarked vs `庆余年2`)
      final seasonGroups = WorkAggregation.aggregateSearchResults(
        results: const [
          (sA, CmsVideo(id: 'q1a', title: '庆余年', year: '2019', tag: '国产剧')),
          (sB, CmsVideo(id: 'q1b', title: '庆余年 第一季', year: '2019', tag: '国产剧')),
          (sA, CmsVideo(id: 'q2a', title: '庆余年 第二季', year: '2024', tag: '国产剧')),
          (sB, CmsVideo(id: 'q2b', title: '庆余年2', year: '2024', tag: '国产剧')),
        ],
        query: '庆余年',
      );
      expect(seasonGroups, hasLength(2));
      expect(seasonGroups.every((g) => g.sourceCount == 2), isTrue);

      // 3. `上篇` vs `下篇` and `上部` vs `下部`
      final partGroups = WorkAggregation.aggregateSearchResults(
        results: const [
          (sA, CmsVideo(id: 'p1a', title: '云海秘闻 上篇', year: '2024', tag: '国产剧')),
          (sB, CmsVideo(id: 'p1b', title: '云海秘闻（上篇）', year: '2024', tag: '国产剧')),
          (sA, CmsVideo(id: 'p2a', title: '云海秘闻 下篇', year: '2024', tag: '国产剧')),
        ],
        query: '云海秘闻',
      );
      expect(partGroups, hasLength(2));
      expect(partGroups.first.sourceCount, 2);
      expect(partGroups.last.sourceCount, 1);

      // 4. Animation vs Live-action vs Motion comic (even same year & title!)
      final mediumGroups = WorkAggregation.aggregateSearchResults(
        results: const [
          (sA, CmsVideo(id: 'm1', title: '三体', year: '2023', tag: '国产剧')),
          (sB, CmsVideo(id: 'm2', title: '三体 真人版', year: '2023', tag: '')),
          (sA, CmsVideo(id: 'm3', title: '三体', year: '2023', tag: '动漫')),
          (sC, CmsVideo(id: 'm4', title: '三体 动画版', year: '2023', tag: '')),
          (sC, CmsVideo(id: 'm5', title: '三体 动态漫画', year: '2023', tag: '动漫')),
        ],
        query: '三体',
      );
      expect(mediumGroups, hasLength(3));
      expect(
        mediumGroups.map((g) => (g.identity.workType, g.sourceCount)),
        containsAll(const [
          (AggregatedWorkType.liveAction, 2),
          (AggregatedWorkType.animation, 2),
          (AggregatedWorkType.motionComic, 1),
        ]),
      );
    });
  });

  group('Rework 2: Windows Search, Detail & Player end-to-end', () {
    testWidgets(
      'Review ZIP regression: Windows search aggregates one work from two sources in both Grid and List views',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = await initTestStorage();
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 'ownedA',
                  'name': '来源甲',
                  'type': 1,
                  'api': 'https://a.owned.invalid/api'
                },
                {
                  'key': 'ownedB',
                  'name': '来源乙',
                  'type': 1,
                  'api': 'https://b.owned.invalid/api'
                },
              ],
            })));
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: AdaptiveShell(
            storage: storage,
            client: WindowsFixtureClient(),
            onSetPreventCloseForTest: (_) async {},
          ),
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('搜索影片 · Ctrl+K'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('windows-search-input')),
          '海边',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        final cards = find.byWidgetPredicate(
          (w) => w is InkWell && w.key.toString().contains('windows-search-'),
        );
        expect(cards, findsOneWidget);
        expect(find.text('2 个来源'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('win-search-view-list')));
        await tester.pumpAndSettle();
        expect(cards, findsOneWidget);
        expect(find.text('2 个来源'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      '3 mock sites (A+B same series, C remake): Search shows 2 cards; Detail deduplicates Ep 2 across A+B and exposes Site-B-only Ep 3',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = await initTestStorage();
        final client = _ThreeSiteMockClient();
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 'site_a',
                  'name': 'A站',
                  'type': 1,
                  'api': 'https://site-a.invalid/api',
                  'playUrl': 'https://parse-a.invalid/?url=',
                },
                {
                  'key': 'site_b',
                  'name': 'B站',
                  'type': 1,
                  'api': 'https://site-b.invalid/api',
                  'playUrl': 'https://parse-b.invalid/?url=',
                },
                {
                  'key': 'site_c',
                  'name': 'C站',
                  'type': 1,
                  'api': 'https://site-c.invalid/api',
                },
              ],
            })));
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: AdaptiveShell(
            storage: storage,
            client: client,
            onSetPreventCloseForTest: (_) async {},
          ),
        ));
        await tester.pumpAndSettle();

        // 1. Search shows 2 work cards (A+B merged as 2 个来源, C remake separate) in BOTH Grid & List!
        await tester.tap(find.byTooltip('搜索影片 · Ctrl+K'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('windows-search-input')),
          '暗夜追光',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        final cards = find.byWidgetPredicate(
          (w) => w is InkWell && w.key.toString().contains('windows-search-'),
        );
        expect(cards, findsNWidgets(2));
        expect(find.text('2 个来源'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('win-search-view-list')));
        await tester.pumpAndSettle();
        expect(cards, findsNWidgets(2));
        expect(find.text('2 个来源'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));

        // 2. Detail opened from Home / Favorites / History (NO initialSources)
        // hydrates Site B in background while Site A is immediately playable,
        // rejects Site C remake, deduplicates Ep 2 into 1 entry with A站·A线 + B站·B线,
        // and surfaces Site-B-only Ep 3!
        ({CmsSite site, CmsVideo video, int lineIdx, int epIdx})? launched;
        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: DetailScreen(
            site: _ThreeSiteMockClient.siteA,
            initialVideo: _ThreeSiteMockClient.searchVideoA,
            client: client,
            storage: storage,
            debugPlayerBuilder: (_, site, video, lineIdx, epIdx, resumeMs) {
              launched = (
                site: site,
                video: video,
                lineIdx: lineIdx,
                epIdx: epIdx,
              );
              return const Scaffold(body: Center(child: Text('mock-player')));
            },
          ),
        ));
        await tester.pumpAndSettle();

        // Expand unified episodes drawer.
        await tester.tap(
          find.byKey(const ValueKey('windows-detail-episode-toggle')),
        );
        await tester.pumpAndSettle();

        // Ep 1, Ep 2, Ep 3 each appear ONCE (Site C remake excluded!).
        expect(find.byKey(const ValueKey('unified_ep_card_ep_1')), findsOneWidget);
        expect(find.byKey(const ValueKey('unified_ep_card_ep_2')), findsOneWidget);
        expect(find.byKey(const ValueKey('unified_ep_card_ep_3')), findsOneWidget);

        // Tap Ep 2 -> shows both `A站 · A线` and `B站 · B线` offers!
        await tester.ensureVisible(
          find.byKey(const ValueKey('unified_ep_card_ep_2')),
        );
        await tester.tap(find.byKey(const ValueKey('unified_ep_card_ep_2')));
        await tester.pumpAndSettle();
        expect(find.text('A站 · A线'), findsOneWidget);
        expect(find.text('B站 · B线'), findsOneWidget);
        // Close offers sheet
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // Tap Site-B-only Ep 3 -> single offer launches Site B's Ep 3 directly!
        await tester.ensureVisible(
          find.byKey(const ValueKey('unified_ep_card_ep_3')),
        );
        await tester.tap(find.byKey(const ValueKey('unified_ep_card_ep_3')));
        await tester.pumpAndSettle();
        expect(launched, isNotNull);
        expect(launched!.site.key, 'site_b');
        expect(launched!.video.lines[launched!.lineIdx].episodes[launched!.epIdx].name, '第03集');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    testWidgets(
      'Player Level-1 换源: A02 at 12:34 -> B ([预告, 第01集, 第02集, 第03集]) opens B02 at 754000ms with B parser & headers; ambiguous opens picker; connection/parse/stream failure preserves A02 & 754000ms',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = await initTestStorage();
        final client = _ThreeSiteMockClient();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        var failNextStreamOpen = false;
        final player = _RecordingMediaPlayer(
          onOpen: (self, media) async {
            if (failNextStreamOpen && media.uri.contains('broken-ep2')) {
              failNextStreamOpen = false;
              self._state.durationValue = Duration.zero;
              self._state.positionValue = Duration.zero;
              self._state.playingValue = false;
              self._state.bufferingValue = false;
              self.emitError('Failed to open ${media.uri}');
              return;
            }
            self._state.durationValue = const Duration(minutes: 45);
            self._state.positionValue =
                media.start ?? const Duration(milliseconds: 500);
            self._state.playingValue = true;
            self._state.bufferingValue = false;
            self._stream.durationCtrl.add(self._state.durationValue);
            self._stream.positionCtrl.add(self._state.positionValue);
            self._stream.bufferingCtrl.add(false);
            self._stream.playingCtrl.add(true);
          },
        );
        addTearDown(player.dispose);

        final altSources = <WorkSourceRef>[
          WorkSourceRef(
            site: _ThreeSiteMockClient.siteA,
            video: _ThreeSiteMockClient.detailVideoA,
          ),
          WorkSourceRef(
            site: _ThreeSiteMockClient.siteB,
            video: _ThreeSiteMockClient.searchVideoB, // unhydrated stub -> MUST call Site B detail!
          ),
          WorkSourceRef(
            site: _ThreeSiteMockClient.siteAmbiguous,
            video: _ThreeSiteMockClient.detailVideoAmbiguous,
          ),
          WorkSourceRef(
            site: _ThreeSiteMockClient.siteDown,
            video: const CmsVideo(id: 'down_1', title: '暗夜追光', year: '2024'),
          ),
          WorkSourceRef(
            site: _ThreeSiteMockClient.siteResolveFail,
            video: _ThreeSiteMockClient.detailVideoResolveFail,
          ),
          WorkSourceRef(
            site: _ThreeSiteMockClient.siteStreamFail,
            video: _ThreeSiteMockClient.detailVideoStreamFail,
          ),
        ];

        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: PlayerScreen(
            site: _ThreeSiteMockClient.siteA,
            video: _ThreeSiteMockClient.detailVideoA,
            initialLineIndex: 0,
            initialEpisodeIndex: 1, // A02 (`第02集`)
            initialPositionMs: 0,
            storage: storage,
            client: client,
            alternativeSources: altSources,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 250));

        // Verify initial playback is A02, advance playback to 12:34 (754000ms).
        expect(player.opened.last.uri, 'http://127.0.0.1:18081/parsed/a02.mp4');
        player.emitPosition(const Duration(minutes: 12, seconds: 34));
        await tester.pump(const Duration(milliseconds: 100));

        // 1. Level-1 `换源` button is directly visible on DesktopPlayerHud!
        final switchBtn = find.byKey(const Key('desktop-switch-source-button'));
        expect(switchBtn, findsOneWidget);

        // 2. Test target site connection failure (`site_down`) -> preserves A02 & 754000ms!
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();
        final openCountBeforeDown = player.opened.length;
        await tester.ensureVisible(
          find.byKey(const ValueKey('cross-site-source-site_down')),
        );
        await tester.tap(find.byKey(const ValueKey('cross-site-source-site_down')));
        await tester.pumpAndSettle();
        expect(player.opened.length, openCountBeforeDown);
        expect(player.opened.last.uri, 'http://127.0.0.1:18081/parsed/a02.mp4');
        expect(player.state.position.inMilliseconds, 754000);

        // 3. Test target site parser failure (`site_parse_fail`) -> preserves A02 & 754000ms!
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('cross-site-line-site_parse_fail-0')),
        );
        await tester.tap(
          find.byKey(const ValueKey('cross-site-line-site_parse_fail-0')),
        );
        await tester.pumpAndSettle();
        expect(player.opened.length, openCountBeforeDown);
        expect(player.opened.last.uri, 'http://127.0.0.1:18081/parsed/a02.mp4');

        // 4. Test ambiguous target (`site_ambig`) -> opens manual episode picker without interrupting A02!
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('cross-site-line-site_ambig-0')),
        );
        await tester.tap(
          find.byKey(const ValueKey('cross-site-line-site_ambig-0')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('cross-site-disambig-ep-site_ambig-0')),
          findsOneWidget,
        );
        expect(player.opened.length, openCountBeforeDown);
        // Dismiss disambiguation sheet
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // 5. Test stream-open failure rollback (`site_stream_fail`) -> rolls back to A02 at 754000ms!
        failNextStreamOpen = true;
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('cross-site-sources-sheet')),
          const Offset(0, -260),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('cross-site-line-site_stream_fail-0')),
        );
        await tester.pumpAndSettle();
        expect(player.opened.last.uri, 'http://127.0.0.1:18081/parsed/a02.mp4');
        expect(player.opened.last.startMs, 754000);
        // Advance back to 12:34 cleanly for the main B02 switch test.
        player.emitPosition(const Duration(minutes: 12, seconds: 34));
        await tester.pump(const Duration(milliseconds: 100));

        // 6. Main acceptance: Switch from A02 (12:34 = 754000ms) -> B站 · B线 ([预告, 第01集, 第02集, 第03集])!
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('cross-site-line-site_b-0')),
        );
        await tester.tap(find.byKey(const ValueKey('cross-site-line-site_b-0')));
        await tester.pumpAndSettle();

        final switched = player.opened.last;
        // ignore: avoid_print
        print(
          'EVIDENCE_CROSS_SITE_SWITCH: uri=${switched.uri}, startMs=${switched.startMs}, headers=${switched.headers}',
        );
        expect(client.detailRequestedSites, contains('site_b'));
        expect(
          client.resolvedCalls.any(
            (c) => c.siteKey == 'site_b' && c.rawUrl == 'https://site-b.invalid/raw/b02',
          ),
          isTrue,
        );
        expect(switched.uri, 'http://127.0.0.1:18082/parsed/b02.mp4');
        expect(switched.startMs, 754000);
        expect(switched.headers['X-Site-Token'], 'site-b-token');
        expect(switched.headers['Referer'], 'https://site-b.invalid/');
        expect(switched.headers['X-Parser'], 'https://parse-b.invalid/?url=');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  });

  group('Rework 1: PlayerScreen audio-filter failure runtime recovery', () {
    testWidgets(
      'Audio filter initialized failed! on PlayerScreen recovers original audio without aborting video playback',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = await initTestStorage();
        final sp = await SharedPreferences.getInstance();
        await sp.setString(
          WindowsVideoQualityController.prefKeyLoudnessPreset,
          'cinemaVocal',
        );
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        final props = <(String, String)>[];
        final winQuality = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          recoverySettleDelayOverride: Duration.zero,
          propertySetterOverride: (k, v) async => props.add((k, v)),
        );
        addTearDown(winQuality.dispose);
        await winQuality.loadSaved();
        expect(winQuality.loudnessPreset, AudioLoudnessPreset.cinemaVocal);

        final player = _RecordingMediaPlayer();
        addTearDown(player.dispose);

        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: PlayerScreen(
            site: _ThreeSiteMockClient.siteA,
            video: const CmsVideo(
              id: 'local_aud',
              title: '人声恢复测试片',
              lines: [
                CmsLine(
                  name: '本地线',
                  episodes: [
                    CmsEpisode(name: '第01集', url: 'file:///tmp/sample.mp4'),
                  ],
                ),
              ],
            ),
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugWinQualityController: winQuality,
          ),
        ));
        await tester.pump(const Duration(milliseconds: 250));

        // Simulate active preset applied and then mpv reporting audio filter failure
        // on stream.error.
        await winQuality.applyLoudnessPreset(
          player,
          AudioLoudnessPreset.cinemaVocal,
          persist: false,
        );
        props.clear();
        player.emitError('Audio filter initialized failed!');
        await tester.pump(const Duration(milliseconds: 100));

        // Must clear af, reselect audio track, sync UI preset to off, and NOT show fatal error!
        expect(
          props,
          equals(const [
            ('af', ''),
            ('volume-max', '100'),
            ('aid', 'no'),
            ('aid', '1'),
          ]),
        );
        expect(winQuality.loudnessPreset, AudioLoudnessPreset.off);
        expect(
          await WindowsVideoQualityController.readSavedLoudnessPreset(),
          AudioLoudnessPreset.off,
        );
        // Video playback error overlay must NOT have triggered.
        expect(find.textContaining('播放失败'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
    );
  });

  group('Round-3 rework regressions: single-site multi-line, 全部剧集 parity, identity, and latest-progress handoff', () {
    testWidgets(
      'Slow cross-site switch on same episode resumes with LATEST playback position at commit time',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = await initTestStorage();
        final gate = Completer<void>();
        final client = _DelayedResolveMockClient(gate);
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final player = _RecordingMediaPlayer();
        addTearDown(player.dispose);

        await tester.pumpWidget(MaterialApp(
          builder: (_, child) => WindowsAppearanceScope(
            controller: appearance,
            child: child!,
          ),
          home: PlayerScreen(
            site: _ThreeSiteMockClient.siteA,
            video: _ThreeSiteMockClient.detailVideoA,
            initialLineIndex: 0,
            initialEpisodeIndex: 1,
            initialPositionMs: 0,
            storage: storage,
            client: client,
            alternativeSources: [
              WorkSourceRef(
                site: _ThreeSiteMockClient.siteB,
                video: _ThreeSiteMockClient.searchVideoB,
              ),
            ],
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 250));
        player.emitPosition(const Duration(seconds: 754));
        await tester.pump(const Duration(milliseconds: 80));

        await tester.tap(find.byKey(const Key('desktop-switch-source-button')));
        await tester.pumpAndSettle();
        final bLine = find.byKey(const ValueKey('cross-site-line-site_b-0'));
        await tester.ensureVisible(bLine);
        await tester.tap(bLine);
        await tester.pumpAndSettle();
        expect(client.waiting, isTrue);

        // Playback advances from 12:34 (754s) to 12:49 (769s) while Site B is resolving!
        player.emitPosition(const Duration(seconds: 769));
        await tester.pump(const Duration(milliseconds: 80));
        gate.complete();
        await tester.pumpAndSettle();

        expect(player.opened.last.uri, endsWith('b02.mp4'));
        expect(player.opened.last.startMs, 769000);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 700));
      },
    );
  });
}

class _DelayedResolveMockClient extends _ThreeSiteMockClient {
  final Completer<void> gate;
  bool waiting = false;
  _DelayedResolveMockClient(this.gate);

  @override
  Future<CmsEpisode> resolveEpisodeForPlayback(
    CmsSite site,
    CmsEpisode episode, {
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
  }) async {
    if (site.key == 'site_b') {
      waiting = true;
      await gate.future;
    }
    return super.resolveEpisodeForPlayback(
      site,
      episode,
      parses: parses,
      rules: rules,
      ads: ads,
    );
  }
}

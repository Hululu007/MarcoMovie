import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/poster_expand_route.dart';
import 'test_storage_helper.dart';

class DetailLoadingClient extends CmsClient {
  final detail = Completer<(CmsSite, CmsVideo)>();
  int searches = 0;
  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates, {
    bool forceRefresh = false,
  }) => detail.future;
  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    searches++;
    return const CmsListing();
  }
}

void main() {
  const site = CmsSite(
    key: 'owned',
    name: 'Owned',
    type: 1,
    api: 'https://owned.invalid/api',
  );
  const video = CmsVideo(
    id: 'one',
    title: 'Fixture 第一季',
    lines: [
      CmsLine(
        name: 'Owned',
        episodes: [CmsEpisode(name: '第一集', url: 'https://owned.invalid/a.mp4')],
      ),
    ],
  );

  testWidgets('episode loading takes priority over related-season discovery', (
    tester,
  ) async {
    final storage = await initTestStorage();
    final client = DetailLoadingClient();
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
    await tester.pump(const Duration(seconds: 1));
    expect(client.searches, 0);
    await tester.runAsync(() async {
      client.detail.complete((site, video));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(client.searches, 0);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(client.searches, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });

  testWidgets(
    'leaving details suppresses delayed season searches and late detail results',
    (tester) async {
      final storage = await initTestStorage();
      final client = DetailLoadingClient();
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
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        client.detail.complete((site, video));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump(const Duration(seconds: 1));
      expect(client.searches, 0);
      expect(tester.takeException(), isNull);
    },
  );

  group('iOS 0.7.5 Detail pull-to-refresh, line preservation & gesture copy', () {
    const httpSite = CmsSite(
      key: 'cms_http_1',
      name: '普通CMS源',
      type: 1,
      api: 'https://cms.example/api.php/provide/vod',
    );

    http.Response buildVodResponse({
      required String id,
      required String title,
      required List<(String lineName, List<(String epName, String epUrl)>)>
          lines,
      String remarks = '',
    }) {
      final playFrom = lines.map((l) => l.$1).join(r'$$$');
      final playUrl = lines
          .map((l) => l.$2.map((e) => '${e.$1}\$${e.$2}').join('#'))
          .join(r'$$$');
      return http.Response(
        jsonEncode({
          'code': 1,
          'list': [
            {
              'vod_id': id,
              'vod_name': title,
              'vod_remarks': remarks,
              'vod_year': '2026',
              'vod_play_from': playFrom,
              'vod_play_url': playUrl,
            },
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    ScrollableState findDetailVerticalScrollable(WidgetTester tester) {
      final scrollableFinder = find.descendant(
        of: find.byType(DetailScreen),
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      return tester.state<ScrollableState>(scrollableFinder.first);
    }

    Future<TestGesture> pullDetailToOverscroll(
      WidgetTester tester,
      double targetOverscroll, {
      TestGesture? existingGesture,
    }) async {
      final scrollable = findDetailVerticalScrollable(tester);
      final gesture = existingGesture ??
          await tester.startGesture(const Offset(195, 260));
      for (var step = 0; step < 80; step++) {
        final current = -scrollable.position.pixels;
        final diff = targetOverscroll - current;
        if (diff.abs() <= 2.5) break;
        final deltaY = diff > 0
            ? (diff * 1.45).clamp(4.0, 26.0)
            : (diff * 1.45).clamp(-26.0, -4.0);
        await gesture.moveBy(Offset(0, deltaY));
        await tester.pump(const Duration(milliseconds: 16));
      }
      return gesture;
    }

    Future<void> performPullRefresh(WidgetTester tester) async {
      final gesture = await pullDetailToOverscroll(tester, 84.0);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets(
      'Item 1: pull-to-refresh fetches updated episodes, updates cache, handles fallback-with-lines, late prefetch, M3U VOD, failure retry & duplicate coalescing',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var targetDetailRequests = 0;
        var otherDetailRequests = 0;
        var currentLines = <(String, List<(String, String)>)>[
          (
            '极速线路',
            const [('第01集', 'https://media.example/ep1.m3u8')],
          ),
        ];
        var shouldFailNext = false;
        Completer<http.Response>? holdNextDetailResponse;

        final mockHttp = MockClient((request) async {
          final ac = request.url.queryParameters['ac'];
          final ids = request.url.queryParameters['ids'];
          if (ac == 'detail' && ids == 'vid-100') {
            targetDetailRequests++;
            if (holdNextDetailResponse != null) {
              final c = holdNextDetailResponse!;
              holdNextDetailResponse = null;
              return c.future;
            }
            if (shouldFailNext) {
              shouldFailNext = false;
              return http.Response('Internal Server Error', 500);
            }
            return buildVodResponse(
              id: 'vid-100',
              title: '连载新剧',
              lines: currentLines,
              remarks: '更新至${currentLines.first.$2.length}集',
            );
          }
          if (ac == 'detail' && ids == 'vid-other') {
            otherDetailRequests++;
            return buildVodResponse(
              id: 'vid-other',
              title: '其他缓存影片',
              lines: const [
                ('其他线路', [('第01集', 'https://media.example/other1.m3u8')]),
              ],
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);

        // Warm another video's cache to verify refreshing vid-100 does not evict it.
        await cmsClient.fetchDetail(
          httpSite,
          const CmsVideo(id: 'vid-other', title: '其他缓存影片'),
        );
        expect(otherDetailRequests, 1);

        final playedUrls = <String>[];
        Widget buildDetailPage(CmsVideo initialVideo, {CmsSite site = httpSite}) {
          return MaterialApp(
            home: DetailScreen(
              site: site,
              initialVideo: initialVideo,
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                playedUrls.add(v.lines[lineIdx].episodes[epIdx].url);
                return Scaffold(
                  body: Center(
                    child: Text('PLAY:${v.lines[lineIdx].episodes[epIdx].url}'),
                  ),
                );
              },
            ),
          );
        }

        // 1) Initial open: 1 HTTP detail request, 1 episode shown.
        const initialNoLines = CmsVideo(id: 'vid-100', title: '连载新剧');
        await tester.pumpWidget(buildDetailPage(initialNoLines));
        await tester.pumpAndSettle();

        expect(targetDetailRequests, 1);
        expect(find.text('1'), findsOneWidget);
        expect(find.text('2'), findsNothing);

        // 2) Upstream adds Episode 2; pull-to-refresh triggers 2nd HTTP request and makes Episode 2 selectable.
        currentLines = const [
          (
            '极速线路',
            [
              ('第01集', 'https://media.example/ep1.m3u8'),
              ('第02集', 'https://media.example/ep2.m3u8'),
            ],
          ),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();

        expect(targetDetailRequests, 2);
        expect(find.text('2'), findsOneWidget);

        // On iOS, tapping episode number circle 2 only scrolls to card 2
        // (0 player launches); tapping episode card 2 starts playback.
        await tester.tap(find.text('2'));
        await tester.pumpAndSettle();
        expect(playedUrls, isEmpty);
        await tester.tap(find.byKey(const ValueKey('ep_card_0_1')));
        await tester.pumpAndSettle();
        expect(playedUrls.last, 'https://media.example/ep2.m3u8');

        // Pop player back to detail.
        final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
        nav.pop();
        await tester.pumpAndSettle();

        // 3) Failure during pull-to-refresh preserves existing 2 episodes and allows retry.
        shouldFailNext = true;
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 3);
        expect(find.text('2'), findsOneWidget);
        expect(find.textContaining('读取详情失败'), findsNothing);

        // Retry succeeds with 3 episodes.
        currentLines = const [
          (
            '极速线路',
            [
              ('第01集', 'https://media.example/ep1.m3u8'),
              ('第02集', 'https://media.example/ep2.m3u8'),
              ('第03集', 'https://media.example/ep3.m3u8'),
            ],
          ),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 4);
        expect(find.text('3'), findsOneWidget);

        // 4) Duplicate pull-release while refresh is already in-flight coalesces into 1 request.
        final inFlight = Completer<http.Response>();
        holdNextDetailResponse = inFlight;
        await performPullRefresh(tester);
        expect(targetDetailRequests, 5);
        await performPullRefresh(tester);
        expect(targetDetailRequests, 5);
        inFlight.complete(
          buildVodResponse(
            id: 'vid-100',
            title: '连载新剧',
            lines: currentLines,
          ),
        );
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 5);

        // 5) Ordinary re-entry hits the fresh cache (0 additional HTTP requests) and still shows 3 episodes.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildDetailPage(initialNoLines));
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 5);
        expect(find.text('3'), findsOneWidget);

        // Other video's cache entry was preserved untouched.
        await cmsClient.fetchDetail(
          httpSite,
          const CmsVideo(id: 'vid-other', title: '其他缓存影片'),
        );
        expect(otherDetailRequests, 1);

        // 6) Empty cache + initialVideo already carrying lines: ordinary open does 0 HTTP,
        //    pull-to-refresh bypasses fallback.lines.isNotEmpty and fetches fresh 2 episodes.
        cmsClient.clearDetailCache();
        targetDetailRequests = 0;
        currentLines = const [
          (
            '极速线路',
            [
              ('第01集', 'https://media.example/ep1.m3u8'),
              ('第02集', 'https://media.example/ep2.m3u8'),
            ],
          ),
        ];
        const initialWithOldLines = CmsVideo(
          id: 'vid-100',
          title: '连载新剧',
          lines: [
            CmsLine(
              name: '极速线路',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://media.example/ep1.m3u8'),
              ],
            ),
          ],
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildDetailPage(initialWithOldLines));
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 0);
        expect(find.text('2'), findsNothing);

        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 1);
        expect(find.text('2'), findsOneWidget);

        // 7) Stale prefetch returning AFTER a newer pull-to-refresh must NOT overwrite UI or cache.
        cmsClient.clearDetailCache();
        targetDetailRequests = 0;
        final slowPrefetchResponse = Completer<http.Response>();
        holdNextDetailResponse = slowPrefetchResponse;
        final prefetchFuture = cmsClient.prefetchDetail(
          httpSite,
          initialNoLines,
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(targetDetailRequests, 1);

        // Pull-to-refresh while stale prefetch is still pending -> returns 2 episodes immediately.
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 2);
        expect(find.text('2'), findsOneWidget);

        // Now complete the old prefetch with stale 1-episode payload.
        slowPrefetchResponse.complete(
          buildVodResponse(
            id: 'vid-100',
            title: '连载新剧',
            lines: const [
              ('极速线路', [('第01集', 'https://media.example/ep1.m3u8')]),
            ],
          ),
        );
        await tester.runAsync(() => prefetchFuture);
        await tester.pumpAndSettle();

        // UI keeps 2 episodes AND fresh ordinary re-entry still reads 2 episodes from cache!
        expect(find.text('2'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildDetailPage(initialNoLines));
        await tester.pumpAndSettle();
        expect(targetDetailRequests, 2);
        expect(find.text('2'), findsOneWidget);

        // 8) M3U VOD keeps its inline lines on pull-to-refresh without HTTP errors.
        const m3uSite = CmsSite(
          key: 'm3u_local',
          name: '本地M3U',
          type: 1,
          api: 'm3u_vod://playlist',
        );
        const m3uVideo = CmsVideo(
          id: 'm3u-1',
          title: 'M3U点播片',
          lines: [
            CmsLine(
              name: '播放列表',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://media.example/m3u1.m3u8'),
              ],
            ),
          ],
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildDetailPage(m3uVideo, site: m3uSite));
        await tester.pumpAndSettle();
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(find.text('1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Item 2: pull-to-refresh preserves manually selected line across [A,B], [B,A], falls back when B disappears or becomes unplayable, and honors mid-flight switches',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var responseLines = <(String, List<(String, String)>)>[
          ('线路A', const [('第01集', 'https://media.example/a-1.m3u8')]),
          ('线路B', const [('第01集', 'https://media.example/b-1.m3u8')]),
        ];
        Completer<http.Response>? holdNext;

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-lines') {
            if (holdNext != null) {
              final c = holdNext!;
              holdNext = null;
              return c.future;
            }
            return buildVodResponse(
              id: 'vid-lines',
              title: '多线路测试剧',
              lines: responseLines,
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo: const CmsVideo(id: 'vid-lines', title: '多线路测试剧'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        String activeCapsuleLabel() {
          final picker = find.byKey(const ValueKey('source_picker_button'));
          final text = tester.widget<Text>(
            find.descendant(of: picker, matching: find.byType(Text)).first,
          );
          return text.data ?? '';
        }

        Future<void> selectLineInSheet(
          String lineName, {
          bool whileRefreshing = false,
        }) async {
          Future<void> settle() async {
            if (whileRefreshing) {
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 350));
            } else {
              await tester.pumpAndSettle();
            }
          }

          await tester.tap(find.byKey(const ValueKey('source_picker_button')));
          await settle();
          await tester.tap(find.text(lineName).last);
          await settle();
        }

        Future<String> tapPrimaryPlayAndPop() async {
          await tester.tap(find.byKey(const Key('detail-primary-play-button')));
          await tester.pumpAndSettle();
          final url = playedUrls.last;
          final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
          nav.pop();
          await tester.pumpAndSettle();
          return url;
        }

        // Initially defaults to 线路A.
        expect(activeCapsuleLabel(), '线路A');

        // User manually picks 线路B via real line picker sheet.
        await selectLineInSheet('线路B');
        expect(activeCapsuleLabel(), '线路B');

        // Case 2a: Refresh returns [A, B] -> stays on 线路B and plays B's URL.
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路B');
        expect(await tapPrimaryPlayAndPop(), 'https://media.example/b-1.m3u8');

        // Case 2b: Refresh returns reordered [B, A] -> stays on 线路B and plays B's URL.
        responseLines = const [
          ('线路B', [('第01集', 'https://media.example/b-reordered.m3u8')]),
          ('线路A', [('第01集', 'https://media.example/a-reordered.m3u8')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路B');
        expect(
          await tapPrimaryPlayAndPop(),
          'https://media.example/b-reordered.m3u8',
        );

        // Case 2c: Slow refresh in flight — user switches B -> C while request is pending.
        responseLines = const [
          ('线路A', [('第01集', 'https://media.example/a-3.m3u8')]),
          ('线路B', [('第01集', 'https://media.example/b-3.m3u8')]),
          ('线路C', [('第01集', 'https://media.example/c-3.m3u8')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路B');

        final slowRefresh = Completer<http.Response>();
        holdNext = slowRefresh;
        await performPullRefresh(tester);
        // Switch line to 线路C BEFORE the slow refresh returns.
        await selectLineInSheet('线路C', whileRefreshing: true);
        expect(activeCapsuleLabel(), '线路C');

        slowRefresh.complete(
          buildVodResponse(
            id: 'vid-lines',
            title: '多线路测试剧',
            lines: const [
              ('线路A', [('第01集', 'https://media.example/a-slow.m3u8')]),
              ('线路B', [('第01集', 'https://media.example/b-slow.m3u8')]),
              ('线路C', [('第01集', 'https://media.example/c-slow.m3u8')]),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路C');
        expect(
          await tapPrimaryPlayAndPop(),
          'https://media.example/c-slow.m3u8',
        );

        // Case 2d: Selected line C becomes unplayable (magnet/P2P link) -> falls back to valid line A.
        responseLines = const [
          ('线路A', [('第01集', 'https://media.example/a-fallback.m3u8')]),
          ('线路C', [('第01集', 'magnet:?xt=urn:btih:deadbeef0123456789')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路A');
        expect(
          await tapPrimaryPlayAndPop(),
          'https://media.example/a-fallback.m3u8',
        );

        // Switch to 线路B after restoring [A, B], then delete B upstream -> falls back cleanly to 线路A.
        responseLines = const [
          ('线路A', [('第01集', 'https://media.example/a-keep.m3u8')]),
          ('线路B', [('第01集', 'https://media.example/b-temp.m3u8')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        await selectLineInSheet('线路B');
        expect(activeCapsuleLabel(), '线路B');

        responseLines = const [
          ('线路A', [('第01集', 'https://media.example/a-only.m3u8')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路A');
        expect(
          await tapPrimaryPlayAndPop(),
          'https://media.example/a-only.m3u8',
        );
      },
    );

    testWidgets(
      'Item 3: pull-to-refresh pill copy matches 72/48pt release hysteresis while Detail stays mounted and Back / left-edge swipe pop cleanly',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var detailRequestCount = 0;
        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-gesture') {
            detailRequestCount++;
            return buildVodResponse(
              id: 'vid-gesture',
              title: '下拉手势测试片',
              lines: const [
                ('主线路', [('第01集', 'https://media.example/g1.m3u8')]),
              ],
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });
        final cmsClient = CmsClient(client: mockHttp);

        void pushDetail(BuildContext ctx) {
          Navigator.of(ctx).push(
            PosterExpandRoute<void>(
              initialSourceRect: PosterExpandRoute.captureRect(ctx)!,
              sourceCardId: 'gesture-card-1',
              builder: (_) => DetailScreen(
                site: httpSite,
                initialVideo:
                    const CmsVideo(id: 'vid-gesture', title: '下拉手势测试片'),
                client: cmsClient,
                storage: storage,
              ),
            ),
          );
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              key: const ValueKey('gesture-home-page'),
              body: Center(
                child: Builder(
                  builder: (ctx) => GestureDetector(
                    key: const ValueKey('open-detail-card'),
                    onTap: () => pushDetail(ctx),
                    child: const SizedBox(
                      width: 120,
                      height: 180,
                      child: ColoredBox(color: Colors.blueGrey),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-detail-card')));
        await tester.pumpAndSettle();
        expect(find.byType(DetailScreen), findsOneWidget);
        expect(detailRequestCount, 1);

        String pillText() {
          final pill = find.byKey(const ValueKey('detail-pull-refresh-pill'));
          expect(pill, findsOneWidget);
          return tester
                  .widget<Text>(
                    find.descendant(of: pill, matching: find.byType(Text)).first,
                  )
                  .data ??
              '';
        }

        // 1) Pull to ~64 pt without ever crossing 72 pt -> copy says '下拉刷新详情', release triggers 0 refreshes.
        var gesture = await pullDetailToOverscroll(tester, 64.0);
        expect(pillText(), '下拉刷新详情');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(detailRequestCount, 1);
        expect(find.byType(DetailScreen), findsOneWidget);

        // 2) Pull past 72 pt (~82 pt) -> copy says '松手立即刷新', push back to ~64 pt -> copy STAYS '松手立即刷新', release triggers 1 refresh.
        gesture = await pullDetailToOverscroll(tester, 82.0);
        expect(pillText(), '松手立即刷新');
        gesture = await pullDetailToOverscroll(
          tester,
          64.0,
          existingGesture: gesture,
        );
        expect(pillText(), '松手立即刷新');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(detailRequestCount, 2);
        expect(find.byType(DetailScreen), findsOneWidget);

        // 3) Pull past 72 pt (~82 pt) -> push back below 48 pt (~38 pt) -> copy reverts to '下拉刷新详情', release triggers 0 refreshes.
        gesture = await pullDetailToOverscroll(tester, 82.0);
        expect(pillText(), '松手立即刷新');
        gesture = await pullDetailToOverscroll(
          tester,
          38.0,
          existingGesture: gesture,
        );
        expect(pillText(), '下拉刷新详情');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(detailRequestCount, 2);
        expect(find.byType(DetailScreen), findsOneWidget);

        // 4) Back button pops Detail cleanly.
        await tester.tap(find.byIcon(CupertinoIcons.chevron_back));
        await tester.pumpAndSettle();
        expect(find.byType(DetailScreen), findsNothing);

        // 5) Re-open Detail and verify left-edge swipe pops cleanly.
        await tester.tap(find.byKey(const ValueKey('open-detail-card')));
        await tester.pumpAndSettle();
        expect(find.byType(DetailScreen), findsOneWidget);

        await tester.flingFrom(
          const Offset(10, 420),
          const Offset(240, 0),
          1100.0,
        );
        await tester.pumpAndSettle();
        expect(find.byType(DetailScreen), findsNothing);
      },
    );

    testWidgets(
      'Review Item 1a: open line picker before refresh reorders [A,B] to [B,A] or deletes B; tapping displayed B matches by identity and never selects A',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        Completer<http.Response>? holdNext;
        var currentLines = <(String, List<(String, String)>)>[
          ('线路A', const [('第01集', 'https://media.example/a.mp4')]),
          ('线路B', const [('第01集', 'https://media.example/b.mp4')]),
        ];

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-sheet-line') {
            if (holdNext != null) {
              final c = holdNext!;
              holdNext = null;
              return c.future;
            }
            return buildVodResponse(
              id: 'vid-sheet-line',
              title: '弹层选线时序测试',
              lines: currentLines,
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo:
                  const CmsVideo(id: 'vid-sheet-line', title: '弹层选线时序测试'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        String activeCapsuleLabel() {
          final picker = find.byKey(const ValueKey('source_picker_button'));
          return tester
                  .widget<Text>(
                    find.descendant(of: picker, matching: find.byType(Text))
                        .first,
                  )
                  .data ??
              '';
        }

        expect(activeCapsuleLabel(), '线路A');

        // Start a delayed pull-to-refresh, then open the line picker BEFORE it resolves.
        final pendingReorder = Completer<http.Response>();
        holdNext = pendingReorder;
        await performPullRefresh(tester);

        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('线路B'), findsOneWidget);

        // Complete refresh with reordered [B, A] while the line picker sheet is still open.
        pendingReorder.complete(
          buildVodResponse(
            id: 'vid-sheet-line',
            title: '弹层选线时序测试',
            lines: const [
              ('线路B', [('第01集', 'https://media.example/b-reordered.mp4')]),
              ('线路A', [('第01集', 'https://media.example/a-reordered.mp4')]),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Tap the still-displayed 线路B row -> must select 线路B (index 0) and play B's URL!
        await tester.tap(find.text('线路B').last);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路B');

        await tester.tap(find.byKey(const Key('detail-primary-play-button')));
        await tester.pumpAndSettle();
        expect(playedUrls.last, 'https://media.example/b-reordered.mp4');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // Now test target line deleted while line picker is open -> must warn & never select wrong line.
        final pendingDelete = Completer<http.Response>();
        holdNext = pendingDelete;
        await performPullRefresh(tester);

        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingDelete.complete(
          buildVodResponse(
            id: 'vid-sheet-line',
            title: '弹层选线时序测试',
            lines: const [
              ('线路A', [('第01集', 'https://media.example/a-only.mp4')]),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Refresh already fell back to 线路A; tapping stale 线路B in the open sheet prompts re-selection.
        await tester.tap(find.text('线路B').last);
        await tester.pumpAndSettle();
        expect(activeCapsuleLabel(), '线路A');
        expect(find.textContaining('请重新选择'), findsOneWidget);
      },
    );

    testWidgets(
      'Review Item 1b: open all-episodes sheet on A before refresh reorders [A,B] to [B,A] or deletes A ep2; tapping displayed A ep2 plays A ep2 or blocks deleted target without playing B',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        Completer<http.Response>? holdNext;
        final initialLines = <(String, List<(String, String)>)>[
          (
            '线路A',
            const [
              ('第01集', 'https://media.example/a-ep1.mp4'),
              ('第02集', 'https://media.example/a-ep2.mp4'),
            ],
          ),
          (
            '线路B',
            const [
              ('第01集', 'https://media.example/b-ep1.mp4'),
            ],
          ),
        ];

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-sheet-ep') {
            if (holdNext != null) {
              final c = holdNext!;
              holdNext = null;
              return c.future;
            }
            return buildVodResponse(
              id: 'vid-sheet-ep',
              title: '全部剧集弹层时序测试',
              lines: initialLines,
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo:
                  const CmsVideo(id: 'vid-sheet-ep', title: '全部剧集弹层时序测试'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Start delayed refresh while on 线路A (2 eps), then open "全部剧集 (2)" sheet.
        final pendingReorder = Completer<http.Response>();
        holdNext = pendingReorder;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.textContaining('全部剧集 ·'), findsOneWidget);

        // Refresh completes reordering lines to [B (1 ep), A (2 eps)] while sheet stays open.
        pendingReorder.complete(
          buildVodResponse(
            id: 'vid-sheet-ep',
            title: '全部剧集弹层时序测试',
            lines: const [
              ('线路B', [('第01集', 'https://media.example/b-ep1.mp4')]),
              (
                '线路A',
                [
                  ('第01集', 'https://media.example/a-ep1.mp4'),
                  ('第02集', 'https://media.example/a-ep2.mp4'),
                ],
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Tap A's episode 2 inside the open sheet -> must play a-ep2.mp4 (NEVER b-ep1.mp4!).
        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(playedUrls, ['https://media.example/a-ep2.mp4']);
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // Now test episode 2 DELETED during refresh while sheet is open -> must NOT play any other episode!
        final pendingDeleteEp = Completer<http.Response>();
        holdNext = pendingDeleteEp;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingDeleteEp.complete(
          buildVodResponse(
            id: 'vid-sheet-ep',
            title: '全部剧集弹层时序测试',
            lines: const [
              ('线路B', [('第01集', 'https://media.example/b-ep1.mp4')]),
              ('线路A', [('第01集', 'https://media.example/a-ep1.mp4')]),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final playCountBefore = playedUrls.length;
        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(playedUrls.length, playCountBefore);
        expect(find.textContaining('请重新选择'), findsOneWidget);
      },
    );

    testWidgets(
      'Review Item 2a: authoritative empty CMS detail (same-ID zero lines & empty list) evicts stale cache, failure preserves UI without re-caching, and late stale prefetch never revives evicted cache',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var reqCount = 0;
        late http.Response Function() responseBuilder;
        Completer<http.Response>? holdNext;

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-empty-case') {
            reqCount++;
            if (holdNext != null) {
              final c = holdNext!;
              holdNext = null;
              return c.future;
            }
            return responseBuilder();
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);
        const seedVideo = CmsVideo(id: 'vid-empty-case', title: '下架测试剧');

        Widget buildPage() => MaterialApp(
              home: DetailScreen(
                site: httpSite,
                initialVideo: seedVideo,
                client: cmsClient,
                storage: storage,
              ),
            );

        // --- Sub-case 1: 1 ep -> 2 eps -> same-ID zero lines ---
        responseBuilder = () => buildVodResponse(
              id: 'vid-empty-case',
              title: '下架测试剧',
              lines: const [
                ('主线', [('第01集', 'https://media.example/e1.m3u8')]),
              ],
            );
        await tester.pumpWidget(buildPage());
        await tester.pumpAndSettle();
        expect(reqCount, 1);
        expect(find.text('1'), findsOneWidget);

        responseBuilder = () => buildVodResponse(
              id: 'vid-empty-case',
              title: '下架测试剧',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/e1.m3u8'),
                    ('第02集', 'https://media.example/e2.m3u8'),
                  ],
                ),
              ],
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 2);
        expect(find.text('2'), findsOneWidget);

        // Upstream withdraws all episodes (same vod_id, zero lines).
        responseBuilder = () => http.Response(
              jsonEncode({
                'code': 1,
                'list': [
                  {
                    'vod_id': 'vid-empty-case',
                    'vod_name': '下架测试剧',
                    'vod_play_from': '',
                    'vod_play_url': '',
                  },
                ],
              }),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 3);
        expect(find.text('1'), findsNothing);
        expect(find.text('2'), findsNothing);

        // Exit & re-enter -> stale 2-episode cache was evicted, makes req #4 and stays 0 episodes!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildPage());
        await tester.pumpAndSettle();
        expect(reqCount, 4);
        expect(find.text('1'), findsNothing);
        expect(find.text('2'), findsNothing);

        // --- Sub-case 2: 2 eps -> authoritative successful empty list: [] ---
        responseBuilder = () => buildVodResponse(
              id: 'vid-empty-case',
              title: '下架测试剧',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/e1.m3u8'),
                    ('第02集', 'https://media.example/e2.m3u8'),
                  ],
                ),
              ],
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 5);
        expect(find.text('2'), findsOneWidget);

        responseBuilder = () => http.Response(
              jsonEncode({'code': 1, 'list': []}),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 6);
        expect(find.text('1'), findsNothing);
        expect(find.text('2'), findsNothing);

        // Exit & re-enter -> does NOT resurrect 2 episodes; fetches req #7 and remains 0 episodes.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildPage());
        await tester.pumpAndSettle();
        expect(reqCount, 7);
        expect(find.text('2'), findsNothing);

        // --- Sub-case 3: Request failure keeps UI episodes for retry without re-caching old lines ---
        responseBuilder = () => buildVodResponse(
              id: 'vid-empty-case',
              title: '下架测试剧',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/e1.m3u8'),
                    ('第02集', 'https://media.example/e2.m3u8'),
                  ],
                ),
              ],
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 8);
        expect(find.text('2'), findsOneWidget);

        // Clear cache so we verify a failed refresh does NOT re-register page's old 2 eps into cache.
        cmsClient.clearDetailCache();
        responseBuilder = () => http.Response('Internal Server Error', 500);
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 9);
        // Page keeps 2 episodes for retry.
        expect(find.text('2'), findsOneWidget);
        expect(cmsClient.debugDetailCacheSize, 0);

        // Also verify HTML error page is treated as failure (NOT authoritative delist!).
        responseBuilder = () => http.Response('<html><body>502 Bad Gateway</body></html>', 200);
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 10);
        expect(find.text('2'), findsOneWidget);
        expect(cmsClient.debugDetailCacheSize, 0);

        // Exit & re-enter when upstream now returns empty -> makes req #11 (cache was NOT polluted by failure).
        responseBuilder = () => http.Response(
              jsonEncode({'code': 1, 'list': []}),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildPage());
        await tester.pumpAndSettle();
        expect(reqCount, 11);
        expect(find.text('2'), findsNothing);

        // --- Sub-case 4: Late stale prefetch must NOT revive cache evicted by authoritative empty refresh ---
        final stalePrefetch = Completer<http.Response>();
        holdNext = stalePrefetch;
        final prefetchFuture = cmsClient.prefetchDetail(httpSite, seedVideo);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(reqCount, 12);

        // Authoritative empty refresh finishes while stale prefetch is still in flight.
        responseBuilder = () => http.Response(
              jsonEncode({'code': 1, 'list': []}),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 13);
        expect(find.text('2'), findsNothing);

        // Stale prefetch completes late with old 2 episodes -> must NOT write into cache!
        stalePrefetch.complete(
          buildVodResponse(
            id: 'vid-empty-case',
            title: '下架测试剧',
            lines: const [
              (
                '主线',
                [
                  ('第01集', 'https://media.example/e1.m3u8'),
                  ('第02集', 'https://media.example/e2.m3u8'),
                ],
              ),
            ],
          ),
        );
        await tester.runAsync(() => prefetchFuture);
        await tester.pumpAndSettle();
        expect(cmsClient.debugDetailCacheSize, 0);
        expect(cmsClient.debugTrackedDetailFlightCount, 0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildPage());
        await tester.pumpAndSettle();
        expect(reqCount, 14);
        expect(find.text('2'), findsNothing);
      },
    );

    test(
      'Review Item 2b: XBPQ, XYQ and XPath rule engines discard stale fallback lines and evict cache when refreshed page has zero episodes',
      () async {
        final scenarios = <({
          String label,
          CmsSite site,
          String withEpHtml,
          String emptyEpHtml,
        })>[
          (
            label: 'XBPQ',
            site: CmsSite(
              key: 'rule_xbpq',
              name: 'XBPQ源',
              type: 3,
              api: 'csp_XBPQ',
              ext: jsonEncode({
                '主页url': 'https://rule.example',
                '线路数组': 'class="tab"&&</div>',
                '线路标题': '<span>&&</span>',
                '播放数组': 'class="playlist"&&</ul>',
                '播放列表': '<a&&/a>',
                '播放标题': '>&&<',
                '播放链接': 'href="&&"',
              }),
            ),
            withEpHtml:
                '<html><body><div class="tab"><span>线路1</span></div><ul class="playlist"><a href="/play/1.m3u8">E1</a></ul></body></html>',
            emptyEpHtml:
                '<html><body><div class="video-info-content">暂无剧集</div></body></html>',
          ),
          (
            label: 'XYQ',
            site: CmsSite(
              key: 'rule_xyq',
              name: 'XYQ源',
              type: 3,
              api: 'csp_XYQ',
              ext: jsonEncode({
                '首页网址': 'https://rule.example',
                '线路列表数组规则': '.tab',
                '线路标题': 'span&&Text',
                '播放列表数组规则': '.playlist',
                '选集列表数组规则': 'a',
                '选集标题': 'Text',
                '选集链接': 'href',
              }),
            ),
            withEpHtml:
                '<html><body><div class="tab"><span>线路1</span></div><ul class="playlist"><a href="/play/1.m3u8">E1</a></ul></body></html>',
            emptyEpHtml:
                '<html><body><div class="video-info-content">暂无剧集</div></body></html>',
          ),
          (
            label: 'XPath',
            site: CmsSite(
              key: 'rule_xpath',
              name: 'XPath源',
              type: 3,
              api: 'csp_XPath',
              ext: jsonEncode({
                'homeUrl': 'https://rule.example',
                'dtUrl': '{vid}',
                'dtFromNode': '//div[@class="tab"]',
                'dtFromName': '//span/text()',
                'dtUrlNode': '//ul[@class="playlist"]',
                'dtUrlSubNode': '//a',
                'dtUrlId': '/@href',
                'dtUrlName': '/text()',
                'playUrl': '{playUrl}',
              }),
            ),
            withEpHtml:
                '<html><body><div class="tab"><span>线路1</span></div><ul class="playlist"><a href="/play/1.m3u8">E1</a></ul></body></html>',
            emptyEpHtml:
                '<html><body><div class="video-info-content">暂无剧集</div></body></html>',
          ),
        ];

        for (final sc in scenarios) {
          var currentHtml = sc.withEpHtml;
          var calls = 0;
          final client = CmsClient(
            client: MockClient((req) async {
              calls++;
              return http.Response(
                currentHtml,
                200,
                headers: const {'content-type': 'text/html; charset=utf-8'},
              );
            }),
          );
          final seed = CmsVideo(
            id: 'https://rule.example/vod/${sc.label}',
            title: '${sc.label}影片',
          );

          final first = await client.fetchDetail(sc.site, seed);
          expect(calls, 1, reason: sc.label);
          expect(first.lines.single.episodes.single.name, 'E1', reason: sc.label);

          // Authoritative page update removes all episodes; forceRefresh passes `first` (which still has E1 in fallback!).
          currentHtml = sc.emptyEpHtml;
          final refreshed = await client.fetchDetail(
            sc.site,
            first,
            forceRefresh: true,
          );
          expect(calls, 2, reason: sc.label);
          expect(refreshed.lines, isEmpty, reason: '${sc.label} must not revive fallback E1');

          // Re-entering (non-force) must NOT hit stale cached E1.
          final reentered = await client.fetchDetail(sc.site, seed);
          expect(calls, 3, reason: sc.label);
          expect(reentered.lines, isEmpty, reason: '${sc.label} cache must be evicted');

          // Blank HTML must throw FormatException (parse error, distinct from delisted page).
          currentHtml = '   ';
          await expectLater(
            client.fetchDetail(sc.site, first, forceRefresh: true),
            throwsFormatException,
          );
          expect(client.debugTrackedDetailFlightCount, 0, reason: sc.label);
        }
      },
    );

    test(
      'Review Item 5: detail flight tracker reclaims all entries across many distinct videos and guards concurrent refresh vs late prefetch',
      () async {
        final mockHttp = MockClient((request) async {
          final id = request.url.queryParameters['ids'] ?? '';
          if (id == 'fail-vid') {
            return http.Response('err', 500);
          }
          if (id == 'empty-vid') {
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }
          return buildVodResponse(
            id: id,
            title: '影片 $id',
            lines: [
              ('线路1', [('第01集', 'https://media.example/$id.m3u8')]),
            ],
          );
        });
        final client = CmsClient(client: mockHttp);

        for (var i = 0; i < 120; i++) {
          await client.fetchDetail(
            httpSite,
            CmsVideo(id: 'v-$i', title: '影片 v-$i'),
          );
        }
        await client.fetchDetail(
          httpSite,
          const CmsVideo(id: 'empty-vid', title: '空影片'),
        );
        await expectLater(
          client.fetchDetail(
            httpSite,
            const CmsVideo(id: 'fail-vid', title: '失败影片'),
          ),
          throwsException,
        );

        expect(client.debugTrackedDetailFlightCount, 0);
        expect(client.debugDetailCacheSize, lessThanOrEqualTo(48));

        // Verify concurrent stale prefetch + newer forceRefresh stays tracked ONLY while active and reclaims to 0 once done.
        final slowPrefetch = Completer<http.Response>();
        var raceCalls = 0;
        final raceClient = CmsClient(
          client: MockClient((request) async {
            raceCalls++;
            if (raceCalls == 1) return slowPrefetch.future;
            return buildVodResponse(
              id: 'race-1',
              title: '竞态片',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/r1.m3u8'),
                    ('第02集', 'https://media.example/r2.m3u8'),
                  ],
                ),
              ],
            );
          }),
        );
        const raceSeed = CmsVideo(id: 'race-1', title: '竞态片');
        final prefetchFut = raceClient.prefetchDetail(httpSite, raceSeed);
        await Future<void>.delayed(Duration.zero);
        expect(raceClient.debugTrackedDetailFlightCount, 1);

        final fresh = await raceClient.fetchDetail(
          httpSite,
          raceSeed,
          forceRefresh: true,
        );
        expect(fresh.lines.single.episodes.length, 2);
        // Tracker remains alive while old prefetch is still in flight.
        expect(raceClient.debugTrackedDetailFlightCount, 1);

        slowPrefetch.complete(
          buildVodResponse(
            id: 'race-1',
            title: '竞态片',
            lines: const [
              ('主线', [('第01集', 'https://media.example/r1.m3u8')]),
            ],
          ),
        );
        await prefetchFut;
        // Reclaimed immediately once all in-flight requests for the key finish.
        expect(raceClient.debugTrackedDetailFlightCount, 0);

        final cached = await raceClient.fetchDetail(httpSite, raceSeed);
        expect(cached.lines.single.episodes.length, 2);
        expect(raceCalls, 2);
      },
    );

    testWidgets(
      'Round2 Item 1: manual selection of 2nd duplicate-name line stays on /b.mp4 across same-order & reversed refresh, respects stable source IDs, and prompts re-selection if deleted',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var duplicateLines = <(String, List<(String, String)>)>[
          ('超清线路', const [('第01集', 'https://media.example/a.mp4')]),
          ('超清线路', const [('第01集', 'https://media.example/b.mp4')]),
        ];
        http.Response? customVodResponse;

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-dup-line') {
            if (customVodResponse != null) {
              return customVodResponse;
            }
            return buildVodResponse(
              id: 'vid-dup-line',
              title: '同名线路测试剧',
              lines: duplicateLines,
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo:
                  const CmsVideo(id: 'vid-dup-line', title: '同名线路测试剧'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        Future<String> tapPrimaryPlayAndPop() async {
          await tester.tap(find.byKey(const Key('detail-primary-play-button')));
          await tester.pumpAndSettle();
          final url = playedUrls.last;
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
          await tester.pumpAndSettle();
          return url;
        }

        // Open source picker and manually select the 2nd duplicate-name line (/b.mp4).
        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pumpAndSettle();
        // Sheet shows two tiles both titled '超清线路'; tap the 2nd one.
        final dupRows = find.text('超清线路');
        expect(dupRows, findsAtLeastNWidgets(2));
        await tester.tap(dupRows.last);
        await tester.pumpAndSettle();

        // Confirm initial playback of manually selected 2nd duplicate-name line.
        expect(await tapPrimaryPlayAndPop(), 'https://media.example/b.mp4');

        // 1) Same-order pull-to-refresh: server returns identical lines, order, and URLs.
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(await tapPrimaryPlayAndPop(), 'https://media.example/b.mp4');

        // 2) Reversed-order pull-to-refresh: [b, a] -> must still play /b.mp4.
        duplicateLines = const [
          ('超清线路', [('第01集', 'https://media.example/b.mp4')]),
          ('超清线路', [('第01集', 'https://media.example/a.mp4')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(await tapPrimaryPlayAndPop(), 'https://media.example/b.mp4');

        // 3) Original /b.mp4 line disappears, leaving only the other duplicate-name line /a.mp4:
        //    must prompt the user to re-select instead of silently pretending /a.mp4 is /b.mp4.
        duplicateLines = const [
          ('超清线路', [('第01集', 'https://media.example/a.mp4')]),
        ];
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('请重新选择'), findsOneWidget);

        // 4) Stable source line IDs (`vod_url_with_player.code`) with identical display name:
        //    even when order reverses AND URLs rotate, stable line ID keeps 2nd line selected.
        customVodResponse = http.Response(
          jsonEncode({
            'code': 1,
            'list': [
              {
                'vod_id': 'vid-dup-line',
                'vod_name': '同名线路测试剧',
                'vod_url_with_player': [
                  {
                    'code': 'line_code_1',
                    'name': '极速专线',
                    'url': '第01集\$https://media.example/a-v1.mp4',
                  },
                  {
                    'code': 'line_code_2',
                    'name': '极速专线',
                    'url': '第01集\$https://media.example/b-v1.mp4',
                  },
                ],
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('极速专线').last);
        await tester.pumpAndSettle();
        expect(await tapPrimaryPlayAndPop(), 'https://media.example/b-v1.mp4');

        // Reverse order & rotate stream URLs while preserving stable line `code`.
        customVodResponse = http.Response(
          jsonEncode({
            'code': 1,
            'list': [
              {
                'vod_id': 'vid-dup-line',
                'vod_name': '同名线路测试剧',
                'vod_url_with_player': [
                  {
                    'code': 'line_code_2',
                    'name': '极速专线',
                    'url': '第01集\$https://media.example/b-v2.mp4',
                  },
                  {
                    'code': 'line_code_1',
                    'name': '极速专线',
                    'url': '第01集\$https://media.example/a-v2.mp4',
                  },
                ],
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(await tapPrimaryPlayAndPop(), 'https://media.example/b-v2.mp4');
      },
    );

    testWidgets(
      'Round2 Item 2: all-episodes sheet with duplicate-name lines plays /original2.mp4 in Case A and blocks with prompt & 0 player calls in Case B when original line is deleted',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        Completer<http.Response>? holdNext;
        const twoDupLines = <(String, List<(String, String)>)>[
          (
            '同名线路',
            [
              ('第01集', 'https://media.example/original1.mp4'),
              ('第02集', 'https://media.example/original2.mp4'),
            ],
          ),
          (
            '同名线路',
            [
              ('第01集', 'https://media.example/other1.mp4'),
              ('第02集', 'https://media.example/other2.mp4'),
            ],
          ),
        ];

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail' &&
              request.url.queryParameters['ids'] == 'vid-dup-sheet') {
            if (holdNext != null) {
              final c = holdNext!;
              holdNext = null;
              return c.future;
            }
            return buildVodResponse(
              id: 'vid-dup-sheet',
              title: '同名线路弹层剧',
              lines: twoDupLines,
            );
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        final cmsClient = CmsClient(client: mockHttp);
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo:
                  const CmsVideo(id: 'vid-dup-sheet', title: '同名线路弹层剧'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // --- Case A1 (same order): original line & /original2.mp4 still exist ---
        final pendingCaseA1 = Completer<http.Response>();
        holdNext = pendingCaseA1;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingCaseA1.complete(
          buildVodResponse(
            id: 'vid-dup-sheet',
            title: '同名线路弹层剧',
            lines: twoDupLines,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(playedUrls, ['https://media.example/original2.mp4']);
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // --- Case A2 (reversed order): original line moved to index 1, still plays /original2.mp4 ---
        final pendingCaseA2 = Completer<http.Response>();
        holdNext = pendingCaseA2;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingCaseA2.complete(
          buildVodResponse(
            id: 'vid-dup-sheet',
            title: '同名线路弹层剧',
            lines: [twoDupLines[1], twoDupLines[0]],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(
          playedUrls,
          [
            'https://media.example/original2.mp4',
            'https://media.example/original2.mp4',
          ],
        );
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // --- Case B: refresh deletes original line, leaving ONLY the other duplicate-name line (/other2.mp4) ---
        final pendingCaseB = Completer<http.Response>();
        holdNext = pendingCaseB;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingCaseB.complete(
          buildVodResponse(
            id: 'vid-dup-sheet',
            title: '同名线路弹层剧',
            lines: [twoDupLines[1]],
          ),
        );
        await tester.pumpAndSettle();

        final playCallsBefore = playedUrls.length;
        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(playedUrls.length, playCallsBefore);
        expect(playedUrls, isNot(contains('https://media.example/other2.mp4')));
        expect(find.textContaining('请重新选择'), findsOneWidget);
      },
    );

    testWidgets(
      'Round2 Item 3: authoritative delisting prevents stale card with embedded old line from resurrecting episodes on exit & re-entry, recovers on pull refresh, bounds empty cache with TTL, and preserves M3U inline lines',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var reqCount = 0;
        late http.Response Function() responseBuilder;

        final mockHttp = MockClient((request) async {
          if (request.url.queryParameters['ac'] == 'detail') {
            reqCount++;
            return responseBuilder();
          }
          return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
        });

        var clockNow = DateTime(2026, 11, 23, 20, 0, 0);
        final cmsClient = CmsClient(client: mockHttp)
          ..debugClock = () => clockNow;

        // Same list card carrying 1 stale embedded episode (exact repro from Review Item 3).
        const staleCardWithOneEp = CmsVideo(
          id: 'vid-stale-card',
          title: '自带旧集卡片剧',
          lines: [
            CmsLine(
              name: '主线',
              episodes: [
                CmsEpisode(name: '第01集', url: 'https://media.example/old1.mp4'),
              ],
            ),
          ],
        );
        final playedUrls = <String>[];

        Widget buildFromSameCard() => MaterialApp(
              home: DetailScreen(
                site: httpSite,
                initialVideo: staleCardWithOneEp,
                client: cmsClient,
                storage: storage,
                debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                  final url = v.lines[lineIdx].episodes[epIdx].url;
                  playedUrls.add(url);
                  return Scaffold(body: Center(child: Text('PLAY:$url')));
                },
              ),
            );

        // Step 1: Open from card carrying 1 episode (0 HTTP requests).
        responseBuilder = () => buildVodResponse(
              id: 'vid-stale-card',
              title: '自带旧集卡片剧',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/e1.mp4'),
                    ('第02集', 'https://media.example/e2.mp4'),
                  ],
                ),
              ],
            );
        await tester.pumpWidget(buildFromSameCard());
        await tester.pumpAndSettle();
        expect(reqCount, 0);
        expect(find.text('1'), findsOneWidget);
        expect(find.text('2'), findsNothing);

        // Step 2: Upstream has 2 eps -> pull-to-refresh shows 2 eps (req #1).
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 1);
        expect(find.text('2'), findsOneWidget);
        expect(cmsClient.debugDetailCacheSize, 1);
        expect(cmsClient.debugDetailEmptyCacheSize, 0);

        // Step 3: Upstream withdraws all episodes (same vod_id, zero lines) -> pull-to-refresh shows 0 eps (req #2).
        responseBuilder = () => http.Response(
              jsonEncode({
                'code': 1,
                'list': [
                  {
                    'vod_id': 'vid-stale-card',
                    'vod_name': '自带旧集卡片剧',
                    'vod_play_from': '',
                    'vod_play_url': '',
                  },
                ],
              }),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 2);
        expect(find.text('1'), findsNothing);
        expect(find.text('2'), findsNothing);
        expect(cmsClient.debugDetailCacheSize, 0);
        expect(cmsClient.debugDetailEmptyCacheSize, 1);

        // Step 4: Exit and re-open THE EXACT SAME card carrying 1 old episode.
        // Must re-verify upstream (req #3), show 0 episodes, and NEVER let old1.mp4 become playable!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildFromSameCard());
        await tester.pumpAndSettle();
        expect(reqCount, 3);
        expect(find.text('1'), findsNothing);
        expect(find.text('2'), findsNothing);
        expect(find.text('搜索其他片源'), findsOneWidget);
        expect(playedUrls, isEmpty);
        expect(cmsClient.debugDetailCacheSize, 0);
        expect(cmsClient.debugDetailEmptyCacheSize, 1);

        // Step 5: Upstream restores 2 episodes -> active pull-to-refresh recovers both episodes (req #4).
        responseBuilder = () => buildVodResponse(
              id: 'vid-stale-card',
              title: '自带旧集卡片剧',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/r1.mp4'),
                    ('第02集', 'https://media.example/r2.mp4'),
                  ],
                ),
              ],
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(reqCount, 4);
        expect(find.text('1'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(cmsClient.debugDetailCacheSize, 1);
        expect(cmsClient.debugDetailEmptyCacheSize, 0);

        await tester.tap(find.byKey(const Key('detail-primary-play-button')));
        await tester.pumpAndSettle();
        expect(playedUrls.last, 'https://media.example/r1.mp4');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // Step 6: Verify empty-result cache TTL expiration & bounded capacity (<= 48) + M3U VOD inline lines preserved.
        responseBuilder = () => http.Response(
              jsonEncode({'code': 1, 'list': []}),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        for (var i = 0; i < 60; i++) {
          await cmsClient.fetchDetail(
            httpSite,
            CmsVideo(id: 'empty-bound-$i', title: '空片 $i'),
          );
        }
        expect(cmsClient.debugDetailEmptyCacheSize, lessThanOrEqualTo(48));
        expect(
          cmsClient.hasAuthoritativeEmptyDetail(
            httpSite,
            const CmsVideo(id: 'empty-bound-59', title: '空片 59'),
          ),
          isTrue,
        );
        clockNow = clockNow.add(const Duration(minutes: 6));
        expect(
          cmsClient.hasAuthoritativeEmptyDetail(
            httpSite,
            const CmsVideo(id: 'empty-bound-59', title: '空片 59'),
          ),
          isFalse,
        );

        const m3uSite = CmsSite(
          key: 'm3u_vod',
          name: 'M3U片源',
          type: 1,
          api: 'm3u_vod://https://m3u.example/playlist.m3u',
        );
        const m3uCard = CmsVideo(
          id: 'm3u-1',
          title: 'M3U内嵌影片',
          lines: [
            CmsLine(
              name: 'M3U直连',
              episodes: [
                CmsEpisode(name: '正片', url: 'https://m3u.example/movie.m3u8'),
              ],
            ),
          ],
        );
        final reqsBeforeM3u = reqCount;
        final m3uRes = await cmsClient.fetchDetail(
          m3uSite,
          m3uCard,
          forceRefresh: true,
        );
        expect(reqCount, reqsBeforeM3u);
        expect(m3uRes.lines.single.episodes.single.url,
            'https://m3u.example/movie.m3u8');
      },
    );

    testWidgets(
      'Round2 Item 4: upstream business errors & corrupted responses (CMS code:0 error, corrupt list, truncated XML, XBPQ JSON error, T4 business error) retain playable episodes & cache while legitimate empty lists clear and later recover',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var cmsReqs = 0;
        late http.Response Function() cmsResp;

        final cmsClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['ac'] == 'detail' &&
                request.url.queryParameters['ids'] == 'vid-err-proto') {
              cmsReqs++;
              return cmsResp();
            }
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }),
        );
        const cmsSeed = CmsVideo(id: 'vid-err-proto', title: '错误响应守卫剧');

        Widget buildCmsPage() => MaterialApp(
              home: DetailScreen(
                site: httpSite,
                initialVideo: cmsSeed,
                client: cmsClient,
                storage: storage,
              ),
            );

        // Seed 1 valid episode in DetailScreen + cache.
        cmsResp = () => buildVodResponse(
              id: 'vid-err-proto',
              title: '错误响应守卫剧',
              lines: const [
                ('主线', [('第01集', 'https://media.example/ok1.mp4')]),
              ],
            );
        await tester.pumpWidget(buildCmsPage());
        await tester.pumpAndSettle();
        expect(cmsReqs, 1);
        expect(find.text('1'), findsOneWidget);
        expect(cmsClient.debugDetailCacheSize, 1);
        expect(cmsClient.debugDetailEmptyCacheSize, 0);

        // All 3 standard CMS error/corrupt HTTP 200 payloads must preserve 1 ep + cache.
        final cmsBadPayloads = <({String label, String body, String contentType})>[
          (
            label: 'CMS code=0 business error with list:[]',
            body: jsonEncode({
              'code': 0,
              'msg': 'upstream temporarily unavailable',
              'list': [],
            }),
            contentType: 'application/json; charset=utf-8',
          ),
          (
            label: 'CMS non-empty corrupted array [null,42]',
            body: '{"list":[null,42]}',
            contentType: 'application/json; charset=utf-8',
          ),
          (
            label: 'CMS truncated XML',
            body: '<rss><list><video><id>vid-err-proto</id><name>Broken',
            contentType: 'application/xml; charset=utf-8',
          ),
        ];

        for (final bad in cmsBadPayloads) {
          final beforeReqs = cmsReqs;
          cmsResp = () => http.Response(
                bad.body,
                200,
                headers: {'content-type': bad.contentType},
              );
          await performPullRefresh(tester);
          await tester.pumpAndSettle();
          expect(cmsReqs, beforeReqs + 1, reason: bad.label);
          expect(find.text('1'), findsOneWidget,
              reason: '${bad.label} must retain existing episode');
          expect(cmsClient.debugDetailCacheSize, 1,
              reason: '${bad.label} must NOT evict playable cache');
          expect(cmsClient.debugDetailEmptyCacheSize, 0,
              reason: '${bad.label} must NOT mark video authoritatively empty');

          // Exit & re-enter immediately hits preserved 1-episode cache (0 extra reqs).
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.pumpWidget(buildCmsPage());
          await tester.pumpAndSettle();
          expect(cmsReqs, beforeReqs + 1, reason: '${bad.label} re-entry cache');
          expect(find.text('1'), findsOneWidget,
              reason: '${bad.label} re-entry keeps playable episode');
        }

        // Legitimate empty list MUST clear to 0 episodes, evict cache, and record empty marker.
        final reqsBeforeLegitEmpty = cmsReqs;
        cmsResp = () => http.Response(
              jsonEncode({'code': 1, 'msg': '数据列表', 'list': []}),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(cmsReqs, reqsBeforeLegitEmpty + 1);
        expect(find.text('1'), findsNothing);
        expect(cmsClient.debugDetailCacheSize, 0);
        expect(cmsClient.debugDetailEmptyCacheSize, 1);

        // Exit & re-enter stays 0 episodes and re-verifies upstream.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildCmsPage());
        await tester.pumpAndSettle();
        expect(cmsReqs, reqsBeforeLegitEmpty + 2);
        expect(find.text('1'), findsNothing);

        // Upstream recovers 2 episodes -> pull-to-refresh restores both.
        cmsResp = () => buildVodResponse(
              id: 'vid-err-proto',
              title: '错误响应守卫剧',
              lines: const [
                (
                  '主线',
                  [
                    ('第01集', 'https://media.example/ok1.mp4'),
                    ('第02集', 'https://media.example/ok2.mp4'),
                  ],
                ),
              ],
            );
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(cmsReqs, reqsBeforeLegitEmpty + 3);
        expect(find.text('2'), findsOneWidget);
        expect(cmsClient.debugDetailCacheSize, 1);
        expect(cmsClient.debugDetailEmptyCacheSize, 0);

        // Clean unmount before testing XBPQ & T4 protocols.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        // --- XBPQ HTML detail receiving JSON error object ---
        final xbpqSite = CmsSite(
          key: 'xbpq_err_site',
          name: 'XBPQ错误源',
          type: 3,
          api: 'csp_XBPQ',
          ext: jsonEncode({
            '主页url': 'https://xbpq.example',
            '线路数组': 'class="tab"&&</div>',
            '线路标题': '<span>&&</span>',
            '播放数组': 'class="playlist"&&</ul>',
            '播放列表': '<a&&/a>',
            '播放标题': '>&&<',
            '播放链接': 'href="&&"',
          }),
        );
        var xbpqBody =
            '<html><body><div class="tab"><span>线路1</span></div><ul class="playlist"><a href="/p/1.m3u8">E1</a></ul></body></html>';
        final xbpqClient = CmsClient(
          client: MockClient(
            (req) async => http.Response(
              xbpqBody,
              200,
              headers: const {'content-type': 'text/html; charset=utf-8'},
            ),
          ),
        );
        const xbpqSeed = CmsVideo(
          id: 'https://xbpq.example/vod/1',
          title: 'XBPQ测试片',
        );
        final xbpqFirst = await xbpqClient.fetchDetail(xbpqSite, xbpqSeed);
        expect(xbpqFirst.lines.single.episodes.length, 1);
        expect(xbpqClient.debugDetailCacheSize, 1);

        // XBPQ receives JSON error object -> throws FormatException, preserves cache!
        xbpqBody = '{"code":500,"msg":"upstream json error"}';
        await expectLater(
          xbpqClient.fetchDetail(xbpqSite, xbpqFirst, forceRefresh: true),
          throwsFormatException,
        );
        expect(xbpqClient.debugDetailCacheSize, 1);
        expect(xbpqClient.debugDetailEmptyCacheSize, 0);
        final xbpqReenter = await xbpqClient.fetchDetail(xbpqSite, xbpqSeed);
        expect(xbpqReenter.lines.single.episodes.length, 1);

        // Legitimate empty HTML clears to 0; recovery restores 2 episodes.
        xbpqBody =
            '<html><body><div class="video-info-content">暂无剧集</div></body></html>';
        final xbpqEmpty = await xbpqClient.fetchDetail(
          xbpqSite,
          xbpqFirst,
          forceRefresh: true,
        );
        expect(xbpqEmpty.lines, isEmpty);
        expect(xbpqClient.debugDetailCacheSize, 0);
        expect(xbpqClient.debugDetailEmptyCacheSize, 1);

        xbpqBody =
            '<html><body><div class="tab"><span>线路1</span></div><ul class="playlist"><a href="/p/1.m3u8">E1</a><a href="/p/2.m3u8">E2</a></ul></body></html>';
        final xbpqRecovered = await xbpqClient.fetchDetail(
          xbpqSite,
          xbpqSeed,
          forceRefresh: true,
        );
        expect(xbpqRecovered.lines.single.episodes.length, 2);
        expect(xbpqClient.debugDetailCacheSize, 1);
        expect(xbpqClient.debugDetailEmptyCacheSize, 0);

        // --- T4 business error lacking valid detail data ---
        const t4Site = CmsSite(
          key: 't4_err_site',
          name: 'T4测试源',
          type: 4,
          api: 'https://t4.example/vod',
        );
        var t4Body = jsonEncode({
          'list': [
            {
              'vod_id': 't4-1',
              'vod_name': 'T4影片',
              'vod_play_from': 'T4线路',
              'vod_play_url': '第01集\$ep1',
            },
          ],
        });
        final t4Client = CmsClient(
          client: MockClient(
            (req) async => http.Response(
              t4Body,
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
        const t4Seed = CmsVideo(id: 't4-1', title: 'T4影片');
        final t4First = await t4Client.fetchDetail(t4Site, t4Seed);
        expect(t4First.lines.single.episodes.length, 1);
        expect(t4Client.debugDetailCacheSize, 1);

        for (final errJson in const [
          '{"code":0,"msg":"upstream temporarily unavailable"}',
          '{"msg":"upstream error"}',
          '{"code":500,"msg":"internal error","list":[]}',
          '{"code":200,"msg":"ok","data":null}',
        ]) {
          t4Body = errJson;
          await expectLater(
            t4Client.fetchDetail(t4Site, t4First, forceRefresh: true),
            throwsFormatException,
            reason: 'T4 error payload $errJson must throw',
          );
          expect(t4Client.debugDetailCacheSize, 1, reason: errJson);
          expect(t4Client.debugDetailEmptyCacheSize, 0, reason: errJson);
        }
        // Re-entry still gets cached 1 episode after T4 business errors.
        expect(
          (await t4Client.fetchDetail(t4Site, t4Seed)).lines.single.episodes.length,
          1,
        );

        // Legitimate empty list for T4 (and alternate success codes 200 / 0+ok / valid empty XML).
        t4Body = jsonEncode({'list': []});
        final t4Empty = await t4Client.fetchDetail(
          t4Site,
          t4First,
          forceRefresh: true,
        );
        expect(t4Empty.lines, isEmpty);
        expect(t4Client.debugDetailCacheSize, 0);
        expect(t4Client.debugDetailEmptyCacheSize, 1);

        // Recovery on T4 restores 2 episodes.
        t4Body = jsonEncode({
          'list': [
            {
              'vod_id': 't4-1',
              'vod_name': 'T4影片',
              'vod_play_from': 'T4线路',
              'vod_play_url': '第01集\$ep1#第02集\$ep2',
            },
          ],
        });
        final t4Recovered = await t4Client.fetchDetail(
          t4Site,
          t4Seed,
          forceRefresh: true,
        );
        expect(t4Recovered.lines.single.episodes.length, 2);
        expect(t4Client.debugDetailCacheSize, 1);
        expect(t4Client.debugDetailEmptyCacheSize, 0);

        // Alternate valid protocol empty envelopes must succeed with 0 lines.
        for (final validEmpty in const [
          '{"code":200,"msg":"ok","list":[]}',
          '{"code":0,"msg":"ok","list":[]}',
          '{"list":[]}',
          '<rss version="5.1"><list page="1" pagecount="0"></list></rss>',
        ]) {
          final altClient = CmsClient(
            client: MockClient((_) async => http.Response(validEmpty, 200)),
          );
          final res = await altClient.fetchDetail(
            httpSite,
            const CmsVideo(id: 'alt-empty', title: '空测试'),
            forceRefresh: true,
          );
          expect(res.lines, isEmpty, reason: validEmpty);
          expect(altClient.debugDetailEmptyCacheSize, 1, reason: validEmpty);
        }
      },
    );

    testWidgets(
      'Round3 Item 1-1: MacCMS vod_play_list with positional sid (1,2) and stable from keeps manually selected line B across B/A reorder and plays B URL',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var swapped = false;

        http.Response buildMacCmsPlayListResp() {
          final first = swapped
              ? {
                  'sid': 1,
                  'from': 'line_b_from',
                  'player_info': {'from': 'line_b_from', 'show': '线路B'},
                  'urls': {
                    '1': {
                      'name': '第01集',
                      'url': 'https://media.example/maccms-b-v2.mp4',
                    },
                  },
                }
              : {
                  'sid': 1,
                  'from': 'line_a_from',
                  'player_info': {'from': 'line_a_from', 'show': '线路A'},
                  'urls': {
                    '1': {
                      'name': '第01集',
                      'url': 'https://media.example/maccms-a-v1.mp4',
                    },
                  },
                };
          final second = swapped
              ? {
                  'sid': 2,
                  'from': 'line_a_from',
                  'player_info': {'from': 'line_a_from', 'show': '线路A'},
                  'urls': {
                    '1': {
                      'name': '第01集',
                      'url': 'https://media.example/maccms-a-v2.mp4',
                    },
                  },
                }
              : {
                  'sid': 2,
                  'from': 'line_b_from',
                  'player_info': {'from': 'line_b_from', 'show': '线路B'},
                  'urls': {
                    '1': {
                      'name': '第01集',
                      'url': 'https://media.example/maccms-b-v1.mp4',
                    },
                  },
                };
          return http.Response(
            jsonEncode({
              'code': 1,
              'list': [
                {
                  'vod_id': 'vid-maccms-sid',
                  'vod_name': 'MacCMS位置sid测试剧',
                  'vod_play_list': {'1': first, '2': second},
                },
              ],
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }

        final cmsClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['ac'] == 'detail' &&
                request.url.queryParameters['ids'] == 'vid-maccms-sid') {
              return buildMacCmsPlayListResp();
            }
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }),
        );
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo: const CmsVideo(
                id: 'vid-maccms-sid',
                title: 'MacCMS位置sid测试剧',
              ),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Manually select line B (initially sid=2, from=line_b_from).
        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路B').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('detail-primary-play-button')));
        await tester.pumpAndSettle();
        expect(playedUrls.last, 'https://media.example/maccms-b-v1.mp4');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // Upstream reorders to [B (sid=1), A (sid=2)] and rotates URLs.
        swapped = true;
        await performPullRefresh(tester);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('detail-primary-play-button')));
        await tester.pumpAndSettle();
        expect(playedUrls.last, 'https://media.example/maccms-b-v2.mp4');
        expect(playedUrls.last, isNot(contains('maccms-a')));
      },
    );

    testWidgets(
      'Round3 Item 1-2: swapping two Quark shares under the same netdisk line preserves manual selection of Share B and plays Share B file',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        final quarkSessionCred = QuarkAccountSession(
          cookie: '__pus=fixture-identity; __puus=fixture-cookie',
          driveSt: 'fixture-drive-ticket',
          accountId: sha256.convert(utf8.encode('fixture-identity')).toString(),
          validatedAt: DateTime.now(),
        ).toCredential();
        await storage.setNetdiskCred('quark', quarkSessionCred);
        var sharesSwapped = false;

        final cmsClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.host == 'cms.example' &&
                request.url.queryParameters['ac'] == 'detail' &&
                request.url.queryParameters['ids'] == 'vid-quark-swap') {
              final playUrl = sharesSwapped
                  ? '分享B\$https://pan.quark.cn/s/shareB123#分享A\$https://pan.quark.cn/s/shareA123'
                  : '分享A\$https://pan.quark.cn/s/shareA123#分享B\$https://pan.quark.cn/s/shareB123';
              return http.Response(
                jsonEncode({
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 'vid-quark-swap',
                      'vod_name': '双夸克分享交换测试',
                      'vod_play_from': 'quark',
                      'vod_play_url': playUrl,
                    },
                  ],
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            if (request.url.host == 'drive-pc.quark.cn') {
              if (request.url.path.endsWith('/token')) {
                final body = jsonDecode(request.body) as Map<String, dynamic>;
                final pwdId = (body['pwd_id'] ?? '').toString();
                return http.Response(
                  jsonEncode({
                    'status': 200,
                    'code': 0,
                    'data': {'stoken': 'stoken-$pwdId'},
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              if (request.url.path.endsWith('/detail')) {
                final pwdId = request.url.queryParameters['pwd_id'] ?? '';
                final isB = pwdId == 'shareB123';
                return http.Response(
                  jsonEncode({
                    'status': 200,
                    'code': 0,
                    'metadata': {'_total': 1},
                    'data': {
                      'share': {'status': 1, 'audit_status': 4},
                      'list': [
                        {
                          'fid': isB ? 'fid_from_share_B' : 'fid_from_share_A',
                          'file_name': isB
                              ? 'Movie.FromShareB.2160p.mkv'
                              : 'Movie.FromShareA.2160p.mkv',
                          'file_type': 1,
                          'category': 1,
                          'share_fid_token': isB ? 'tok_B' : 'tok_A',
                        },
                      ],
                    },
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
            }
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }),
        );
        final playedUrls = <String>[];

        Future<void> settleQuarkAsync() async {
          for (var i = 0; i < 12; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump();
          }
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo: const CmsVideo(
                id: 'vid-quark-swap',
                title: '双夸克分享交换测试',
              ),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await settleQuarkAsync();

        // Manually pick the 2nd Quark sub-line (`quark 2`, backed by shareB123).
        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('quark 2').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('detail-primary-play-button')));
        await tester.pumpAndSettle();
        expect(playedUrls.last, contains('fid_from_share_B'));
        expect(playedUrls.last, contains('shareB123'));
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();

        // Swap the two shares upstream (`[shareB123, shareA123]`) and pull to refresh.
        sharesSwapped = true;
        await performPullRefresh(tester);
        await settleQuarkAsync();

        // Playback must STILL resolve to Share B's file (never Share A's)!
        await tester.tap(find.byKey(const Key('detail-primary-play-button')));
        await tester.pumpAndSettle();
        expect(playedUrls, [
          'mmwogg://quark?v=1&pwd_id=shareB123&fid=fid_from_share_B&pdir_fid=0',
          'mmwogg://quark?v=1&pwd_id=shareB123&fid=fid_from_share_B&pdir_fid=0',
        ]);
        expect(playedUrls.last, isNot(contains('fid_from_share_A')));
      },
    );

    testWidgets(
      'Round3 Item 1-3: duplicate-name lines sharing Ep1 URL but differing on Ep2 block playback with 0 player calls when line A is deleted, and play A Ep2 when A remains',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        Completer<http.Response>? holdNext;
        const lineA = (
          '同名线路',
          [
            ('第01集', 'https://media.example/shared-ep1.mp4'),
            ('第02集', 'https://media.example/lineA-ep2.mp4'),
          ],
        );
        const lineB = (
          '同名线路',
          [
            ('第01集', 'https://media.example/shared-ep1.mp4'),
            ('第02集', 'https://media.example/lineB-ep2.mp4'),
          ],
        );

        final cmsClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['ac'] == 'detail' &&
                request.url.queryParameters['ids'] == 'vid-shared-ep1') {
              if (holdNext != null) {
                final c = holdNext!;
                holdNext = null;
                return c.future;
              }
              return buildVodResponse(
                id: 'vid-shared-ep1',
                title: '首集同址测试剧',
                lines: const [lineA, lineB],
              );
            }
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }),
        );
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo:
                  const CmsVideo(id: 'vid-shared-ep1', title: '首集同址测试剧'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Negative case first: open A's all-episodes sheet, refresh deletes A leaving ONLY B
        // (which still shares /shared-ep1.mp4!). Tapping old Ep2 must NOT call player at all!
        final pendingDeleteA = Completer<http.Response>();
        holdNext = pendingDeleteA;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingDeleteA.complete(
          buildVodResponse(
            id: 'vid-shared-ep1',
            title: '首集同址测试剧',
            lines: const [lineB],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(playedUrls, isEmpty);
        expect(find.textContaining('请重新选择'), findsOneWidget);

        // Positive case: restore [A, B], select A, open A's all-episodes sheet,
        // refresh reverses order to [B, A] while keeping A's distinguishing Ep2 URL ->
        // tapping Ep2 uniquely confirms A and plays lineA-ep2.mp4!
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(ListView).last,
                matching: find.text('同名线路'),
              )
              .first,
        );
        await tester.pumpAndSettle();

        final pendingReverseKeepA = Completer<http.Response>();
        holdNext = pendingReverseKeepA;
        await performPullRefresh(tester);

        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingReverseKeepA.complete(
          buildVodResponse(
            id: 'vid-shared-ep1',
            title: '首集同址测试剧',
            lines: const [lineB, lineA],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('第 2 集').last);
        await tester.pumpAndSettle();
        expect(playedUrls, ['https://media.example/lineA-ep2.mp4']);
      },
    );

    test(
      'Round3 Item 2: playableDetail accepts valid CMS shapes (error:0, code:0+custom success msg, list:null+data.list, data.list:null+inline vod) while rejecting explicit failures',
      () async {
        final validCases = <({
          String label,
          String id,
          String expectedUrl,
          Map<String, dynamic> payload,
        })>[
          (
            label: 'code=1 with numeric error=0',
            id: 'compat-1',
            expectedUrl: 'https://media.example/compat-e1.mp4',
            payload: {
              'code': 1,
              'error': 0,
              'list': [
                {
                  'vod_id': 'compat-1',
                  'vod_name': '兼容影片1',
                  'vod_play_from': '主线',
                  'vod_play_url': '第01集\$https://media.example/compat-e1.mp4',
                },
              ],
            },
          ),
          (
            label: 'code=0 with msg=获取详情成功',
            id: 'compat-2',
            expectedUrl: 'https://media.example/compat-e2.mp4',
            payload: {
              'code': 0,
              'msg': '获取详情成功',
              'list': [
                {
                  'vod_id': 'compat-2',
                  'vod_name': '兼容影片2',
                  'vod_play_from': '主线',
                  'vod_play_url': '第01集\$https://media.example/compat-e2.mp4',
                },
              ],
            },
          ),
          (
            label: 'top-level list=null with data.list containing E1',
            id: 'compat-3',
            expectedUrl: 'https://media.example/compat-e3.mp4',
            payload: {
              'code': 1,
              'list': null,
              'data': {
                'list': [
                  {
                    'vod_id': 'compat-3',
                    'vod_name': '兼容影片3',
                    'vod_play_from': '主线',
                    'vod_play_url':
                        '第01集\$https://media.example/compat-e3.mp4',
                  },
                ],
              },
            },
          ),
          (
            label: 'data.list=null with inline vod_id/vod_name/vod_play_url',
            id: 'compat-4',
            expectedUrl: 'https://media.example/compat-e4.mp4',
            payload: {
              'code': 1,
              'data': {
                'list': null,
                'vod_id': 'compat-4',
                'vod_name': '兼容影片4',
                'vod_play_from': '主线',
                'vod_play_url': '第01集\$https://media.example/compat-e4.mp4',
              },
            },
          ),
        ];

        for (final c in validCases) {
          final client = CmsClient(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode(c.payload),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              ),
            ),
          );
          final (_, video) = await client.playableDetail(
            httpSite,
            CmsVideo(id: c.id, title: '初始标题'),
            const [httpSite],
          );
          expect(
            video.lines.single.episodes.single.url,
            c.expectedUrl,
            reason: c.label,
          );
          expect(
            client.hasAuthoritativeEmptyDetail(
              httpSite,
              CmsVideo(id: c.id, title: '初始标题'),
            ),
            isFalse,
            reason: c.label,
          );
        }

        // Explicit business failure counterexamples must STILL throw and never
        // clear an existing cached episode or mark the video as delisted.
        final failurePayloads = <({String label, Map<String, dynamic> payload})>[
          (
            label: 'code=0 upstream unavailable with empty list',
            payload: {
              'code': 0,
              'msg': 'upstream temporarily unavailable',
              'list': [],
            },
          ),
          (
            label: 'code=1 non-zero error=1',
            payload: {'code': 1, 'error': 1, 'list': []},
          ),
          (
            label: 'code=1 string error',
            payload: {'code': 1, 'error': 'backend failed', 'list': []},
          ),
          (
            label: 'code=500 server error',
            payload: {'code': 500, 'msg': 'internal error', 'list': []},
          ),
          (
            label: 'list=null and data=null',
            payload: {'code': 1, 'list': null, 'data': null},
          ),
        ];

        for (final failCase in failurePayloads) {
          var returnError = false;
          final client = CmsClient(
            client: MockClient((_) async {
              if (returnError) {
                return http.Response(
                  jsonEncode(failCase.payload),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              return buildVodResponse(
                id: 'vid-neg',
                title: '反例影片',
                lines: const [
                  ('主线', [('第01集', 'https://media.example/keep-e1.mp4')]),
                ],
              );
            }),
          );
          const seed = CmsVideo(id: 'vid-neg', title: '反例影片');
          final (_, initial) =
              await client.playableDetail(httpSite, seed, const [httpSite]);
          expect(initial.lines.single.episodes.single.url,
              'https://media.example/keep-e1.mp4');

          returnError = true;
          await expectLater(
            client.playableDetail(
              httpSite,
              initial,
              const [httpSite],
              forceRefresh: true,
            ),
            throwsFormatException,
            reason: failCase.label,
          );
          expect(client.debugDetailCacheSize, 1, reason: failCase.label);
          expect(
            client.hasAuthoritativeEmptyDetail(httpSite, seed),
            isFalse,
            reason: failCase.label,
          );
          final (_, cachedAfterErr) =
              await client.playableDetail(httpSite, seed, const [httpSite]);
          expect(
            cachedAfterErr.lines.single.episodes.single.url,
            'https://media.example/keep-e1.mp4',
            reason: '${failCase.label} must preserve cached E1',
          );
        }
      },
    );

    test(
      'Round3 Item 3-1: Quark token HTTP 503 during share refresh preserves cached E1 without marking authoritative empty and recovers when Quark returns 200',
      () async {
        var quarkTokenStatus = 200;
        var recoveredWithTwoEps = false;

        final client = CmsClient(
          client: MockClient((request) async {
            if (request.url.host == 'cms.example' &&
                request.url.queryParameters['ac'] == 'detail' &&
                request.url.queryParameters['ids'] == 'vid-qk-503') {
              return http.Response(
                jsonEncode({
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 'vid-qk-503',
                      'vod_name': '夸克503恢复测试',
                      'vod_play_from': '夸克网盘',
                      'vod_play_url':
                          '正片\$https://pan.quark.cn/s/qk503share',
                    },
                  ],
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            if (request.url.host == 'drive-pc.quark.cn') {
              if (request.url.path.endsWith('/token')) {
                if (quarkTokenStatus != 200) {
                  return http.Response(
                    'Service Temporarily Unavailable',
                    quarkTokenStatus,
                  );
                }
                return http.Response(
                  jsonEncode({
                    'status': 200,
                    'code': 0,
                    'data': {'stoken': 'stoken-ok'},
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              if (request.url.path.endsWith('/detail')) {
                return http.Response(
                  jsonEncode({
                    'status': 200,
                    'code': 0,
                    'metadata': {'_total': recoveredWithTwoEps ? 2 : 1},
                    'data': {
                      'share': {'status': 1, 'audit_status': 4},
                      'list': [
                        {
                          'fid': 'qk_ep1',
                          'file_name': 'Show.E01.2160p.mkv',
                          'file_type': 1,
                          'category': 1,
                          'share_fid_token': 't1',
                        },
                        if (recoveredWithTwoEps)
                          {
                            'fid': 'qk_ep2',
                            'file_name': 'Show.E02.2160p.mkv',
                            'file_type': 1,
                            'category': 1,
                            'share_fid_token': 't2',
                          },
                      ],
                    },
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
            }
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }),
        );

        const seed = CmsVideo(id: 'vid-qk-503', title: '夸克503恢复测试');

        // 1) Initial load succeeds and caches E1.
        final (_, initial) =
            await client.playableDetail(httpSite, seed, const [httpSite]);
        expect(initial.lines.single.episodes, hasLength(1));
        expect(initial.lines.single.episodes.single.url, contains('qk_ep1'));
        expect(client.debugDetailCacheSize, 1);
        expect(client.hasAuthoritativeEmptyDetail(httpSite, seed), isFalse);

        // 2) Refresh hits Quark token HTTP 503 -> throws, preserves cached E1,
        //    and does NOT mark authoritative empty.
        quarkTokenStatus = 503;
        await expectLater(
          client.playableDetail(
            httpSite,
            initial,
            const [httpSite],
            forceRefresh: true,
          ),
          throwsFormatException,
        );
        expect(client.debugDetailCacheSize, 1);
        expect(client.hasAuthoritativeEmptyDetail(httpSite, seed), isFalse);

        // Ordinary re-entry still gets cached E1.
        final (_, preserved) =
            await client.playableDetail(httpSite, seed, const [httpSite]);
        expect(preserved.lines.single.episodes, hasLength(1));
        expect(preserved.lines.single.episodes.single.url, contains('qk_ep1'));

        // 3) Quark token API recovers (HTTP 200) -> retry fetches fresh 2 episodes.
        quarkTokenStatus = 200;
        recoveredWithTwoEps = true;
        final (_, recovered) = await client.playableDetail(
          httpSite,
          preserved,
          const [httpSite],
          forceRefresh: true,
        );
        expect(recovered.lines.single.episodes, hasLength(2));
        expect(recovered.lines.single.episodes[1].url, contains('qk_ep2'));
        expect(client.debugDetailCacheSize, 1);
        expect(client.hasAuthoritativeEmptyDetail(httpSite, seed), isFalse);
      },
    );

    testWidgets(
      'Round3 Item 3-2: misnested XML <rss><list></rss></list> keeps cached E1 without authoritative empty flag while valid empty <rss><list/></rss> clears episodes and prevents E1 resurrection on re-entry',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        const xmlSite = CmsSite(
          key: 'xml_site',
          name: 'XML测试源',
          type: 0,
          api: 'https://xml.example/api.php/provide/vod/at/xml/',
        );
        const validWithEp1Xml =
            '<rss version="5.1"><list page="1" pagecount="1"><video><id>xml-101</id><name><![CDATA[XML测试剧]]></name><dl><dd flag="xmlA"><![CDATA[第01集\$https://media.example/xml-e1.mp4]]></dd></dl></video></list></rss>';
        var currentXml = validWithEp1Xml;
        var xmlReqs = 0;

        final client = CmsClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['ids'] == 'xml-101') {
              xmlReqs++;
              return http.Response(
                currentXml,
                200,
                headers: const {'content-type': 'application/xml; charset=utf-8'},
              );
            }
            return http.Response('<rss><list/></rss>', 200);
          }),
        );

        const cardWithOldEp1 = CmsVideo(
          id: 'xml-101',
          title: 'XML测试剧',
          lines: [
            CmsLine(
              name: 'xmlA',
              episodes: [
                CmsEpisode(
                  name: '第01集',
                  url: 'https://media.example/xml-e1.mp4',
                ),
              ],
            ),
          ],
        );
        const seedNoLines = CmsVideo(id: 'xml-101', title: 'XML测试剧');

        Widget buildXmlDetail(CmsVideo initialVideo) => MaterialApp(
              home: DetailScreen(
                site: xmlSite,
                initialVideo: initialVideo,
                client: client,
                storage: storage,
              ),
            );

        // 1) First open fetches valid E1.
        await tester.pumpWidget(buildXmlDetail(seedNoLines));
        await tester.pumpAndSettle();
        expect(xmlReqs, 1);
        expect(find.text('1'), findsOneWidget);
        expect(client.debugDetailCacheSize, 1);
        expect(client.hasAuthoritativeEmptyDetail(xmlSite, seedNoLines), isFalse);

        // 2) Refresh receives misnested XML `<rss><list></rss></list>`:
        //    must retain E1, keep playable cache, and NOT mark authoritative empty!
        currentXml = '<rss><list></rss></list>';
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(xmlReqs, 2);
        expect(find.text('1'), findsOneWidget);
        expect(client.debugDetailCacheSize, 1);
        expect(client.hasAuthoritativeEmptyDetail(xmlSite, seedNoLines), isFalse);

        // Exit & re-enter still hits preserved cached E1 (0 extra reqs).
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildXmlDetail(seedNoLines));
        await tester.pumpAndSettle();
        expect(xmlReqs, 2);
        expect(find.text('1'), findsOneWidget);

        // 3) Contrast: upstream returns valid empty XML `<rss><list/></rss>`:
        //    must clear E1, evict cache, and set hasAuthoritativeEmptyDetail == true!
        currentXml = '<rss><list/></rss>';
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        expect(xmlReqs, 3);
        expect(find.text('1'), findsNothing);
        expect(client.debugDetailCacheSize, 0);
        expect(client.hasAuthoritativeEmptyDetail(xmlSite, seedNoLines), isTrue);

        // Exit & re-enter from a card carrying stale E1 must re-verify upstream
        // and STILL show 0 episodes (E1 never resurrects)!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(buildXmlDetail(cardWithOldEp1));
        await tester.pumpAndSettle();
        expect(xmlReqs, 4);
        expect(find.text('1'), findsNothing);
        expect(client.debugDetailCacheSize, 0);
        expect(client.hasAuthoritativeEmptyDetail(xmlSite, cardWithOldEp1), isTrue);
      },
    );

    testWidgets(
      'Round4 Item 1: deleting second duplicate-name episode within the same line blocks playback with 0 player calls while keeping both plays the second URL',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        Completer<http.Response>? holdNext;
        final cmsClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['ac'] == 'detail' &&
                request.url.queryParameters['ids'] == 'vid-dup-ep') {
              if (holdNext != null) {
                final c = holdNext!;
                holdNext = null;
                return c.future;
              }
              return buildVodResponse(
                id: 'vid-dup-ep',
                title: '同线同名剧集测试',
                lines: const [
                  (
                    '单一线路',
                    [
                      ('第01集', 'https://media.example/first.mp4'),
                      ('第01集', 'https://media.example/second.mp4'),
                    ],
                  ),
                ],
              );
            }
            return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
          }),
        );
        final playedUrls = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo:
                  const CmsVideo(id: 'vid-dup-ep', title: '同线同名剧集测试'),
              client: cmsClient,
              storage: storage,
              debugPlayerBuilder: (ctx, s, v, lineIdx, epIdx, resumeMs) {
                final url = v.lines[lineIdx].episodes[epIdx].url;
                playedUrls.add(url);
                return Scaffold(body: Center(child: Text('PLAY:$url')));
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Case A: deleting the 2nd duplicate-name episode while sheet is open
        // must block playback (0 player calls) and never fall back to first.mp4.
        final pendingDeleteSecond = Completer<http.Response>();
        holdNext = pendingDeleteSecond;
        await performPullRefresh(tester);
        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        pendingDeleteSecond.complete(
          buildVodResponse(
            id: 'vid-dup-ep',
            title: '同线同名剧集测试',
            lines: const [
              (
                '单一线路',
                [('第01集', 'https://media.example/first.mp4')],
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final sheetEp1Labels = find.descendant(
          of: find.byType(GridView).last,
          matching: find.text('第 1 集'),
        );
        expect(sheetEp1Labels, findsNWidgets(2));
        await tester.tap(sheetEp1Labels.at(1));
        await tester.pumpAndSettle();
        expect(playedUrls, isEmpty);
        expect(find.textContaining('请重新选择'), findsOneWidget);

        // Case B: restoring both entries and tapping the 2nd entry plays second.mp4.
        await performPullRefresh(tester);
        await tester.pumpAndSettle();
        final pendingKeepBoth = Completer<http.Response>();
        holdNext = pendingKeepBoth;
        await performPullRefresh(tester);
        await tester.tap(find.text('全部剧集 (2)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        pendingKeepBoth.complete(
          buildVodResponse(
            id: 'vid-dup-ep',
            title: '同线同名剧集测试',
            lines: const [
              (
                '单一线路',
                [
                  ('第01集', 'https://media.example/first.mp4'),
                  ('第01集', 'https://media.example/second.mp4'),
                ],
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(sheetEp1Labels.at(1));
        await tester.pumpAndSettle();
        expect(playedUrls, ['https://media.example/second.mp4']);
      },
    );

    test(
      'Round4 Items 2 & 3: XML comments are ignored in detail parsing, code=0 login prompt preserves E1, and code=0 No error with E1 succeeds',
      () async {
        // Item 2: XML comments
        String xmlRow(String url) =>
            '<video><id>xml-c1</id><name>注释测试</name><dl><dd flag="main"><![CDATA[E1\$$url]]></dd></dl></video>';
        var payload = '<rss><list>${xmlRow('https://media.example/old.mp4')}</list></rss>';
        final xmlClient = CmsClient(
          client: MockClient(
            (_) async => http.Response(
              payload,
              200,
              headers: const {'content-type': 'application/xml; charset=utf-8'},
            ),
          ),
        );
        const xmlSeed = CmsVideo(id: 'xml-c1', title: '注释测试');
        final (_, xmlInit) =
            await xmlClient.playableDetail(httpSite, xmlSeed, const [httpSite]);
        expect(xmlInit.lines.single.episodes.single.url,
            'https://media.example/old.mp4');

        // Only commented video -> clears cache and marks authoritative empty.
        payload =
            '<rss><list><!--${xmlRow('https://media.example/old.mp4')}--></list></rss>';
        final (_, xmlCleared) = await xmlClient.playableDetail(
          httpSite,
          xmlInit,
          const [httpSite],
          forceRefresh: true,
        );
        expect(xmlCleared.lines, isEmpty);
        expect(xmlClient.debugDetailCacheSize, 0);
        expect(xmlClient.hasAuthoritativeEmptyDetail(httpSite, xmlSeed), isTrue);

        // Commented old video followed by new video -> returns new.mp4 on refresh & re-entry.
        payload =
            '<rss><list><!--${xmlRow('https://media.example/old.mp4')}-->${xmlRow('https://media.example/new.mp4')}</list></rss>';
        final (_, xmlNew) = await xmlClient.playableDetail(
          httpSite,
          xmlInit,
          const [httpSite],
          forceRefresh: true,
        );
        expect(xmlNew.lines.single.episodes.single.url,
            'https://media.example/new.mp4');
        expect(xmlClient.hasAuthoritativeEmptyDetail(httpSite, xmlSeed), isFalse);
        final (_, xmlReentered) =
            await xmlClient.playableDetail(httpSite, xmlSeed, const [httpSite]);
        expect(xmlReentered.lines.single.episodes.single.url,
            'https://media.example/new.mp4');

        // Item 3A: code=0 login prompt preserves E1 & allows retry recovery.
        var jsonPayload = jsonEncode({
          'code': 1,
          'list': [
            {
              'vod_id': 'cms-login-1',
              'vod_name': '登录提示测试',
              'vod_play_from': 'main',
              'vod_play_url': r'E1$https://media.example/e1.mp4',
            },
          ],
        });
        final jsonClient = CmsClient(
          client: MockClient(
            (_) async => http.Response(
              jsonPayload,
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
        const jsonSeed = CmsVideo(id: 'cms-login-1', title: '登录提示测试');
        final (_, jsonInit) = await jsonClient.playableDetail(
            httpSite, jsonSeed, const [httpSite]);
        expect(jsonInit.lines.single.episodes.single.url,
            'https://media.example/e1.mp4');

        for (final ambiguousPayload in [
          {'code': 0, 'msg': '请先登录', 'list': <Object>[]},
          {
            'code': 0,
            'msg': '请先登录',
            'list': [
              {
                'vod_id': 'cms-login-1',
                'vod_name': '登录提示测试',
                'vod_play_from': '',
                'vod_play_url': '',
              },
            ],
          },
          {'code': 0, 'msg': '需要绑定会员账号', 'list': <Object>[]},
        ]) {
          jsonPayload = jsonEncode(ambiguousPayload);
          await expectLater(
            jsonClient.playableDetail(
              httpSite,
              jsonInit,
              const [httpSite],
              forceRefresh: true,
            ),
            throwsFormatException,
          );
          expect(jsonClient.debugDetailCacheSize, 1);
          expect(jsonClient.hasAuthoritativeEmptyDetail(httpSite, jsonSeed),
              isFalse);
          final (_, kept) = await jsonClient.playableDetail(
              httpSite, jsonSeed, const [httpSite]);
          expect(kept.lines.single.episodes.single.url,
              'https://media.example/e1.mp4');
        }

        // Item 3B: code=0 with msg="No error" and valid E1 succeeds on first open.
        final noErrClient = CmsClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'code': 0,
                'msg': 'No error',
                'list': [
                  {
                    'vod_id': 'cms-no-err',
                    'vod_name': 'NoError测试',
                    'vod_play_from': 'main',
                    'vod_play_url': r'E1$https://media.example/no-err-e1.mp4',
                  },
                ],
              }),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
        const noErrSeed = CmsVideo(id: 'cms-no-err', title: 'NoError测试');
        final (_, noErrVideo) = await noErrClient.playableDetail(
            httpSite, noErrSeed, const [httpSite]);
        expect(noErrVideo.lines.single.episodes.single.url,
            'https://media.example/no-err-e1.mp4');
        expect(
            noErrClient.hasAuthoritativeEmptyDetail(httpSite, noErrSeed), isFalse);
      },
    );

    test(
      'Round4 Item 4: Quark partial 503 preserves per-share E1 alongside updated trailer and retries on re-entry; incomplete listing keeps E1; withdrawn/empty share clears E1 while keeping healthy lines',
      () async {
        var mode = 'ready';
        var trailerRev = 1;
        var tokenCalls = 0;

        CmsClient makeClient({required bool includeTrailer}) => CmsClient(
              client: MockClient((request) async {
                if (request.url.host == 'cms.example') {
                  const cloud = r'正片$https://pan.quark.cn/s/r4share';
                  final trailer = '预告\$https://cdn.example/t-$trailerRev.mp4';
                  return http.Response(
                    jsonEncode({
                      'code': 1,
                      'list': [
                        {
                          'vod_id': 'r4-qk',
                          'vod_name': '夸克分层缓存测试',
                          'vod_play_from': includeTrailer ? r'预告$$$夸克' : '夸克',
                          'vod_play_url':
                              includeTrailer ? '$trailer\$\$\$$cloud' : cloud,
                        },
                      ],
                    }),
                    200,
                    headers: const {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  );
                }
                if (request.url.host == 'drive-pc.quark.cn') {
                  if (request.url.path.endsWith('/token')) {
                    tokenCalls++;
                    if (mode == '503') {
                      return http.Response('Service unavailable', 503);
                    }
                    return http.Response(
                      jsonEncode({
                        'status': 200,
                        'code': 0,
                        'data': {'stoken': 'tok'},
                      }),
                      200,
                      headers: const {
                        'content-type': 'application/json; charset=utf-8',
                      },
                    );
                  }
                  final count = mode == 'recovered'
                      ? 2
                      : mode == 'ready'
                          ? 1
                          : 0;
                  return http.Response(
                    jsonEncode({
                      'status': 200,
                      'code': 0,
                      'metadata': {'_total': mode == 'incomplete' ? 1 : count},
                      'data': {
                        'share': {'status': mode == 'withdrawn' ? 0 : 1},
                        'list': [
                          for (var i = 1; i <= count; i++)
                            {
                              'fid': 'e$i',
                              'file_name': 'Show.E$i.mkv',
                              'file_type': 1,
                              'category': 1,
                              'share_fid_token': 'ref$i',
                            },
                        ],
                      },
                    }),
                    200,
                    headers: const {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  );
                }
                return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
              }),
            );

        List<String> fidsOf(CmsVideo v) => [
              for (final l in v.lines)
                for (final e in l.episodes)
                  if (Uri.parse(e.url).queryParameters['fid'] case final String f)
                    f,
            ];
        List<String> urlsOf(CmsVideo v) => [
              for (final l in v.lines)
                for (final e in l.episodes) e.url,
            ];

        const seed = CmsVideo(id: 'r4-qk', title: '夸克分层缓存测试');

        // 4①: Healthy trailer updates + Quark 503 preserves E1 + ordinary re-entry retries & finds E2.
        mode = 'ready';
        trailerRev = 1;
        tokenCalls = 0;
        final mixedClient = makeClient(includeTrailer: true);
        final (_, mixedInit) =
            await mixedClient.playableDetail(httpSite, seed, const [httpSite]);
        expect(fidsOf(mixedInit), ['e1']);

        mode = '503';
        trailerRev = 2;
        final (_, partial) = await mixedClient.playableDetail(
          httpSite,
          mixedInit,
          const [httpSite],
          forceRefresh: true,
        );
        expect(urlsOf(partial), contains('https://cdn.example/t-2.mp4'));
        expect(fidsOf(partial), ['e1']);
        expect(mixedClient.hasAuthoritativeEmptyDetail(httpSite, seed), isFalse);

        final callsBeforeReopen = tokenCalls;
        mode = 'recovered';
        final (_, reopened) =
            await mixedClient.playableDetail(httpSite, seed, const [httpSite]);
        expect(tokenCalls, greaterThan(callsBeforeReopen));
        expect(fidsOf(reopened), containsAll(['e1', 'e2']));

        // Mixed trailer + confirmed withdrawn share -> clears Quark E1, keeps healthy trailer.
        mode = 'withdrawn';
        trailerRev = 3;
        final (_, afterWithdrawnMixed) = await mixedClient.playableDetail(
          httpSite,
          reopened,
          const [httpSite],
          forceRefresh: true,
        );
        expect(urlsOf(afterWithdrawnMixed), ['https://cdn.example/t-3.mp4']);
        expect(fidsOf(afterWithdrawnMixed), isEmpty);

        // 4②: Quark-only incomplete listing (_total=1, list=[]) keeps E1 and allows retry.
        mode = 'ready';
        final incClient = makeClient(includeTrailer: false);
        final (_, incInit) =
            await incClient.playableDetail(httpSite, seed, const [httpSite]);
        expect(fidsOf(incInit), ['e1']);

        mode = 'incomplete';
        await expectLater(
          incClient.playableDetail(
            httpSite,
            incInit,
            const [httpSite],
            forceRefresh: true,
          ),
          throwsFormatException,
        );
        expect(incClient.hasAuthoritativeEmptyDetail(httpSite, seed), isFalse);
        final (_, stillKept) =
            await incClient.playableDetail(httpSite, seed, const [httpSite]);
        expect(fidsOf(stillKept), ['e1']);

        mode = 'recovered';
        final (_, incRecovered) = await incClient.playableDetail(
          httpSite,
          stillKept,
          const [httpSite],
          forceRefresh: true,
        );
        expect(fidsOf(incRecovered), containsAll(['e1', 'e2']));

        // 4③: Confirmed withdrawn share AND valid empty share both clear E1 & prevent stale card resurrection.
        for (final emptyMode in const ['withdrawn', 'empty']) {
          mode = 'ready';
          final client = makeClient(includeTrailer: false);
          final (_, warm) =
              await client.playableDetail(httpSite, seed, const [httpSite]);
          expect(fidsOf(warm), ['e1']);

          mode = emptyMode;
          final (_, refreshed) = await client.playableDetail(
            httpSite,
            warm,
            const [httpSite],
            forceRefresh: true,
          );
          expect(fidsOf(refreshed), isEmpty, reason: emptyMode);
          expect(client.debugDetailCacheSize, 0, reason: emptyMode);
          expect(client.hasAuthoritativeEmptyDetail(httpSite, seed), isTrue,
              reason: emptyMode);

          final (_, fromStaleCard) =
              await client.playableDetail(httpSite, warm, const [httpSite]);
          expect(fidsOf(fromStaleCard), isEmpty, reason: emptyMode);
          final (_, fromBareCard) =
              await client.playableDetail(httpSite, seed, const [httpSite]);
          expect(fidsOf(fromBareCard), isEmpty, reason: emptyMode);
        }
      },
    );

    test(
      'Round5 Items 1-3: withdrawn share A + transient 503 share B keeps only B; missing Quark stoken keeps E1 without delisting; XML trailing error text retains E1 while comments outside root still clear',
      () async {
        // Item 1: Share A withdrawn + Share B HTTP 503 -> drops A, preserves B, B recovers E2 without A reappearing.
        const shareA = 'r5alpha';
        const shareB = 'r5bravo';
        final states = <String, String>{shareA: 'ok', shareB: 'ok'};
        final dualClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.host == 'cms.example') {
              return http.Response(
                jsonEncode({
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 'r5-dual',
                      'vod_name': '双分享状态测试',
                      'vod_play_from': '线路A\$\$\$线路B',
                      'vod_play_url':
                          '正片\$https://pan.quark.cn/s/$shareA\$\$\$正片\$https://pan.quark.cn/s/$shareB',
                    },
                  ],
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            if (request.url.path.endsWith('/token')) {
              final pwdId = (jsonDecode(request.body) as Map)['pwd_id'] as String;
              final st = states[pwdId];
              if (st == '503') {
                return http.Response('Service Unavailable', 503);
              }
              return http.Response(
                jsonEncode({
                  'status': 200,
                  'code': 0,
                  'data': {if (st != 'no_token') 'stoken': 'tok-$pwdId'},
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            final pwdId = request.url.queryParameters['pwd_id']!;
            final st = states[pwdId];
            final withdrawn = st == 'withdrawn';
            final files = <String>[
              if (!withdrawn) '$pwdId-e1',
              if (st == 'recovered') '$pwdId-e2',
            ];
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'metadata': {'_total': files.length},
                'data': {
                  'share': {'status': withdrawn ? 0 : 1},
                  'list': [
                    for (final f in files)
                      {
                        'fid': f,
                        'file_name': '$f.mkv',
                        'file_type': 1,
                        'category': 1,
                        'share_fid_token': 'ref-$f',
                      },
                  ],
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        );
        List<String> fidsOf(CmsVideo v) => [
              for (final l in v.lines)
                for (final e in l.episodes)
                  Uri.parse(e.url).queryParameters['fid']!,
            ];

        const dualSeed = CmsVideo(id: 'r5-dual', title: '双分享状态测试');
        final (_, dualInit) =
            await dualClient.playableDetail(httpSite, dualSeed, const [httpSite]);
        expect(fidsOf(dualInit), unorderedEquals(['$shareA-e1', '$shareB-e1']));

        states[shareA] = 'withdrawn';
        states[shareB] = '503';
        final (_, afterMixed) = await dualClient.playableDetail(
          httpSite,
          dualInit,
          const [httpSite],
          forceRefresh: true,
        );
        expect(fidsOf(afterMixed), ['$shareB-e1']);
        expect(dualClient.hasAuthoritativeEmptyDetail(httpSite, dualSeed), isFalse);

        final (_, reopenDuring503) =
            await dualClient.playableDetail(httpSite, dualSeed, const [httpSite]);
        expect(fidsOf(reopenDuring503), ['$shareB-e1']);

        states[shareB] = 'recovered';
        final (_, bRecovered) = await dualClient.playableDetail(
          httpSite,
          dualSeed,
          const [httpSite],
          forceRefresh: true,
        );
        expect(fidsOf(bRecovered), unorderedEquals(['$shareB-e1', '$shareB-e2']));
        final (_, reopenStaleCard) =
            await dualClient.playableDetail(httpSite, dualInit, const [httpSite]);
        expect(
          fidsOf(reopenStaleCard),
          unorderedEquals(['$shareB-e1', '$shareB-e2']),
        );

        // Item 2: Missing stoken (HTTP 200, code=0, data={}) retains E1 without delisting and recovers E2.
        var singleState = 'ok';
        final noTokenClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.host == 'cms.example') {
              return http.Response(
                jsonEncode({
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 'r5-notoken',
                      'vod_name': '无stoken测试',
                      'vod_play_from': '夸克',
                      'vod_play_url': '正片\$https://pan.quark.cn/s/$shareA',
                    },
                  ],
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            if (request.url.path.endsWith('/token')) {
              return http.Response(
                jsonEncode({
                  'status': 200,
                  'code': 0,
                  'data': {if (singleState != 'no_token') 'stoken': 'tok-ok'},
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            final files = <String>[
              '$shareA-e1',
              if (singleState == 'recovered') '$shareA-e2',
            ];
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'metadata': {'_total': files.length},
                'data': {
                  'share': {'status': 1},
                  'list': [
                    for (final f in files)
                      {
                        'fid': f,
                        'file_name': '$f.mkv',
                        'file_type': 1,
                        'category': 1,
                        'share_fid_token': 'ref-$f',
                      },
                  ],
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        );
        const noTokenSeed = CmsVideo(id: 'r5-notoken', title: '无stoken测试');
        final (_, ntInit) = await noTokenClient.playableDetail(
            httpSite, noTokenSeed, const [httpSite]);
        expect(fidsOf(ntInit), ['$shareA-e1']);

        singleState = 'no_token';
        await expectLater(
          noTokenClient.playableDetail(
            httpSite,
            ntInit,
            const [httpSite],
            forceRefresh: true,
          ),
          throwsFormatException,
        );
        expect(
            noTokenClient.hasAuthoritativeEmptyDetail(httpSite, noTokenSeed),
            isFalse);
        final (_, ntKept) = await noTokenClient.playableDetail(
            httpSite, noTokenSeed, const [httpSite]);
        expect(fidsOf(ntKept), ['$shareA-e1']);

        singleState = 'recovered';
        final (_, ntRecovered) = await noTokenClient.playableDetail(
          httpSite,
          noTokenSeed,
          const [httpSite],
          forceRefresh: true,
        );
        expect(fidsOf(ntRecovered), unorderedEquals(['$shareA-e1', '$shareA-e2']));

        // Item 3: XML trailing error text retains E1; whitespace + comments outside root still clear.
        var xmlBody =
            '<rss><list><video><id>r5-xml</id><name>XML文本测试</name><dl><dd flag="main"><![CDATA[E1\$https://media.example/r5-e1.mp4]]></dd></dl></video></list></rss>';
        final xmlClient = CmsClient(
          client: MockClient(
            (_) async => http.Response(
              xmlBody,
              200,
              headers: const {'content-type': 'application/xml; charset=utf-8'},
            ),
          ),
        );
        const xmlSeed = CmsVideo(id: 'r5-xml', title: 'XML文本测试');
        final (_, xmlInit) =
            await xmlClient.playableDetail(httpSite, xmlSeed, const [httpSite]);
        expect(xmlInit.lines.single.episodes.single.url,
            'https://media.example/r5-e1.mp4');

        xmlBody = '<rss><list/></rss>\nWarning: upstream connection refused';
        await expectLater(
          xmlClient.playableDetail(
            httpSite,
            xmlInit,
            const [httpSite],
            forceRefresh: true,
          ),
          throwsFormatException,
        );
        expect(xmlClient.hasAuthoritativeEmptyDetail(httpSite, xmlSeed), isFalse);
        final (_, xmlKept) =
            await xmlClient.playableDetail(httpSite, xmlSeed, const [httpSite]);
        expect(xmlKept.lines.single.episodes.single.url,
            'https://media.example/r5-e1.mp4');

        xmlBody = '\n<!-- begin -->\n<rss><list/></rss>\n<!-- end --> \n';
        final (_, xmlCleared) = await xmlClient.playableDetail(
          httpSite,
          xmlInit,
          const [httpSite],
          forceRefresh: true,
        );
        expect(xmlCleared.lines, isEmpty);
        expect(xmlClient.hasAuthoritativeEmptyDetail(httpSite, xmlSeed), isTrue);
        final (_, xmlStaleReopen) =
            await xmlClient.playableDetail(httpSite, xmlInit, const [httpSite]);
        expect(xmlStaleReopen.lines, isEmpty);
      },
    );

    testWidgets(
      'Round6: cold share B=503 while share A withdraws drops A on refresh and stale-card re-entry (both CmsClient and real DetailScreen) without delisting, then B recovery loads b-e1/b-e2 on ordinary re-entry',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        var withdrawnA = false;
        var availableB = false;

        final client = CmsClient(
          client: MockClient((request) async {
            if (request.url.host == 'cms.example') {
              return http.Response(
                jsonEncode({
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 'r6-cold',
                      'vod_name': '冷分享重试测试',
                      'vod_play_from': r'网盘 A$$$网盘 B',
                      'vod_play_url':
                          r'正片$https://pan.quark.cn/s/r6oldA$$$正片$https://pan.quark.cn/s/r6newB',
                    },
                  ],
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            if (request.url.path.endsWith('/token')) {
              final share = (jsonDecode(request.body) as Map)['pwd_id'];
              if (share == 'r6newB' && !availableB) {
                return http.Response('Unavailable', 503);
              }
              return http.Response(
                jsonEncode({
                  'code': 0,
                  'status': 200,
                  'data': {'stoken': 'r6-tok'},
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            final share = request.url.queryParameters['pwd_id'];
            final withdrawn = share == 'r6oldA' && withdrawnA;
            final ids = share == 'r6oldA'
                ? [if (!withdrawn) 'a-e1']
                : ['b-e1', 'b-e2'];
            return http.Response(
              jsonEncode({
                'code': 0,
                'status': 200,
                'metadata': {'_total': ids.length},
                'data': {
                  'share': {'status': withdrawn ? 0 : 1},
                  'list': [
                    for (final id in ids)
                      {
                        'fid': id,
                        'file_name': '$id.mkv',
                        'file_type': 1,
                        'category': 1,
                      },
                  ],
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        );

        List<String?> fidsOf(CmsVideo v) => [
              for (final l in v.lines)
                for (final e in l.episodes)
                  Uri.parse(e.url).queryParameters['fid'],
            ];

        Future<void> settleQuark() async {
          for (var i = 0; i < 12; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump();
          }
          await tester.pumpAndSettle();
        }

        const bareCard = CmsVideo(id: 'r6-cold', title: '冷分享重试测试');

        // 1) Initial load: A returns a-e1, B returns 503 -> obtain oldCard carrying a-e1.
        final (_, oldCard) = await tester.runAsync(
          () => client.playableDetail(httpSite, bareCard, const [httpSite]),
        ) as (CmsSite, CmsVideo);
        expect(fidsOf(oldCard), ['a-e1']);

        // 2) A withdraws while B stays 503 -> refresh evicts A, sets pending retry, does NOT delist.
        withdrawnA = true;
        Object? refreshError;
        await tester.runAsync(() async {
          try {
            await client.playableDetail(
              httpSite,
              oldCard,
              const [httpSite],
              forceRefresh: true,
            );
          } catch (e) {
            refreshError = e;
          }
        });
        expect(refreshError, isA<FormatException>());
        expect(client.hasAuthoritativeEmptyDetail(httpSite, bareCard), isFalse);
        expect(client.hasPendingDetailRetry(httpSite, bareCard), isTrue);

        // 3) Ordinary re-entry on real DetailScreen from oldCard carrying a-e1 while B is still 503:
        //    must ignore a-e1, show retry error UI, and NOT mark delisted.
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo: oldCard,
              client: client,
              storage: storage,
            ),
          ),
        );
        await settleQuark();
        expect(find.textContaining('读取详情失败'), findsOneWidget);
        expect(find.text('网盘 A'), findsNothing);
        expect(client.hasAuthoritativeEmptyDetail(httpSite, bareCard), isFalse);
        expect(client.hasPendingDetailRetry(httpSite, bareCard), isTrue);

        // 4) B recovers with b-e1 & b-e2; ordinary re-entry from the SAME oldCard shows b-e1/b-e2
        //    without manual pull-to-refresh and clears pending retry state.
        availableB = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: httpSite,
              initialVideo: oldCard,
              client: client,
              storage: storage,
            ),
          ),
        );
        await settleQuark();
        expect(find.text('网盘 B'), findsWidgets);
        expect(find.text('网盘 A'), findsNothing);
        expect(client.hasPendingDetailRetry(httpSite, bareCard), isFalse);
        expect(client.hasAuthoritativeEmptyDetail(httpSite, bareCard), isFalse);
        final (_, cached) = await tester.runAsync(
          () => client.playableDetail(httpSite, oldCard, const [httpSite]),
        ) as (CmsSite, CmsVideo);
        expect(fidsOf(cached), unorderedEquals(['b-e1', 'b-e2']));
      },
    );

    test(
      'Round7: stale expanded cloud card re-entered 6 minutes after A withdrawal still retries upstream B (offline never revives A, recovered returns b-e1/b-e2)',
      () async {
        for (final recovered in const [false, true]) {
          var clockNow = DateTime.utc(2026, 11, 23, 12);
          var cmsCalls = 0;
          var shareBTokenCalls = 0;
          var withdrawnA = false;
          var availableB = false;

          final client = CmsClient(
            client: MockClient((request) async {
              if (request.url.host == 'cms.example') {
                cmsCalls++;
                return http.Response(
                  jsonEncode({
                    'code': 1,
                    'list': [
                      {
                        'vod_id': 'r7-expiry',
                        'vod_name': '六分钟过期重试测试',
                        'vod_play_from': r'网盘 A$$$网盘 B',
                        'vod_play_url':
                            r'正片$https://pan.quark.cn/s/r7oldA$$$正片$https://pan.quark.cn/s/r7newB',
                      },
                    ],
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              if (request.url.path.endsWith('/token')) {
                final share = (jsonDecode(request.body) as Map)['pwd_id'];
                if (share == 'r7newB') {
                  shareBTokenCalls++;
                  if (!availableB) return http.Response('Unavailable', 503);
                }
                return http.Response(
                  jsonEncode({
                    'code': 0,
                    'status': 200,
                    'data': {'stoken': 'r7-tok'},
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              final share = request.url.queryParameters['pwd_id'];
              final withdrawn = share == 'r7oldA' && withdrawnA;
              final ids = share == 'r7oldA'
                  ? [if (!withdrawn) 'a-e1']
                  : ['b-e1', 'b-e2'];
              return http.Response(
                jsonEncode({
                  'code': 0,
                  'status': 200,
                  'metadata': {'_total': ids.length},
                  'data': {
                    'share': {'status': withdrawn ? 0 : 1},
                    'list': [
                      for (final id in ids)
                        {
                          'fid': id,
                          'file_name': '$id.mkv',
                          'file_type': 1,
                          'category': 1,
                        },
                    ],
                  },
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }),
          )..debugClock = () => clockNow;

          List<String?> fidsOf(CmsVideo v) => [
                for (final l in v.lines)
                  for (final e in l.episodes)
                    Uri.parse(e.url).queryParameters['fid'],
              ];

          const bare = CmsVideo(id: 'r7-expiry', title: '六分钟过期重试测试');
          final (_, oldCard) =
              await client.playableDetail(httpSite, bare, const [httpSite]);
          expect(fidsOf(oldCard), ['a-e1']);

          withdrawnA = true;
          await expectLater(
            client.playableDetail(
              httpSite,
              oldCard,
              const [httpSite],
              forceRefresh: true,
            ),
            throwsFormatException,
          );
          expect(client.hasAuthoritativeEmptyDetail(httpSite, bare), isFalse);

          final cmsBefore = cmsCalls;
          final tokenBefore = shareBTokenCalls;
          clockNow = clockNow.add(const Duration(minutes: 6));
          availableB = recovered;

          if (recovered) {
            final (_, reopened) =
                await client.playableDetail(httpSite, oldCard, const [httpSite]);
            expect(fidsOf(reopened), unorderedEquals(['b-e1', 'b-e2']));
          } else {
            await expectLater(
              client.playableDetail(httpSite, oldCard, const [httpSite]),
              throwsFormatException,
            );
          }
          expect(cmsCalls - cmsBefore, greaterThan(0));
          expect(shareBTokenCalls - tokenBefore, greaterThan(0));
          expect(client.hasAuthoritativeEmptyDetail(httpSite, bare), isFalse);
        }
      },
    );

    testWidgets(
      'Round8: DetailScreen blocks withdrawn cloud line A from frame 0 and primary play button while awaiting CMS response after 6-min expiry, plays b-e1 once B recovers, and preserves fresh cache & M3U inline playback',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          IosLiquidGlassBridge.setAvailableForTest(false);
          tester.view.reset();
        });

        final storage = await initTestStorage();
        await storage.setNetdiskCred(
          'quark',
          QuarkAccountSession(
            cookie: '__pus=fixture-identity; __puus=fixture-cookie',
            driveSt: 'fixture-drive-ticket',
            accountId: sha256.convert(utf8.encode('fixture-identity')).toString(),
            validatedAt: DateTime.now(),
          ).toCredential(),
        );

        Future<void> settleAsync() async {
          for (var i = 0; i < 16; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 25));
          }
        }

        for (final recovered in const [false, true]) {
          var clockNow = DateTime.utc(2026, 11, 23, 12);
          var cmsCalls = 0;
          var withdrawnA = false;
          var availableB = false;
          Completer<void>? gate;

          final client = CmsClient(
            client: MockClient((request) async {
              if (request.url.host == 'cms.example') {
                cmsCalls++;
                final currentGate = gate;
                if (currentGate != null) await currentGate.future;
                return http.Response(
                  jsonEncode({
                    'code': 1,
                    'list': [
                      {
                        'vod_id': 'r8-play',
                        'vod_name': '详情页防点播旧集测试',
                        'vod_play_from': r'网盘 A$$$网盘 B',
                        'vod_play_url':
                            r'正片$https://pan.quark.cn/s/r8oldA$$$正片$https://pan.quark.cn/s/r8newB',
                      },
                    ],
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              if (request.url.path.endsWith('/token')) {
                final share = (jsonDecode(request.body) as Map)['pwd_id'];
                if (share == 'r8newB' && !availableB) {
                  return http.Response('Unavailable', 503);
                }
                return http.Response(
                  jsonEncode({
                    'code': 0,
                    'status': 200,
                    'data': {'stoken': 'r8-tok'},
                  }),
                  200,
                  headers: const {
                    'content-type': 'application/json; charset=utf-8',
                  },
                );
              }
              final share = request.url.queryParameters['pwd_id'];
              final withdrawn = share == 'r8oldA' && withdrawnA;
              final ids = share == 'r8oldA'
                  ? [if (!withdrawn) 'a-e1']
                  : ['b-e1', 'b-e2'];
              return http.Response(
                jsonEncode({
                  'code': 0,
                  'status': 200,
                  'metadata': {'_total': ids.length},
                  'data': {
                    'share': {'status': withdrawn ? 0 : 1},
                    'list': [
                      for (final id in ids)
                        {
                          'fid': id,
                          'file_name': '$id.mkv',
                          'file_type': 1,
                          'category': 1,
                        },
                    ],
                  },
                }),
                200,
                headers: const {
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }),
          )..debugClock = () => clockNow;

          const bare = CmsVideo(id: 'r8-play', title: '详情页防点播旧集测试');
          final (_, oldCard) = (await tester.runAsync(
            () => client.playableDetail(httpSite, bare, const [httpSite]),
          ))!;
          withdrawnA = true;
          await tester.runAsync(() async {
            try {
              await client.playableDetail(
                httpSite,
                oldCard,
                const [httpSite],
                forceRefresh: true,
              );
            } on FormatException {
              // expected while B is 503
            }
          });

          clockNow = clockNow.add(const Duration(minutes: 6));
          availableB = recovered;
          final cmsBefore = cmsCalls;
          gate = Completer<void>();
          final playedFids = <String?>[];

          await tester.pumpWidget(
            MaterialApp(
              home: DetailScreen(
                site: httpSite,
                initialVideo: oldCard,
                client: client,
                storage: storage,
                debugPlayerBuilder: (_, s, v, line, ep, resumeMs) {
                  final u = v.lines[line].episodes[ep].url;
                  playedFids.add(Uri.parse(u).queryParameters['fid']);
                  return const Scaffold(body: Text('PLAYER'));
                },
              ),
            ),
          );

          // Frame 0 & while awaiting CMS reply: zero A shown, zero player calls.
          expect(find.text('网盘 A'), findsNothing);
          await settleAsync();
          expect(find.text('网盘 A'), findsNothing);
          final playBtn = find.byKey(const Key('detail-primary-play-button'));
          if (playBtn.hitTestable().evaluate().isNotEmpty) {
            await tester.tap(playBtn);
            await settleAsync();
          }
          expect(playedFids, isEmpty);

          // Release CMS response.
          gate.complete();
          gate = null;
          await settleAsync();
          await tester.pumpAndSettle();
          expect(cmsCalls, greaterThan(cmsBefore));
          expect(find.text('网盘 A'), findsNothing);

          if (recovered) {
            expect(find.text('网盘 B'), findsWidgets);
            expect(playBtn.hitTestable(), findsOneWidget);
            await tester.tap(playBtn);
            await settleAsync();
            expect(playedFids, ['b-e1']);

            // Valid fresh cache re-entry from the same oldCard shows B immediately
            // with 0 extra CMS requests and plays b-e1 directly.
            final cmsAfterRecover = cmsCalls;
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            await tester.pumpWidget(
              MaterialApp(
                home: DetailScreen(
                  site: httpSite,
                  initialVideo: oldCard,
                  client: client,
                  storage: storage,
                  debugPlayerBuilder: (_, s, v, line, ep, resumeMs) {
                    final u = v.lines[line].episodes[ep].url;
                    playedFids.add(Uri.parse(u).queryParameters['fid']);
                    return const Scaffold(body: Text('PLAYER'));
                  },
                ),
              ),
            );
            expect(find.text('网盘 A'), findsNothing);
            expect(find.text('网盘 B'), findsWidgets);
            await tester.tap(playBtn);
            await settleAsync();
            expect(cmsCalls, cmsAfterRecover);
            expect(playedFids, ['b-e1', 'b-e1']);
          } else {
            expect(find.text('网盘 B'), findsNothing);
            expect(find.textContaining('读取详情失败'), findsOneWidget);
            expect(playedFids, isEmpty);
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );

    testWidgets(
      'Round9: M3U inline Quark share expands on first DetailScreen entry, blocks play while loading, supports pull-to-refresh and fresh-cache re-entry, and keeps direct M3U immediately playable',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.reset();
          IosLiquidGlassBridge.setAvailableForTest(false);
        });

        final storage = await initTestStorage();
        await storage.setNetdiskCred(
          'quark',
          QuarkAccountSession(
            cookie: '__pus=fixture-identity; __puus=fixture-cookie',
            driveSt: 'fixture-drive-ticket',
            accountId:
                sha256.convert(utf8.encode('fixture-identity')).toString(),
            validatedAt: DateTime.now(),
          ).toCredential(),
        );

        const playlist =
            '#EXTM3U\n'
            '#EXTINF:-1 group-title="测试",示例剧\n'
            'https://pan.quark.cn/s/inline-share\n'
            '#EXTINF:-1 group-title="直链",直链片\n'
            'https://media.example/direct.m3u8\n';
        const m3uSite = CmsSite(
          key: 'inline_m3u_r9',
          name: '本地 M3U',
          type: 1,
          api: 'm3u_vod://playlist',
          ext: playlist,
        );
        final parsedVideos = CmsParser.parseM3uVodHome(playlist).$2.videos;
        final shareCard = parsedVideos.firstWhere((v) => v.title == '示例剧');
        final directCard = parsedVideos.firstWhere((v) => v.title == '直链片');

        var tokenRequests = 0;
        var includeE2 = false;
        Completer<void>? tokenGate = Completer<void>();

        final client = CmsClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/token')) {
              tokenRequests++;
              expect(jsonDecode(request.body)['pwd_id'], 'inline-share');
              final currentGate = tokenGate;
              if (currentGate != null) await currentGate.future;
              return http.Response(
                jsonEncode({
                  'code': 0,
                  'status': 200,
                  'data': {'stoken': 'fixture'},
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (request.url.path.endsWith('/detail')) {
              final list = <Map<String, Object>>[
                {
                  'fid': 'e1',
                  'file_name': 'E1.mkv',
                  'file_type': 1,
                  'category': 1,
                },
                if (includeE2)
                  {
                    'fid': 'e2',
                    'file_name': 'E2.mkv',
                    'file_type': 1,
                    'category': 1,
                  },
              ];
              return http.Response(
                jsonEncode({
                  'code': 0,
                  'status': 200,
                  'metadata': {'_total': list.length},
                  'data': {
                    'share': {'status': 1},
                    'list': list,
                  },
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            throw StateError('unexpected request: ${request.url}');
          }),
        );

        Future<void> settleAsync() async {
          for (var i = 0; i < 12; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 25));
          }
        }

        final openedUrls = <String>[];
        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: DetailScreen(
              site: m3uSite,
              initialVideo: shareCard,
              client: client,
              storage: storage,
              debugPlayerBuilder: (_, s, v, line, ep, resumeMs) {
                openedUrls.add(v.lines[line].episodes[ep].url);
                return const Scaffold(body: Text('PLAYER'));
              },
            ),
          ),
        );
        await settleAsync();

        // While Quark token response is pending: request fired, play blocked.
        expect(tokenRequests, 1);
        final playBtn = find.byKey(const Key('detail-primary-play-button'));
        if (playBtn.hitTestable().evaluate().isNotEmpty) {
          await tester.tap(playBtn);
          await settleAsync();
        }
        expect(openedUrls, isEmpty);

        // Release token response -> first tap plays e1.
        tokenGate.complete();
        tokenGate = null;
        await settleAsync();
        await tester.pumpAndSettle();
        expect(playBtn.hitTestable(), findsOneWidget);
        await tester.tap(playBtn);
        await settleAsync();
        expect(openedUrls.length, 1);
        expect(Uri.parse(openedUrls.single).queryParameters['fid'], 'e1');

        // Pop player back to DetailScreen and pull-to-refresh to verify the
        // preserved raw M3U share URL re-queries Quark and discovers E2.
        if (navKey.currentState!.canPop()) {
          navKey.currentState!.pop();
          await settleAsync();
          await tester.pumpAndSettle();
        }
        includeE2 = true;
        final tokenBeforeRefresh = tokenRequests;
        await performPullRefresh(tester);
        await settleAsync();
        await tester.pumpAndSettle();
        expect(tokenRequests, greaterThan(tokenBeforeRefresh));
        final refreshed = client.peekFreshCachedDetail(m3uSite, shareCard);
        expect(refreshed, isNotNull);
        expect(
          refreshed!.lines.single.episodes
              .map((e) => Uri.parse(e.url).queryParameters['fid'])
              .toList(),
          ['e1', 'e2'],
        );
        expect(find.text('2'), findsOneWidget);

        // Re-entry while fresh cache is valid plays immediately with 0 extra
        // Quark requests.
        final tokenAfterRefresh = tokenRequests;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: m3uSite,
              initialVideo: shareCard,
              client: client,
              storage: storage,
              debugPlayerBuilder: (_, s, v, line, ep, resumeMs) {
                openedUrls.add(v.lines[line].episodes[ep].url);
                return const Scaffold(body: Text('PLAYER'));
              },
            ),
          ),
        );
        expect(playBtn.hitTestable(), findsOneWidget);
        await tester.tap(playBtn);
        await settleAsync();
        expect(tokenRequests, tokenAfterRefresh);
        expect(openedUrls.length, 2);
        expect(Uri.parse(openedUrls.last).queryParameters['fid'], 'e1');

        // Plain M3U direct stream remains immediately playable with 0 requests.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: m3uSite,
              initialVideo: directCard,
              client: client,
              storage: storage,
              debugPlayerBuilder: (_, s, v, line, ep, resumeMs) {
                openedUrls.add(v.lines[line].episodes[ep].url);
                return const Scaffold(body: Text('PLAYER'));
              },
            ),
          ),
        );
        expect(playBtn.hitTestable(), findsOneWidget);
        await tester.tap(playBtn);
        await settleAsync();
        expect(tokenRequests, tokenAfterRefresh);
        expect(openedUrls.last, 'https://media.example/direct.m3u8');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

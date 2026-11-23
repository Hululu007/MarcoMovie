import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_search_page.dart';

import 'test_storage_helper.dart';

class _MultiSourceSearchClient extends CmsClient {
  final List<CmsVideo> homeVideos;
  final Map<String, List<CmsVideo>> searchBySite;
  int homeFetchCount = 0;

  _MultiSourceSearchClient({
    this.homeVideos = const [],
    this.searchBySite = const {},
  });

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    homeFetchCount++;
    return (
      const [CmsCategory(id: '1', name: '剧集')],
      CmsListing(videos: homeVideos),
    );
  }

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    return CmsListing(videos: searchBySite[site.key] ?? const []);
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
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  group('Smart search aggregation engine (C)', () {
    const sitePreferred = CmsSite(
      key: 'huajuan',
      name: '花卷 | 4K',
      type: 1,
      api: 'https://huajuan.example/api',
    );
    const siteDirect = CmsSite(
      key: 'guangying',
      name: '光影 | 不卡',
      type: 1,
      api: 'https://guangying.example/api',
    );
    const siteBackup = CmsSite(
      key: 'nuomi',
      name: '糯米 | 秒播',
      type: 1,
      api: 'https://nuomi.example/api',
    );

    test(
      'merges noisy quality/episode variants, deduplicates, and preserves sequels & spin-offs',
      () {
        final groups = aggregateSearchResults(
          query: '兰香如故',
          preferredSiteKey: ':huajuan',
          sourceLabelOf: (s) => s.name,
          results: const [
            (
              siteDirect,
              CmsVideo(
                id: 'v1',
                title: '兰香如故（臻彩）',
                poster: 'https://img.example/nopic.jpg',
                remarks: 'HD',
                year: '2026',
              ),
            ),
            (
              sitePreferred,
              CmsVideo(
                id: 'v2',
                title: '兰香如故【4K】',
                poster: 'https://img.example/lanxiang-hd.jpg',
                remarks: '更新至38集',
                area: '中国大陆',
                actor: '谭松韵 / 刘学义',
                doubanScore: 8.6,
              ),
            ),
            (
              siteBackup,
              CmsVideo(
                id: 'v3',
                title: '兰香如故 更新至第38集',
                remarks: '全38集',
              ),
            ),
            // Duplicate of sitePreferred v2 should be deduplicated.
            (
              sitePreferred,
              CmsVideo(
                id: 'v2',
                title: '兰香如故【4K】',
              ),
            ),
            // Spin-off with middle dot stays separate.
            (
              siteDirect,
              CmsVideo(
                id: 'v4',
                title: '兰香如故·花胜秋宴',
              ),
            ),
            // Sequel digits stay separate.
            (
              siteDirect,
              CmsVideo(id: 'q1', title: '庆余年'),
            ),
            (
              siteDirect,
              CmsVideo(id: 'q2', title: '庆余年2'),
            ),
          ],
        );

        expect(groups.length, 4);
        final top = groups.first;
        expect(top.displayTitle, '兰香如故');
        expect(top.matches.length, 3);
        expect(top.primaryMatch.site.key, 'huajuan');
        expect(top.poster, 'https://img.example/lanxiang-hd.jpg');
        expect(top.doubanScore, 8.6);
        expect(top.year, '2026');
        expect(top.area, '中国大陆');
        expect(top.actor, '谭松韵 / 刘学义');

        final titles = groups.map((g) => g.displayTitle).toList();
        expect(titles, contains('兰香如故·花胜秋宴'));
        expect(titles, contains('庆余年'));
        expect(titles, contains('庆余年2'));
      },
    );
  });

  group('IosGlobalSearchPage (B + A + C)', () {
    testWidgets(
      'renders zero-state recent chips + Home hot picks, bottom floating Liquid Glass bar, smart aggregation, and mode/source switching',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage();
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'huajuan',
                'name': '花卷 | 4K',
                'type': 1,
                'api': 'https://huajuan.example/api',
              },
              {
                'key': 'guangying',
                'name': '光影 | 不卡',
                'type': 1,
                'api': 'https://guangying.example/api',
              },
              {
                'key': 'empty_site',
                'name': '空线路',
                'type': 1,
                'api': 'https://empty.example/api',
              },
            ],
          }),
        );
        await storage.addSearchKeyword('庆余年');
        await storage.addSearchKeyword('唐朝诡事录');

        final client = _MultiSourceSearchClient(
          homeVideos: const [
            CmsVideo(id: 'h1', title: '多喜一家人', remarks: '更新至10集'),
            CmsVideo(id: 'h2', title: '我要看见你', remarks: '全13集'),
          ],
          searchBySite: const {
            'huajuan': [
              CmsVideo(
                id: 's1',
                title: '兰香如故【4K】',
                remarks: '更新至38集',
                year: '2026',
                area: '中国大陆',
                doubanScore: 8.6,
              ),
            ],
            'guangying': [
              CmsVideo(
                id: 's2',
                title: '兰香如故（臻彩）',
                remarks: 'HD',
              ),
            ],
            'empty_site': [],
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pumpAndSettle();
        final initialHomeFetches = client.homeFetchCount;

        // Open Global Search from the bottom Dock search button.
        await tester.tap(find.byKey(const ValueKey('home-search-button')));
        await tester.pumpAndSettle();

        expect(find.byType(IosGlobalSearchPage), findsOneWidget);
        expect(find.byType(AppleSearchField), findsOneWidget);
        // Zero-state reuses already-loaded Home hot picks without refetching.
        expect(client.homeFetchCount, initialHomeFetches);
        expect(find.text('最近搜索'), findsOneWidget);
        expect(find.text('庆余年'), findsOneWidget);
        expect(find.text('唐朝诡事录'), findsOneWidget);
        expect(find.text('本源热播'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(IosGlobalSearchPage),
            matching: find.text('多喜一家人'),
          ),
          findsOneWidget,
        );

        // Bottom floating Liquid Glass search capsule + circular X button sit near bottom (B).
        final capsuleRect = tester.getRect(
          find.byKey(const ValueKey('search-floating-glass-capsule')),
        );
        final closeRect = tester.getRect(
          find.byKey(const ValueKey('search-close-button')),
        );
        expect(capsuleRect.top, greaterThan(844 * 0.75));
        expect(closeRect.left, greaterThan(capsuleRect.right));
        expect(closeRect.width, closeTo(closeRect.height, 0.5));

        // Run a cross-source search.
        await tester.enterText(find.byType(CupertinoTextField).last, '兰香如故');
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();

        // Smart aggregation (C) merges the 2 matching sources into 1 cinema card.
        expect(
          find.descendant(
            of: find.byType(ListView).last,
            matching: find.text('兰香如故'),
          ),
          findsOneWidget,
        );
        expect(find.text('共 2 个片源'), findsOneWidget);
        expect(find.text('8.6'), findsOneWidget);

        // Horizontal source filter strip shows ONLY sites with count > 0 + '全部'.
        final filterBar = find.byKey(const ValueKey('search-site-filter-bar'));
        expect(filterBar, findsOneWidget);
        expect(
          find.descendant(of: filterBar, matching: find.text('全部')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: filterBar, matching: find.text('花卷 | 4K')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: filterBar, matching: find.text('空线路')),
          findsNothing,
        );

        // Switch from 智能聚合 to 全部海报 (full-width poster grid).
        await tester.tap(find.text('全部海报'));
        await tester.pumpAndSettle();
        expect(find.byType(GridView), findsOneWidget);
        expect(find.text('兰香如故【4K】'), findsOneWidget);
        expect(find.text('兰香如故（臻彩）'), findsOneWidget);

        // Filter to a single source via the horizontal strip.
        await tester.tap(
          find.descendant(of: filterBar, matching: find.text('花卷 | 4K')),
        );
        await tester.pumpAndSettle();
        expect(find.text('兰香如故【4K】'), findsOneWidget);
        expect(find.text('兰香如故（臻彩）'), findsNothing);

        // Close search via bottom-right circular glass X button.
        await tester.tap(find.byKey(const ValueKey('search-close-button')));
        await tester.pumpAndSettle();
        expect(find.byType(IosGlobalSearchPage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'iOS 26 native mode mounts UiKitView for bottom circular close button and segmented switcher',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(true);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage();
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 's1',
                'name': '花卷 | 4K',
                'type': 1,
                'api': 'https://huajuan.example/api',
              },
            ],
          }),
        );
        final client = CmsClient(
          client: MockClient((req) async {
            if (req.url.queryParameters.containsKey('wd')) {
              return http.Response(
                jsonEncode({
                  'list': [
                    {'vod_id': '1', 'vod_name': '兰香如故'},
                  ],
                }),
                200,
              );
            }
            return http.Response('{"class":[],"list":[]}', 200);
          }),
        );

        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final revision = ValueNotifier<int>(0);
        addTearDown(revision.dispose);
        const site = CmsSite(
          key: 's1',
          name: '花卷 | 4K',
          type: 1,
          api: 'https://huajuan.example/api',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: IosGlobalSearchPage(
              controller: controller,
              storage: storage,
              client: client,
              stateRevision: revision,
              readSnapshot: () => const GlobalSearchSnapshot(
                isPrivate: false,
                searching: false,
                searchPerformed: true,
                searchKeyword: '兰香如故',
                siteFilterKey: '',
                searchEpoch: 1,
                results: [
                  (site, CmsVideo(id: '1', title: '兰香如故')),
                ],
                notices: {},
                verificationSites: {},
                visibleSupportedSites: [site],
                activeSite: site,
                homeHotVideos: [],
              ),
              sourceLabelOf: (s) => s.name,
              onSearch: (_) {},
              onResetSearch: () {},
              onSiteFilterChanged: (_) {},
              onRetryVerifiedSearch: (_) async {},
              onOpenVideoDetail: (_, __) {},
              buildVideoCard: (_, v, {badge, onTap}) => Text(v.title),
            ),
          ),
        );
        await tester.pump();

        final uiKitViews = tester
            .widgetList<UiKitView>(find.byType(UiKitView))
            .map((v) => v.viewType)
            .toList();
        expect(uiKitViews, contains('marco_movie/ios26_glass_button'));
        expect(uiKitViews, contains('marco_movie/ios26_segmented_control'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

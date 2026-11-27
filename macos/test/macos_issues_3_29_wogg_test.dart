import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_file_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/wogg_netdisk_adapter.dart';
import 'package:marco_movie/core/wogg_source.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/macos_official_notice.dart';
import 'package:marco_movie/ui/player_screen.dart';

class _RecordingCmsClient extends CmsClient {
  _RecordingCmsClient({
    required this.onHome,
    required this.onCategory,
    required this.onDetail,
  }) : super(client: MockClient((_) async => http.Response('{}', 404)));

  final Future<(List<CmsCategory>, CmsListing)> Function(CmsSite site) onHome;
  final Future<CmsListing> Function(CmsSite site, String categoryId, int page)
      onCategory;
  final Future<CmsVideo> Function(CmsSite site, CmsVideo video) onDetail;

  final List<String> fetchedCategoryIds = <String>[];
  int homeCalls = 0;
  int detailCalls = 0;

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) {
    homeCalls++;
    return onHome(site);
  }

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) {
    fetchedCategoryIds.add(categoryId);
    return onCategory(site, categoryId, page);
  }

  @override
  Future<CmsVideo> fetchDetail(CmsSite site, CmsVideo video) {
    detailCalls++;
    return onDetail(site, video);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<StorageService> initStorage({
    Map<String, Object> initialPrefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      MacosOfficialNoticePrefs.acknowledgedVersionKey:
          MacosOfficialNoticePrefs.currentVersion,
      ...initialPrefs,
    });
    return StorageService.init(fileStore: InMemoryStorageFileStore());
  }

  group('Issues #3 & #29 — 臻彩 (category 44), stale cache refresh, desktop flow & real 4K quality', () {
    test('WoggSource preserves real HTML nav categories: keeps 44 臻彩 when present and omits it when absent', () async {
      const htmlWithZhencai = '''
<!doctype html><html><head><title>玩偶哥哥 4K</title></head><body>
  <nav class="nav">
    <a href="/vodtype/1.html">电影</a>
    <a href="/vodtype/2.html">剧集</a>
    <a href="/vodtype/3.html">动漫</a>
    <a href="/vodtype/4.html">综艺</a>
    <a href="/vodtype/44.html">臻彩</a>
  </nav>
  <div class="module-items">
    <div class="module-item">
      <div class="module-item-pic">
        <a href="/voddetail/9001.html" title="流浪地球 4K 臻彩">
          <img data-src="https://img.example/9001.jpg" />
        </a>
      </div>
      <div class="module-item-text">4K 臻彩 HDR</div>
    </div>
  </div>
</body></html>
''';
      const htmlWithoutZhencai = '''
<!doctype html><html><head><title>玩偶哥哥</title></head><body>
  <nav class="nav">
    <a href="/vodtype/1.html">电影</a>
    <a href="/vodtype/2.html">剧集</a>
    <a href="/vodtype/3.html">动漫</a>
  </nav>
  <div class="module-items">
    <div class="module-item">
      <div class="module-item-pic">
        <a href="/voddetail/9002.html" title="普通电影">
          <img data-src="https://img.example/9002.jpg" />
        </a>
      </div>
      <div class="module-item-note">1080P</div>
    </div>
  </div>
</body></html>
''';
      const site = CmsSite(
        key: 'wogg_test',
        name: '玩偶测试',
        type: 3,
        api: 'csp_WoGG',
        ext: 'https://wogg.example/',
      );

      final requested = <String>[];
      final withSource = WoggSource(
        read: (url, headers) async {
          requested.add(url);
          return htmlWithZhencai;
        },
        readBytes: (_, __) async => Uint8List(0),
        listShare: (_) async => const [],
      );
      final rawWith =
          await withSource.invoke(site, 'homeContent', const []);
      final parsedWith = jsonDecode(rawWith) as Map<String, dynamic>;
      final catsWith = (parsedWith['class'] as List).cast<Map<String, dynamic>>();
      final listWith = (parsedWith['list'] as List).cast<Map<String, dynamic>>();
      expect(requested, ['https://wogg.example/']);
      expect(
        catsWith.map((c) => '${c['type_id']}:${c['type_name']}').toList(),
        contains('44:臻彩'),
      );
      expect(listWith.single['vod_remarks'], '4K 臻彩 HDR');

      final withoutSource = WoggSource(
        read: (_, __) async => htmlWithoutZhencai,
        readBytes: (_, __) async => Uint8List(0),
        listShare: (_) async => const [],
      );
      final rawWithout =
          await withoutSource.invoke(site, 'homeContent', const []);
      final parsedWithout = jsonDecode(rawWithout) as Map<String, dynamic>;
      final catsWithout =
          (parsedWithout['class'] as List).cast<Map<String, dynamic>>();
      expect(catsWithout.map((c) => '${c['type_id']}').toList(), ['1', '2', '3']);
      expect(
        catsWithout.any(
          (c) => '${c['type_id']}' == '44' || '${c['type_name']}'.contains('臻彩'),
        ),
        isFalse,
        reason: 'Must not fabricate category 44 / 臻彩 when source nav omits it',
      );
    });

    test('WoggNetdiskAdapter dynamic category path preserves real 44 臻彩, skips pagination links, and paginates /vodtype/44', () async {
      final base = Uri.parse('https://pan4k.example/');
      const navWithZhencai = '''
<html><body>
  <header class="navbar">
    <a href="/vodtype/1.html">电影</a>
    <a href="/vodtype/2.html">剧集</a>
    <a href="/vodtype/44.html">臻彩视界</a>
    <a href="/vodtype/44-2.html">下一页</a>
  </header>
  <div class="module-items">
    <div class="module-item">
      <a href="/voddetail/4401.html" title="沙丘2 臻彩视界">
        <img data-original="https://img.example/dune.jpg" />
        <div class="module-item-text">臻彩 4K</div>
      </a>
    </div>
  </div>
</body></html>
''';
      final cats = WoggNetdiskAdapter.parseCategories(navWithZhencai, base);
      expect(cats.map((c) => '${c.id}:${c.name}').toList(), [
        '1:电影',
        '2:剧集',
        '44:臻彩视界',
      ]);
      final listing =
          WoggNetdiskAdapter.parseListing(navWithZhencai, base, page: 1);
      expect(listing.videos.single.title, '沙丘2 臻彩视界');
      expect(listing.videos.single.remarks, '臻彩 4K');

      // Source without 臻彩 must NOT fabricate 44
      const navWithoutZhencai = '''
<html><body>
  <header class="navbar">
    <a href="/vodtype/1.html">电影</a>
    <a href="/vodtype/2.html">剧集</a>
  </header>
</body></html>
''';
      final catsNo44 = WoggNetdiskAdapter.parseCategories(navWithoutZhencai, base);
      expect(catsNo44.map((c) => c.id).toList(), ['1', '2']);
      expect(catsNo44.any((c) => c.id == '44'), isFalse);

      // Verify category 44 page 2 pagination (both numeric '44' and '/vodtype/44.html')
      final requestedPaths = <String>[];
      const site = CmsSite(
        key: 'muou_4k',
        name: '木偶4K',
        type: 3,
        api: 'csp_Muou',
        ext: 'https://pan4k.example/',
      );
      final adapter = WoggNetdiskAdapter(
        site,
        (url, {headers = const {}, requestTimeout}) async {
          final parsedUri = Uri.parse(url);
          requestedPaths.add(parsedUri.path);
          if (parsedUri.path == '/vodshow/44--------2---.html') {
            return navWithZhencai;
          }
          throw const FormatException('404');
        },
      );
      final page2 = await adapter.category('44', 2);
      expect(requestedPaths, contains('/vodshow/44--------2---.html'));
      expect(page2.videos.single.title, '沙丘2 臻彩视界');

      requestedPaths.clear();
      final page2FromPath = await adapter.category('/vodtype/44.html', 2);
      expect(requestedPaths, contains('/vodshow/44--------2---.html'));
      expect(page2FromPath.videos.single.title, '沙丘2 臻彩视界');
    });

    test('CmsParser.extraTopLevelHomeCategories exposes real 44 臻彩 and returns empty when absent', () {
      const catsWith = [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
        CmsCategory(id: '3', name: '动漫'),
        CmsCategory(id: '4', name: '综艺'),
        CmsCategory(id: '44', name: '臻彩'),
      ];
      final extras = CmsParser.extraTopLevelHomeCategories(catsWith);
      expect(extras.map((c) => '${c.id}:${c.name}').toList(), ['44:臻彩']);

      const catsWithout = [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
        CmsCategory(id: '3', name: '动漫'),
        CmsCategory(id: '4', name: '综艺'),
      ];
      expect(CmsParser.extraTopLevelHomeCategories(catsWithout), isEmpty);
    });

    testWidgets('Desktop Home: stale cache missing 44 refreshes -> shows 臻彩 pill -> click 44 -> opens DetailScreen', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      Future<void> pumpBounded([int steps = 10]) async {
        for (var i = 0; i < steps; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
      }

      final rawConfig = jsonEncode({
        'sites': [
          {
            'key': 'wogg_live',
            'name': '玩偶4K',
            'type': 3,
            'api': 'csp_WoGG',
            'ext': 'https://wogg.example/',
          },
        ],
      });

      final storage = await initStorage();
      await storage.upsertSubscriptions([
        SubscriptionEntry(
          id: 'sub_wogg',
          name: '玩偶测试订阅',
          rawContent: rawConfig,
          siteCount: 1,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      final activeSite = storage.loadSavedConfig()!.availableSites.single;

      // Prime an OLD stale cache snapshot that does NOT have category 44 (臻彩)
      await storage.saveCachedSiteHome(
        activeSite,
        const [
          CmsCategory(id: '1', name: '电影'),
          CmsCategory(id: '2', name: '剧集'),
        ],
        const CmsListing(
          page: 1,
          pageCount: 1,
          videos: [
            CmsVideo(id: 'old_1', title: '旧缓存片单', remarks: '1080P'),
          ],
        ),
      );

      final client = _RecordingCmsClient(
        onHome: (_) async => (
          const [
            CmsCategory(id: '1', name: '电影'),
            CmsCategory(id: '2', name: '剧集'),
            CmsCategory(id: '3', name: '动漫'),
            CmsCategory(id: '4', name: '综艺'),
            CmsCategory(id: '44', name: '臻彩'),
          ],
          const CmsListing(
            page: 1,
            pageCount: 1,
            videos: [
              CmsVideo(id: 'home_1', title: '首页热映', remarks: '4K'),
            ],
          ),
        ),
        onCategory: (_, catId, page) async {
          if (catId == '44') {
            return const CmsListing(
              page: 1,
              pageCount: 1,
              videos: [
                CmsVideo(
                  id: 'zc_4401',
                  title: '奥本海默 臻彩视界',
                  remarks: '4K 臻彩 HDR',
                ),
              ],
            );
          }
          return const CmsListing(page: 1, pageCount: 1, videos: []);
        },
        onDetail: (_, video) async => CmsVideo(
          id: video.id,
          title: video.title,
          remarks: video.remarks,
          description: '4K 臻彩杜比视界测试片源',
          lines: const [
            CmsLine(
              name: '夸克原画',
              episodes: [
                CmsEpisode(
                  name: '4K 原画',
                  url: 'https://pan.quark.cn/s/demo4k',
                ),
              ],
            ),
          ],
        ),
      );

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await pumpBounded();

      // Fresh home fetch replaced stale cache and surfaced the real 44 臻彩 pill
      final zhencaiPill = find.byKey(const ValueKey('home-source-category-44'));
      expect(zhencaiPill, findsOneWidget);
      expect(find.byKey(const ValueKey('home-refresh-button')), findsOneWidget);

      // Cached snapshot on disk should also now contain 44: 臻彩
      final refreshedCache = storage.getCachedSiteHome(activeSite);
      expect(refreshedCache, isNotNull);
      expect(
        refreshedCache!.categories.any((c) => c.id == '44' && c.name == '臻彩'),
        isTrue,
      );

      // Click 臻彩 on desktop Home -> verify fetchCategory receives exact real ID '44'
      await tester.tap(zhencaiPill);
      await pumpBounded();
      expect(client.fetchedCategoryIds, contains('44'));
      expect(find.text('奥本海默 臻彩视界'), findsOneWidget);

      // Tap video card -> navigates to DetailScreen and loads real detail
      await tester.tap(find.text('奥本海默 臻彩视界'));
      await pumpBounded(14);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(client.detailCalls, greaterThanOrEqualTo(1));
      expect(find.textContaining('奥本海默 臻彩视界'), findsWidgets);
    });

    testWidgets('Desktop Home does NOT fabricate 臻彩 pill when source omits category 44', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final storage = await initStorage();
      await storage.upsertSubscriptions([
        SubscriptionEntry(
          id: 'sub_plain',
          name: '普通订阅',
          rawContent: jsonEncode({
            'sites': [
              {
                'key': 'plain_cms',
                'name': '普通CMS源',
                'type': 1,
                'api': 'https://plain.example/api.php/provide/vod/',
              },
            ],
          }),
          siteCount: 1,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);
      final client = _RecordingCmsClient(
        onHome: (_) async => (
          const [
            CmsCategory(id: '1', name: '电影'),
            CmsCategory(id: '2', name: '剧集'),
          ],
          const CmsListing(
            page: 1,
            pageCount: 1,
            videos: [CmsVideo(id: 'v1', title: '普通影片')],
          ),
        ),
        onCategory: (_, __, ___) async =>
            const CmsListing(page: 1, pageCount: 1, videos: []),
        onDetail: (_, v) async => v,
      );

      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.byKey(const ValueKey('home-source-category-44')), findsNothing);
      expect(find.text('臻彩'), findsNothing);
    });

    test('Issue #29: Real 4K/原画/臻彩 variant ranking, netdisk line selection, and WoggNetdiskAdapter global search', () async {
      // 1. Quality ranking preserves real variants & selects highest true tier
      const epWith4k = CmsEpisode(
        name: '第1集',
        url: 'https://cdn.example/1080p.m3u8',
        variants: [
          CmsEpisode(name: '720P 标清', url: 'https://cdn.example/720p.m3u8'),
          CmsEpisode(name: '1080P 高清', url: 'https://cdn.example/1080p.m3u8'),
          CmsEpisode(name: '4K 超清', url: 'https://cdn.example/4k.m3u8'),
          CmsEpisode(name: '臻彩视界 HDR', url: 'https://cdn.example/zhencai.m3u8'),
          CmsEpisode(name: '原画', url: 'https://cdn.example/original.mkv'),
        ],
      );
      final best = PlayerScreen.selectBestQualityVariant(epWith4k);
      expect(best.name, '第1集');
      expect(best.url, 'https://cdn.example/original.mkv');
      expect(
        PlayerScreen.rankVariantQuality(epWith4k.variants[3]),
        greaterThan(PlayerScreen.rankVariantQuality(epWith4k.variants[2])),
      );

      // When play response only provides 1080P/720P, never fabricates 4K/原画
      const ep1080Only = CmsEpisode(
        name: '第1集',
        url: 'https://cdn.example/720p.m3u8',
        variants: [
          CmsEpisode(name: '720P', url: 'https://cdn.example/720p.m3u8'),
          CmsEpisode(name: '1080P', url: 'https://cdn.example/1080p.m3u8'),
        ],
      );
      final best1080 = PlayerScreen.selectBestQualityVariant(ep1080Only);
      expect(best1080.name, '第1集');
      expect(best1080.url, 'https://cdn.example/1080p.m3u8');
      expect(best1080.variants.length, 2);

      // 2. StorageService.pickRecommendedLineIndex matches UC / Baidu / logged-in drives
      final storage = await initStorage();
      await storage.setNetdiskCredential(
        'uc',
        '__pus=demo_uc_session_token_value_123456',
      );
      expect(storage.isNetdiskLoggedIn('uc'), isTrue);
      await storage.setPreferredQuality('4k_netdisk');
      const lines = [
        CmsLine(
          name: '夸克4K',
          episodes: [CmsEpisode(name: '正片', url: 'https://pan.quark.cn/s/a')],
        ),
        CmsLine(
          name: '优汐4K',
          episodes: [CmsEpisode(name: '正片', url: 'https://drive.uc.cn/s/b')],
        ),
        CmsLine(
          name: '百度网盘',
          episodes: [CmsEpisode(name: '正片', url: 'https://pan.baidu.com/s/c')],
        ),
      ];
      expect(
        storage.pickRecommendedLineIndex(lines),
        1,
        reason: 'Logged-in UC/优汐 drive should beat unauthenticated Quark/Baidu',
      );

      // 3. CmsClient.searchAcrossSites includes WoggNetdiskAdapter 4K netdisk sites
      final requestedUrls = <String>[];
      final searchClient = CmsClient(
        client: MockClient((req) async {
          requestedUrls.add(req.url.toString());
          const html = '''
<html><body>
  <div class="module-items">
    <div class="module-search-item">
      <a href="/voddetail/8801.html" title="流浪地球2 4K">
        <img data-src="https://img.example/8801.jpg" />
        <div class="module-item-text">4K 原画</div>
      </a>
    </div>
  </div>
</body></html>
''';
          return http.Response.bytes(utf8.encode(html), 200);
        }),
      );
      const muouSite = CmsSite(
        key: 'muou_4k',
        name: '木偶4K',
        type: 3,
        api: 'csp_Muou',
        ext: 'https://muou.example/',
      );
      final searchHits = await searchClient
          .searchAcrossSites([muouSite], '流浪地球')
          .toList();
      expect(requestedUrls, isNotEmpty);
      expect(searchHits, hasLength(1));
      expect(searchHits.single.$1.key, 'muou_4k');
      expect(searchHits.single.$2.single.title, '流浪地球2 4K');
    });
  });
}

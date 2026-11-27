import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/csp_rule_engines.dart';
import 'package:marco_movie/core/guard_source.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all 21 fty Guard spider aliases map cleanly and expose clear unsupported reasons', () {
    const expected = <String, String>{
      'csp_JpysGuard': 'jpys-v1',
      'csp_JpjGuard': 'jpj-v1',
      'csp_NmyswvGuard': 'nmyswv-v1',
      'csp_HmysGuard': 'hmys-v1',
      'csp_App99Guard': 'app99-v1',
      'csp_AppSxGuard': 'appsx-v1',
      'csp_NewCzGuard': 'newcz-v1',
      'csp_LibvioGuard': 'libvio-v1',
      'csp_YGPGuard': 'ygp-v1',
      'csp_KanqiuGuard': 'kanqiu-v1',
      'csp_DoubaoGuard': 'doubao-v1',
      'csp_LivegzGuard': 'livegz-v1',
      'csp_AllliveGuard': 'alllive-v1',
      'csp_Tingshu275Guard': 'tingshu275-v1',
      'csp_YuetingGuard': 'yueting-v1',
      'csp_SeedHubGuard': 'seedhub-v1',
      'csp_S_zpsGuard': 'szps-v1',
      'csp_YpansoGuard': 'ypanso-v1',
      'csp_BpansoGuard': 'bpanso-v1',
      'csp_KkssGuard': 'kkss-v1',
      'csp_UussGuard': 'uuss-v1',
    };
    for (final entry in expected.entries) {
      final site = CmsSite(
        key: entry.key,
        name: entry.key,
        type: 3,
        api: entry.key,
        spider: 'https://import.invalid/fty.jar;md5;d41d8cd98f00b204e9800998ecf8427e',
        ext: 'https://configured.invalid/ext',
      );
      expect(CspBridge.guardAdapterFor(site), entry.value, reason: entry.key);
      expect(GuardSource.supports(site), isTrue, reason: entry.key);
      expect(site.canBrowse, isTrue, reason: entry.key);
      expect(CspBridge.backendsForSite(site), isEmpty, reason: entry.key);
    }

    const sixv = CmsSite(key: 'sixv', name: '新6V', type: 3, api: 'csp_SixVGuard');
    const music = CmsSite(key: 'music', name: '酷狗', type: 3, api: 'csp_MusicGuard');
    const aidj = CmsSite(key: 'aidj', name: 'AI剧', type: 3, api: 'csp_AiDjGuard');
    expect(sixv.unsupportedReason, contains('磁力'));
    expect(music.unsupportedReason, contains('验证'));
    expect(aidj.unsupportedReason, contains('加密'));

    const adNotice = CmsSite(key: 'cc', name: '请勿信视频中任何广告', type: 3, api: 'csp_Douban');
    const pushSite = CmsSite(key: 'push_agent', name: '推送', type: 3, api: 'csp_PushGuard');
    const myDrive = CmsSite(key: 'mydrive', name: '我的云盘', type: 3, api: 'csp_MyDriveGuard');
    expect(CspBridge.isPickerHiddenUtilitySite(adNotice), isTrue);
    expect(CspBridge.isPickerHiddenUtilitySite(pushSite), isTrue);
    expect(CspBridge.isPickerHiddenUtilitySite(myDrive), isFalse);
  });

  test('CmsParser resolves relative ext map paths and extracts Douban & RT scores', () {
    final cfg = CmsParser.parseConfig(
      jsonEncode({
        'sites': [
          {
            'key': 'bili',
            'name': '哔哩合集',
            'type': 3,
            'api': 'csp_BiliGuard',
            'ext': {'json': './json/bili.json'},
          },
          {
            'key': 'xyq',
            'name': '香雅情规则',
            'type': 3,
            'api': 'csp_XYQ',
            'ext': {'url': './XYQ/rule.json'},
          },
        ],
      }),
      origin: 'https://sub.invalid/tvbox/api.json',
    );
    final biliExt = jsonDecode(cfg.sites[0].ext) as Map<String, dynamic>;
    final xyqExt = jsonDecode(cfg.sites[1].ext) as Map<String, dynamic>;
    expect(biliExt['json'], 'https://sub.invalid/tvbox/json/bili.json');
    expect(xyqExt['url'], 'https://sub.invalid/tvbox/XYQ/rule.json');
    expect(cfg.sites[1].canBrowse, isTrue);

    final listing = CmsParser.parseListing(jsonEncode({
      'list': [
        {
          'vod_id': '101',
          'vod_name': '测试高分片',
          'vod_douban_score': '8.8',
          'vod_remarks': 'HD中字',
          'vod_content': '该片烂番茄新鲜度 95%，口碑极佳。',
          'vod_play_from': '直连',
          'vod_play_url': r'正片$https://media.invalid/101.m3u8',
        },
        {
          'vod_id': '102',
          'vod_name': '无评分片',
          'vod_douban_score': '0.0',
          'vod_remarks': '更新至第8集',
          'vod_content': '普通剧情简介，没有任何评分信息。',
        },
      ],
    }));
    expect(listing.videos[0].doubanScore, 8.8);
    expect(listing.videos[0].rtScore, 95);
    expect(listing.videos[1].doubanScore, isNull);
    expect(listing.videos[1].rtScore, isNull);
  });

  test('CspRuleEngines evaluates XBPQ, XYQ, XPath and api.php/v1.vod end-to-end', () async {
    const xbpqRule = '''
    {
      // XBPQ comment with trailing comma
      "主页url": "https://xbpq.invalid",
      "分类": "电影\$1#剧集\$2",
      "分类url": "https://xbpq.invalid/cate/{cateId}-{catePg}.html",
      "搜索url": "https://xbpq.invalid/search.php?wd={wd}",
      "数组": "<div class=\\"card\\">&&</div>",
      "标题": "title=\\"&&\\"",
      "链接": "href=\\"&&\\"",
      "图片": "data-pic=\\"&&\\"",
      "副标题": "<span>&&</span>",
      "线路数组": "<div class=\\"tab\\">&&</div>",
      "线路标题": ">&&<",
      "播放数组": "<ul class=\\"plist\\">&&</ul>",
      "播放列表": "<a&&</a>",
      "播放标题": ">&&<",
      "播放链接": "href=\\"&&\\"",
      "简介": "<p class=\\"desc\\">&&</p>",
    }
    ''';
    final xbpqSite = CmsSite(
      key: 'xbpq_demo',
      name: 'XBPQ测试',
      type: 3,
      api: 'csp_XBPQ',
      ext: xbpqRule,
    );
    expect(CspRuleEngines.supports(xbpqSite), isTrue);
    expect(xbpqSite.canBrowse, isTrue);

    final encodedStream = base64Encode(
      utf8.encode('https://cdn.invalid/stream/ep1.m3u8'),
    );
    Future<String> mockFetch(
      String url, {
      Map<String, String> headers = const {},
      Duration? requestTimeout,
    }) async {
      if (url.contains('/cate/') || url == 'https://xbpq.invalid' || url.contains('/search.php')) {
        return '<div class="card"><a href="/detail/9.html" title="测试电影"><img data-pic="/p.jpg"/><span>HD</span></a></div>';
      }
      if (url.endsWith('/detail/9.html')) {
        return '<div class="tab"><span>极速线</span></div>'
            '<p class="desc">精彩剧情简介</p>'
            '<ul class="plist"><a href="/play/9-1-1.html">第01集</a></ul>';
      }
      if (url.endsWith('/play/9-1-1.html')) {
        return '<script>var player_aaaa={"encrypt":2,"url":"$encodedStream"}<\\/script>';
      }
      if (url.contains('/api.php/v1.vod/types')) {
        return jsonEncode({
          'data': {
            'typelist': [
              {'type_id': 1, 'type_name': '动作片'},
            ],
          },
        });
      }
      if (url.contains('/api.php/v1.vod/detail')) {
        return jsonEncode({
          'data': {
            'vod_id': 77,
            'vod_name': '如意测试片',
            'vod_play_list': {
              'lzm3u8': {
                'player_info': {'show': '量子超清'},
                'url': r'第1集$https://cdn.invalid/lz/1.m3u8',
              },
            },
          },
        });
      }
      if (url.contains('/api.php/v1.vod')) {
        return jsonEncode({
          'data': {
            'page': 1,
            'total': 1,
            'limit': 20,
            'list': [
              {'vod_id': 77, 'vod_name': '如意测试片', 'vod_pic': 'https://cdn.invalid/77.jpg'},
            ],
          },
        });
      }
      throw StateError('Unexpected URL: $url');
    }

    final (cats, home) = await CspBridge.fetchHome(xbpqSite, mockFetch);
    expect(cats.map((c) => c.name), ['电影', '剧集']);
    expect(home.videos.single.title, '测试电影');
    final detail = await CspBridge.fetchDetail(xbpqSite, home.videos.single, mockFetch);
    expect(detail.lines.single.name, '极速线');
    final resolvedEp = await CspBridge.resolveEpisodeForPlayback(
      xbpqSite,
      detail.lines.single.episodes.single,
      mockFetch,
    );
    expect(resolvedEp.url, 'https://cdn.invalid/stream/ep1.m3u8');

    const v1Site = CmsSite(
      key: 'v1vod',
      name: 'V1接口',
      type: 3,
      api: 'csp_AppYsV2',
      ext: 'https://v1.invalid/api.php/v1.vod',
    );
    final (v1Cats, v1Home) = await CspBridge.fetchHome(v1Site, mockFetch);
    expect(v1Cats.single.name, '动作片');
    expect(v1Home.videos.single.title, '如意测试片');
    final v1Detail = await CspBridge.fetchDetail(v1Site, v1Home.videos.single, mockFetch);
    expect(v1Detail.lines.single.name, '量子超清');
    expect(v1Detail.lines.single.episodes.single.url, 'https://cdn.invalid/lz/1.m3u8');
  });

  test('CmsClient expands mmshare:// cloud links, caches detail, and races fast VOD sources first', () async {
    int detailHits = 0;
    final slowStarted = Completer<void>();
    final transport = MockClient((request) async {
      if (request.url.host == 't4-pan.invalid') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'list': [
              {
                'vod_id': 'pan-1',
                'vod_name': '网盘剧集',
                'vod_play_from': r'UC网盘$$$失效百度',
                'vod_play_url':
                    r'分享$mmshare://https://drive.uc.cn/s/ucfix$$$分享$mmshare://https://pan.baidu.com/s/1dead',
              },
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.host == 'pan.baidu.com') {
        return http.Response('expired', 404);
      }
      if (request.url.host == 'pc-api.uc.cn') {
        if (request.url.path.endsWith('/token')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'status': 200,
              'code': 0,
              'data': {'stoken': 'tok-1'},
            })),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 200,
            'code': 0,
            'metadata': {'_total': 1},
            'data': {
              'list': [
                {
                  'fid': 'uc-fid-1',
                  'file_name': 'S01E01.2160p.mkv',
                  'file': true,
                  'format_type': 'video/x-matroska',
                },
              ],
            },
          })),
          200,
        );
      }
      if (request.url.host == 'slow.invalid') {
        if (!slowStarted.isCompleted) slowStarted.complete();
        await Future<void>.delayed(const Duration(seconds: 4));
        return http.Response('{"list":[]}', 200);
      }
      if (request.url.host == 'fast.invalid') {
        if (request.url.queryParameters['ac'] == 'detail' &&
            request.url.queryParameters.containsKey('ids')) {
          detailHits++;
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'list': [
              {
                'vod_id': 'fast-9',
                'vod_name': '星际穿越',
                'vod_year': '2014',
                'vod_play_from': '极速m3u8',
                'vod_play_url': r'正片$https://cdn.invalid/interstellar.m3u8',
              },
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{"list":[]}', 200);
    });

    final client = CmsClient(client: transport);
    const panT4Site = CmsSite(
      key: 'pan_t4',
      name: '网盘T4',
      type: 4,
      api: 'https://t4-pan.invalid/vod',
    );
    final expanded = await client.fetchDetail(
      panT4Site,
      const CmsVideo(id: 'pan-1', title: '网盘剧集'),
    );
    expect(expanded.lines, hasLength(1));
    expect(expanded.lines.single.episodes.single.cloudProvider, 'uc');
    expect(expanded.sourceWarnings, isNotEmpty);

    // SingleFlight + DetailCache verification
    const fastSite = CmsSite(
      key: 'fast',
      name: '秒播源',
      type: 1,
      api: 'https://fast.invalid/api.php/provide/vod/',
    );
    final pair = await Future.wait([
      client.fetchDetail(fastSite, const CmsVideo(id: 'fast-9', title: '星际穿越')),
      client.fetchDetail(fastSite, const CmsVideo(id: 'fast-9', title: '星际穿越')),
    ]);
    expect(pair[0].lines, isNotEmpty);
    expect(detailHits, 1);
    await client.fetchDetail(fastSite, const CmsVideo(id: 'fast-9', title: '星际穿越'));
    expect(detailHits, 1);

    // Fast-winner playableDetail race (does not wait 4s for slow.invalid)
    const doubanSite = CmsSite(
      key: 'douban',
      name: '豆瓣片单',
      type: 3,
      api: 'csp_DouDouGuard',
    );
    const slowNetdiskSite = CmsSite(
      key: 'slow_pan',
      name: '玩偶4K云盘',
      type: 1,
      api: 'https://slow.invalid/api.php/provide/vod/',
    );
    final sw = Stopwatch()..start();
    final (winnerSite, matchedVideo) = await client.playableDetail(
      doubanSite,
      const CmsVideo(
        id: 'msearch:星际穿越',
        title: '星际穿越',
        year: '2014',
        doubanScore: 9.4,
      ),
      [slowNetdiskSite, fastSite],
    );
    sw.stop();
    expect(winnerSite.key, 'fast');
    expect(matchedVideo.doubanScore, 9.4);
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });

  testWidgets(
    'DetailScreen shows Douban & RT badges when real data exists and strictly hides missing ones',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      const site = CmsSite(
        key: 'vod1',
        name: '极速专线',
        type: 1,
        api: 'https://vod1.invalid/api',
      );
      final mockClient = CmsClient(
        client: MockClient((_) async => http.Response('{"list":[]}', 200)),
      );

      // Case 1: Both Douban and Rotten Tomatoes scores exist + immediate frame-1 episode rendering (portrait iPhone)
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PosterLoader.debugSeedRatings('奥本海默', year: '2023', douban: 8.8, rt: 93);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: DetailScreen(
            site: site,
            initialVideo: const CmsVideo(
              id: 'opp-1',
              title: '奥本海默',
              year: '2023',
              lines: [
                CmsLine(
                  name: '蓝光',
                  episodes: [CmsEpisode(name: '正片', url: 'https://vod1.invalid/opp.m3u8')],
                ),
              ],
            ),
            client: mockClient,
            storage: storage,
          ),
        ),
      );
      // Frame 1: episodes and both rating capsules are already visible without waiting!
      expect(find.byKey(const ValueKey('ep_card_0_0')), findsOneWidget);
      expect(find.text('全部剧集 (1)'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-douban-badge')), findsOneWidget);
      expect(find.text('豆瓣 ★ 8.8'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-rt-badge')), findsOneWidget);
      expect(find.text('烂番茄 93%'), findsOneWidget);

      // Case 2: Widescreen iPad layout + only Douban exists -> RT badge hidden
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      PosterLoader.debugSeedRatings('漫长的季节', year: '2023', douban: 9.4, rt: null);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: DetailScreen(
            key: const ValueKey('case-2'),
            site: site,
            initialVideo: const CmsVideo(
              id: 'long-1',
              title: '漫长的季节',
              year: '2023',
              lines: [
                CmsLine(
                  name: '蓝光',
                  episodes: [CmsEpisode(name: '第1集', url: 'https://vod1.invalid/1.m3u8')],
                ),
              ],
            ),
            client: mockClient,
            storage: storage,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('ep_card_0_0')), findsOneWidget);
      expect(find.text('豆瓣 ★ 9.4'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-rt-badge')), findsNothing);

      // Case 3: Neither Douban nor Rotten Tomatoes exists -> BOTH badges strictly hidden
      PosterLoader.debugSeedRatings('冷门自制短剧', year: '2026', douban: null, rt: null);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            key: const ValueKey('case-3'),
            site: site,
            initialVideo: const CmsVideo(
              id: 'obscure-1',
              title: '冷门自制短剧',
              year: '2026',
              lines: [
                CmsLine(
                  name: '直连',
                  episodes: [CmsEpisode(name: '第1集', url: 'https://vod1.invalid/s1.m3u8')],
                ),
              ],
            ),
            client: mockClient,
            storage: storage,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('detail-douban-badge')), findsNothing);
      expect(find.byKey(const ValueKey('detail-rt-badge')), findsNothing);
      expect(find.text('极速专线'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

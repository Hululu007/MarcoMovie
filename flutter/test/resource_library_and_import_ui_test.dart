import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/emby_library.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/add_resource_library_sheet.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('EmbyLibrary composeAddress & parseAddressToSpec handle HTTP/8096, HTTPS/8920, and /web cleanup', () {
    expect(
      EmbyLibrary.composeAddress(
        useHttps: false,
        host: 'emby.example',
        portText: '8096',
        path: '',
      ),
      'http://emby.example:8096',
    );
    expect(
      EmbyLibrary.composeAddress(
        useHttps: true,
        host: 'emby.example',
        portText: '8920',
        path: 'media',
      ),
      'https://emby.example:8920/media',
    );
    final spec = EmbyLibrary.parseAddressToSpec(
      'http://nas.example:8096/emby/web/index.html#!/home',
    );
    expect(spec.useHttps, isFalse);
    expect(spec.host, 'nas.example');
    expect(spec.port, 8096);
    expect(spec.path, '/emby');
  });

  test('EmbyLibrary supports bare-root fallback, same-origin redirects, external .strm DirectPlay, and empty Views fallback', () async {
    final prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevHttpOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/emby/Users/AuthenticateByName') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (path == '/Users/AuthenticateByName') {
        req.response.statusCode = 307;
        req.response.headers.set('Location', '/Users/AuthenticateByNameReal');
        await req.response.close();
        return;
      }
      if (path == '/Users/AuthenticateByNameReal') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'User': {'Id': 'u1'},
          'AccessToken': 'tok-1',
        }));
        await req.response.close();
        return;
      }
      if (path == '/Users/u1/Views') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'Items': []}));
        await req.response.close();
        return;
      }
      if (path == '/Users/u1/Items') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'Items': [], 'TotalRecordCount': 0}));
        await req.response.close();
        return;
      }
      if (path == '/Items/strm1/PlaybackInfo') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'PlaySessionId': 'ps-strm',
          'MediaSources': [
            {
              'Id': 'ms-strm',
              'SupportsDirectPlay': true,
              'SupportsDirectStream': false,
              'Protocol': 'Http',
              'Path': 'https://cdn.example/strm-video.mp4',
              'RequiredHttpHeaders': {'User-Agent': 'CustomPlayer'},
            },
          ],
        }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final baseUri = 'http://127.0.0.1:${server.port}';
    final entry = await EmbyLibrary.login(
      baseUri,
      'alice',
      'pw',
      group: '默认分组',
      isPrivate: false,
      label: '家庭媒体库',
      allowCloudSync: false,
    );
    expect(entry.name, '家庭媒体库');
    final savedMeta = await EmbyLibrary.loadSavedAccountMeta(entry.id);
    expect(savedMeta?.allowCloudSync, isFalse);
    expect(savedMeta?.label, '家庭媒体库');

    final siteMap =
        (jsonDecode(entry.rawContent)['sites'] as List).first as Map<String, dynamic>;
    final site = CmsSite(
      key: siteMap['key'].toString(),
      name: siteMap['name'].toString(),
      type: (siteMap['type'] as num).toInt(),
      api: siteMap['api'].toString(),
    );
    final lib = await EmbyLibrary.open(site);
    final (cats, _) = await lib.home();
    expect(cats.length, 1);
    expect(cats.first.name, '全部媒体');

    final strmEp = await lib.resolve(
      const CmsEpisode(name: 'STRM', url: 'mmemby://play?id=strm1&source=ms-strm'),
    );
    expect(strmEp.url, 'https://cdn.example/strm-video.mp4');
    expect(strmEp.headers, isEmpty);
  });

  testWidgets('Emby form in AddResourceLibraryView uses unified accent submit button & splits pasted HTTP URL', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService(prefs);
    final client = CmsClient(
      client: MockClient((_) async => http.Response('{"class":[],"list":[]}', 200)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: AddResourceLibraryView(
            storage: storage,
            client: client,
            onLibraryAdded: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('add-lib-tile-emby')));
    await tester.pumpAndSettle();

    expect(find.text('是否允许云端同步'), findsOneWidget);
    expect(find.text('HTTPS'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('路径'), findsOneWidget);
    expect(find.text('端口号'), findsOneWidget);

    final httpsSwitch = tester.widget<CupertinoSwitch>(
      find.byKey(const ValueKey('emby-https-switch')),
    );
    expect(httpsSwitch.value, isFalse);

    final submitBtn = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('emby-submit-btn')),
    );
    expect(submitBtn.color, ApplePalette.light.accent);
    expect(submitBtn.color, isNot(const Color(0xFF52B54B)));

    await tester.enterText(
      find.byKey(const ValueKey('emby-host-input')),
      'http://nas.example:8096/emby',
    );
    await tester.pump();
    expect(find.widgetWithText(CupertinoTextField, '/emby'), findsOneWidget);
    expect(find.widgetWithText(CupertinoTextField, '8096'), findsOneWidget);
  });

  test('CmsClient preserves real share IDs over placeholder "0"/"1" and recovers 聚剧|四盘 inline history', () async {
    expect(CmsClient.isGenericPlaceholderVodId(''), isTrue);
    expect(CmsClient.isGenericPlaceholderVodId('0'), isTrue);
    expect(CmsClient.isGenericPlaceholderVodId('1'), isTrue);
    expect(CmsClient.isGenericPlaceholderVodId('https://pan.quark.cn/s/jujuRecovered4k'), isFalse);

    final stubClient = _StubPansouCmsClient();
    const jujuSite = CmsSite(
      key: 'zpan',
      name: '聚剧|四盘',
      type: 3,
      api: 'csp_S_zpsGuard',
      searchable: true,
    );

    // Case 1: Placeholder "0" saved in WatchHistory skips broken /api/detail and recovers inline search lines.
    final (owner1, recovered1) = await stubClient.playableDetail(
      jujuSite,
      const CmsVideo(id: '0', title: '藏海传 [4K]'),
      [jujuSite],
    );
    expect(owner1.key, 'zpan');
    expect(stubClient.detailCalls, 0);
    expect(stubClient.searchCalls, 1);
    expect(recovered1.id, 'https://pan.quark.cn/s/jujuRecovered4k');
    expect(recovered1.lines.single.episodes.single.name, '第1集');

    // Case 2: Expired PanSou detail ID throws 404 -> falls back to inline search lines without looping.
    final (_, recovered2) = await stubClient.playableDetail(
      jujuSite,
      const CmsVideo(id: 'https://pan.quark.cn/s/expiredId', title: '藏海传'),
      [jujuSite],
    );
    expect(stubClient.detailCalls, 1);
    expect(stubClient.searchCalls, 2);
    expect(recovered2.id, 'https://pan.quark.cn/s/jujuRecovered4k');
    expect(recovered2.lines.single.episodes.single.name, '第1集');
  });
}

class _StubPansouCmsClient extends CmsClient {
  int detailCalls = 0;
  int searchCalls = 0;

  @override
  Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo fallback, {
    bool forceRefresh = false,
  }) async {
    detailCalls++;
    throw Exception('HTTP 404 from /api/detail');
  }

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    searchCalls++;
    return CmsListing(
      videos: [
        CmsVideo(
          id: 'https://pan.quark.cn/s/jujuRecovered4k',
          title: '$keyword [4K HDR]',
          lines: const [
            CmsLine(
              name: '夸克原画',
              episodes: [
                CmsEpisode(
                  name: '第1集',
                  url: 'https://pan.quark.cn/s/jujuRecovered4k',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

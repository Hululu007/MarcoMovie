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

  test('EmbyLibrary structured URL assembler & splitter handle HTTP/8096, HTTPS/8920, and /web cleanup', () {
    expect(
      EmbyLibrary.resolveServerUrl(
        hostOrUrl: 'emby.example',
        useHttps: false,
        port: '8096',
        subpath: '',
      ).toString(),
      'http://emby.example:8096',
    );
    expect(
      EmbyLibrary.resolveServerUrl(
        hostOrUrl: 'emby.example',
        useHttps: true,
        port: '8920',
        subpath: 'media',
      ).toString(),
      'https://emby.example:8920/media',
    );
    final split = EmbyLibrary.splitServerUrl('http://nas.example:8096/emby/web/index.html#!/home');
    expect(split.useHttps, isFalse);
    expect(split.host, 'nas.example');
    expect(split.port, '8096');
    expect(split.subpath, '/emby');
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
              'Path': 'https://cdn.example/strm-video.mp4',
              'RequiredHttpHeaders': {'User-Agent': 'CustomPlayer'},
            },
          ],
        }));
        await req.response.close();
        return;
      }
      if (path == '/Users/u1/RedirectForeign') {
        req.response.statusCode = 302;
        req.response.headers.set('Location', 'http://foreign.example/leak');
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
    expect(entry.name, 'Emby · 家庭媒体库');
    final savedCfg = await EmbyLibrary.readAccountConfig(entry.id);
    expect(savedCfg?['allowCloudSync'], isFalse);
    expect(savedCfg?['label'], '家庭媒体库');

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
    expect(strmEp.headers['User-Agent'], 'CustomPlayer');
    expect(strmEp.headers.containsKey('X-Emby-Token'), isFalse);
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

    final httpsSwitch = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch).at(1));
    expect(httpsSwitch.value, isFalse);

    final submitBtn = tester.widget<CupertinoButton>(
      find.widgetWithText(CupertinoButton, '验证并添加资源库'),
    );
    expect(submitBtn.color, ApplePalette.light.accent);
    expect(submitBtn.color, isNot(const Color(0xFF52B54B)));

    // Paste full HTTP URL into 服务器地址 -> splits cleanly into host/port/path
    await tester.enterText(
      find.widgetWithText(CupertinoTextField, 'emby.example 或粘贴完整 URL'),
      'http://nas.example:8096/emby',
    );
    await tester.pump();
    expect(find.widgetWithText(CupertinoTextField, 'nas.example'), findsOneWidget);
  });
}

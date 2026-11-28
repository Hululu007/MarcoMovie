import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/emby_library.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/add_resource_library_sheet.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // Allow real loopback HttpServer / TCP sockets in mixed widget + IO tests.
    HttpOverrides.global = null;
  });

  group('Emby address composition & spec parsing', () {
    test('composes HTTP :8096, HTTPS :443/:8920, custom /path and cleans pasted browser URLs', () {
      expect(
        EmbyLibrary.composeAddress(
          useHttps: false,
          host: 'emby.example.com',
          portText: '8096',
        ),
        'http://emby.example.com:8096',
      );
      expect(
        EmbyLibrary.composeAddress(
          useHttps: true,
          host: 'emby.example.com',
          path: 'emby',
          portText: '443',
        ),
        'https://emby.example.com/emby',
      );
      expect(
        EmbyLibrary.composeAddress(
          useHttps: true,
          host: 'https://emby.example.com:8920/media/web/index.html#!/home',
          path: '',
          portText: '',
        ),
        'https://emby.example.com:8920/media',
      );
      expect(
        () => EmbyLibrary.composeAddress(
          useHttps: false,
          host: 'emby.example.com',
          portText: '99999',
        ),
        throwsFormatException,
      );

      final parsed = EmbyLibrary.parseAddressToSpec(
        'https://emby.example.com:8443/library',
      );
      expect(parsed.useHttps, isTrue);
      expect(parsed.host, 'emby.example.com');
      expect(parsed.port, 8443);
      expect(parsed.path, '/library');
    });
  });

  group('Emby protocol fallback, redirects, headers & DirectPlay/STRM', () {
    test('falls back from /emby 404 to bare root, sends X-Emby-Authorization & custom User-Agent, and persists across open()', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final paths = <String>[];
      String? seenXEmbyAuth;
      String? seenUserAgent;
      Map<String, dynamic>? seenPlaybackBody;

      server.listen((req) async {
        final p = req.uri.path;
        paths.add(p);
        seenXEmbyAuth ??= req.headers.value('X-Emby-Authorization');
        seenUserAgent ??= req.headers.value(HttpHeaders.userAgentHeader);
        if (p == '/emby/Users/AuthenticateByName') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        if (p == '/Users/AuthenticateByName') {
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          expect(body['Username'], 'demo_user');
          expect(body['Pw'], '');
          req.response.write(jsonEncode({
            'AccessToken': 'test-only-bare-token',
            'User': {'Id': 'u-bare'},
          }));
          await req.response.close();
          return;
        }
        if (p == '/Users/u-bare/Views') {
          req.response.write(jsonEncode({
            'Items': [
              {'Id': 'v1', 'Name': '4K 电影'},
            ],
          }));
          await req.response.close();
          return;
        }
        if (p == '/Users/u-bare/Items') {
          req.response.write(jsonEncode({
            'Items': [
              {'Id': 'm1', 'Name': '示例影片', 'Type': 'Movie'},
            ],
            'TotalRecordCount': 1,
          }));
          await req.response.close();
          return;
        }
        if (p == '/Items/m1/PlaybackInfo') {
          seenPlaybackBody =
              jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
          req.response.write(jsonEncode({
            'PlaySessionId': 'ps-4k',
            'MediaSources': [
              {
                'Id': 'src-strm',
                'SupportsDirectPlay': true,
                'Protocol': 'Http',
                'Path': 'https://cdn.example.net/stream/4k-sample.mkv',
              },
            ],
          }));
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final entry = await EmbyLibrary.login(
        'http://127.0.0.1:${server.port}',
        'demo_user',
        '',
        label: '4K影视库',
        allowCloudSync: true,
        group: '主力影视',
        isPrivate: false,
      );

      expect(entry.name, '4K影视库');
      expect(paths, [
        '/emby/Users/AuthenticateByName',
        '/Users/AuthenticateByName',
        '/Users/u-bare/Views',
      ]);
      expect(seenXEmbyAuth, contains('MediaBrowser Client="Marco Movie"'));
      expect(seenUserAgent, startsWith('MarcoMovie/'));

      final site = CmsSite(
        key: entry.id,
        name: entry.name,
        type: 1,
        api: '${EmbyLibrary.prefix}${entry.id.substring(5)}',
      );
      final opened = await EmbyLibrary.open(site);
      expect(opened.base.path, isEmpty);

      final views = await opened.home();
      expect(views.$1.single.name, '4K 电影');

      // DirectPlay enabled & HEVC included; cross-origin HTTP STRM omits X-Emby-Token.
      final resolved = await opened.resolve(
        const CmsEpisode(name: '正片', url: 'mmemby://play?id=m1&source=src-strm'),
      );
      expect(seenPlaybackBody?['EnableDirectPlay'], isTrue);
      expect(
        seenPlaybackBody?['DeviceProfile']?['DirectPlayProfiles']?[0]?['VideoCodec'],
        contains('hevc'),
      );
      expect(resolved.url, 'https://cdn.example.net/stream/4k-sample.mkv');
      expect(resolved.headers, isEmpty);

      final meta = await EmbyLibrary.loadSavedAccountMeta(entry.id);
      expect(meta, isNotNull);
      expect(meta!.label, '4K影视库');
      expect(meta.allowCloudSync, isTrue);
      expect(meta.useHttps, isFalse);
      expect(meta.host, '127.0.0.1');
      expect(meta.port, server.port);
      expect(meta.username, 'demo_user');
    });

    test('follows same-host 307 redirect on login without dropping POST body', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final p = req.uri.path;
        if (p == '/emby/Users/AuthenticateByName') {
          req.response.statusCode = 307;
          req.response.headers.set('Location', '/v2/emby/Users/AuthenticateByName');
        } else if (p == '/v2/emby/Users/AuthenticateByName') {
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          expect(body['Pw'], 'test-only-password');
          req.response.write(jsonEncode({
            'AccessToken': 'test-only-redir-token',
            'User': {'Id': 'u-redir'},
          }));
        } else if (p == '/emby/Users/u-redir/Views') {
          req.response.write(jsonEncode({'Items': []}));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final entry = await EmbyLibrary.login(
        'http://127.0.0.1:${server.port}',
        'demo_user',
        'test-only-password',
        group: '默认分组',
        isPrivate: false,
      );
      expect(entry.id, startsWith('emby_'));
    });

    test('surfaces clear Chinese TLS guidance when connecting HTTPS to an HTTP socket', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.write('HTTP/1.1 plain text');
        await req.response.close();
      });

      await expectLater(
        EmbyLibrary.login(
          'https://127.0.0.1:${server.port}',
          'demo_user',
          'test-only-password',
          group: '默认分组',
          isPrivate: false,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTP'), contains('HTTPS')),
          ),
        ),
      );
    });
  });

  group('Emby allowCloudSync isolation & two-device sync', () {
    test('syncs allowCloudSync=true Emby libraries & accounts while keeping allowCloudSync=false local and exportBackupJson() token-free', () async {
      Future<HttpServer> startMockEmby(String token) async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          final p = req.uri.path;
          if (p.endsWith('/Users/AuthenticateByName')) {
            req.response.write(jsonEncode({
              'AccessToken': token,
              'User': {'Id': 'u1'},
            }));
          } else if (p.endsWith('/Views')) {
            req.response.write(jsonEncode({
              'Items': [
                {'Id': 'v1', 'Name': '电影'},
              ],
            }));
          } else {
            req.response.statusCode = 404;
          }
          await req.response.close();
        });
        return server;
      }

      final cloudServer = await startMockEmby('test-only-cloud-token');
      final localServer = await startMockEmby('test-only-local-token');

      SharedPreferences.setMockInitialValues({});
      final deviceA = await StorageService.init();

      final cloudEntry = await EmbyLibrary.login(
        'http://127.0.0.1:${cloudServer.port}',
        'demo_user',
        'test-only-pass',
        label: '云端同步 Emby',
        allowCloudSync: true,
        group: '主力影视',
        isPrivate: false,
      );
      final localOnlyEntry = await EmbyLibrary.login(
        'http://127.0.0.1:${localServer.port}',
        'demo_user',
        'test-only-pass',
        label: '仅本机 Emby',
        allowCloudSync: false,
        group: '主力影视',
        isPrivate: false,
      );
      await deviceA.upsertSubscriptions([cloudEntry, localOnlyEntry]);

      // Standard local backup must never leak Emby tokens.
      final backupJson = deviceA.exportBackupJson();
      expect(backupJson, isNot(contains('test-only-cloud-token')));
      expect(backupJson, isNot(contains('test-only-local-token')));

      // Cloud sync payload includes allowCloudSync=true Emby + credentials, but omits allowCloudSync=false.
      final syncJson = deviceA.exportSyncPayload();
      expect(syncJson, contains('云端同步 Emby'));
      expect(syncJson, contains('test-only-cloud-token'));
      expect(syncJson, isNot(contains('仅本机 Emby')));
      expect(syncJson, isNot(contains('test-only-local-token')));

      // Second device imports sync payload and can immediately open the synced Emby library.
      SharedPreferences.setMockInitialValues({});
      final deviceB = await StorageService.init();
      final mergeRes = await deviceB.mergeSyncPayload(syncJson);
      expect(mergeRes.subscriptionsChanged, isTrue);
      expect(deviceB.getSubscriptions().map((e) => e.name), ['云端同步 Emby']);
      final siteOnB = deviceB.loadSavedConfig()!.supportedSites.single;
      final libOnB = await EmbyLibrary.open(siteOnB);
      expect(libOnB.token, 'test-only-cloud-token');
    });
  });

  group('iOS structured Emby form widget flow', () {
    testWidgets(
      'tapping Emby in AddResourceLibraryView opens structured HTTP 8096 form with toggles, password eye & end-to-end save',
      (tester) async {
        HttpOverrides.global = null;
        SharedPreferences.setMockInitialValues({});
        final storage = (await tester.runAsync(() => StorageService.init()))!;
        final server = (await tester.runAsync(
          () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        ))!;
        server.idleTimeout = null;
        try {
          server.listen((req) async {
            final p = req.uri.path;
            if (p == '/Users/AuthenticateByName') {
              final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
              expect(body['Username'], 'demo_user');
              expect(body['Pw'], 'p@ss with space');
              req.response.write(jsonEncode({
                'AccessToken': 'test-only-widget-token',
                'User': {'Id': 'u-widget'},
              }));
            } else if (p == '/Users/u-widget/Views') {
              req.response.write(jsonEncode({
                'Items': [
                  {'Id': 'v1', 'Name': '4K库'},
                ],
              }));
            } else {
              req.response.statusCode = 404;
            }
            await req.response.close();
          });

          var addedCallbacks = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: IosSettingsScaffold(
                title: '添加资源库',
                body: AddResourceLibraryView(
                  storage: storage,
                  client: CmsClient(),
                  onLibraryAdded: () => addedCallbacks++,
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));

          await tester.tap(find.byKey(const ValueKey('add-lib-tile-emby')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          expect(find.text('连接 Emby 媒体库'), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-name-input')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-cloud-sync-switch')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-https-switch')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-host-input')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-path-input')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-port-input')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-user-input')), findsOneWidget);
          expect(find.byKey(const ValueKey('emby-pass-input')), findsOneWidget);

          // HTTPS defaults to OFF and port defaults to 8096.
          expect(
            tester
                .widget<CupertinoSwitch>(
                  find.byKey(const ValueKey('emby-https-switch')),
                )
                .value,
            isFalse,
          );
          expect(
            tester
                .widget<CupertinoSwitch>(
                  find.byKey(const ValueKey('emby-cloud-sync-switch')),
                )
                .value,
            isTrue,
          );
          expect(
            tester
                .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('emby-port-input')),
                )
                .controller
                ?.text,
            '8096',
          );

          // Toggling HTTPS ON switches default port 8096 -> 443 and toggling OFF restores 8096.
          await tester.tap(find.byKey(const ValueKey('emby-https-switch')));
          await tester.pump();
          expect(
            tester
                .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('emby-port-input')),
                )
                .controller
                ?.text,
            '443',
          );
          await tester.tap(find.byKey(const ValueKey('emby-https-switch')));
          await tester.pump();
          expect(
            tester
                .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('emby-port-input')),
                )
                .controller
                ?.text,
            '8096',
          );

          // Password visibility eye toggles obscureText cleanly.
          final eyeBtn = find.byKey(const ValueKey('emby-pass-visibility-btn'));
          await tester.ensureVisible(eyeBtn);
          await tester.pump();
          expect(
            tester
                .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('emby-pass-input')),
                )
                .obscureText,
            isTrue,
          );
          await tester.tap(eyeBtn);
          await tester.pump();
          expect(
            tester
                .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('emby-pass-input')),
                )
                .obscureText,
            isFalse,
          );

          Future<void> typeField(String key, String value) async {
            final finder = find.byKey(ValueKey(key));
            await tester.ensureVisible(finder);
            await tester.pump();
            await tester.enterText(finder, value);
          }

          await typeField('emby-name-input', '家庭4K库');
          await typeField('emby-host-input', '127.0.0.1');
          await typeField('emby-port-input', '${server.port}');
          await typeField('emby-user-input', 'demo_user');
          await typeField('emby-pass-input', 'p@ss with space');
          await tester.pump();

          expect(
            find.text('连接地址预览：http://127.0.0.1:${server.port}'),
            findsOneWidget,
          );

          final submitFinder = find.byKey(const ValueKey('emby-submit-btn'));
          await tester.ensureVisible(submitFinder);
          await tester.pump();
          await tester.tap(submitFinder);
          await tester.pump();
          for (var i = 0; i < 40 && addedCallbacks == 0; i++) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            });
            await tester.pump(const Duration(milliseconds: 50));
          }

          final errFinder = find.byKey(const ValueKey('emby-error-banner'));
          if (errFinder.evaluate().isNotEmpty) {
            final errText = tester
                .widget<Text>(
                  find.descendant(of: errFinder, matching: find.byType(Text)),
                )
                .data;
            fail('Unexpected Emby form error: $errText');
          }
          expect(addedCallbacks, 1);
          final subs = storage.getSubscriptions();
          expect(subs.length, 1);
          expect(subs.single.name, '家庭4K库');
          expect(subs.single.format, 'Emby');
          await tester.pumpAndSettle();
        } finally {
          await tester.runAsync(() => server.close(force: true));
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

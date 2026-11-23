import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/macos_update_sheet.dart';

import 'test_storage_helper.dart';

class _StreamClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  _StreamClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zipBytes = utf8.encode('PK\x03\x04verified-macos-desktop-zip-fixture');
  final zipSha = sha256.convert(zipBytes).toString();

  AppUpdate sampleMacUpdate({
    String version = '0.5.21',
    String assetName = 'MarcoMovie-0.5.21-macos-desktop.zip',
  }) =>
      AppUpdate(
        version,
        '## 更新内容\n- 修复 Mac 窗口记忆与离线音轨下载',
        null,
        zipSha,
        zipBytes.length,
        null,
        Uri.parse(
          'https://github.com/Pilipala9919/MarcoMovie/releases/download/macos-v$version/$assetName',
        ),
      );

  group('AppUpdate macOS parsing, verification and download', () {
    test('parses live 0.5.20 mirror packages schema (-macos-desktop.zip) and compat alias (-macos.zip)', () {
      final desktop = AppUpdate.parse(
        {
          'schema': 1,
          'platform': 'macos',
          'versionName': '0.5.20',
          'prerelease': false,
          'notes': 'macOS 0.5.20',
          'packages': {
            'MarcoMovie-0.5.20-macos-desktop.zip': {
              'size': zipBytes.length,
              'sha256': zipSha,
              'url':
                  'https://github.com/Pilipala9919/MarcoMovie/releases/download/macos-v0.5.20/MarcoMovie-0.5.20-macos-desktop.zip',
            },
          },
        },
        platform: 'macos',
      );
      expect(desktop.version, '0.5.20');
      expect(desktop.macosUrl?.path, endsWith('/MarcoMovie-0.5.20-macos-desktop.zip'));
      expect(desktop.size, zipBytes.length);
      expect(desktop.checksum, zipSha);
      expect(desktop.windowsUrl, isNull);
      expect(desktop.iosUrl, isNull);

      final alias = AppUpdate.parse(
        {
          'platform': 'macos',
          'versionName': '0.5.21',
          'packages': {
            'MarcoMovie-0.5.21-macos.zip': {
              'size': zipBytes.length,
              'sha256': zipSha,
              'url':
                  'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.21-macos.zip',
            },
          },
        },
        platform: 'macos',
      );
      expect(alias.macosUrl?.path, endsWith('/MarcoMovie-0.5.21-macos.zip'));
      expect(alias.size, zipBytes.length);
      expect(alias.checksum, zipSha);
    });

    test('mirror failure falls back to GitHub Release, skips other platforms and prereleases', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (req.url.host != 'api.github.com') {
          expect(req.url.path, '/movie/updates/macos.json');
          return http.Response('', 503);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'tag_name': 'windows-v0.9.0',
              'prerelease': false,
              'assets': [
                {
                  'name': 'MarcoMovie-0.9.0-windows-setup.exe',
                  'size': zipBytes.length,
                  'digest': 'sha256:$zipSha',
                  'browser_download_url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/windows-v0.9.0/MarcoMovie-0.9.0-windows-setup.exe',
                },
              ],
            },
            {
              'tag_name': 'macos-v0.6.0-preview',
              'prerelease': true,
              'assets': [
                {
                  'name': 'MarcoMovie-0.6.0-macos-desktop.zip',
                  'size': zipBytes.length,
                  'digest': 'sha256:$zipSha',
                  'browser_download_url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/macos-v0.6.0-preview/MarcoMovie-0.6.0-macos-desktop.zip',
                },
              ],
            },
            {
              'tag_name': 'macos-v0.5.21',
              'prerelease': false,
              'body': '正式 Mac 更新',
              'assets': [
                {
                  'name': 'MarcoMovie-0.5.21-macos.zip',
                  'size': zipBytes.length,
                  'digest': 'sha256:$zipSha',
                  'browser_download_url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/macos-v0.5.21/MarcoMovie-0.5.21-macos.zip',
                },
                {
                  'name': 'MarcoMovie-0.5.21-macos-desktop.zip',
                  'size': zipBytes.length,
                  'digest': 'sha256:$zipSha',
                  'browser_download_url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/macos-v0.5.21/MarcoMovie-0.5.21-macos-desktop.zip',
                },
              ],
            },
          ])),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final release = await AppUpdate.check(client: client, platform: 'macos');
      expect(calls, 2);
      expect(release.version, '0.5.21');
      expect(
        release.macosUrl?.path,
        endsWith('/MarcoMovie-0.5.21-macos-desktop.zip'),
      );
    });

    test('rejects wrong platform, untrusted download host, or mismatched asset filename', () {
      expect(
        () => AppUpdate.parse(
          {'platform': 'windows', 'versionName': '0.5.21'},
          platform: 'macos',
        ),
        throwsFormatException,
      );
      final foreign = AppUpdate.parse(
        {
          'platform': 'macos',
          'versionName': '0.5.21',
          'packages': {
            'MarcoMovie-0.5.21-macos-desktop.zip': {
              'size': zipBytes.length,
              'sha256': zipSha,
              'url': 'https://evil.invalid/MarcoMovie-0.5.21-macos-desktop.zip',
            },
          },
        },
        platform: 'macos',
      );
      expect(foreign.macosUrl, isNull);
    });

    test('downloadMacos verifies size and SHA-256, rejects truncated/same-length corrupt/cancelled streams, and cleans staging', () async {
      final dir = await Directory.systemTemp.createTemp('marco-mac-upd-');
      addTearDown(() => dir.delete(recursive: true));
      final rel = sampleMacUpdate();

      // 1. Happy path + verified cache reuse.
      var hits = 0;
      final okClient = MockClient((req) async {
        hits++;
        expect(req.url, rel.macosUrl);
        return http.Response.bytes(zipBytes, 200);
      });
      final saved = await rel.downloadMacos(
        directory: dir,
        cancellation: UpdateCancellation(),
        client: okClient,
      );
      expect(saved.path, endsWith('MarcoMovie-0.5.21-macos-desktop.zip'));
      expect(await saved.readAsBytes(), zipBytes);
      await rel.downloadMacos(
        directory: dir,
        cancellation: UpdateCancellation(),
        client: okClient,
      );
      expect(hits, 1);

      // 2. Truncated and same-length corrupted payloads fail and leave zero artifacts.
      for (final kind in ['truncated', 'same-length-corrupt']) {
        final isolated = await Directory.systemTemp.createTemp('marco-mac-bad-');
        addTearDown(() => isolated.delete(recursive: true));
        final payload = kind == 'truncated'
            ? zipBytes.sublist(0, 6)
            : List<int>.filled(zipBytes.length, 0x5A);
        final badClient = _StreamClient(
          (_) async => http.StreamedResponse(Stream.value(payload), 200),
        );
        await expectLater(
          rel.downloadMacos(
            directory: isolated,
            cancellation: UpdateCancellation(),
            client: badClient,
          ),
          throwsFormatException,
        );
        expect(await isolated.list().toList(), isEmpty);
      }

      // 3. Cancellation aborts request and removes staging directory.
      final cancelDir = await Directory.systemTemp.createTemp('marco-mac-cancel-');
      addTearDown(() => cancelDir.delete(recursive: true));
      final body = StreamController<List<int>>();
      final started = Completer<void>();
      Future<void>? aborted;
      final cancelClient = _StreamClient((req) async {
        aborted = (req as http.AbortableRequest).abortTrigger;
        started.complete();
        return http.StreamedResponse(body.stream, 200);
      });
      final cancel = UpdateCancellation();
      final future = rel.downloadMacos(
        directory: cancelDir,
        cancellation: cancel,
        client: cancelClient,
      );
      final expectation = expectLater(future, throwsA(isA<UpdateCancelled>()));
      await started.future;
      cancel.cancel();
      await expectation;
      await aborted;
      unawaited(body.close());
      expect(await cancelDir.list().toList(), isEmpty);
    });
  });

  group('MacosUpdateSheet UI integration', () {
    testWidgets('downloads verified package, reveals in Finder, and keeps official website available', (tester) async {
      final dir = Directory.systemTemp.createTempSync('marco-mac-sheet-');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final rel = sampleMacUpdate();
      final revealed = <String>[];
      final openedUrls = <String>[];
      final downloadDone = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MacosUpdateSheet(
              installedVersion: '0.5.20',
              readVersion: () async => '0.5.20',
              check: (_, __) async => rel,
              targetDirectory: () async => dir,
              download: (release, targetDir, cancellation, onProgress) async {
                onProgress(zipBytes.length ~/ 2, zipBytes.length);
                final f = File(
                  '${targetDir.path}${Platform.pathSeparator}MarcoMovie-${release.version}-macos-desktop.zip',
                );
                f.writeAsBytesSync(zipBytes);
                expect(f.lengthSync(), release.size);
                expect(sha256.convert(f.readAsBytesSync()).toString(), release.checksum);
                if (!downloadDone.isCompleted) downloadDone.complete();
                return f;
              },
              revealInFinder: (f) async {
                revealed.add(f.path);
                return true;
              },
              openWebsite: (url) async => openedUrls.add(url),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('发现新版本 v0.5.21'), findsOneWidget);
      expect(find.byKey(const ValueKey('macos-update-download-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('macos-update-website-button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('macos-update-download-button')));
      await downloadDone.future;
      await tester.pump();
      await tester.pump();

      expect(revealed, hasLength(1));
      expect(revealed.single, endsWith('MarcoMovie-0.5.21-macos-desktop.zip'));
      expect(find.byKey(const ValueKey('macos-update-reveal-button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('macos-update-website-button')));
      await tester.pump();
      expect(openedUrls, [MacosUpdateSheet.officialDownloadSiteUrl]);
    });
  });

  group('0.5.20 macOS user profile overwrite-upgrade compatibility', () {
    test('retains subscriptions, favorites, watch progress, and settings from 0.5.20 profile', () async {
      final storage = await initTestStorage(initialPrefs: {
        StorageService.keySubscriptions: jsonEncode([
          {
            'id': 'sub-0520',
            'name': '我的 0.5.20 订阅',
            'url': 'https://sub.example/config.json',
            'group': '默认分组',
            'enabled': true,
            'rawContent': jsonEncode({
              'sites': [
                {
                  'key': 'site_0520',
                  'name': '经典片源',
                  'type': 1,
                  'api': 'https://api.example/vod',
                },
              ],
            }),
          },
        ]),
        StorageService.keyFavorites: jsonEncode([
          {
            'site': 'site_0520',
            'siteName': '经典片源',
            'id': 'vid-42',
            'title': '0.5.20 收藏影片',
            'poster': 'https://img.example/p.jpg',
            'added': 1763600000000,
          },
        ]),
        StorageService.keyWatchHistory: jsonEncode([
          {
            'site': 'site_0520',
            'id': 'vid-42',
            'title': '0.5.20 收藏影片',
            'poster': 'https://img.example/p.jpg',
            'line': '主线路',
            'episode': '第5集',
            'index': 4,
            'position': 612000,
            'duration': 2700000,
            'updated': 1763600100000,
          },
        ]),
        StorageService.keyAppThemeMode: 'light',
        StorageService.keyGridDensity: 'compact',
        StorageService.keyPlaySpeed: 1.5,
        StorageService.keyAutoNext: false,
        StorageService.keySkipIntroSec: 90,
        StorageService.keySkipOutroSec: 120,
        StorageService.keyRepeatMode: 'one',
      });
      final subs = storage.getSubscriptions();
      expect(subs, hasLength(1));
      expect(subs.first.name, '我的 0.5.20 订阅');
      expect(storage.loadSavedConfig()?.sites.map((s) => s.key), contains('site_0520'));

      expect(storage.isFavorite('site_0520', 'vid-42'), isTrue);
      final history = storage.getWatchHistory();
      expect(history, hasLength(1));
      expect(history.first.episode, '第5集');
      expect(history.first.position, 612000);
      expect(history.first.duration, 2700000);

      expect(storage.appThemeMode, 'light');
      expect(storage.gridDensity, 'compact');
      expect(storage.playSpeed, 1.5);
      expect(storage.autoNext, isFalse);
      expect(storage.skipIntroSec, 90);
      expect(storage.skipOutroSec, 120);
      expect(storage.repeatMode, 'one');
    });
  });
}

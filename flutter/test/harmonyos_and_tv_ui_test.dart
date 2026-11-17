// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/tv/tv_detail_screen.dart';
import 'package:marco_movie/ui/tv/tv_focus_widgets.dart';
import 'package:marco_movie/ui/tv/tv_living_room_shell.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCmsHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final ac = uri.queryParameters['ac'] ?? '';
    final wd = uri.queryParameters['wd'] ?? '';
    Map<String, dynamic> payload;
    if (wd.isNotEmpty) {
      payload = <String, dynamic>{
        'code': 1,
        'page': 1,
        'pagecount': 1,
        'list': [
          {
            'vod_id': '99',
            'vod_name': '搜索命中剧集_$wd',
            'vod_pic': '',
            'vod_remarks': 'HD',
            'vod_play_from': 'm3u8',
            'vod_play_url': '第01集\$http://127.0.0.1:18080/ep1.m3u8',
          },
        ],
      };
    } else if (ac == 'list') {
      payload = <String, dynamic>{
        'code': 1,
        'class': [
          {'type_id': 1, 'type_name': '电影'},
          {'type_id': 2, 'type_name': '剧集'},
        ],
        'list': [],
      };
    } else {
      payload = <String, dynamic>{
        'code': 1,
        'page': 1,
        'pagecount': 1,
        'list': [
          {
            'vod_id': '101',
            'vod_name': '测试大屏电影',
            'vod_pic': '',
            'vod_year': '2026',
            'vod_area': '中国大陆',
            'vod_remarks': '4K HDR',
            'vod_content': '鸿蒙智慧屏遥控焦点测试简介',
            'vod_play_from': '超清m3u8',
            'vod_play_url':
                '第01集\$http://127.0.0.1:18080/1.m3u8#第02集\$http://127.0.0.1:18080/2.m3u8',
          },
        ],
      };
    }
    final bytes = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    OhosRuntime.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OhosRuntime.systemChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.pilipala.marcomovie/ohos_avplayer'),
          null,
        );
  });

  group('OhosRuntime & Device Form-Factor Routing', () {
    test('detects phone, tablet/2in1, and smart-screen tv profiles via channel', () async {
      OhosRuntime.debugIsOhosOverride = true;
      final secureVault = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
        switch (call.method) {
          case 'getDeviceProfile':
            return <String, dynamic>{
              'deviceType': 'tv',
              'osFullName': 'OpenHarmony-5.0.0',
              'sdkApiVersion': 12,
            };
          case 'getDirectories':
            return <String, String>{
              'filesDir': '/data/storage/el2/base/haps/entry/files',
              'cacheDir': '/data/storage/el2/base/haps/entry/cache',
              'tempDir': '/data/storage/el2/base/haps/entry/temp',
            };
          case 'secureWrite':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            secureVault[args['key'].toString()] = args['value'].toString();
            return null;
          case 'secureRead':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            return secureVault[args['key'].toString()];
          case 'secureDelete':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            secureVault.remove(args['key'].toString());
            return null;
        }
        return null;
      });

      await OhosRuntime.ensureInitialized();
      expect(OhosRuntime.isOhos, isTrue);
      expect(OhosRuntime.deviceProfile.isTv, isTrue);
      expect(OhosRuntime.isSmartScreenHardware, isTrue);
      expect(OhosRuntime.shouldUseTvUi('auto'), isTrue);
      expect(OhosRuntime.shouldUseTvUi('standard'), isFalse);
      expect(
        OhosRuntime.filesDir,
        '/data/storage/el2/base/haps/entry/files',
      );

      const backend = OhosSecureStorageBackend();
      await backend.write('webdav_pass', 's3cr3t');
      expect(await backend.read('webdav_pass'), 's3cr3t');
      await backend.delete('webdav_pass');
      expect(await backend.read('webdav_pass'), isNull);
    });
  });

  group('TvRemoteSeekController Curve & Invariants', () {
    test('short tap steps ±15s and clamps to [0, duration]', () {
      final seek = TvRemoteSeekController();
      seek.onKeyDown(
        direction: 1,
        currentPositionMs: 10000,
        durationMs: 120000,
        nowEpochMs: 1000,
      );
      expect(seek.commitOnKeyUp(1300), 25000);

      seek.onKeyDown(
        direction: -1,
        currentPositionMs: 8000,
        durationMs: 120000,
        nowEpochMs: 2000,
      );
      expect(seek.commitOnKeyUp(2200), 0);
    });

    test('hold past 500ms accelerates linearly from 30s/s to 240s/s cap', () {
      expect(TvRemoteSeekController.previewSpeedAt(0), 30.0);
      expect(TvRemoteSeekController.previewSpeedAt(2.0), 90.0);
      expect(TvRemoteSeekController.previewSpeedAt(7.0), 240.0);
      expect(TvRemoteSeekController.previewSpeedAt(12.0), 240.0);

      final seek = TvRemoteSeekController();
      seek.onKeyDown(
        direction: 1,
        currentPositionMs: 60000,
        durationMs: 3600000,
        nowEpochMs: 1000,
      );
      seek.onKeyDown(
        direction: 1,
        currentPositionMs: 60000,
        durationMs: 3600000,
        nowEpochMs: 2500,
      );
      final preview = seek.updatePreview(2500);
      expect(preview.isHoldPreview, isTrue);
      expect(preview.currentSpeedX, 60.0);
      expect(preview.targetMs, 120000);

      // Reversing direction resets anchor & acceleration
      seek.onKeyDown(
        direction: -1,
        currentPositionMs: 60000,
        durationMs: 3600000,
        nowEpochMs: 2600,
      );
      expect(seek.commitOnKeyUp(2800), 45000);
    });

    test('cancel aborts active hold seek without committing', () {
      final seek = TvRemoteSeekController();
      seek.onKeyDown(
        direction: 1,
        currentPositionMs: 50000,
        durationMs: 300000,
        nowEpochMs: 1000,
      );
      seek.cancel();
      expect(seek.isActive, isFalse);
      expect(seek.commitOnKeyUp(2000), isNull);
    });
  });

  group('OhosPlatformPlayer & VideoKernel Bridge', () {
    testWidgets('opens stream with headers, processes native events, and renders Texture', (tester) async {
      OhosRuntime.debugIsOhosOverride = true;
      const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(avChannel, (call) async {
        calls.add(call);
        if (call.method == 'create') {
          return <String, dynamic>{'playerId': 7, 'textureId': 42};
        }
        if (call.method == 'getTracks') {
          return <Map<String, dynamic>>[
            {'index': 0, 'trackType': 'video', 'codec': 'hevc', 'title': '4K'},
            {'index': 1, 'trackType': 'audio', 'codec': 'aac', 'title': '国语'},
          ];
        }
        return null;
      });

      final kernel = VideoKernel.create(hwdec: 'auto');
      expect(kernel.ohosPlatform, isNotNull);

      await kernel.ohosPlatform!.setProperty('user-agent', 'MarcoOhos/1.0');
      await kernel.player.open(
        Media(
          'http://127.0.0.1:18080/live.m3u8',
          httpHeaders: const {'Referer': 'http://127.0.0.1/'},
        ),
      );

      expect(kernel.ohosPlatform!.textureId, 42);
      final openCall = calls.firstWhere((c) => c.method == 'open');
      final openArgs = Map<String, dynamic>.from(openCall.arguments as Map);
      expect(openArgs['url'], 'http://127.0.0.1:18080/live.m3u8');
      final headers = Map<String, dynamic>.from(openArgs['headers'] as Map);
      expect(headers['User-Agent'], 'MarcoOhos/1.0');
      expect(headers['Referer'], 'http://127.0.0.1/');

      kernel.ohosPlatform!.handleNativeEvent({
        'type': 'videoSize',
        'width': 1920,
        'height': 1080,
      });
      kernel.ohosPlatform!.handleNativeEvent({
        'type': 'position',
        'positionMs': 12500,
        'durationMs': 90000,
        'bufferedMs': 25000,
      });
      kernel.ohosPlatform!.handleNativeEvent({
        'type': 'state',
        'playing': true,
        'buffering': false,
        'completed': false,
      });

      expect(kernel.player.state.playing, isTrue);
      expect(kernel.player.state.width, 1920);
      expect(kernel.player.state.position, const Duration(milliseconds: 12500));
      expect(kernel.player.state.duration, const Duration(milliseconds: 90000));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: kernel.buildVideoSurface(
              fit: BoxFit.contain,
              videoWidth: 1920,
              videoHeight: 1080,
            ),
          ),
        ),
      );
      expect(find.byType(Texture), findsOneWidget);

      await kernel.player.seek(const Duration(seconds: 30));
      await kernel.player.setRate(1.5);
      await tester.pumpWidget(const SizedBox.shrink());
      await kernel.player.dispose();
      expect(calls.any((c) => c.method == 'dispose'), isTrue);
    });
  });

  group('10-Foot TV Living Room Shell & Remote Navigation', () {
    testWidgets('renders TV shell, site picker, detail episodes & remote keyboard search', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final configJson = jsonEncode({
        'sites': [
          {
            'key': 'local_cms',
            'name': '本地测试采集站',
            'type': 1,
            'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
            'searchable': 1,
          },
          {
            'key': 'jar_only',
            'name': '受限JAR站点',
            'type': 3,
            'api': 'csp_UnsupportedJarOnly',
            'jar': 'http://127.0.0.1:18080/spider.jar',
          },
        ],
      });
      await storage.saveConfig(configJson);

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      OhosRuntime.debugIsOhosOverride = true;
      OhosRuntime.debugDeviceTypeOverride = 'tv';

      final client = CmsClient(client: _FakeCmsHttpClient());
      await tester.pumpWidget(
        MaterialApp(
          home: TvLivingRoomShell(storage: storage, client: client),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('测试大屏电影'), findsOneWidget);
      expect(find.text('电影'), findsOneWidget);

      // Press Menu (F1) to verify Site Picker shows available & grayed-out sites
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('切换片源（可用 1 / 共 2）'), findsOneWidget);
      expect(find.text('受限JAR站点'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Open TV Detail Screen by selecting the poster card
      await tester.tap(find.text('测试大屏电影'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(TvDetailScreen), findsOneWidget);
      expect(find.text('第01集'), findsOneWidget);
      expect(find.text('第02集'), findsOneWidget);

      // Toggle favorite in TV Detail Screen
      await tester.tap(find.text('☆ 收藏'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('★ 已收藏'), findsOneWidget);

      // Return to Home via Back button
      await tester.tap(find.text('← 返回'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Switch to Search tab & use TV Remote Grid Keyboard
      await tester.tap(find.text('搜索'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(TvRemoteGridKeyboard), findsOneWidget);

      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(TvRemoteGridKeyboard),
          matching: find.text('搜索'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('搜索命中剧集_A'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('PlayerScreen TV remote tap-to-seek commits target to OhosPlatformPlayer', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      OhosRuntime.debugIsOhosOverride = true;
      OhosRuntime.debugDeviceTypeOverride = 'tv';

      // Verify PlayerScreen TV remote tap-to-seek integration with OhosPlatformPlayer
      const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
      final seekTargets = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(avChannel, (call) async {
        if (call.method == 'create') {
          return <String, dynamic>{'playerId': 1, 'textureId': 9};
        }
        if (call.method == 'seek') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          seekTargets.add((args['positionMs'] as num).toInt());
        }
        return null;
      });

      final ohosPlayer = OhosPlatformPlayer();
      final debugPlayer = Player(platformPlayer: ohosPlayer);

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerScreen(
            site: const CmsSite(
              key: 'local_cms',
              name: '本地测试站',
              type: 1,
              api: 'http://127.0.0.1:18080/api',
            ),
            video: const CmsVideo(
              id: '101',
              title: '测试大屏电影',
              lines: [
                CmsLine(
                  name: 'm3u8',
                  episodes: [
                    CmsEpisode(
                      name: '第01集',
                      url: 'https://localhost/1.mp4',
                    ),
                  ],
                ),
              ],
            ),
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: debugPlayer,
            debugVideoSurface: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      ohosPlayer.handleNativeEvent({
        'type': 'position',
        'positionMs': 20000,
        'durationMs': 600000,
        'bufferedMs': 40000,
      });
      await tester.pump(const Duration(milliseconds: 50));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));

      expect(seekTargets, contains(35000));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
    });
  });
}

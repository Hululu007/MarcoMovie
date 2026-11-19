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
import 'package:marco_movie/ui/tv/tv_player_overlay.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StaticJsonHttpClient extends http.BaseClient {
  final String responseJson;

  _StaticJsonHttpClient(this.responseJson);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode(responseJson);
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

class _FakeCmsHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (uri.path.endsWith('/live.m3u')) {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="央视频道",CCTV-1 综合\n'
          'http://127.0.0.1:18080/cctv1.m3u8\n'
          '#EXTINF:-1 group-title="央视频道",CCTV-6 电影\n'
          'http://127.0.0.1:18080/cctv6.m3u8\n'
          '#EXTINF:-1 group-title="卫视频道",湖南卫视\n'
          'http://127.0.0.1:18080/hunan.m3u8\n';
      final bytes = utf8.encode(m3u);
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        headers: const {'content-type': 'text/plain; charset=utf-8'},
      );
    }
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

    test('passes preferredHdr/preferredBufferDuration and handles audio/subtitle track selection + deselectTrack', () async {
      OhosRuntime.debugIsOhosOverride = true;
      const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(avChannel, (call) async {
        calls.add(call);
        if (call.method == 'create') {
          return <String, dynamic>{'playerId': 11, 'textureId': 88};
        }
        if (call.method == 'getTracks') {
          return <Map<String, dynamic>>[
            {'index': 0, 'trackType': 1, 'codec': 'hevc', 'title': '4K HDR'},
            {'index': 1, 'trackType': 0, 'codec': 'eac3', 'title': '国语杜比'},
            {'index': 2, 'trackType': 0, 'codec': 'aac', 'title': '粤语原声'},
            {'index': 3, 'trackType': 2, 'codec': 'subrip', 'title': '简中字幕'},
          ];
        }
        return true;
      });

      final kernel = VideoKernel.create(hwdec: 'auto');
      expect(kernel.mode, VideoKernelMode.ohosHardwareHdr);

      await kernel.player.open(
        Media('http://127.0.0.1:18080/uhd.mkv'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final openCall = calls.firstWhere((c) => c.method == 'open');
      final openArgs = Map<String, dynamic>.from(openCall.arguments as Map);
      expect(openArgs['preferredHdr'], isTrue);
      expect(openArgs['preferredBufferDuration'], 20);

      // Verify resolution formatting helper for 4K / 2K / 1080P / 720P
      expect(formatVideoResolutionLabel(3840, 2160), '4K UHD');
      expect(formatVideoResolutionLabel(2560, 1440), '2K QHD');
      expect(formatVideoResolutionLabel(1920, 1080), '1080P FHD');
      expect(formatVideoResolutionLabel(1280, 720), '720P HD');

      kernel.ohosPlatform!.handleNativeEvent({
        'type': 'videoSize',
        'width': 3840,
        'height': 2160,
        'bitrate': 28500000,
      });
      kernel.ohosPlatform!.handleNativeEvent({
        'type': 'bufferingPercent',
        'percent': 65,
      });
      expect(kernel.player.state.videoResolutionLabel, '4K UHD');
      expect(kernel.ohosPlatform!.videoResolutionLabel, '4K UHD');
      expect(kernel.ohosPlatform!.bufferingPercent, 65);
      expect(kernel.ohosPlatform!.streamBitrate, 28500000);

      // Select Cantonese audio track (native index 2)
      final cantonese = kernel.player.state.tracks.audio
          .firstWhere((t) => (t.title ?? '').contains('粤语'));
      await kernel.player.setAudioTrack(cantonese);
      final selectAudio = calls.lastWhere((c) => c.method == 'selectTrack');
      expect(
        Map<String, dynamic>.from(selectAudio.arguments as Map)['index'],
        2,
      );

      // Select Simplified Chinese subtitle track (native index 3)
      final zhSub = kernel.player.state.tracks.subtitle
          .firstWhere((t) => (t.title ?? '').contains('简中'));
      await kernel.player.setSubtitleTrack(zhSub);
      final selectSub = calls.lastWhere((c) => c.method == 'selectTrack');
      expect(
        Map<String, dynamic>.from(selectSub.arguments as Map)['index'],
        3,
      );
      expect(kernel.ohosPlatform!.activeSubtitleTrackIndex, 3);

      // Disable subtitles -> must invoke native deselectTrack(index: 3)
      await kernel.player.setSubtitleTrack(SubtitleTrack.no());
      final deselectCalls =
          calls.where((c) => c.method == 'deselectTrack').toList();
      expect(deselectCalls, hasLength(1));
      final deselectArgs =
          Map<String, dynamic>.from(deselectCalls.single.arguments as Map);
      expect(deselectArgs['playerId'], 11);
      expect(deselectArgs['index'], 3);
      expect(kernel.ohosPlatform!.activeSubtitleTrackIndex, isNull);

      await kernel.player.dispose();
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

    testWidgets('TvDetailScreen renders 4K 云盘 badges on Quark/UC/Baidu/Ali lines', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const site = CmsSite(
        key: 'netdisk_demo',
        name: '云盘测试源',
        type: 1,
        api: 'http://127.0.0.1:18080/unused',
      );
      const shareUrlFixtures = <CmsLine>[
        CmsLine(
          name: '直链夸克测试',
          episodes: [
            CmsEpisode(name: 'EP1', url: 'https://pan.quark.cn/s/demo1'),
          ],
        ),
        CmsLine(
          name: '直链UC测试',
          episodes: [
            CmsEpisode(name: 'EP1', url: 'https://drive.uc.cn/s/demo2'),
          ],
        ),
        CmsLine(
          name: '直链百度测试',
          episodes: [
            CmsEpisode(name: 'EP1', url: 'https://pan.baidu.com/s/demo3'),
          ],
        ),
        CmsLine(
          name: '直链阿里测试',
          episodes: [
            CmsEpisode(name: 'EP1', url: 'https://www.alipan.com/s/demo4'),
          ],
        ),
      ];
      expect(TvDetailScreen.detectNetdiskDrive(shareUrlFixtures[0]), 'quark');
      expect(TvDetailScreen.detectNetdiskDrive(shareUrlFixtures[1]), 'uc');
      expect(TvDetailScreen.detectNetdiskDrive(shareUrlFixtures[2]), 'baidu');
      expect(TvDetailScreen.detectNetdiskDrive(shareUrlFixtures[3]), 'ali');

      const videoWithNetdiskLines = CmsVideo(
        id: 'nd_4k_1',
        title: '测试4K原盘剧集',
        lines: [
          CmsLine(
            name: '夸父4K原画',
            episodes: [
              CmsEpisode(
                name: '4K REMUX 第01集',
                url: 'mmwogg://quark?share_id=demo1',
              ),
            ],
          ),
          CmsLine(
            name: '优汐HDR',
            episodes: [
              CmsEpisode(
                name: 'DV 第01集',
                url: 'mmcloud://uc?share_id=demo2',
              ),
            ],
          ),
          CmsLine(
            name: '嘟嘟原盘',
            episodes: [
              CmsEpisode(
                name: 'ISO 第01集',
                url: 'mmcloud://baidu?share_id=demo3',
              ),
            ],
          ),
          CmsLine(
            name: '阿狸臻彩',
            episodes: [
              CmsEpisode(
                name: 'SDR 第01集',
                url: 'mmcloud://ali?share_id=demo4',
              ),
            ],
          ),
          CmsLine(
            name: '极速m3u8',
            episodes: [
              CmsEpisode(
                name: '1080P 第01集',
                url: 'http://127.0.0.1:18080/direct.m3u8',
              ),
            ],
          ),
        ],
      );

      expect(
        TvDetailScreen.detectNetdiskDrive(videoWithNetdiskLines.lines[0]),
        'quark',
      );
      expect(
        TvDetailScreen.detectNetdiskDrive(videoWithNetdiskLines.lines[1]),
        'uc',
      );
      expect(
        TvDetailScreen.detectNetdiskDrive(videoWithNetdiskLines.lines[2]),
        'baidu',
      );
      expect(
        TvDetailScreen.detectNetdiskDrive(videoWithNetdiskLines.lines[3]),
        'ali',
      );
      expect(
        TvDetailScreen.detectNetdiskDrive(videoWithNetdiskLines.lines[4]),
        isNull,
      );

      // Return identical lines when TvDetailScreen calls fetchDetail
      final fakeNetdiskClient = CmsClient(
        client: _StaticJsonHttpClient(
          jsonEncode({
            'code': 1,
            'list': [
              {
                'vod_id': 'nd_4k_1',
                'vod_name': '测试4K原盘剧集',
                'vod_play_from':
                    '夸父4K原画\$\$\$优汐HDR\$\$\$嘟嘟原盘\$\$\$阿狸臻彩\$\$\$极速m3u8',
                'vod_play_url': '4K REMUX 第01集\$mmwogg://quark?share_id=demo1'
                    '\$\$\$DV 第01集\$mmcloud://uc?share_id=demo2'
                    '\$\$\$ISO 第01集\$mmcloud://baidu?share_id=demo3'
                    '\$\$\$SDR 第01集\$mmcloud://ali?share_id=demo4'
                    '\$\$\$1080P 第01集\$http://127.0.0.1:18080/direct.m3u8',
              },
            ],
          }),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: TvDetailScreen(
            site: site,
            initialVideo: videoWithNetdiskLines,
            storage: storage,
            client: fakeNetdiskClient,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // Exactly 4 Netdisk lines carry the crisp `4K 云盘` badge; direct m3u8 does not.
      expect(find.text('4K 云盘'), findsNWidgets(4));
      expect(find.text('☁️ 云盘扫码管理'), findsOneWidget);

      // Tapping an unauthenticated Quark episode opens Netdisk QR Account Sheet directly!
      await tester.tap(find.text('4K REMUX 第01集'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('我的夸父'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 25));
    });

    testWidgets('TvPlayerControlSheet supports D-pad focus navigation for speed, audio, subtitle, and aspect ratio', (tester) async {
      OhosRuntime.debugIsOhosOverride = true;
      OhosRuntime.debugDeviceTypeOverride = 'tv';

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(avChannel, (call) async {
        calls.add(call);
        if (call.method == 'create') {
          return <String, dynamic>{'playerId': 5, 'textureId': 50};
        }
        if (call.method == 'getTracks') {
          return <Map<String, dynamic>>[
            {'index': 0, 'trackType': 1, 'codec': 'hevc', 'title': '4K'},
            {'index': 1, 'trackType': 0, 'codec': 'aac', 'title': '国语配音'},
            {'index': 2, 'trackType': 0, 'codec': 'eac3', 'title': '英语原声'},
            {'index': 3, 'trackType': 2, 'codec': 'ass', 'title': '双语特效字幕'},
          ];
        }
        return true;
      });

      final ohosPlatform = OhosPlatformPlayer();
      final player = Player(platformPlayer: ohosPlatform);
      await player.open(Media('http://127.0.0.1:18080/movie.mkv'));
      await tester.pump(const Duration(milliseconds: 50));
      ohosPlatform.handleNativeEvent({
        'type': 'videoSize',
        'width': 3840,
        'height': 2160,
      });

      var selectedSpeed = 1.0;
      var selectedFit = BoxFit.contain;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvPlayerControlSheet(
              player: player,
              initialSpeed: selectedSpeed,
              onSpeedSelected: (next) => selectedSpeed = next,
              initialFit: selectedFit,
              onFitSelected: (next) => selectedFit = next,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('4K UHD'), findsOneWidget);
      expect(find.text('1.0x'), findsOneWidget);
      expect(find.text('英语原声 · EAC3'), findsOneWidget);
      expect(find.text('双语特效字幕'), findsOneWidget);
      expect(find.text('关闭字幕'), findsOneWidget);

      // Autofocus starts on `1.0x`; D-pad Right moves to `1.25x` and Enter activates it
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 100));
      expect(selectedSpeed, 1.25);
      expect(
        calls.any(
          (c) =>
              c.method == 'setRate' &&
              (Map<String, dynamic>.from(c.arguments as Map)['rate'] as num) ==
                  1.25,
        ),
        isTrue,
      );

      // Select English audio track, subtitle track, then disable subtitles via D-pad/tap
      await tester.tap(find.text('英语原声 · EAC3'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        calls.where((c) => c.method == 'selectTrack').any(
              (c) =>
                  Map<String, dynamic>.from(c.arguments as Map)['index'] == 2,
            ),
        isTrue,
      );

      await tester.tap(find.text('双语特效字幕'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(ohosPlatform.activeSubtitleTrackIndex, 3);

      await tester.tap(find.text('关闭字幕'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(calls.any((c) => c.method == 'deselectTrack'), isTrue);

      await tester.tap(find.text('裁切填满'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(selectedFit, BoxFit.cover);

      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });

    testWidgets('TvLivingRoomShell Live tab shows group summary OSD and switches groups Left/Right', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final configJson = jsonEncode({
        'sites': [
          {
            'key': 'local_cms',
            'name': '本地测试采集站',
            'type': 1,
            'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
          },
        ],
        'lives': [
          {
            'name': '高清直播源',
            'type': 0,
            'url': 'http://127.0.0.1:18080/live.m3u',
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

      await tester.tap(find.text('直播'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('2 组 / 共 3 频道'), findsOneWidget);
      expect(find.text('当前分组：央视频道 (2 台)'), findsOneWidget);
      expect(find.text('CCTV-1 综合'), findsOneWidget);

      // Switch group via BracketRight / Next Group pill
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('当前分组：卫视频道 (1 台)'), findsOneWidget);
      expect(find.text('湖南卫视'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 25));
    });

    testWidgets('Immersive TvDetailScreen opens full-screen episode sheet with pagination & line switching', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const site = CmsSite(
        key: 'series_demo',
        name: '家庭影院主源',
        type: 1,
        api: 'http://127.0.0.1:18080/unused',
      );
      final ep24 = List.generate(
        24,
        (i) => '第${(i + 1).toString().padLeft(2, '0')}集\$http://127.0.0.1:18080/ep${i + 1}.m3u8',
      ).join('#');
      final fakeClient = CmsClient(
        client: _StaticJsonHttpClient(
          jsonEncode({
            'code': 1,
            'list': [
              {
                'vod_id': '201',
                'vod_name': '远山回响',
                'vod_year': '2026',
                'vod_area': '自然纪实',
                'vod_remarks': '全24集',
                'vod_content': '沉浸式全屏剧集详情与选集测试。',
                'vod_play_from': '超清直连\$\$\$夸父4K',
                'vod_play_url': '$ep24\$\$\$第01集\$mmwogg://quark?share_id=q1#第02集\$mmwogg://quark?share_id=q2',
              },
            ],
          }),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: TvDetailScreen(
            site: site,
            initialVideo: const CmsVideo(
              id: '201',
              title: '远山回响',
              year: '2026',
              area: '自然纪实',
              remarks: '全24集',
            ),
            storage: storage,
            client: fakeClient,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('远山回响'), findsOneWidget);
      expect(find.text('超清直连 (24)'), findsOneWidget);
      expect(find.text('夸父4K (2)'), findsOneWidget);

      // Select the 24-episode line and verify hero & toolbar episode counts update
      await tester.tap(find.text('超清直连 (24)'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('选集 · 共24集'), findsOneWidget);
      expect(find.text('全屏选集 ›'), findsOneWidget);

      // Open full-screen immersive episode sheet
      await tester.tap(find.text('选集 · 共24集'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('← 返回详情'), findsOneWidget);
      expect(find.text('1-20'), findsOneWidget);
      expect(find.text('21-24'), findsOneWidget);
      expect(find.text('第01集'), findsWidgets);

      // Switch to page 2 (21-24)
      await tester.tap(find.text('21-24'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('第24集'), findsWidgets);

      // Switch to Netdisk line inside full-screen episode sheet & verify 4K badge
      await tester.tap(find.text('夸父4K (2)').last);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('选集 · 共 2 集 · 夸父4K'), findsOneWidget);

      // Close full-screen sheet back to immersive detail page
      await tester.tap(find.text('← 返回详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('← 返回详情'), findsNothing);
      expect(find.text('选集 · 共2集'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

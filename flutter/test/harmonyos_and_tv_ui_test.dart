// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_log.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/cloud_sync_panel.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/tv/tv_detail_screen.dart';
import 'package:marco_movie/ui/tv/tv_focus_widgets.dart';
import 'package:marco_movie/ui/tv/tv_living_room_shell.dart';
import 'package:marco_movie/ui/tv/tv_player_overlay.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PassthroughHttpOverrides extends HttpOverrides {}

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

class _AbortTrackingHttpClient extends http.BaseClient {
  final Future<http.Response> Function(
    http.BaseRequest request,
    Future<void>? abortTrigger,
  ) handler;

  int liveInFlight = 0;
  int maxLiveInFlight = 0;
  final List<String> startedUrls = <String>[];
  final List<String> abortedUrls = <String>[];

  _AbortTrackingHttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final urlStr = request.url.toString();
    startedUrls.add(urlStr);
    final Future<void>? abortTrigger =
        request is http.AbortableRequest ? request.abortTrigger : null;
    liveInFlight++;
    if (liveInFlight > maxLiveInFlight) {
      maxLiveInFlight = liveInFlight;
    }
    var settled = false;
    void releaseSlot() {
      if (!settled) {
        settled = true;
        liveInFlight--;
      }
    }

    final abortCompleter = Completer<http.StreamedResponse>();
    abortTrigger?.then((_) {
      abortedUrls.add(urlStr);
      releaseSlot();
      if (!abortCompleter.isCompleted) {
        abortCompleter.completeError(http.RequestAbortedException(request.url));
      }
    });

    final work = handler(request, abortTrigger).then((resp) {
      releaseSlot();
      return http.StreamedResponse(
        Stream<List<int>>.value(resp.bodyBytes),
        resp.statusCode,
        headers: resp.headers,
        request: request,
      );
    }).catchError((Object err, StackTrace st) {
      releaseSlot();
      throw err;
    });

    return Future.any<http.StreamedResponse>([work, abortCompleter.future]);
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
    AppUpdate.debugHttpClientOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OhosRuntime.systemChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.pilipala.marcomovie/ohos_avplayer'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
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

    testWidgets('TvLivingRoomShell Apple TV parity: 6 ambient themes, intensity, poster sync & settings studio', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final configJson = jsonEncode({
        'sites': [
          {
            'key': 'local_cms',
            'name': '家庭影院主源',
            'type': 1,
            'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
            'searchable': 1,
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

      // Floating centered Apple TV-parity nav bar has `发现` + right `扫码快传`
      expect(find.text('发现'), findsOneWidget);
      expect(find.text('扫码快传'), findsOneWidget);

      // Navigate to Settings -> 外观与柔光
      await tester.tap(find.text('设置'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('系统设置'), findsOneWidget);
      expect(find.text('客厅全局渐变柔光主题'), findsOneWidget);
      expect(find.text('极光青翠'), findsOneWidget);
      expect(find.text('暮色流光'), findsOneWidget);
      expect(find.text('暖金影院'), findsOneWidget);

      // Switch theme to 暮色流光 & intensity to 浓郁流光 and verify persistence
      await tester.tap(find.text('暮色流光'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(storage.tvAmbientTheme, 'twilight');
      expect(find.textContaining('当前：暮色流光'), findsOneWidget);

      await tester.tap(find.text('浓郁流光'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(storage.tvAmbientIntensity, 'vivid');

      // Toggle 海报色彩氛围联动 off
      await tester.tap(find.text('海报色彩氛围联动'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(storage.tvAmbientPosterSync, isFalse);

      // Switch settings sidebar to 播放与跳过 & verify UI mode options
      await tester.tap(find.text('播放与跳过'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('自动识别（手机/平板/智慧屏）'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('HarmonyOS 0.1.2 Upgrade Regressions (P0 / P1 / P2)', () {
    testWidgets(
      'P0-2 Credential storage: WebDAV password, long cookie (>2KB), lock-screen errors, legacy fallback migration & retry, zero plaintext leak',
      (tester) async {
        OhosRuntime.debugIsOhosOverride = true;
        final assetStore = <String, String>{};
        final legacyFallback = <String, String>{
          StorageService.keyWebdavPass: 'LegacyWebDavPass_011!',
        };
        var deviceLocked = true;
        var interruptFallbackDeleteOnce = true;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
          final args = call.arguments is Map
              ? Map<String, dynamic>.from(call.arguments as Map)
              : const <String, dynamic>{};
          final key = args['key']?.toString() ?? '';
          switch (call.method) {
            case 'secureRead':
              if (deviceLocked) {
                throw PlatformException(
                  code: '24000005',
                  message:
                      '系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)',
                );
              }
              if (assetStore.containsKey(key)) {
                legacyFallback.remove(key);
                return assetStore[key];
              }
              final legacy = legacyFallback[key];
              if (legacy == null) return null;
              // Simulate verified write to Asset Store, then crash/interrupt before fallback delete on 1st try
              assetStore[key] = legacy;
              if (interruptFallbackDeleteOnce) {
                interruptFallbackDeleteOnce = false;
                return legacy;
              }
              legacyFallback.remove(key);
              return legacy;
            case 'secureWrite':
              if (deviceLocked) {
                throw PlatformException(
                  code: '24000005',
                  message:
                      '系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)',
                );
              }
              final val = args['value']?.toString() ?? '';
              assetStore[key] = val;
              legacyFallback.remove(key);
              return true;
            case 'secureDelete':
              if (deviceLocked) {
                throw PlatformException(
                  code: '24000005',
                  message:
                      '系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)',
                );
              }
              assetStore.remove(key);
              legacyFallback.remove(key);
              return true;
          }
          return null;
        });

        const backend = OhosSecureStorageBackend();
        // 1) Locked device: read/write/delete must fail cleanly and leave legacy fallback untouched
        await expectLater(
          backend.read(StorageService.keyWebdavPass),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('24000005'),
            ),
          ),
        );
        expect(legacyFallback[StorageService.keyWebdavPass], 'LegacyWebDavPass_011!');

        await expectLater(
          backend.write(StorageService.keyQuarkCookie, 'SuperSecretCookieValue'),
          throwsA(isA<FormatException>()),
        );
        expect(legacyFallback.containsKey(StorageService.keyQuarkCookie), isFalse);

        // 2) Unlock: 1st read migrates into Asset Store; interrupted cleanup retried on 2nd read
        deviceLocked = false;
        expect(
          await backend.read(StorageService.keyWebdavPass),
          'LegacyWebDavPass_011!',
        );
        expect(assetStore[StorageService.keyWebdavPass], 'LegacyWebDavPass_011!');
        expect(legacyFallback.containsKey(StorageService.keyWebdavPass), isTrue);
        // Second read cleans up leftover fallback entry cleanly
        expect(
          await backend.read(StorageService.keyWebdavPass),
          'LegacyWebDavPass_011!',
        );
        expect(legacyFallback.containsKey(StorageService.keyWebdavPass), isFalse);

        // 3) Long Netdisk Cookie (> 3 KB) round-trip + restart persistence + logout
        SharedPreferences.setMockInitialValues({});
        final storage1 = await StorageService.init(
          secureStore: DefaultSecureCredentialStore(backend: backend),
        );
        final longCookie = List.generate(
          80,
          (i) => '__puus_part_$i=${'A1b2C3d4E5f6G7h8' * 2}',
        ).join('; ');
        expect(utf8.encode(longCookie).length, greaterThan(3000));
        await storage1.setNetdiskCredential('quark', longCookie);
        expect(storage1.getNetdiskCred('quark'), longCookie);

        // Verify ordinary SharedPreferences does NOT contain plaintext password or cookie
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(StorageService.keyQuarkCookie), isNull);
        expect(prefs.getString(StorageService.keyWebdavPass), isNull);
        for (final k in prefs.getKeys()) {
          final v = prefs.get(k)?.toString() ?? '';
          expect(v, isNot(contains(longCookie)));
          expect(v, isNot(contains('LegacyWebDavPass_011!')));
        }

        // Simulated restart reads persisted credentials from Asset Store
        final storage2 = await StorageService.init(
          secureStore: DefaultSecureCredentialStore(backend: backend),
        );
        expect(storage2.webdavPass, 'LegacyWebDavPass_011!');
        expect(storage2.getNetdiskCred('quark'), longCookie);

        // Lock device again: logout (delete) must fail honestly, keep cache intact, and show error in UI
        deviceLocked = true;
        await expectLater(
          storage2.setNetdiskCredential('quark', ''),
          throwsA(isA<FormatException>()),
        );
        expect(storage2.getNetdiskCred('quark'), longCookie);

        // CloudSyncSettingsPanel displays real failure result when WebDAV save fails while locked
        String? lastNoticeMsg;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CloudSyncSettingsPanel(
                  storage: storage2,
                  onNotice: (_, msg) => lastNoticeMsg = msg,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.ensureVisible(find.text('仅保存配置'));
        await tester.pump();
        await tester.tap(find.text('仅保存配置'));
        await tester.pumpAndSettle();
        expect(lastNoticeMsg, isNotNull);
        expect(lastNoticeMsg, contains('24000005'));
        expect(lastNoticeMsg, isNot(contains('LegacyWebDavPass_011!')));
        // Logs must never leak plaintext secrets
        final recentLogs = await AppLog.instance.exportLogsFormatted();
        expect(recentLogs, isNot(contains(longCookie)));
        expect(recentLogs, isNot(contains('LegacyWebDavPass_011!')));

        // Unlock & logout succeeds cleanly
        deviceLocked = false;
        await storage2.setNetdiskCredential('quark', '');
        expect(storage2.getNetdiskCred('quark'), isEmpty);
        expect(assetStore.containsKey(StorageService.keyQuarkCookie), isFalse);
      },
    );

    testWidgets(
      'P0-3 Smart Screen HarmonyOS independent update covers same/newer/offline/APK/bad-digest & unsigned install guide',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        var installedVersion = '0.1.1';
        final launchedUrls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
          if (call.method == 'getPackageInfo') {
            return <String, String>{
              'appName': 'Marco Movie',
              'packageName': 'com.pilipala.marcomovie',
              'version': installedVersion,
              'buildNumber': '1000002',
            };
          }
          if (call.method == 'openExternalUrl') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            launchedUrls.add(args['url'].toString());
            return true;
          }
          return null;
        });

        final validDigest = 'c' * 64;
        var mode = 'newer';
        AppUpdate.debugHttpClientOverride = MockClient((request) async {
          if (mode == 'offline') {
            throw const SocketException('offline');
          }
          if (mode == 'apk') {
            if (request.url.host != 'api.github.com') {
              return http.Response(
                jsonEncode({
                  'platform': 'harmonyos',
                  'versionName': '0.1.2',
                  'packages': {
                    'MarcoMovie-0.1.2-harmonyos-universal.hap': {
                      'size': 40000000,
                      'sha256': validDigest,
                      'url':
                          'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.1.2/MarcoMovie-0.1.2-mobile.apk',
                    },
                  },
                }),
                200,
              );
            }
            return http.Response('[]', 200);
          }
          if (mode == 'bad_digest') {
            if (request.url.host != 'api.github.com') {
              return http.Response(
                jsonEncode({
                  'platform': 'harmonyos',
                  'versionName': '0.1.2',
                  'packages': {
                    'MarcoMovie-0.1.2-harmonyos-universal.hap': {
                      'size': 40000000,
                      'sha256': 'INVALID_SHA',
                      'url':
                          'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
                    },
                  },
                }),
                200,
              );
            }
            return http.Response('[]', 200);
          }
          expect(request.url.path, '/movie/updates/harmonyos.json');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'schema': 1,
                'platform': 'harmonyos',
                'versionName': mode == 'same' ? '0.1.1' : '0.1.2',
                'prerelease': false,
                'notes': '# Marco Movie HarmonyOS NEXT 0.1.2\n- 恢复 API 12 兼容并修复安全凭据存储',
                'packages': {
                  'MarcoMovie-${mode == 'same' ? '0.1.1' : '0.1.2'}-harmonyos-universal.hap': {
                    'size': 39546323,
                    'sha256': validDigest,
                    'url':
                        'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v${mode == 'same' ? '0.1.1' : '0.1.2'}/MarcoMovie-${mode == 'same' ? '0.1.1' : '0.1.2'}-harmonyos-universal.hap',
                  },
                },
                'release_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/tag/harmonyos-v${mode == 'same' ? '0.1.1' : '0.1.2'}',
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final client = CmsClient(client: _FakeCmsHttpClient());
        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('设置'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('版本与更新'));
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.textContaining('当前已装版本：v0.1.1'), findsOneWidget);

        // 1) Newer version -> shows release notes, SHA-256, unsigned signing guide, and opens HAP URL
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('发现新版本 v0.1.2'), findsOneWidget);
        expect(find.textContaining('MarcoMovie-0.1.2-harmonyos-universal.hap'), findsOneWidget);
        expect(find.textContaining('DevEco Studio'), findsOneWidget);
        expect(find.textContaining('hap-sign-tool'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tv-download-hap-btn')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          launchedUrls,
          contains(
            'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
          ),
        );

        // 2) Same version
        mode = 'same';
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('当前已是最新版本（v0.1.1）'), findsOneWidget);

        // 3) Offline
        mode = 'offline';
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('暂时无法检查更新'), findsOneWidget);
        expect(find.byKey(const ValueKey('tv-download-hap-btn')), findsNothing);

        // 4) Returned APK rejected
        mode = 'apk';
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('暂时无法检查更新'), findsOneWidget);
        expect(find.byKey(const ValueKey('tv-download-hap-btn')), findsNothing);

        // 5) Bad SHA-256 digest rejected
        mode = 'bad_digest';
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('暂时无法检查更新'), findsOneWidget);
        expect(find.byKey(const ValueKey('tv-download-hap-btn')), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'P1-4 Smart Screen live TV auto-fails over A1 -> A2 preserving headers, stays on A when both fail, and enters B only on manual Next Channel',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        final chA = LiveChannel(
          name: '频道 A',
          group: '测试分组',
          urls: const [
            'http://127.0.0.1:18080/a1.m3u8',
            'http://127.0.0.1:18080/a2.m3u8',
          ],
          streams: const [
            CmsEpisode(
              name: '线路 1',
              url: 'http://127.0.0.1:18080/a1.m3u8',
              headers: {'Referer': 'https://a1.example/', 'User-Agent': 'Agent-A1'},
            ),
            CmsEpisode(
              name: '线路 2',
              url: 'http://127.0.0.1:18080/a2.m3u8',
              headers: {'Referer': 'https://a2.example/', 'User-Agent': 'Agent-A2'},
            ),
          ],
        );
        final chB = LiveChannel(
          name: '频道 B',
          group: '测试分组',
          urls: const ['http://127.0.0.1:18080/b1.m3u8'],
          streams: const [
            CmsEpisode(
              name: '线路 1',
              url: 'http://127.0.0.1:18080/b1.m3u8',
              headers: {'Referer': 'https://b1.example/', 'User-Agent': 'Agent-B1'},
            ),
          ],
        );
        final group = LiveGroup(name: '测试分组', channels: [chA, chB]);

        final openCalls = <Map<String, dynamic>>[];
        const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 21, 'textureId': 210};
          }
          if (call.method == 'open') {
            openCalls.add(Map<String, dynamic>.from(call.arguments as Map));
          }
          return true;
        });

        final ohosPlayer = OhosPlatformPlayer();
        final debugPlayer = Player(platformPlayer: ohosPlayer);

        final liveVideo = CmsVideo(
          id: chA.name,
          title: chA.name,
          lines: [CmsLine(name: chA.group, episodes: chA.episodes)],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(
                key: 'live',
                name: '测试直播',
                type: 0,
                api: '',
              ),
              video: liveVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              liveGroups: [group],
              initialLiveChannel: chA,
              debugPlayer: debugPlayer,
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // 1) Initial playback opens A1 with A1's headers
        expect(openCalls, isNotEmpty);
        expect(openCalls.last['url'], 'http://127.0.0.1:18080/a1.m3u8');
        final a1Headers = Map<String, dynamic>.from(openCalls.last['headers'] as Map);
        expect(a1Headers['Referer'], 'https://a1.example/');
        expect(a1Headers['User-Agent'], 'Agent-A1');

        // 2) A1 fails (first error triggers direct/proxy retry, second error fails over to A2 — NEVER B!)
        ohosPlayer.handleNativeEvent({'type': 'error', 'code': 5400103, 'message': 'A1 failed #1'});
        await tester.pump(const Duration(milliseconds: 200));
        ohosPlayer.handleNativeEvent({'type': 'error', 'code': 5400103, 'message': 'A1 failed #2'});
        await tester.pump(const Duration(milliseconds: 250));

        expect(openCalls.last['url'], 'http://127.0.0.1:18080/a2.m3u8');
        final a2Headers = Map<String, dynamic>.from(openCalls.last['headers'] as Map);
        expect(a2Headers['Referer'], 'https://a2.example/');
        expect(a2Headers['User-Agent'], 'Agent-A2');
        expect(openCalls.any((c) => c['url'].toString().contains('b1.m3u8')), isFalse);

        // 3) A2 also fails -> stays on Channel A and shows Retry UI, STILL never jumps to B!
        ohosPlayer.handleNativeEvent({'type': 'error', 'code': 5400103, 'message': 'A2 failed #1'});
        await tester.pump(const Duration(milliseconds: 200));
        ohosPlayer.handleNativeEvent({'type': 'error', 'code': 5400103, 'message': 'A2 failed #2'});
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('重试播放'), findsOneWidget);
        expect(find.text('频道 A'), findsWidgets);
        expect(openCalls.any((c) => c['url'].toString().contains('b1.m3u8')), isFalse);

        // 4) Manual Next Channel -> enters Channel B with B1's headers!
        await tester.tap(find.byKey(const ValueKey('live-error-next-channel')));
        await tester.pump(const Duration(milliseconds: 250));

        expect(openCalls.last['url'], 'http://127.0.0.1:18080/b1.m3u8');
        final b1Headers = Map<String, dynamic>.from(openCalls.last['headers'] as Map);
        expect(b1Headers['Referer'], 'https://b1.example/');
        expect(b1Headers['User-Agent'], 'Agent-B1');
        expect(find.textContaining('频道 B'), findsWidgets);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    test(
      'P1-5a LocalMediaLease loopback proxy preserves Referer/UA across plain MP4 and HLS master -> sub -> segment',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final seenRequests = <String, Map<String, String>>{};
          final upstreamClient = MockClient((req) async {
            final path = req.url.path;
            final headersLower = <String, String>{
              for (final e in req.headers.entries)
                e.key.toLowerCase(): e.value,
            };
            final ref = headersLower['referer'] ?? '';
            final ua = headersLower['user-agent'] ?? '';
            seenRequests[path] = {'referer': ref, 'user-agent': ua};
            if (path == '/plain.mp4') {
              return http.Response(
                'FAKE-MP4-BYTES',
                200,
                headers: const {'content-type': 'video/mp4'},
              );
            }
            if (ref != 'https://hls-origin.example/' ||
                ua != 'MarcoOhosHeaderTest/1.0') {
              return http.Response('missing required headers', 403);
            }
            if (path == '/master.m3u8') {
              return http.Response(
                '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nsub/index.m3u8\n',
                200,
                headers: const {
                  'content-type': 'application/vnd.apple.mpegurl',
                },
              );
            }
            if (path == '/sub/index.m3u8') {
              return http.Response(
                '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
                200,
                headers: const {
                  'content-type': 'application/vnd.apple.mpegurl',
                },
              );
            }
            if (path == '/sub/seg0.ts') {
              return http.Response.bytes(
                List<int>.filled(188, 0x47),
                200,
                headers: const {'content-type': 'video/mp2t'},
              );
            }
            return http.Response('not found', 404);
          });

          // Plain MP4 through LocalMediaLease
          final mp4Lease = await LocalMediaLease.open(
            target: Uri.parse('https://hls-origin.example/plain.mp4'),
            headers: const {'User-Agent': 'MarcoOhosHeaderTest/1.0'},
            client: upstreamClient,
            isCancelled: () => false,
          );
          addTearDown(mp4Lease.close);
          final mp4Resp = await http.get(mp4Lease.url);
          expect(mp4Resp.statusCode, 200);
          expect(mp4Resp.body, 'FAKE-MP4-BYTES');

          // Header-protected HLS master -> sub -> segment
          final hlsLease = await LocalMediaLease.open(
            target: Uri.parse('https://hls-origin.example/master.m3u8'),
            headers: const {
              'Referer': 'https://hls-origin.example/',
              'User-Agent': 'MarcoOhosHeaderTest/1.0',
            },
            client: upstreamClient,
            isCancelled: () => false,
          );
          addTearDown(hlsLease.close);
          final masterResp = await http.get(hlsLease.url);
          expect(masterResp.statusCode, 200);
          final subUrlLine = masterResp.body
              .split('\n')
              .map((l) => l.trim())
              .firstWhere((l) => l.startsWith('http://'));
          final subResp = await http.get(Uri.parse(subUrlLine));
          expect(subResp.statusCode, 200);
          final segUrlLine = subResp.body
              .split('\n')
              .map((l) => l.trim())
              .firstWhere((l) => l.startsWith('http://'));
          final segResp = await http.get(Uri.parse(segUrlLine));
          expect(segResp.statusCode, 200);
          expect(segResp.bodyBytes.length, 188);
          for (final expectedPath in [
            '/master.m3u8',
            '/sub/index.m3u8',
            '/sub/seg0.ts',
          ]) {
            expect(
              seenRequests[expectedPath]?['referer'],
              'https://hls-origin.example/',
            );
            expect(
              seenRequests[expectedPath]?['user-agent'],
              'MarcoOhosHeaderTest/1.0',
            );
          }
        }, _PassthroughHttpOverrides());
      },
    );

    testWidgets(
      'P1-5b Header-error propagation, AVPlayer API 12 speed tiers (0.5x-2.0x) consistency across episode switch, and background/foreground resume',
      (tester) async {
        // Speed options (no 2.5x/3.0x on OHOS), speed normalization on init & episode switch,
        // header-preservation error display, seek/resume, and background/foreground recovery
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        await storage.setPlaySpeed(3.0); // Synced from another platform!
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'phone';

        final calls = <MethodCall>[];
        var failNextOpenWithHeaderError = false;
        const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          calls.add(call);
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 31, 'textureId': 310};
          }
          if (call.method == 'open' && failNextOpenWithHeaderError) {
            failNextOpenWithHeaderError = false;
            throw PlatformException(
              code: 'OHOS_AVPLAYER_ERROR',
              message: '无法保留必要请求头打开播放源 (code=5400102)：Operation not allowed，请重试或切换线路',
            );
          }
          return true;
        });

        final ohosPlayer = OhosPlatformPlayer();
        final debugPlayer = Player(platformPlayer: ohosPlayer);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(
                key: 'vod_site',
                name: '测试点播',
                type: 1,
                api: 'http://127.0.0.1:18080/api',
              ),
              video: const CmsVideo(
                id: 'v1',
                title: '请求头与倍速测试片',
                lines: [
                  CmsLine(
                    name: '默认线路',
                    episodes: [
                      CmsEpisode(
                        name: '第01集',
                        url: 'https://localhost/ep1.mp4',
                        headers: {'Referer': 'https://origin.example/'},
                      ),
                      CmsEpisode(
                        name: '第02集',
                        url: 'https://localhost/ep2.mp4',
                        headers: {'Referer': 'https://origin.example/'},
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
        await tester.pump(const Duration(milliseconds: 250));

        // 1) Synced 3.0x was normalized to AVPlayer API 12 max executable 2.0x
        final rateCalls = calls.where((c) => c.method == 'setRate').toList();
        expect(rateCalls, isNotEmpty);
        expect(
          (Map<String, dynamic>.from(rateCalls.last.arguments as Map)['rate'] as num),
          2.0,
        );
        expect(ohosPlayer.state.rate, 2.0);
        expect(find.text('2.0×'), findsWidgets);
        expect(find.text('3.0×'), findsNothing);

        // 2) Open speed sheet on touch UI: only 0.5x..2.0x exist; 2.5x / 3.0x must NOT be offered!
        await tester.tap(find.text('2.0×').first);
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('0.5× 倍速'), findsOneWidget);
        expect(find.text('1.5× 倍速'), findsOneWidget);
        expect(find.text('2.0× 倍速'), findsOneWidget);
        expect(find.text('2.5× 倍速'), findsNothing);
        expect(find.text('3.0× 倍速'), findsNothing);
        await tester.tap(find.text('1.5× 倍速'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(ohosPlayer.state.rate, 1.5);
        expect(find.text('1.5×'), findsWidgets);

        // 3) Simulate playing + position progress + background/foreground lifecycle recovery
        ohosPlayer.handleNativeEvent({
          'type': 'position',
          'positionMs': 45000,
          'durationMs': 300000,
          'bufferedMs': 90000,
        });
        ohosPlayer.handleNativeEvent({
          'type': 'state',
          'playing': true,
          'buffering': false,
          'completed': false,
        });
        await tester.pump(const Duration(milliseconds: 100));

        final pauseCountBefore = calls.where((c) => c.method == 'pause').length;
        final playCountBefore = calls.where((c) => c.method == 'play').length;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          calls.where((c) => c.method == 'pause').length,
          greaterThan(pauseCountBefore),
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          calls.where((c) => c.method == 'play').length,
          greaterThan(playCountBefore),
        );

        // 4) Switch to episode 2 -> speed stays 1.5x and speedDone/rate readback matches UI
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 250));
        ohosPlayer.handleNativeEvent({'type': 'rate', 'rate': 1.5});
        await tester.pump(const Duration(milliseconds: 100));
        expect(ohosPlayer.state.rate, 1.5);
        expect(find.text('1.5×'), findsWidgets);

        // 5) Header-preservation open failure surfaces actionable retryable error
        failNextOpenWithHeaderError = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('无法保留必要请求头打开播放源'), findsOneWidget);
        expect(find.text('重试播放'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    test(
      'P1-6 HarmonyOS document picker preserves raw ZIP bytes & Chinese names, handles cancel/over-limit/corrupt, and round-trips backup export -> restart -> restore',
      () async {
        OhosRuntime.debugIsOhosOverride = true;
        final zipArchive = Archive();
        final subJson = jsonEncode({
          'sites': [
            {
              'key': 'cn_zip_site',
              'name': '中文压缩包片源',
              'type': 1,
              'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
              'searchable': 1,
            },
          ],
        });
        final subBytes = utf8.encode(subJson);
        zipArchive.addFile(ArchiveFile('config.json', subBytes.length, subBytes));
        final validZipBytes = Uint8List.fromList(ZipEncoder().encode(zipArchive)!);

        String mockMode = 'zip';
        String? lastSavedFileName;
        String? lastSavedContent;
        Map<String, dynamic>? lastPickArgs;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
          if (call.method == 'pickDocumentFile') {
            lastPickArgs = Map<String, dynamic>.from(call.arguments as Map);
            switch (mockMode) {
              case 'zip':
                return <String, Object?>{
                  'name': '我的订阅_中文配置.zip',
                  'path': 'file://docs/我的订阅_中文配置.zip',
                  'bytes': validZipBytes,
                  'size': validZipBytes.length,
                };
              case 'cancel':
                return null;
              case 'over_limit':
                throw PlatformException(
                  code: 'OHOS_SYSTEM_ERROR',
                  message: 'FILE_TOO_LARGE:所选文件超过 16 MB 限制',
                );
              case 'corrupt_zip':
                return <String, Object?>{
                  'name': '损坏配置包.zip',
                  'path': 'file://docs/损坏配置包.zip',
                  'bytes': Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 0x00, 0xFF]),
                  'size': 6,
                };
              case 'exported_backup':
                final bytes = Uint8List.fromList(utf8.encode(lastSavedContent ?? ''));
                return <String, Object?>{
                  'name': '中文备份_2026.json',
                  'path': 'file://docs/中文备份_2026.json',
                  'bytes': bytes,
                  'size': bytes.length,
                };
            }
          }
          if (call.method == 'saveTextFile') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            lastSavedFileName = args['fileName']?.toString();
            lastSavedContent = args['content']?.toString();
            return 'file://docs/$lastSavedFileName';
          }
          return null;
        });

        // 1) ZIP subscription preserves raw bytes & Chinese filename and parses via CmsClient.readSubscriptionFile
        final pickedZip = await OhosRuntime.pickDocumentFile(
          purpose: OhosDocumentPurpose.subscription,
          maxBytes: CmsClient.maxResponseBytes,
        );
        expect(pickedZip, isNotNull);
        expect(pickedZip!.name, '我的订阅_中文配置.zip');
        expect(pickedZip.bytes, validZipBytes);
        expect(lastPickArgs?['asBytes'], isTrue);
        expect(lastPickArgs?['extensions'], contains('.zip'));
        final extracted = CmsClient.readSubscriptionFile(pickedZip.bytes, pickedZip.name);
        expect(extracted, contains('中文压缩包片源'));

        // 2) Cancel returns null without throwing
        mockMode = 'cancel';
        expect(
          await OhosRuntime.pickDocumentFile(
            purpose: OhosDocumentPurpose.live,
            maxBytes: CmsClient.maxResponseBytes,
          ),
          isNull,
        );

        // 3) Over-limit throws clean FormatException
        mockMode = 'over_limit';
        await expectLater(
          OhosRuntime.pickDocumentFile(
            purpose: OhosDocumentPurpose.subscription,
            maxBytes: CmsClient.maxResponseBytes,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('16 MB'),
            ),
          ),
        );

        // 4) Corrupt file throws and preserves existing user config
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        await storage.saveConfig(extracted);
        await storage.setTvAmbientTheme('twilight');
        await storage.toggleFavorite(
          const CmsSite(
            key: 'cn_zip_site',
            name: '中文压缩包片源',
            type: 1,
            api: 'http://127.0.0.1:18080/api.php/provide/vod/',
          ),
          const CmsVideo(
            id: 'fav1',
            title: '原配置保留测试剧',
            poster: '',
            remarks: '4K',
          ),
        );
        mockMode = 'corrupt_zip';
        final corruptPicked = await OhosRuntime.pickDocumentFile(
          purpose: OhosDocumentPurpose.subscription,
          maxBytes: CmsClient.maxResponseBytes,
        );
        expect(
          () => CmsClient.readSubscriptionFile(corruptPicked!.bytes, corruptPicked.name),
          throwsA(anything),
        );
        expect(storage.loadSavedConfig()?.sites.first.key, 'cn_zip_site');
        expect(storage.getFavorites().first.title, '原配置保留测试剧');

        // 5) Export backup -> simulated fresh restart -> restore via OhosRuntime document picker
        final exportedJson = storage.exportBackupJson();
        final savedUri = await OhosRuntime.saveTextFile(
          fileName: 'marco-movie-backup.json',
          content: exportedJson,
        );
        expect(savedUri, isNotNull);
        expect(lastSavedContent, exportedJson);

        SharedPreferences.setMockInitialValues({});
        final freshStorage = await StorageService.init();
        expect(freshStorage.getFavorites(), isEmpty);
        mockMode = 'exported_backup';
        final restoredPick = await OhosRuntime.pickDocumentFile(
          purpose: OhosDocumentPurpose.backup,
          maxBytes: StorageService.maxSyncPayloadBytes,
        );
        expect(restoredPick!.name, '中文备份_2026.json');
        await freshStorage.importBackupJson(
          restoredPick.decodeUtf8(allowMalformed: false),
        );
        expect(freshStorage.loadSavedConfig()?.sites.first.key, 'cn_zip_site');
        expect(freshStorage.getFavorites().first.title, '原配置保留测试剧');
      },
    );

    testWidgets(
      'P2-7 Smart Screen global search covers 17th site with max concurrency 4, handles single-site timeout, all-failed, true-zero, and rapid keyword switch',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        final sitesJson = List.generate(
          18,
          (i) => {
            'key': 's_${i + 1}',
            'name': '站点${i + 1}',
            'type': 1,
            'api': 'http://127.0.0.1:18080/site/${i + 1}/api.php/provide/vod/',
            'searchable': 1,
          },
        );
        await storage.saveConfig(jsonEncode({'sites': sitesJson}));

        var activeInFlight = 0;
        var maxInFlight = 0;
        var searchMode = 'hit17';
        final slowACompleter = Completer<void>();

        final searchClient = CmsClient(
          client: MockClient((request) async {
            final path = request.url.path;
            final wd = request.url.queryParameters['wd'] ?? '';
            if (wd.isEmpty) {
              return http.Response(
                jsonEncode({'code': 1, 'page': 1, 'pagecount': 1, 'list': []}),
                200,
              );
            }
            activeInFlight++;
            if (activeInFlight > maxInFlight) maxInFlight = activeInFlight;
            try {
              final siteMatch = RegExp(r'/site/(\d+)/').firstMatch(path);
              final siteNum = int.parse(siteMatch!.group(1)!);

              if (searchMode == 'hit17') {
                await Future<void>.delayed(const Duration(milliseconds: 5));
                if (siteNum == 17) {
                  return http.Response.bytes(
                    utf8.encode(
                      jsonEncode({
                        'code': 1,
                        'list': [
                          {
                            'vod_id': 'hit17',
                            'vod_name': '第17站唯一命中影片',
                            'vod_play_from': 'm3u8',
                            'vod_play_url': '正片\$http://127.0.0.1:18080/17.m3u8',
                          },
                        ],
                      }),
                    ),
                    200,
                    headers: const {'content-type': 'application/json; charset=utf-8'},
                  );
                }
                return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
              }

              if (searchMode == 'single_timeout') {
                if (siteNum == 1) {
                  await Future<void>.delayed(const Duration(milliseconds: 400));
                }
                if (siteNum == 2) {
                  return http.Response.bytes(
                    utf8.encode(
                      jsonEncode({
                        'code': 1,
                        'list': [
                          {
                            'vod_id': 'fast2',
                            'vod_name': '二号站先到命中',
                            'vod_play_from': 'm3u8',
                            'vod_play_url': '正片\$http://127.0.0.1:18080/2.m3u8',
                          },
                        ],
                      }),
                    ),
                    200,
                    headers: const {'content-type': 'application/json; charset=utf-8'},
                  );
                }
                return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
              }

              if (searchMode == 'all_fail') {
                return http.Response('Internal Server Error', 500);
              }

              if (searchMode == 'true_zero') {
                return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
              }

              if (searchMode == 'race') {
                if (wd == 'A') {
                  await slowACompleter.future;
                  return http.Response.bytes(
                    utf8.encode(
                      jsonEncode({
                        'code': 1,
                        'list': [
                          {
                            'vod_id': 'staleA',
                            'vod_name': '旧关键词A迟到结果',
                            'vod_play_from': 'm3u8',
                            'vod_play_url': '正片\$http://127.0.0.1:18080/a.m3u8',
                          },
                        ],
                      }),
                    ),
                    200,
                    headers: const {'content-type': 'application/json; charset=utf-8'},
                  );
                }
                if (siteNum == 1) {
                  return http.Response.bytes(
                    utf8.encode(
                      jsonEncode({
                        'code': 1,
                        'list': [
                          {
                            'vod_id': 'freshB',
                            'vod_name': '新关键词B正确结果',
                            'vod_play_from': 'm3u8',
                            'vod_play_url': '正片\$http://127.0.0.1:18080/b.m3u8',
                          },
                        ],
                      }),
                    ),
                    200,
                    headers: const {'content-type': 'application/json; charset=utf-8'},
                  );
                }
                return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
              }

              return http.Response(jsonEncode({'code': 1, 'list': []}), 200);
            } finally {
              activeInFlight--;
            }
          }),
        );

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: storage,
              client: searchClient,
              searchSiteTimeout: const Duration(milliseconds: 120),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('搜索'));
        await tester.pump(const Duration(milliseconds: 200));

        final submitSearch = find.descendant(
          of: find.byType(TvRemoteGridKeyboard),
          matching: find.text('搜索'),
        );

        // 1) Site #17 is the ONLY hit + concurrency never exceeds 4
        await tester.tap(find.text('A'));
        await tester.pump();
        await tester.tap(submitSearch);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('第17站唯一命中影片'), findsOneWidget);
        expect(maxInFlight, lessThanOrEqualTo(4));

        // 2) Single-site timeout: fast hit arrives & displays + timeout notice shown
        searchMode = 'single_timeout';
        await tester.tap(submitSearch);
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.text('二号站先到命中'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.textContaining('含 1 站超时'), findsOneWidget);

        // 3) All sites fail -> distinct failure state with retry pill
        searchMode = 'all_fail';
        await tester.tap(submitSearch);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining('搜索失败：全部 18 个站点'), findsOneWidget);
        expect(find.byKey(const ValueKey('tv-search-retry-btn')), findsOneWidget);

        // 4) True zero results -> clean empty message, no retry failure alert
        searchMode = 'true_zero';
        await tester.tap(submitSearch);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('未找到匹配的影视内容，可尝试缩短关键词'), findsOneWidget);
        expect(find.byKey(const ValueKey('tv-search-retry-btn')), findsNothing);

        // 5) Rapid keyword switch: start slow 'A', immediately switch to 'AB', release 'A' late -> only 'B' shown
        searchMode = 'race';
        await tester.tap(submitSearch); // searches 'A' (hangs on slowACompleter)
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.text('B')); // query becomes 'AB'
        await tester.pump();
        await tester.tap(submitSearch); // searches 'AB' (fast hit)
        await tester.pump(const Duration(milliseconds: 120));
        slowACompleter.complete();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('新关键词B正确结果'), findsOneWidget);
        expect(find.text('旧关键词A迟到结果'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'P1-4b TvLivingRoomShell live tab opens PlayerScreen with only current channel routes + liveGroups',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        const m3uPayload = '''
#EXTM3U
#EXTINF:-1 group-title="新闻组",频道A
#EXTVLCOPT:http-referrer=https://a1.example/
#EXTVLCOPT:http-user-agent=Agent-A1
http://127.0.0.1:18080/a1.m3u8
#EXTINF:-1 group-title="新闻组",频道A
#EXTVLCOPT:http-referrer=https://a2.example/
#EXTVLCOPT:http-user-agent=Agent-A2
http://127.0.0.1:18080/a2.m3u8
#EXTINF:-1 group-title="新闻组",频道B
#EXTVLCOPT:http-referrer=https://b1.example/
http://127.0.0.1:18080/b1.m3u8
''';
        await storage.saveConfig(
          jsonEncode({
            'sites': [],
            'lives': [
              {
                'name': '测试直播源',
                'type': 0,
                'url': 'http://127.0.0.1:18080/live.m3u',
              },
            ],
          }),
        );

        final liveClient = CmsClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/live.m3u')) {
              return http.Response.bytes(
                utf8.encode(m3uPayload),
                200,
                headers: const {'content-type': 'text/plain; charset=utf-8'},
              );
            }
            return http.Response('{}', 200);
          }),
        );

        CmsVideo? openedVideo;
        List<LiveGroup>? openedGroups;
        LiveChannel? openedInitialChannel;

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: storage,
              client: liveClient,
              debugLiveRouteBuilder: (site, video, groups, initialChannel) {
                openedVideo = video;
                openedGroups = groups;
                openedInitialChannel = initialChannel;
                return MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('LiveRouteOpened')),
                );
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('直播'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.ensureVisible(find.text('频道A').first);
        await tester.pump();
        await tester.tap(find.text('频道A').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('LiveRouteOpened'), findsOneWidget);
        expect(openedVideo, isNotNull);
        expect(openedVideo!.lines.first.episodes.length, 2);
        expect(
          openedVideo!.lines.first.episodes.map((e) => e.url).toList(),
          [
            'http://127.0.0.1:18080/a1.m3u8',
            'http://127.0.0.1:18080/a2.m3u8',
          ],
        );
        expect(
          openedVideo!.lines.first.episodes[0].headers['Referer'],
          'https://a1.example/',
        );
        expect(
          openedVideo!.lines.first.episodes[1].headers['Referer'],
          'https://a2.example/',
        );
        expect(openedInitialChannel?.name, '频道A');
        expect(openedGroups?.first.channels.map((c) => c.name).toList(), ['频道A', '频道B']);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'Journey 1 (Touchscreen Phone): HarmonyOS update panel reads HAP (not windowsUrl), imports subscription, searches, plays VOD, and resumes progress after exit',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'phone';

        final subConfigJson = jsonEncode({
          'sites': [
            {
              'key': 'phone_vod',
              'name': '鸿蒙手机点播站',
              'type': 1,
              'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
              'searchable': 1,
            },
          ],
        });
        final launchedUrls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
          if (call.method == 'getPackageInfo') {
            return <String, String>{
              'appName': 'Marco Movie',
              'packageName': 'com.pilipala.marcomovie',
              'version': '0.1.1',
              'buildNumber': '1000002',
            };
          }
          if (call.method == 'openExternalUrl') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
            launchedUrls.add(args['url'].toString());
            return true;
          }
          if (call.method == 'pickDocumentFile') {
            final bytes = Uint8List.fromList(utf8.encode(subConfigJson));
            return <String, Object?>{
              'name': '手机订阅配置.json',
              'path': 'file://docs/手机订阅配置.json',
              'bytes': bytes,
              'size': bytes.length,
            };
          }
          return null;
        });

        final avCalls = <MethodCall>[];
        OhosPlatformPlayer? activeOhosPlayer;
        const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          avCalls.add(call);
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 51, 'textureId': 510};
          }
          return true;
        });

        final validDigest = 'd' * 64;
        AppUpdate.debugHttpClientOverride = MockClient((request) async {
          expect(request.url.path, '/movie/updates/harmonyos.json');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'schema': 1,
                'platform': 'harmonyos',
                'versionName': '0.1.2',
                'prerelease': false,
                'notes': '- 鸿蒙手机端更新说明',
                'packages': {
                  'MarcoMovie-0.1.2-harmonyos-universal.hap': {
                    'size': 39500000,
                    'sha256': validDigest,
                    'url':
                        'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
                  },
                },
                'release_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/tag/harmonyos-v0.1.2',
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });

        // 1) Import subscription via HarmonyOS document picker & verify search returns VOD
        final picked = await OhosRuntime.pickDocumentFile(
          purpose: OhosDocumentPurpose.subscription,
          maxBytes: CmsClient.maxResponseBytes,
        );
        expect(picked?.name, '手机订阅配置.json');
        await storage.saveConfig(
          CmsClient.readSubscriptionFile(picked!.bytes, picked.name),
        );
        final savedSite = storage.loadSavedConfig()!.sites.first;
        expect(savedSite.key, 'phone_vod');

        final phoneClient = CmsClient(
          client: MockClient((request) async {
            final wd = request.url.queryParameters['wd'] ?? '';
            if (wd.isNotEmpty) {
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'code': 1,
                    'list': [
                      {
                        'vod_id': 'vod_101',
                        'vod_name': '鸿蒙续播测试剧',
                        'vod_play_from': '高清线',
                        'vod_play_url':
                            '第01集\$https://localhost/ep1.mp4#第02集\$https://localhost/ep2.mp4',
                      },
                    ],
                  }),
                ),
                200,
                headers: const {'content-type': 'application/json; charset=utf-8'},
              );
            }
            return http.Response.bytes(
              utf8.encode(jsonEncode({'code': 1, 'page': 1, 'pagecount': 1, 'list': []})),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );

        final foundListing = await phoneClient.fetchSearch(savedSite, '续播');
        expect(foundListing.videos, hasLength(1));
        final vod = foundListing.videos.first;
        expect(vod.title, '鸿蒙续播测试剧');

        // 2) Play VOD -> advance to 65s -> exit -> reopen and verify resume seek to 65s
        activeOhosPlayer = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: savedSite,
              video: vod,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: Player(platformPlayer: activeOhosPlayer),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        activeOhosPlayer.handleNativeEvent({
          'type': 'position',
          'positionMs': 65000,
          'durationMs': 600000,
          'bufferedMs': 120000,
        });
        activeOhosPlayer.handleNativeEvent({
          'type': 'state',
          'playing': true,
          'buffering': false,
          'completed': false,
        });
        await tester.pump(const Duration(milliseconds: 200));
        // Exit player -> saves watch progress
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));

        final history = storage.getWatchHistory();
        expect(history, isNotEmpty);
        expect(history.first.position, 65000);

        // Reopen same VOD -> resumes at 65s
        avCalls.clear();
        final resumePlayer = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: savedSite,
              video: vod,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              initialPositionMs: history.first.resumePosition,
              storage: storage,
              debugPlayer: Player(platformPlayer: resumePlayer),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        final openCall = avCalls.lastWhere((c) => c.method == 'open');
        final openArgs = Map<String, dynamic>.from(openCall.arguments as Map);
        expect(openArgs['startPositionMs'], 65000);

        // 3) Touchscreen AdaptiveShell update check reads HarmonyOS HAP (never windowsUrl) & shows unsigned guide
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: phoneClient,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('设置').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final updateTile = find.text('检查版本更新').evaluate().isNotEmpty
            ? find.text('检查版本更新')
            : find.text('软件更新与版本');
        await tester.scrollUntilVisible(
          updateTile,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -180));
        await tester.pump();
        await tester.tap(updateTile);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining('0.1.2'), findsWidgets);
        expect(find.textContaining('DevEco Studio'), findsOneWidget);
        expect(find.textContaining('MarcoMovie-0.1.2-harmonyos-universal.hap'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'Journey 2 (Smart Screen Remote-Only): D-pad search -> detail -> episode -> return preserving state',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'tv_vod',
                'name': '智慧屏片源站',
                'type': 1,
                'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
                'searchable': 1,
              },
            ],
          }),
        );

        final tvClient = CmsClient(
          client: MockClient((request) async {
            final wd = request.url.queryParameters['wd'] ?? '';
            final ids = request.url.queryParameters['ids'] ?? '';
            if (wd.isNotEmpty || ids.isNotEmpty) {
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'code': 1,
                    'list': [
                      {
                        'vod_id': 'tv_1',
                        'vod_name': '遥控器全流程剧',
                        'vod_remarks': '全2集',
                        'vod_play_from': '4K线路',
                        'vod_play_url':
                            '第01集\$https://localhost/tv1.mp4#第02集\$https://localhost/tv2.mp4',
                      },
                    ],
                  }),
                ),
                200,
                headers: const {'content-type': 'application/json; charset=utf-8'},
              );
            }
            return http.Response.bytes(
              utf8.encode(jsonEncode({'code': 1, 'page': 1, 'pagecount': 1, 'list': []})),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: storage,
              client: tvClient,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // 1) Navigate to Search tab, enter 'A' and search
        await tester.tap(find.text('搜索'));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('A'));
        await tester.pump();
        final submitSearch = find.descendant(
          of: find.byType(TvRemoteGridKeyboard),
          matching: find.text('搜索'),
        );
        await tester.tap(submitSearch);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('遥控器全流程剧'), findsOneWidget);

        // 2) Enter TvDetailScreen -> verify episodes rendered -> navigate back with Escape (remote Back)
        await tester.ensureVisible(find.text('遥控器全流程剧'));
        await tester.pump();
        await tester.tap(find.text('遥控器全流程剧'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(TvDetailScreen), findsOneWidget);
        expect(find.text('第02集'), findsWidgets);

        await tester.tap(find.text('← 返回'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));

        // 3) Returned cleanly to search results still showing the matched card
        expect(find.byType(TvDetailScreen), findsNothing);
        expect(find.text('遥控器全流程剧'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      },
    );
  });

  group('Round-2 HarmonyOS Review Rework Regressions', () {
    tearDown(() {
      const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(avChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(OhosRuntime.systemChannel, null);
      AppUpdate.debugHttpClientOverride = null;
      OhosRuntime.resetForTesting();
    });

    testWidgets(
      'R2-2 distinguishes silent stall failover, 10s mid-playback terminal error, and explicit user pause',
      (tester) async {
        const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
        final chA = const LiveChannel(
          name: '测试频道A',
          group: '央视频道',
          urls: [
            'http://127.0.0.1:18080/a1.m3u8',
            'http://127.0.0.1:18080/a2.m3u8',
          ],
        );
        final chB = const LiveChannel(
          name: '测试频道B',
          group: '央视频道',
          urls: ['http://127.0.0.1:18080/b1.m3u8'],
        );
        final liveGroups = [LiveGroup(name: '央视频道', channels: [chA, chB])];

        // --- Case 1: Silent stall (playing=false, buffering=true) -> retry A1 -> switch A2 -> stay on A with Retry ---
        SharedPreferences.setMockInitialValues({});
        var storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';
        final opens1 = <String>[];
        late OhosPlatformPlayer player1;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 71, 'textureId': 710};
          }
          if (call.method == 'open') {
            opens1.add((call.arguments as Map)['url'] as String);
            scheduleMicrotask(() {
              player1.handleNativeEvent({
                'type': 'state',
                'playing': false,
                'buffering': true,
                'completed': false,
              });
            });
          }
          return true;
        });
        player1 = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(key: 'live', name: '直播', type: 0, api: ''),
              video: CmsVideo(
                id: chA.name,
                title: chA.name,
                lines: [CmsLine(name: chA.group, episodes: chA.episodes)],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              initialLiveChannel: chA,
              liveGroups: liveGroups,
              debugPlayer: Player(platformPlayer: player1),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(opens1, ['http://127.0.0.1:18080/a1.m3u8']);
        // 7s -> retries A1; 15s -> switches to A2; 30s -> A2 exhausted -> stays on A with Retry UI
        for (var s = 0; s < 32; s++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(opens1.contains('http://127.0.0.1:18080/a2.m3u8'), isTrue);
        expect(opens1.contains('http://127.0.0.1:18080/b1.m3u8'), isFalse);
        expect(find.text('重试播放'), findsOneWidget);
        expect(find.textContaining('测试频道A'), findsWidgets);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));

        // --- Case 2: Normal playback for 10s, then native reports terminal error ---
        SharedPreferences.setMockInitialValues({});
        storage = await StorageService.init();
        final opens2 = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 72, 'textureId': 720};
          }
          if (call.method == 'open') {
            opens2.add((call.arguments as Map)['url'] as String);
          }
          return true;
        });
        final player2 = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(key: 'live', name: '直播', type: 0, api: ''),
              video: CmsVideo(
                id: chA.name,
                title: chA.name,
                lines: [CmsLine(name: chA.group, episodes: chA.episodes)],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              initialLiveChannel: chA,
              liveGroups: liveGroups,
              debugPlayer: Player(platformPlayer: player2),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        player2.handleNativeEvent({
          'type': 'state',
          'playing': true,
          'buffering': false,
          'completed': false,
        });
        player2.handleNativeEvent({
          'type': 'videoSize',
          'width': 1920,
          'height': 1080,
        });
        for (var sec = 1; sec <= 10; sec++) {
          player2.handleNativeEvent({
            'type': 'position',
            'positionMs': sec * 1000,
            'durationMs': 0,
            'bufferedMs': sec * 1000,
          });
          await tester.pump(const Duration(seconds: 1));
        }
        // 10s of normal playback: no timeout retry, no error
        expect(opens2, ['http://127.0.0.1:18080/a1.m3u8']);
        expect(find.text('重试播放'), findsNothing);
        // Terminal AVPlayer error at t=10s must surface Retry UI (NOT swallowed, NOT jumping to A2/B)
        player2.handleNativeEvent({
          'type': 'state',
          'playing': false,
          'buffering': false,
          'completed': false,
        });
        player2.handleNativeEvent({
          'type': 'error',
          'code': 5400103,
          'message': 'AVPlayer error (5400103): stream disconnected',
        });
        await tester.pump(const Duration(milliseconds: 250));
        expect(opens2, ['http://127.0.0.1:18080/a1.m3u8']);
        expect(find.text('重试播放'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));

        // --- Case 3: Explicit user pause cancels startup timeout (no retry, no failover, no error) ---
        SharedPreferences.setMockInitialValues({});
        storage = await StorageService.init();
        final opens3 = <String>[];
        var pauseCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 73, 'textureId': 730};
          }
          if (call.method == 'open') {
            opens3.add((call.arguments as Map)['url'] as String);
          }
          if (call.method == 'pause') {
            pauseCalls++;
          }
          return true;
        });
        final player3 = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(key: 'live', name: '直播', type: 0, api: ''),
              video: CmsVideo(
                id: chA.name,
                title: chA.name,
                lines: [CmsLine(name: chA.group, episodes: chA.episodes)],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              initialLiveChannel: chA,
              liveGroups: liveGroups,
              debugPlayer: Player(platformPlayer: player3),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        player3.handleNativeEvent({
          'type': 'state',
          'playing': false,
          'buffering': true,
          'completed': false,
        });
        await tester.pump(const Duration(milliseconds: 100));
        // User explicitly pauses via Space key during initial wait
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 100));
        expect(pauseCalls, greaterThanOrEqualTo(1));

        // A failed in-flight open must not resume or switch a user-paused live stream.
        player3.handleNativeEvent({
          'type': 'error',
          'code': 5400103,
          'message': 'AVPlayer error: in-flight source failed after user paused',
        });
        await tester.pump(const Duration(milliseconds: 250));
        for (var s = 0; s < 25; s++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(opens3, ['http://127.0.0.1:18080/a1.m3u8']);
        expect(find.text('重试播放'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));
      },
    );

    testWidgets(
      'R2-3 phone and Smart Screen update panels distinguish remote older, equal, and newer versions',
      (tester) async {
        http.Response buildFeed(String remoteVersion) {
          final name = 'MarcoMovie-$remoteVersion-harmonyos-universal.hap';
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'schema': 1,
                'platform': 'harmonyos',
                'versionName': remoteVersion,
                'notes': '- HarmonyOS v$remoteVersion release notes',
                'packages': {
                  name: {
                    'size': 39546323,
                    'sha256': 'e' * 64,
                    'url':
                        'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v$remoteVersion/$name',
                  },
                },
                'release_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/tag/harmonyos-v$remoteVersion',
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
          if (call.method == 'getPackageInfo') {
            return <String, String>{
              'appName': 'Marco Movie',
              'packageName': 'com.pilipala.marcomovie',
              'version': '0.1.2',
              'buildNumber': '1000003',
            };
          }
          return null;
        });

        // --- Part A: Smart Screen (TV) 3-way check ---
        SharedPreferences.setMockInitialValues({});
        final tvStorage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';
        var feedVersion = '0.1.1';
        AppUpdate.debugHttpClientOverride =
            MockClient((_) async => buildFeed(feedVersion));

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: tvStorage,
              client: CmsClient(client: _StaticJsonHttpClient('{}')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('设置'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('版本与更新'));
        await tester.pump(const Duration(milliseconds: 150));

        // 1) Remote older (0.1.1 < 0.1.2): show BOTH versions, HIDE download button
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining('0.1.2'), findsWidgets);
        expect(find.textContaining('0.1.1'), findsWidgets);
        expect(find.byKey(const ValueKey('tv-download-hap-btn')), findsNothing);
        expect(find.text('重新下载 HAP v0.1.1'), findsNothing);

        // 2) Remote equal (0.1.2 == 0.1.2): show re-download button
        feedVersion = '0.1.2';
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('tv-download-hap-btn')), findsOneWidget);
        expect(find.text('重新下载 HAP v0.1.2'), findsOneWidget);

        // 3) Remote newer (0.1.3 > 0.1.2): show upgrade download button
        feedVersion = '0.1.3';
        await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const ValueKey('tv-download-hap-btn')), findsOneWidget);
        expect(find.text('下载未签名 HAP v0.1.3'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));

        // --- Part B: Phone / Touchscreen AdaptiveShell 3-way check ---
        Future<void> verifyPhoneUpdateMode(
          String remoteVer, {
          required bool expectDownloadBtn,
          String? expectedBtnLabel,
        }) async {
          SharedPreferences.setMockInitialValues({});
          final phoneStorage = await StorageService.init();
          OhosRuntime.debugIsOhosOverride = true;
          OhosRuntime.debugDeviceTypeOverride = 'phone';
          AppUpdate.debugHttpClientOverride =
              MockClient((_) async => buildFeed(remoteVer));
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(
            MaterialApp(
              home: AdaptiveShell(
                storage: phoneStorage,
                client: CmsClient(client: _StaticJsonHttpClient('{}')),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 250));
          await tester.tap(find.text('设置').last);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          final updateTile = find.text('检查版本更新').evaluate().isNotEmpty
              ? find.text('检查版本更新')
              : find.text('软件更新与版本');
          await tester.scrollUntilVisible(
            updateTile,
            250,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.drag(find.byType(Scrollable).last, const Offset(0, -180));
          await tester.pump();
          await tester.tap(updateTile);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));

          expect(find.textContaining('0.1.2'), findsWidgets);
          expect(find.textContaining(remoteVer), findsWidgets);
          if (expectDownloadBtn) {
            expect(
              find.byKey(const ValueKey('ohos-update-download-hap')),
              findsOneWidget,
            );
            expect(find.text(expectedBtnLabel!), findsOneWidget);
          } else {
            expect(
              find.byKey(const ValueKey('ohos-update-download-hap')),
              findsNothing,
            );
            expect(find.text('重新下载 HAP v$remoteVer'), findsNothing);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 250));
        }

        await verifyPhoneUpdateMode('0.1.1', expectDownloadBtn: false);
        await verifyPhoneUpdateMode(
          '0.1.2',
          expectDownloadBtn: true,
          expectedBtnLabel: '重新下载 HAP v0.1.2',
        );
        await verifyPhoneUpdateMode(
          '0.1.3',
          expectDownloadBtn: true,
          expectedBtnLabel: '下载未签名 HAP v0.1.3',
        );
      },
    );

    testWidgets(
      'R2-4 unifies local backup UTF-8 limits (>8 MiB 2-sub round-trip, exact boundary, corrupt preserves config, WebDAV stays 8 MiB)',
      (tester) async {
        // WebDAV sync limit stays untouched at 8 MiB; local backup limit is unified at 32 MiB
        expect(StorageService.maxSyncPayloadBytes, 8 * 1024 * 1024);
        expect(StorageService.maxLocalBackupBytes, 32 * 1024 * 1024);

        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        // 1) Two valid subscriptions totaling > 8 MiB (~4.6 MiB each -> > 9.2 MiB combined, exported backup > 13 MiB)
        String buildLargeValidConfig(String prefix, int targetBytes) {
          final sites = <Map<String, dynamic>>[];
          final pad = 'x' * 4000;
          var idx = 0;
          while (idx * 4120 < targetBytes) {
            idx++;
            sites.add({
              'key': '${prefix}_site_$idx',
              'name': '$prefix 站点 $idx',
              'type': 1,
              'api': 'http://127.0.0.1:18080/$prefix/$idx',
              'ext': pad,
            });
          }
          return jsonEncode({'sites': sites});
        }

        final rawSub1 = buildLargeValidConfig('subA', 4600 * 1024);
        final rawSub2 = buildLargeValidConfig('subB', 4600 * 1024);
        expect(
          utf8.encode(rawSub1).length + utf8.encode(rawSub2).length,
          greaterThan(StorageService.maxSyncPayloadBytes),
        );

        await storage.saveSubscriptions([
          SubscriptionEntry(
            id: 'sub_large_1',
            name: '大型订阅一',
            url: 'http://127.0.0.1:18080/sub1.json',
            rawContent: rawSub1,
          ),
          SubscriptionEntry(
            id: 'sub_large_2',
            name: '大型订阅二',
            url: 'http://127.0.0.1:18080/sub2.json',
            rawContent: rawSub2,
          ),
        ]);
        await storage.toggleFavorite(
          const CmsSite(key: 'subA_site_1', name: 'subA 站点 1', type: 1, api: 'http://127.0.0.1:18080/subA/1'),
          const CmsVideo(id: 'fav_1', title: '大备份收藏片'),
        );

        String? capturedExportText;
        Uint8List? mockPickedBytes;
        String mockPickedName = 'marco-movie-backup.json';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
          final args = call.arguments is Map
              ? Map<String, dynamic>.from(call.arguments as Map)
              : const <String, dynamic>{};
          if (call.method == 'saveTextFile') {
            capturedExportText = args['content']?.toString() ?? '';
            return 'file://docs/marco-movie-backup.json';
          }
          if (call.method == 'pickDocumentFile') {
            final maxBytes = (args['maxBytes'] as num?)?.toInt() ?? 0;
            final bytes = mockPickedBytes!;
            if (maxBytes > 0 && bytes.length > maxBytes) {
              throw PlatformException(
                code: 'OHOS_ERR',
                message: 'FILE_TOO_LARGE:所选文件超过 ${maxBytes ~/ (1024 * 1024)} MB 限制',
              );
            }
            return <String, Object?>{
              'name': mockPickedName,
              'path': 'file://docs/$mockPickedName',
              'bytes': bytes,
              'size': bytes.length,
            };
          }
          return null;
        });

        // Smart Screen export & restore > 8 MiB two-subscription backup
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: storage,
              client: CmsClient(client: _StaticJsonHttpClient('{}')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('设置'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('备份与存储'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('导出备份文件 / 复制 JSON'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('已导出备份文件'), findsOneWidget);
        expect(capturedExportText, isNotNull);
        final exportedBytes = utf8.encode(capturedExportText!);
        expect(exportedBytes.length, greaterThan(StorageService.maxSyncPayloadBytes));
        expect(exportedBytes.length, lessThanOrEqualTo(StorageService.maxLocalBackupBytes));

        // Reset into a fresh storage & restore via Smart Screen picker (fresh cold start)
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        SharedPreferences.setMockInitialValues({});
        final restoredTvStorage = await StorageService.init();
        mockPickedBytes = Uint8List.fromList(exportedBytes);
        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: restoredTvStorage,
              client: CmsClient(client: _StaticJsonHttpClient('{}')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('设置'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('备份与存储'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('从本地备份文件恢复'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('跨端备份已恢复'), findsOneWidget);
        expect(restoredTvStorage.getSubscriptions().length, 2);
        expect(restoredTvStorage.getFavorites().map((f) => f.title), contains('大备份收藏片'));

        // Corrupt backup file on Smart Screen -> fails cleanly & preserves existing subscriptions/favorites
        mockPickedBytes = Uint8List.fromList(utf8.encode('{corrupt json payload'));
        await tester.tap(find.text('从本地备份文件恢复'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(restoredTvStorage.getSubscriptions().length, 2);
        expect(restoredTvStorage.getFavorites().map((f) => f.title), contains('大备份收藏片'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));

        // Phone AdaptiveShell export & restore of the same > 8 MiB two-subscription backup
        OhosRuntime.debugDeviceTypeOverride = 'phone';
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        capturedExportText = null;

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: restoredTvStorage,
              client: CmsClient(client: _StaticJsonHttpClient('{}')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('设置').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final backupTile = find.text('跨平台备份与恢复').evaluate().isNotEmpty
            ? find.text('跨平台备份与恢复')
            : find.text('备份与恢复');
        await tester.scrollUntilVisible(
          backupTile,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(backupTile);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('backup-save-json-file')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('导出成功'), findsOneWidget);
        expect(
          utf8.encode(capturedExportText!).length,
          greaterThan(StorageService.maxSyncPayloadBytes),
        );
        // Dismiss notice & test phone file pick + restore
        await tester.tap(find.text('好').last);
        await tester.pump(const Duration(milliseconds: 150));
        mockPickedBytes = Uint8List.fromList(utf8.encode(capturedExportText!));
        await tester.tap(find.byKey(const ValueKey('backup-load-json-file')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('backup-restore-confirm')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(restoredTvStorage.getSubscriptions().length, 2);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));

        // 2) Exact UTF-8 boundary check: == maxLocalBackupBytes passes both export & import; +1 byte rejects BOTH!
        const limit = StorageService.maxLocalBackupBytes;
        final shellPrefix = '{"format":"MarcoMovie-1","origin":"","config":"{\\"sites\\":[{\\"key\\":\\"b\\",\\"name\\":\\"边界\\",\\"type\\":1,\\"api\\":\\"http://127.0.0.1:18080/b\\",\\"ext\\":\\"';
        const shellSuffix = '\\"}]}","settings":{}}';
        final overheadBytes = utf8.encode(shellPrefix).length + utf8.encode(shellSuffix).length;
        final exactPayload = '$shellPrefix${'a' * (limit - overheadBytes)}$shellSuffix';
        final exactBytes = utf8.encode(exactPayload);
        expect(exactBytes.length, limit);

        // Exact boundary passes validation, saveTextFile, pickDocumentFile, and importBackupJson
        expect(StorageService.encodeValidatedLocalBackupUtf8(exactPayload).length, limit);
        final savedExact = await OhosRuntime.saveTextFile(
          fileName: 'exact.json',
          content: exactPayload,
          maxBytes: limit,
        );
        expect(savedExact, isNotNull);
        mockPickedBytes = Uint8List.fromList(exactBytes);
        final pickedExact = await OhosRuntime.pickDocumentFile(
          purpose: OhosDocumentPurpose.backup,
          maxBytes: limit,
        );
        expect(pickedExact?.size, limit);
        SharedPreferences.setMockInitialValues({});
        final boundaryStorage = await StorageService.init();
        await boundaryStorage.importValidatedLocalBackupJson(exactPayload);
        expect(boundaryStorage.loadSavedConfig()?.sites.first.key, 'b');

        // Over boundary by 1 UTF-8 byte (+1): rejected on BOTH HarmonyOS export & import, existing config preserved!
        final overByOnePayload = '$shellPrefix${'a' * (limit - overheadBytes + 1)}$shellSuffix';
        expect(utf8.encode(overByOnePayload).length, limit + 1);
        expect(
          () => StorageService.encodeValidatedLocalBackupUtf8(overByOnePayload),
          throwsFormatException,
        );
        await expectLater(
          OhosRuntime.saveTextFile(
            fileName: 'over.json',
            content: overByOnePayload,
            maxBytes: limit,
          ),
          throwsFormatException,
        );
        mockPickedBytes = Uint8List.fromList(utf8.encode(overByOnePayload));
        await expectLater(
          OhosRuntime.pickDocumentFile(
            purpose: OhosDocumentPurpose.backup,
            maxBytes: limit,
          ),
          throwsFormatException,
        );
        await expectLater(
          boundaryStorage.importValidatedLocalBackupJson(overByOnePayload),
          throwsFormatException,
        );
        expect(boundaryStorage.loadSavedConfig()?.sites.first.key, 'b');
      },
    );

    testWidgets(
      'R2-5 Smart Screen depot switch cancels slow Repo A HTTP requests, clears stale results, and Repo B hits site #17 within concurrency 4',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        String buildRepoConfig(String prefix, int count) => jsonEncode({
              'sites': [
                for (var i = 1; i <= count; i++)
                  {
                    'key': '${prefix}_s$i',
                    'name': '$prefix 站 $i',
                    'type': 1,
                    'api': 'http://127.0.0.1:18080/$prefix/site$i',
                    'searchable': 1,
                  },
              ],
            });

        final repoAConfig = buildRepoConfig('repoA', 8);
        final repoBConfig = buildRepoConfig('repoB', 18);

        await storage.saveSubscriptions([
          SubscriptionEntry(
            id: 'multi_depot_sub',
            name: '双仓测试订阅',
            url: 'http://127.0.0.1:18080/multi.json',
            rawContent: repoAConfig,
            depots: const [
              CmsDepot(name: 'A仓', url: 'http://127.0.0.1:18080/depots/a.json'),
              CmsDepot(name: 'B仓', url: 'http://127.0.0.1:18080/depots/b.json'),
            ],
            activeDepotName: 'A仓',
          ),
        ]);

        var repoASearchStarted = 0;
        final repoABlockedCompleters = <Completer<void>>[];
        var timeoutSiteStarted = false;
        var keywordSwitchOldStarted = 0;

        final trackingClient = _AbortTrackingHttpClient((request, abortTrigger) async {
          final path = request.url.path;
          final wd = request.url.queryParameters['wd'] ?? '';
          if (path == '/depots/b.json') {
            return http.Response.bytes(
              utf8.encode(repoBConfig),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (path == '/depots/a.json') {
            return http.Response.bytes(
              utf8.encode(repoAConfig),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (wd.isEmpty) {
            return http.Response.bytes(
              utf8.encode(jsonEncode({'code': 1, 'page': 1, 'pagecount': 1, 'list': []})),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          // Repo A slow responses: site 1 returns an old hit fast; sites 2..8 hang until cancelled
          if (path.startsWith('/repoA/site')) {
            repoASearchStarted++;
            if (path == '/repoA/site1') {
              return http.Response.bytes(
                utf8.encode(jsonEncode({
                  'code': 1,
                  'list': [
                    {
                      'vod_id': 'a_old_1',
                      'vod_name': 'A仓旧结果影片',
                      'vod_play_from': '线1',
                      'vod_play_url': '正片\$http://127.0.0.1:18080/a.m3u8',
                    },
                  ],
                })),
                200,
                headers: const {'content-type': 'application/json; charset=utf-8'},
              );
            }
            final blocker = Completer<void>();
            repoABlockedCompleters.add(blocker);
            await blocker.future;
            return http.Response.bytes(
              utf8.encode(jsonEncode({
                'code': 1,
                'list': [
                  {
                    'vod_id': 'a_late',
                    'vod_name': 'A仓迟到污染结果',
                    'vod_play_from': '线1',
                    'vod_play_url': '正片\$http://127.0.0.1:18080/alate.m3u8',
                  },
                ],
              })),
              200,
              headers: const {'content-type': 'application/json; charset=utf-8'},
            );
          }
          // Repo B:
          // - Keyword 'A': Site #17 is the unique hit (all 18 sites searched with concurrency <= 4)
          // - Keyword 'AB': Site #1 hangs -> per-site timeout must abort underlying request
          // - Keyword 'C': all sites hang -> switching keyword to 'D' must abort underlying requests
          if (path.startsWith('/repoB/site')) {
            final numStr = path.substring('/repoB/site'.length);
            final siteNum = int.tryParse(numStr) ?? 0;
            if (wd == 'A') {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              if (siteNum == 17) {
                return http.Response.bytes(
                  utf8.encode(jsonEncode({
                    'code': 1,
                    'list': [
                      {
                        'vod_id': 'b_17',
                        'vod_name': 'B仓第17站唯一命中',
                        'vod_play_from': '线1',
                        'vod_play_url': '正片\$http://127.0.0.1:18080/b17.m3u8',
                      },
                    ],
                  })),
                  200,
                  headers: const {'content-type': 'application/json; charset=utf-8'},
                );
              }
              return http.Response.bytes(
                utf8.encode(jsonEncode({'code': 1, 'list': []})),
                200,
                headers: const {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (wd == 'AB') {
              if (siteNum == 1) {
                timeoutSiteStarted = true;
                await Completer<void>().future;
              }
              return http.Response.bytes(
                utf8.encode(jsonEncode({'code': 1, 'list': []})),
                200,
                headers: const {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (wd == 'C') {
              keywordSwitchOldStarted++;
              await Completer<void>().future;
            }
            if (wd == 'CD') {
              if (siteNum == 1) {
                return http.Response.bytes(
                  utf8.encode(jsonEncode({
                    'code': 1,
                    'list': [
                      {
                        'vod_id': 'cd_hit',
                        'vod_name': '换词后最新命中',
                        'vod_play_from': '线1',
                        'vod_play_url': '正片\$http://127.0.0.1:18080/cd.m3u8',
                      },
                    ],
                  })),
                  200,
                  headers: const {'content-type': 'application/json; charset=utf-8'},
                );
              }
              return http.Response.bytes(
                utf8.encode(jsonEncode({'code': 1, 'list': []})),
                200,
                headers: const {'content-type': 'application/json; charset=utf-8'},
              );
            }
          }
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 1, 'list': []})),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: TvLivingRoomShell(
              storage: storage,
              client: CmsClient(client: trackingClient),
              searchSiteTimeout: const Duration(milliseconds: 120),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        // 1) Start searching 'A' in Repo A
        await tester.tap(find.text('搜索'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('A'));
        await tester.pump();
        final submitSearch = find.descendant(
          of: find.byType(TvRemoteGridKeyboard),
          matching: find.text('搜索'),
        );
        await tester.tap(submitSearch);
        await tester.pump(const Duration(milliseconds: 40));

        expect(find.text('A仓旧结果影片'), findsOneWidget);
        expect(repoASearchStarted, greaterThanOrEqualTo(4));
        expect(trackingClient.maxLiveInFlight, lessThanOrEqualTo(4));

        // 2) Switch to Repo B via 发现 -> Site Picker while Repo A requests are still pending!
        await tester.tap(find.text('发现'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('repoA 站 1'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('仓库: B仓'));
        await tester.pump(const Duration(milliseconds: 250));

        // All slow Repo A requests must have had their underlying abortTrigger completed!
        final repoAAborted = trackingClient.abortedUrls
            .where((u) => u.contains('/repoA/site'))
            .length;
        expect(repoAAborted, greaterThanOrEqualTo(repoABlockedCompleters.length));
        expect(repoAAborted, greaterThanOrEqualTo(3));
        // Even if slow Repo A completers resolve now, zero late results leak!
        for (final c in repoABlockedCompleters) {
          if (!c.isCompleted) c.complete();
        }
        await tester.pump(const Duration(milliseconds: 50));

        // Return to Search tab -> old Repo A search results must be completely cleared!
        await tester.tap(find.text('搜索'));
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('A仓旧结果影片'), findsNothing);
        expect(find.text('A仓迟到污染结果'), findsNothing);

        // 3) Search the SAME keyword 'A' in Repo B -> Site #17 uniquely hits, real concurrency <= 4
        trackingClient.maxLiveInFlight = 0;
        final submitSearchB = find.descendant(
          of: find.byType(TvRemoteGridKeyboard),
          matching: find.text('搜索'),
        );
        await tester.tap(submitSearchB);
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('B仓第17站唯一命中'), findsOneWidget);
        expect(find.text('A仓旧结果影片'), findsNothing);
        expect(find.text('A仓迟到污染结果'), findsNothing);
        expect(trackingClient.maxLiveInFlight, lessThanOrEqualTo(4));
        expect(trackingClient.maxLiveInFlight, greaterThanOrEqualTo(1));

        // 4) Per-site timeout aborts underlying HTTP request
        await tester.tap(find.text('B'));
        await tester.pump();
        await tester.tap(submitSearchB);
        await tester.pump(const Duration(milliseconds: 350));
        expect(timeoutSiteStarted, isTrue);
        expect(
          trackingClient.abortedUrls
              .any((u) => u.contains('/repoB/site1') && u.contains('wd=AB')),
          isTrue,
        );

        // 5) Rapid keyword change aborts underlying HTTP requests of superseded search
        await tester.tap(find.text('清空'));
        await tester.pump();
        await tester.tap(find.text('C'));
        await tester.pump();
        await tester.tap(submitSearchB);
        await tester.pump(const Duration(milliseconds: 40));
        expect(keywordSwitchOldStarted, greaterThanOrEqualTo(4));
        await tester.tap(find.text('D'));
        await tester.pump();
        await tester.tap(submitSearchB);
        await tester.pump(const Duration(milliseconds: 350));
        final oldKeywordAborted = trackingClient.abortedUrls
            .where((u) => u.contains('/repoB/site') && u.contains('wd=C') && !u.contains('wd=CD'))
            .length;
        expect(oldKeywordAborted, greaterThanOrEqualTo(4));
        expect(find.text('换词后最新命中'), findsOneWidget);
        expect(trackingClient.maxLiveInFlight, lessThanOrEqualTo(4));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'R3-1 healthy live stream rendering startRenderFrame without timeUpdate progress is never falsely switched',
      (tester) async {
        const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        final opens = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 81, 'textureId': 810};
          }
          if (call.method == 'open') {
            opens.add((call.arguments as Map)['url'] as String);
          }
          return true;
        });

        const chA = LiveChannel(
          name: '正常直播无时间轴A',
          group: '央视频道',
          urls: [
            'http://127.0.0.1:18080/live_ok_a1.m3u8',
            'http://127.0.0.1:18080/live_ok_a2.m3u8',
          ],
        );
        final player = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(key: 'live', name: '直播', type: 0, api: ''),
              video: CmsVideo(
                id: chA.name,
                title: chA.name,
                lines: [CmsLine(name: chA.group, episodes: chA.episodes)],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              initialLiveChannel: chA,
              liveGroups: const [LiveGroup(name: '央视频道', channels: [chA])],
              debugPlayer: Player(platformPlayer: player),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(opens, ['http://127.0.0.1:18080/live_ok_a1.m3u8']);

        // Metadata arrives, playing starts, AND AVPlayer emits reliable startRenderFrame ('firstFrame')
        // while never emitting any timeUpdate/position progress.
        player.handleNativeEvent({
          'type': 'state',
          'playing': false,
          'buffering': true,
          'completed': false,
        });
        player.handleNativeEvent({
          'type': 'videoSize',
          'width': 1920,
          'height': 1080,
        });
        player.handleNativeEvent({
          'type': 'state',
          'playing': true,
          'buffering': false,
          'completed': false,
        });
        player.handleNativeEvent({
          'type': 'firstFrame',
          'width': 1920,
          'height': 1080,
        });
        expect(player.hasRenderedFirstFrame, isTrue);
        await tester.pump();

        for (var s = 0; s < 25; s++) {
          await tester.pump(const Duration(seconds: 1));
        }
        // Must remain on A1 with ZERO false retry, ZERO switch to A2, ZERO error overlay
        expect(opens, ['http://127.0.0.1:18080/live_ok_a1.m3u8']);
        expect(find.text('重试播放'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));
      },
    );

    testWidgets(
      'R3-2 paused live stream ignores auto-recovery on late error and cleanly reopens when user explicitly resumes',
      (tester) async {
        const avChannel = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'tv';

        final opens = <String>[];
        var playCalls = 0;
        var pauseCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(avChannel, (call) async {
          if (call.method == 'create') {
            return <String, dynamic>{'playerId': 82, 'textureId': 820};
          }
          if (call.method == 'open') {
            opens.add((call.arguments as Map)['url'] as String);
          } else if (call.method == 'play') {
            playCalls++;
          } else if (call.method == 'pause') {
            pauseCalls++;
          }
          return true;
        });

        const chA = LiveChannel(
          name: '暂停恢复频道A',
          group: '央视频道',
          urls: [
            'http://127.0.0.1:18080/pause_a1.m3u8',
            'http://127.0.0.1:18080/pause_a2.m3u8',
          ],
        );
        final player = OhosPlatformPlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(key: 'live', name: '直播', type: 0, api: ''),
              video: CmsVideo(
                id: chA.name,
                title: chA.name,
                lines: [CmsLine(name: chA.group, episodes: chA.episodes)],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              initialLiveChannel: chA,
              liveGroups: const [LiveGroup(name: '央视频道', channels: [chA])],
              debugPlayer: Player(platformPlayer: player),
              debugVideoSurface: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        player.handleNativeEvent({
          'type': 'state',
          'playing': false,
          'buffering': true,
          'completed': false,
        });
        await tester.pump(const Duration(milliseconds: 100));

        // 1) User explicitly pauses
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 100));
        expect(pauseCalls, 1);
        expect(playCalls, 0);

        // 2) Late native error arrives while paused -> visible paused notice, NO auto open/play/failover
        player.handleNativeEvent({
          'type': 'error',
          'code': 5400103,
          'message': 'AVPlayer error: late error while paused',
        });
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.textContaining('已暂停'), findsOneWidget);
        for (var s = 0; s < 20; s++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(opens, ['http://127.0.0.1:18080/pause_a1.m3u8']);
        expect(playCalls, 0);

        // 3) User explicitly resumes -> cleanly reopens A1 (never silently jumped to A2)
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 300));
        expect(opens, [
          'http://127.0.0.1:18080/pause_a1.m3u8',
          'http://127.0.0.1:18080/pause_a1.m3u8',
        ]);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));
      },
    );

    testWidgets(
      'R3-3 HarmonyOS copy-export enforces the same 32 MiB UTF-8 backup limit as file export/import',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        OhosRuntime.debugIsOhosOverride = true;
        OhosRuntime.debugDeviceTypeOverride = 'phone';

        // Seed 8 x ~4.1 MiB subscriptions -> exported JSON > 32 MiB (~36 MiB)
        final bigExt = 'x' * (4 * 1024 * 1024 + 1024);
        await storage.saveSubscriptions([
          for (var i = 0; i < 8; i++)
            SubscriptionEntry(
              id: 'big_sub_$i',
              name: '超大订阅 $i',
              url: 'http://127.0.0.1:18080/big_$i.json',
              rawContent: jsonEncode({
                'sites': [
                  {
                    'key': 'big_site_$i',
                    'name': '大站 $i',
                    'type': 1,
                    'api': 'http://127.0.0.1:18080/big/$i',
                    'ext': bigExt,
                  },
                ],
              }),
            ),
        ]);
        expect(
          utf8.encode(storage.exportBackupJson()).length,
          greaterThan(StorageService.maxLocalBackupBytes),
        );

        String? copiedClipboardText;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedClipboardText =
                (call.arguments as Map)['text']?.toString();
            return null;
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: CmsClient(client: _StaticJsonHttpClient('{}')),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('设置').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final backupTile = find.text('跨平台备份与恢复').evaluate().isNotEmpty
            ? find.text('跨平台备份与恢复')
            : find.text('备份与恢复');
        await tester.scrollUntilVisible(
          backupTile,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(backupTile);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // HarmonyOS '复制导出' must reject > 32 MiB without writing to clipboard or claiming success
        await tester.tap(find.byKey(const ValueKey('backup-copy-export')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('复制导出失败'), findsOneWidget);
        expect(find.text('已复制备份'), findsNothing);
        expect(copiedClipboardText, isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));
      },
    );
  });
}

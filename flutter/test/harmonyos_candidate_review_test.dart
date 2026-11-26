// Regression checks for Marco Movie HarmonyOS candidate ca0e867.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/tv/tv_living_room_shell.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const av = MethodChannel('com.pilipala.marcomovie/ohos_avplayer');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OhosRuntime.debugIsOhosOverride = true;
    OhosRuntime.debugDeviceTypeOverride = 'tv';
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(av, null);
    messenger.setMockMethodCallHandler(OhosRuntime.systemChannel, null);
    AppUpdate.debugHttpClientOverride = null;
    OhosRuntime.resetForTesting();
  });

  testWidgets('首播持续缓冲仍应自动恢复或提供重试', (tester) async {
    final storage = await StorageService.init();
    final opens = <String>[];
    messenger.setMockMethodCallHandler(av, (call) async {
      if (call.method == 'create') return {'playerId': 21, 'textureId': 210};
      if (call.method == 'open') opens.add(call.arguments['url'] as String);
      return true;
    });
    const urls = [
      'http://127.0.0.1:18080/a1.m3u8',
      'http://127.0.0.1:18080/a2.m3u8'
    ];
    final channel = LiveChannel(name: 'A', group: 'G', urls: urls);
    final player = OhosPlatformPlayer();
    await tester.pumpWidget(MaterialApp(
        home: PlayerScreen(
      site: const CmsSite(key: 'live', name: '测试', type: 0, api: ''),
      video: CmsVideo(
          id: 'A',
          title: 'A',
          lines: [CmsLine(name: 'G', episodes: channel.episodes)]),
      initialLineIndex: 0,
      initialEpisodeIndex: 0,
      storage: storage,
      isLive: true,
      initialLiveChannel: channel,
      liveGroups: [
        LiveGroup(name: 'G', channels: [channel])
      ],
      debugPlayer: Player(platformPlayer: player),
      debugVideoSurface: const SizedBox.expand(),
    )));
    await tester.pump(const Duration(milliseconds: 250));
    expect(opens, [urls.first]);
    player.handleNativeEvent({
      'type': 'state',
      'playing': false,
      'buffering': true,
      'completed': false
    });
    await tester.pump();
    for (var second = 0; second < 20; second++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final retryCount = find.text('重试播放').evaluate().length;
    final openCount = opens.length;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(openCount > 1 || retryCount > 0, isTrue,
        reason: '模拟 20 秒后，open 次数=$openCount，重试按钮数=$retryCount');
  });

  testWidgets('已装 0.1.2 时不应提供 0.1.1 的重新下载按钮', (tester) async {
    final storage = await StorageService.init();
    messenger.setMockMethodCallHandler(OhosRuntime.systemChannel, (call) async {
      if (call.method == 'getPackageInfo') {
        return {
          'appName': 'Marco Movie',
          'packageName': 'com.pilipala.marcomovie',
          'version': '0.1.2',
          'buildNumber': '1000003'
        };
      }
      return null;
    });
    const name = 'MarcoMovie-0.1.1-harmonyos-universal.hap';
    AppUpdate.debugHttpClientOverride = MockClient((_) async => http.Response(
        jsonEncode({
          'schema': 1,
          'platform': 'harmonyos',
          'versionName': '0.1.1',
          'packages': {
            name: {
              'size': 39546323,
              'sha256':
                  '3df10bc519eeda366c9b5f15ecb92cd3df2cf92148191dfca42d034f4b554bae',
              'url':
                  'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.1/$name'
            }
          }
        }),
        200));
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: TvLivingRoomShell(
            storage: storage,
            client: CmsClient(
                client: MockClient((_) async => http.Response('{}', 200))))));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('设置'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('版本与更新'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('tv-check-update-btn')));
    await tester.pump(const Duration(milliseconds: 250));
    // Returning the same release or a newer one is covered by the candidate's existing suite.
    expect(find.textContaining('0.1.2'), findsWidgets);
    expect(find.text('重新下载 HAP v0.1.1'), findsNothing);
  });
}

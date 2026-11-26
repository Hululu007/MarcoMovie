// Regression check for Marco Movie HarmonyOS candidate 845f42c.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/ui/player_screen.dart';
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

  testWidgets('上报画幅和 playing 后一直无首帧、无进度，应恢复或提示重试', (tester) async {
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
    player.handleNativeEvent(
        {'type': 'videoSize', 'width': 1920, 'height': 1080});
    await tester.pump();
    player.handleNativeEvent({
      'type': 'state',
      'playing': true,
      'buffering': false,
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
}

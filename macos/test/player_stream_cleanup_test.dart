import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

final String? testMpvLibrary = Platform.environment['MARCOMOVIE_TEST_MPV'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  group('PlayerScreen Subscription Lifecycle', () {
    late StorageService storage;
    setUpAll(() {
      MediaKit.ensureInitialized(libmpv: testMpvLibrary);
    });
    const site = CmsSite(
      key: 'test_site',
      name: '测试源',
      type: 1,
      api: 'https://source.example/api',
    );
    const video = CmsVideo(
      id: 'vid_1',
      title: '测试视频',
      lines: [
        CmsLine(
          name: '默认线路',
          episodes: [
            CmsEpisode(name: '第01集', url: 'https://source.example/e1.mp4'),
            CmsEpisode(name: '第02集', url: 'https://source.example/e2.mp4'),
            CmsEpisode(name: '第03集', url: 'https://source.example/e3.mp4'),
          ],
        ),
      ],
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = await StorageService.init();
    });

    testWidgets(
        'PlayerScreen mounts and cancels all stream subscriptions on exit',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => PlayerScreen(
                          site: site,
                          video: video,
                          initialLineIndex: 0,
                          initialEpisodeIndex: 0,
                          storage: storage,
                        ),
                      ),
                    );
                  },
                  child: const Text('Open Player'),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Open Player
        await tester.tap(find.text('Open Player'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(PlayerScreen), findsOneWidget);

        // Send Ctrl+W
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // Pump frames for async _saveProgress().whenComplete(...) and maybePop()
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 300));

        // Route should be popped cleanly, returning to home
        expect(find.byType(PlayerScreen), findsNothing,
            reason: 'Ctrl+W must cleanly pop PlayerScreen and cancel subscriptions');
        expect(find.text('Open Player'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  },
      skip: testMpvLibrary == null
          ? 'Set MARCOMOVIE_TEST_MPV to the built desktop library'
          : false);
}

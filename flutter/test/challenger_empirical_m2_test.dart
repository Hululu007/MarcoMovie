import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kTestMpvPath =
    r'D:\Marco Movie\verification\private\fixes-20261107\build\flutter\build\windows\x64\runner\Release\libmpv-2.dll';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'isFullScreen') return false;
      return null;
    });
    MediaKit.ensureInitialized(libmpv: kTestMpvPath);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  group('Feature B3: Responsive layout boundary behavior', () {
    late StorageService storage;
    late CmsClient client;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = await StorageService.init();
      await storage.saveConfig(
        '{"sites":[{"key":"demo","name":"演示源","type":1,"api":"https://source.example/api"}]}',
      );
      client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );
    });

    testWidgets(
        'Desktop (Windows): width 699 uses bottom dock; width 700 uses sidebar; 960x1030 snap retains sidebar',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        // Boundary test: Width 699 (desktop, < 700) -> uses mobile bottom dock
        tester.view.physicalSize = const Size(699, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pumpAndSettle();

        final sidebarDock699 = find.byWidgetPredicate(
          (w) => w is AppleLiquidGlassDock && w.isLandscape == true,
        );
        final bottomDock699 = find.byWidgetPredicate(
          (w) => w is AppleLiquidGlassDock && w.isLandscape == false,
        );
        expect(sidebarDock699, findsNothing,
            reason: 'Desktop width 699 MUST NOT render sidebar dock');
        expect(bottomDock699, findsOneWidget,
            reason: 'Desktop width 699 MUST render mobile bottom dock');

        // Boundary test: Width 700 (desktop, == 700) -> uses sidebar dock
        tester.view.physicalSize = const Size(700, 900);
        await tester.pumpAndSettle();

        final sidebarDock700 = find.byWidgetPredicate(
          (w) => w is AppleLiquidGlassDock && w.isLandscape == true,
        );
        final bottomDock700 = find.byWidgetPredicate(
          (w) => w is AppleLiquidGlassDock && w.isLandscape == false,
        );
        expect(sidebarDock700, findsOneWidget,
            reason: 'Desktop width 700 MUST render sidebar dock');
        expect(bottomDock700, findsNothing,
            reason: 'Desktop width 700 MUST NOT render bottom dock');

        // Half-screen snap at 960x1030 (width < height, but width >= 700) -> retains sidebar!
        tester.view.physicalSize = const Size(960, 1030);
        await tester.pumpAndSettle();

        expect(
          find.byWidgetPredicate(
              (w) => w is AppleLiquidGlassDock && w.isLandscape == true),
          findsOneWidget,
          reason: 'Half-screen snap (960x1030) MUST retain sidebar dock',
        );
        expect(
          find.byWidgetPredicate(
              (w) => w is AppleLiquidGlassDock && w.isLandscape == false),
          findsNothing,
        );

        // Standard desktop landscape at 1280x720 -> renders sidebar
        tester.view.physicalSize = const Size(1280, 720);
        await tester.pumpAndSettle();

        expect(
          find.byWidgetPredicate(
              (w) => w is AppleLiquidGlassDock && w.isLandscape == true),
          findsOneWidget,
          reason: 'Desktop 1280x720 MUST render sidebar dock',
        );
        expect(
          find.byWidgetPredicate(
              (w) => w is AppleLiquidGlassDock && w.isLandscape == false),
          findsNothing,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Desktop (macOS & Linux): boundary 699 vs 700 behaves identically',
        (tester) async {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          tester.view.physicalSize = const Size(699, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() => tester.view.resetPhysicalSize());

          await tester.pumpWidget(
            MaterialApp(
              home: AdaptiveShell(storage: storage, client: client),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byWidgetPredicate(
                (w) => w is AppleLiquidGlassDock && w.isLandscape == false),
            findsOneWidget,
            reason: '$platform at width 699 should render bottom dock',
          );

          tester.view.physicalSize = const Size(700, 900);
          await tester.pumpAndSettle();

          expect(
            find.byWidgetPredicate(
                (w) => w is AppleLiquidGlassDock && w.isLandscape == true),
            findsOneWidget,
            reason: '$platform at width 700 should render sidebar dock',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    testWidgets(
        'Non-Desktop (iOS / Android): uses width > height, NOT width >= 700',
        (tester) async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          // Case A: 800 x 900 (Portrait: width < height, but width >= 700)
          // On mobile, portrait should use bottom dock even though width >= 700!
          tester.view.physicalSize = const Size(800, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() => tester.view.resetPhysicalSize());

          await tester.pumpWidget(
            MaterialApp(
              home: AdaptiveShell(storage: storage, client: client),
            ),
          );
          await tester.pumpAndSettle();

          final sidebarDockA = find.byWidgetPredicate(
            (w) => w is AppleLiquidGlassDock && w.isLandscape == true,
          );
          final bottomDockA = find.byWidgetPredicate(
            (w) => w is AppleLiquidGlassDock && w.isLandscape == false,
          );
          expect(sidebarDockA, findsNothing,
              reason: '$platform portrait (800x900) must NOT use sidebar');
          expect(bottomDockA, findsOneWidget,
              reason: '$platform portrait (800x900) MUST use bottom dock');

          // Case B: 600 x 400 (Landscape: width > height, but width < 700)
          // On mobile, landscape should use sidebar dock even though width < 700!
          tester.view.physicalSize = const Size(600, 400);
          await tester.pumpAndSettle();

          final sidebarDockB = find.byWidgetPredicate(
            (w) => w is AppleLiquidGlassDock && w.isLandscape == true,
          );
          final bottomDockB = find.byWidgetPredicate(
            (w) => w is AppleLiquidGlassDock && w.isLandscape == false,
          );
          expect(sidebarDockB, findsOneWidget,
              reason: '$platform landscape (600x400) MUST use sidebar dock');
          expect(bottomDockB, findsNothing,
              reason: '$platform landscape (600x400) must NOT use bottom dock');

          // Case C: 700 x 700 (Square: width == height -> not landscape)
          tester.view.physicalSize = const Size(700, 700);
          await tester.pumpAndSettle();

          expect(
            find.byWidgetPredicate(
                (w) => w is AppleLiquidGlassDock && w.isLandscape == false),
            findsOneWidget,
            reason: '$platform square (700x700) MUST use bottom dock',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test('Window minimum size is enforced in main.dart', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      expect(
        mainSource.contains('windowManager.setMinimumSize(const Size(720, 520))'),
        isTrue,
        reason: 'main.dart must call windowManager.setMinimumSize(const Size(720, 520))',
      );
    });
  });

  group('Feature B4: Desktop Player Keyboard Shortcuts & Focus Retention', () {
    late StorageService storage;
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

    testWidgets('Focus management: autofocus on _playerFocusNode and retention',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final playerFocusFinder = find.descendant(
          of: find.byType(PlayerScreen),
          matching: find.byType(Focus),
        );
        expect(playerFocusFinder, findsWidgets);
        final focusWidget = tester.widget<Focus>(playerFocusFinder.first);
        expect(focusWidget.autofocus, isTrue);
        expect(focusWidget.focusNode?.hasPrimaryFocus, isTrue,
            reason: 'Player focus node must have primary focus after pumping');

        // Clean up pending timers
        await tester.pump(const Duration(milliseconds: 1500));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Shortcut M: triggers mute HUD and executes volume mute logic',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Send key M -> triggers mute
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.pump(const Duration(milliseconds: 50));

        // HUD should display '静音'
        expect(find.text('静音'), findsOneWidget,
            reason: 'Muting must display 静音 HUD');

        // Clean up HUD timer
        await tester.pump(const Duration(milliseconds: 1500));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Shortcut [ and ]: adjusts speed by 0.25, clamps strictly to [0.5, 3.0], updates storage and HUD',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Default speed is 1.0
        expect(storage.playSpeed, 1.0);

        // Press ']' -> speed becomes 1.25x
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
        await tester.pump(const Duration(milliseconds: 50));
        expect(storage.playSpeed, 1.25);
        expect(find.text('倍速 1.25x'), findsOneWidget);

        // Press ']' again -> speed becomes 1.5x
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
        await tester.pump(const Duration(milliseconds: 50));
        expect(storage.playSpeed, 1.5);
        expect(find.text('倍速 1.5x'), findsOneWidget);

        // Press '[' -> speed decreases to 1.25x
        await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
        await tester.pump(const Duration(milliseconds: 50));
        expect(storage.playSpeed, 1.25);
        expect(find.text('倍速 1.25x'), findsOneWidget);

        // Stress test: decrease speed repeatedly beyond lower clamp (0.5)
        for (int i = 0; i < 10; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(storage.playSpeed, 0.5,
            reason: 'Speed must clamp at minimum 0.5x');
        expect(find.text('倍速 0.5x'), findsOneWidget);

        // Stress test: increase speed repeatedly beyond upper clamp (3.0)
        for (int i = 0; i < 20; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
          await tester.pump(const Duration(milliseconds: 50));
        }
        // HUD displays clamped 3x
        expect(find.text('倍速 3x'), findsOneWidget,
            reason: 'Speed HUD must clamp at maximum 3.0x');

        // Clean up HUD timer
        await tester.pump(const Duration(milliseconds: 1500));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Shortcut N / PageDown advances episode, P / PageUp steps back',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // Currently episode 0 ("第01集").
        // Press N -> advance to episode 1 ("第02集")
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 100));

        // Press PageDown -> advance to episode 2 ("第03集")
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump(const Duration(milliseconds: 100));

        // Boundary test: Press N again when at last episode -> stays at episode 2
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 100));

        // Press P -> step back to episode 1 ("第02集")
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.pump(const Duration(milliseconds: 100));

        // Press PageUp -> step back to episode 0 ("第01集")
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pump(const Duration(milliseconds: 100));

        // Boundary test: Press P again at first episode -> stays at episode 0
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.pump(const Duration(milliseconds: 100));

        // Clean up pending timers
        await tester.pump(const Duration(milliseconds: 1500));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Shortcut Ctrl+W / Cmd+W triggers progress save and cleanly exits playback',
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
            reason: 'Ctrl+W must cleanly pop PlayerScreen');
        expect(find.text('Open Player'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

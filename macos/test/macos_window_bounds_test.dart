import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/macos_window_bounds.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

class _FakeMacosWindowAdapter implements MacosWindowPlatformAdapter {
  MacosWindowNativeState? nativeState;
  final List<ThemeMode> appliedAppearances = [];
  final List<MacosWindowBounds> appliedBounds = [];
  final List<String> revealedPaths = [];
  int saveCalls = 0;

  @override
  Future<MacosWindowNativeState?> getNativeState() async => nativeState;

  @override
  Future<bool> saveNormalBounds() async {
    saveCalls++;
    return true;
  }

  @override
  Future<bool> applyNormalBounds(MacosWindowBounds bounds) async {
    appliedBounds.add(bounds);
    nativeState = MacosWindowNativeState(
      restoredFromSaved: true,
      isFullScreen: nativeState?.isFullScreen ?? false,
      isMiniaturized: nativeState?.isMiniaturized ?? false,
      savedFrame: bounds,
      currentFrame: bounds,
    );
    return true;
  }

  @override
  Future<void> setAppearanceMode(ThemeMode mode) async {
    appliedAppearances.add(mode);
  }

  @override
  Future<bool> revealInFinder(String path) async {
    revealedPaths.add(path);
    return true;
  }

  @override
  Future<bool> isFullScreen() async => nativeState?.isFullScreen ?? false;

  @override
  Future<bool> isMinimized() async => nativeState?.isMiniaturized ?? false;

  @override
  Future<Rect?> getWindowManagerBounds() async => nativeState?.currentFrame?.rect;
}

class _KeyFakeState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(seconds: 42);
  Duration durationValue = const Duration(minutes: 10);
  double volumeValue = 100;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();

  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => playingValue;
  @override
  bool get completed => completedValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => bufferingValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  Track get track => trackValue;
}

class _KeyFakeStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast();
  final heightCtrl = StreamController<int?>.broadcast();
  final trackCtrl = StreamController<Track>.broadcast();
  final tracksCtrl = StreamController<Tracks>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final bufferingCtrl = StreamController<bool>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();
  final volumeCtrl = StreamController<double>.broadcast();

  @override
  Stream<int?> get width => widthCtrl.stream;
  @override
  Stream<int?> get height => heightCtrl.stream;
  @override
  Stream<Track> get track => trackCtrl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtrl.stream;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<bool> get buffering => bufferingCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;
  @override
  Stream<double> get volume => volumeCtrl.stream;

  Future<void> close() => Future.wait([
        widthCtrl.close(),
        heightCtrl.close(),
        trackCtrl.close(),
        tracksCtrl.close(),
        positionCtrl.close(),
        durationCtrl.close(),
        playingCtrl.close(),
        bufferingCtrl.close(),
        completedCtrl.close(),
        errorCtrl.close(),
        volumeCtrl.close(),
      ]);
}

class _KeyFakePlayer extends Fake implements Player {
  final _KeyFakeState _state = _KeyFakeState();
  final _KeyFakeStream _stream = _KeyFakeStream();
  bool _disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      _state.playlistValue = Playlist([playable]);
    }
    if (!_disposed) {
      _stream.widthCtrl.add(1920);
      _stream.heightCtrl.add(1080);
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setRate(double r) async {}
  @override
  Future<void> setVolume(double v) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MacosWindowBounds geometry and clamping', () {
    const primary = Rect.fromLTWH(0, 25, 1440, 850); // AppKit visibleFrame: y=25..875
    const external = Rect.fromLTWH(1440, 0, 2560, 1415);

    test('unified minimum size is 720x520 and rejects undersized or NaN bounds', () {
      expect(MacosWindowBounds.minimumSize, const Size(720, 520));
      expect(
        const MacosWindowBounds(x: 100, y: 100, width: 719, height: 520).isValid,
        isFalse,
      );
      expect(
        const MacosWindowBounds(x: 100, y: 100, width: 720, height: 519).isValid,
        isFalse,
      );
      expect(
        const MacosWindowBounds(x: 100, y: 100, width: 720, height: 520).isValid,
        isTrue,
      );
      expect(
        const MacosWindowBounds(x: double.nan, y: 100, width: 900, height: 600)
            .isValid,
        isFalse,
      );
    });

    test('cold start without saved bounds centers cleanly on primary display', () {
      final resolved = MacosWindowBounds.resolveForVisibleFrames(
        saved: null,
        visibleFrames: const [primary],
        primaryVisibleFrame: primary,
      );
      expect(resolved.width, 1280);
      expect(resolved.height, 760);
      expect(resolved.x, closeTo(80, 1));
      expect(resolved.y, closeTo(70, 1));
      expect(resolved.topY, lessThanOrEqualTo(primary.bottom));
    });

    test('dragged and resized normal window restores 1:1 on relaunch', () {
      const saved = MacosWindowBounds(x: 140, y: 95, width: 1040, height: 680);
      final resolved = MacosWindowBounds.resolveForVisibleFrames(
        saved: saved,
        visibleFrames: const [primary],
        primaryVisibleFrame: primary,
      );
      expect(resolved, saved);
    });

    test('unplugging external monitor moves window onto primary with titlebar visible', () {
      const onExternal = MacosWindowBounds(
        x: 1700,
        y: 220,
        width: 1600,
        height: 980,
      );
      // While external is connected, stays on external.
      final withExt = MacosWindowBounds.resolveForVisibleFrames(
        saved: onExternal,
        visibleFrames: const [primary, external],
        primaryVisibleFrame: primary,
      );
      expect(withExt, onExternal);

      // After external monitor is unplugged, falls back cleanly onto primary.
      final unplugged = MacosWindowBounds.resolveForVisibleFrames(
        saved: onExternal,
        visibleFrames: const [primary],
        primaryVisibleFrame: primary,
      );
      expect(unplugged.width, lessThanOrEqualTo(primary.width));
      expect(unplugged.height, lessThanOrEqualTo(primary.height));
      expect(unplugged.x, greaterThanOrEqualTo(primary.left));
      expect(unplugged.topY, lessThanOrEqualTo(primary.bottom));
      expect(unplugged.topY, greaterThanOrEqualTo(primary.top + 80));
    });

    test('clamps off-left, above-menubar, and below-dock bounds so traffic lights stay visible', () {
      const offTopLeft = MacosWindowBounds(
        x: -240,
        y: 420,
        width: 960,
        height: 640,
      );
      final clamped = MacosWindowBounds.resolveForVisibleFrames(
        saved: offTopLeft,
        visibleFrames: const [primary],
        primaryVisibleFrame: primary,
      );
      expect(clamped.x, greaterThanOrEqualTo(primary.left));
      expect(clamped.topY, lessThanOrEqualTo(primary.bottom));
      expect(clamped.width, 960);
      expect(clamped.height, 640);
    });
  });

  group('MacosWindowBoundsController persistence lifecycle', () {
    test('preserves normal bounds across repeated fullscreen toggles, minimize, and quit', () async {
      final storage = await initTestStorage();
      final adapter = _FakeMacosWindowAdapter();
      const normalFrame = MacosWindowBounds(x: 160, y: 120, width: 1120, height: 700);
      const fullscreenFrame = MacosWindowBounds(x: 0, y: 0, width: 1440, height: 900);

      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: false,
        isFullScreen: false,
        isMiniaturized: false,
        currentFrame: normalFrame,
      );
      final ctrl = MacosWindowBoundsController(
        storage: storage,
        adapter: adapter,
        attachWindowManager: false,
        debounceDuration: const Duration(milliseconds: 10),
      );
      addTearDown(ctrl.dispose);

      await ctrl.syncOnStartup(initialThemeMode: ThemeMode.light);
      expect(adapter.appliedAppearances, [ThemeMode.light]);
      expect(storage.loadMacosWindowBounds(), normalFrame);

      // Simulate green button entering fullscreen -> must NOT overwrite normalFrame.
      ctrl.onWindowEnterFullScreen();
      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: true,
        isFullScreen: true,
        isMiniaturized: false,
        savedFrame: normalFrame,
        currentFrame: fullscreenFrame,
      );
      ctrl.onWindowResized();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(storage.loadMacosWindowBounds(), normalFrame);

      // Quit while fullscreen -> normalFrame stays intact.
      ctrl.onWindowClose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(storage.loadMacosWindowBounds(), normalFrame);

      // Exit fullscreen & minimize -> normalFrame still preserved.
      ctrl.onWindowLeaveFullScreen();
      ctrl.onWindowMinimize();
      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: true,
        isFullScreen: false,
        isMiniaturized: true,
        savedFrame: normalFrame,
        currentFrame: MacosWindowBounds(x: 0, y: 0, width: 720, height: 520),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(storage.loadMacosWindowBounds(), normalFrame);

      // Restore & resize to a new normal frame -> saved cleanly.
      const resizedFrame = MacosWindowBounds(x: 210, y: 140, width: 1200, height: 740);
      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: true,
        isFullScreen: false,
        isMiniaturized: false,
        savedFrame: normalFrame,
        currentFrame: resizedFrame,
      );
      ctrl.onWindowRestore();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(storage.loadMacosWindowBounds(), resizedFrame);
    });

    test('applies fallback saved bounds if native defaults had no record yet', () async {
      final storage = await initTestStorage();
      const saved = MacosWindowBounds(x: 180, y: 100, width: 1080, height: 680);
      await storage.saveMacosWindowBounds(saved);

      final adapter = _FakeMacosWindowAdapter()
        ..nativeState = const MacosWindowNativeState(
          restoredFromSaved: false,
          isFullScreen: false,
          isMiniaturized: false,
          savedFrame: null,
          currentFrame: MacosWindowBounds(x: 80, y: 70, width: 1280, height: 760),
        );
      final ctrl = MacosWindowBoundsController(
        storage: storage,
        adapter: adapter,
        attachWindowManager: false,
      );
      addTearDown(ctrl.dispose);

      await ctrl.syncOnStartup();
      expect(adapter.appliedBounds, [saved]);
      expect(storage.loadMacosWindowBounds(), saved);
    });

    test('does not let un-restored native default frame overwrite Dart backup bounds', () async {
      final storage = await initTestStorage();
      const dartBackup = MacosWindowBounds(x: 240, y: 150, width: 1020, height: 660);
      const defaultCentered = MacosWindowBounds(x: 80, y: 70, width: 1280, height: 760);
      await storage.saveMacosWindowBounds(dartBackup);

      final adapter = _FakeMacosWindowAdapter()
        ..nativeState = const MacosWindowNativeState(
          restoredFromSaved: false,
          isFullScreen: false,
          isMiniaturized: false,
          // Even if an older native side mistakenly returned a centered frame in savedFrame,
          // restoredFromSaved=false must still restore Dart's persisted backup.
          savedFrame: defaultCentered,
          currentFrame: defaultCentered,
        );
      final ctrl = MacosWindowBoundsController(
        storage: storage,
        adapter: adapter,
        attachWindowManager: false,
      );
      addTearDown(ctrl.dispose);

      await ctrl.syncOnStartup();
      expect(adapter.appliedBounds, [dartBackup]);
      expect(storage.loadMacosWindowBounds(), dartBackup);
    });
  });

  group('macOS PlayerScreen keyboard shortcuts (Cmd+W and Esc)', () {
    testWidgets('Cmd+W saves watch progress and pops player route; Esc exits fullscreen before popping', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      var fullscreen = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
        if (call.method == 'isFullScreen') return fullscreen;
        if (call.method == 'setFullScreen') {
          fullscreen = call.arguments['isFullScreen'] == true;
          return null;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
      });

      final storage = await initTestStorage();
      final player = _KeyFakePlayer();
      const site = CmsSite(
        key: 'mac_keys',
        name: 'Mac Keys',
        type: 1,
        api: 'https://owned.invalid/api',
      );
      const video = CmsVideo(
        id: 'v_keys',
        title: '快捷键测试',
        lines: [
          CmsLine(
            name: '默认线路',
            episodes: [CmsEpisode(name: '第1集', url: 'https://owned.invalid/1.mp4')],
          ),
        ],
      );

      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () {
                Navigator.of(ctx)
                    .push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerScreen(
                          site: site,
                          video: video,
                          initialLineIndex: 0,
                          initialEpisodeIndex: 0,
                          storage: storage,
                          debugPlayer: player,
                          debugHudPrefs: PlayerHudPrefs(isDesktop: true),
                          debugVideoSurface: const ColoredBox(color: Colors.black),
                        ),
                      ),
                    )
                    .then((_) => popped = true);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Press Cmd+W -> saves progress (42s) and pops route.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(popped, isTrue);
      final history = storage.getWatchHistory();
      expect(history, isNotEmpty);
      expect(history.first.id, 'v_keys');
      expect(history.first.position, greaterThanOrEqualTo(40000));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await player.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

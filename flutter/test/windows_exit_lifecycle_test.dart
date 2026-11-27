// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fvp/mdk.dart' as mdk;
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/mdk_platform_player.dart';
import 'package:marco_movie/core/windows_tray_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:media_kit/media_kit.dart';

import 'test_storage_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const trayChannel = MethodChannel('marco_movie/windows_tray');
  const windowChannel = MethodChannel('window_manager');

  setUp(() {
    WindowsTrayService.resetForTesting();
  });

  tearDown(() {
    WindowsTrayService.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trayChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  test(
    'AdaptiveShell.runWindowCloseSequence runs prepareExit before flushHistory and executes destroyWindow once',
    () async {
      final events = <String>[];
      await AdaptiveShell.runWindowCloseSequence(
        setPreventClose: (prevent) async => events.add('prevent:$prevent'),
        hideWindow: () async => events.add('hideWindow'),
        prepareExit: () async => events.add('prepareExit'),
        flushHistory: () async => events.add('flushHistory'),
        flushSync: (_) async => events.add('flushSync'),
        closeHost: () async => events.add('closeHost'),
        closeScripts: () async => events.add('closeScripts'),
        destroyWindow: () async => events.add('destroyWindow'),
      );

      expect(
        events,
        equals(const [
          'prevent:true',
          'hideWindow',
          'prepareExit',
          'flushHistory',
          'flushSync',
          'closeHost',
          'closeScripts',
          'prevent:false',
          'destroyWindow',
        ]),
      );
    },
  );

  test(
    'WindowsTrayService.destroyWindow invokes native destroyWindow and runs registered pre-exit hooks',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trayChannel, (call) async {
        nativeCalls.add(call.method);
        return true;
      });

      var hookCalls = 0;
      Future<void> hook() async {
        hookCalls++;
      }

      WindowsTrayService.registerBeforeExitHook(hook);
      await WindowsTrayService.runBeforeExitHooks();
      expect(hookCalls, 1);

      WindowsTrayService.unregisterBeforeExitHook(hook);
      await WindowsTrayService.runBeforeExitHooks();
      expect(hookCalls, 1);

      final destroyed = await WindowsTrayService.destroyWindow();
      expect(destroyed, isTrue);
      expect(nativeCalls, contains('destroyWindow'));
    },
  );

  testWidgets(
    'Rapid consecutive onWindowClose calls in direct-exit mode execute cleanup strictly once',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final storage = await initTestStorage();
      await storage.setWindowsCloseAction('exit');
      final destroyGate = Completer<void>();
      var flushCalls = 0;
      var destroyCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trayChannel, (call) async => true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async => true);

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            storage: storage,
            client: CmsClient(),
            onSetPreventCloseForTest: (_) async {},
            onFlushHistoryForTest: () async {
              flushCalls++;
              await destroyGate.future;
            },
            onFlushSyncForTest: (_) async {},
            onCloseHostForTest: () async {},
            onCloseScriptsForTest: () async {},
            onDestroyWindowForTest: () async {
              destroyCalls++;
            },
          ),
        ),
      );
      await tester.pump();

      final dynamic shellState = tester.state(find.byType(AdaptiveShell));
      final f1 = shellState.onWindowClose() as Future<void>;
      final f2 = shellState.onWindowClose() as Future<void>;
      final f3 = shellState.onWindowClose() as Future<void>;
      destroyGate.complete();
      await Future.wait([f1, f2, f3]);

      expect(flushCalls, 1);
      expect(destroyCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'Close-to-tray hides to tray without exiting, and tray quit triggers unified exit',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final storage = await initTestStorage();
      await storage.setWindowsCloseAction('tray');
      final trayCalls = <String>[];
      var destroyCalls = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trayChannel, (call) async {
        trayCalls.add(call.method);
        return true;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async => true);

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            storage: storage,
            client: CmsClient(),
            onSetPreventCloseForTest: (_) async {},
            onFlushHistoryForTest: () async {},
            onFlushSyncForTest: (_) async {},
            onCloseHostForTest: () async {},
            onCloseScriptsForTest: () async {},
            onDestroyWindowForTest: () async {
              destroyCalls++;
            },
          ),
        ),
      );
      await tester.pump();

      final dynamic shellState = tester.state(find.byType(AdaptiveShell));
      await (shellState.onWindowClose() as Future<void>);

      expect(trayCalls, contains('hideToTray'));
      expect(destroyCalls, 0);

      // Attach tray callbacks (AdaptiveShell skips auto-attach under FLUTTER_TEST)
      // and verify restore + quit callbacks dispatch cleanly.
      var restoreCalls = 0;
      var quitCalls = 0;
      WindowsTrayService.attach(
        onRestore: () => restoreCalls++,
        onQuit: () => quitCalls++,
      );

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'marco_movie/windows_tray',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('restore')),
        (_) {},
      );
      expect(restoreCalls, 1);
      expect(WindowsTrayService.isInTray, isFalse);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'marco_movie/windows_tray',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('quit')),
        (_) {},
      );
      expect(quitCalls, 1);

      // Switching back to direct exit mode triggers unified destroyWindow once.
      await storage.setWindowsCloseAction('exit');
      await (shellState.onWindowClose() as Future<void>);
      expect(destroyCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  test(
    'MdkPlatformPlayer serializes updateTexture across loaded/open/dispose so no TexturePlayer leaks before mdkPlayerAPI_delete',
    () async {
      final fake = _SerializedTextureFakeMdkBackend();
      final player = MdkPlatformPlayer(debugBackend: fake);

      // Simulate libmdk firing MediaStatus.loaded during prepare() so both
      // onStatusChanged and open() trigger _refreshTextureSafely() for the same
      // open generation.
      final openFuture = player.open(Media('http://127.0.0.1/ep1.mkv'));
      await Future<void>.delayed(Duration.zero);
      fake.emitLoaded();
      fake.completePrepare(0);
      await Future<void>.delayed(Duration.zero);
      expect(fake.updateTextureCalls, 1);
      expect(fake.maxConcurrentUpdateTexture, 1);

      fake.completeNextTexture(101);
      await openFuture;
      expect(fake.updateTextureCalls, 1);

      // Episode 2: start open & loaded, hold updateTexture in-flight, and
      // invoke dispose() mid-flight. disposeAsync() MUST wait for the in-flight
      // updateTexture() to finish before deleting the native handle.
      final ep2Open = player.open(Media('http://127.0.0.1/ep2.mkv'));
      await Future<void>.delayed(Duration.zero);
      fake.emitLoaded();
      fake.completePrepare(0);
      await Future<void>.delayed(Duration.zero);
      expect(fake.updateTextureCalls, 2);
      expect(fake.maxConcurrentUpdateTexture, 1);

      final disposeFuture = player.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(fake.disposeAsyncCalled, isFalse);

      fake.completeNextTexture(102);
      await Future.wait([ep2Open, disposeFuture]);
      expect(fake.disposeAsyncCalled, isTrue);
      expect(fake.events.indexOf('texture_end:102'), lessThan(fake.events.indexOf('disposeAsync')));
    },
  );

  test(
    'P1-2: slow MDK updateTexture (>2.3s), pre-first-frame exit, and mid-episode-switch exit never call disposeAsync while texture is outstanding',
    () async {
      // 1) Pre-first-frame exit (open still suspended inside prepare())
      final fakePreFirstFrame = _SerializedTextureFakeMdkBackend();
      final p1 = MdkPlatformPlayer(debugBackend: fakePreFirstFrame);
      final open1 = p1.open(Media('http://127.0.0.1/ep1.mkv'));
      await Future<void>.delayed(Duration.zero);
      expect(fakePreFirstFrame.updateTextureCalls, 0);
      await p1.dispose();
      await open1;
      expect(fakePreFirstFrame.disposeAsyncCalled, isTrue);
      expect(fakePreFirstFrame.updateTextureCalls, 0);

      // 2) Slow texture (>2.3s): disposeAsync MUST wait until texture finishes.
      final fakeSlow = _SerializedTextureFakeMdkBackend();
      final p2 = MdkPlatformPlayer(debugBackend: fakeSlow);
      final open2 = p2.open(Media('http://127.0.0.1/slow.mkv'));
      await Future<void>.delayed(Duration.zero);
      fakeSlow.completePrepare(0);
      await Future<void>.delayed(Duration.zero);
      expect(fakeSlow.updateTextureCalls, 1);
      final disp2 = p2.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(fakeSlow.disposeAsyncCalled, isFalse);
      fakeSlow.completeNextTexture(201);
      await Future.wait([open2, disp2]);
      expect(fakeSlow.disposeAsyncCalled, isTrue);
      expect(
        fakeSlow.events.indexOf('texture_end:201'),
        lessThan(fakeSlow.events.indexOf('disposeAsync')),
      );
    },
  );

  test(
    'P1-2: bounded exit marks native destroy started before destroyWindow so timed-out hooks cannot touch disposed resources',
    () async {
      final release = Completer<void>();
      var postTimeoutSideEffects = 0;
      bool? destroyStartedAtDestroyWindow;

      Future<void> slowHook() async {
        await release.future;
        if (WindowsTrayService.isNativeDestroyStarted) return;
        postTimeoutSideEffects++;
      }

      WindowsTrayService.registerBeforeExitHook(slowHook);
      final sw = Stopwatch()..start();
      await AdaptiveShell.runWindowCloseSequence(
        setPreventClose: (_) async {},
        hideWindow: () async {},
        prepareExit: () => WindowsTrayService.runBeforeExitHooks(
          timeout: const Duration(milliseconds: 120),
        ),
        flushHistory: () async {},
        flushSync: (_) async {},
        closeHost: () async {},
        closeScripts: () async {},
        destroyWindow: () async {
          destroyStartedAtDestroyWindow =
              WindowsTrayService.isNativeDestroyStarted;
        },
        totalBudget: const Duration(milliseconds: 500),
      );
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(destroyStartedAtDestroyWindow, isTrue);

      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(postTimeoutSideEffects, 0);
    },
  );

  testWidgets(
    'P1-2: macOS and Linux close paths do not execute Windows pre-exit hooks',
    variant: TargetPlatformVariant(const <TargetPlatform>{
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
    (tester) async {
      final storage = await initTestStorage();
      await storage.setWindowsCloseAction('exit');
      var windowsHookCalls = 0;
      var destroyCalls = 0;
      WindowsTrayService.registerBeforeExitHook(() async {
        windowsHookCalls++;
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            storage: storage,
            client: CmsClient(),
            onSetPreventCloseForTest: (_) async {},
            onFlushHistoryForTest: () async {},
            onFlushSyncForTest: (_) async {},
            onCloseHostForTest: () async {},
            onCloseScriptsForTest: () async {},
            onDestroyWindowForTest: () async {
              destroyCalls++;
            },
          ),
        ),
      );
      await tester.pump();

      final dynamic shellState = tester.state(find.byType(AdaptiveShell));
      await (shellState.onWindowClose() as Future<void>);

      expect(destroyCalls, 1);
      expect(windowsHookCalls, 0);
      expect(WindowsTrayService.isNativeDestroyStarted, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

class _SerializedTextureFakeMdkBackend implements MdkNativeBackend {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final StreamController<({int oldStatus, int newStatus})> _statusCtl =
      StreamController<({int oldStatus, int newStatus})>.broadcast();
  final StreamController<mdk.PlaybackState> _stateCtl =
      StreamController<mdk.PlaybackState>.broadcast();
  final StreamController<({int error, String category, String detail})> _eventCtl =
      StreamController<({int error, String category, String detail})>.broadcast();

  Completer<int>? _prepareCompleter;
  final List<Completer<int>> _textureCompleters = <Completer<int>>[];
  final List<String> events = <String>[];
  int _inFlightTextures = 0;
  int maxConcurrentUpdateTexture = 0;
  int updateTextureCalls = 0;
  bool disposeAsyncCalled = false;

  void emitLoaded() {
    _statusCtl.add((oldStatus: 0, newStatus: mdk.MediaStatus.loaded));
  }

  void completePrepare(int code) {
    final c = _prepareCompleter;
    _prepareCompleter = null;
    if (c != null && !c.isCompleted) c.complete(code);
  }

  void completeNextTexture(int texId) {
    final c = _textureCompleters.removeAt(0);
    _textureId.value = texId;
    c.complete(texId);
  }

  @override
  ValueListenable<int?> get textureIdListenable => _textureId;
  @override
  Stream<({int oldStatus, int newStatus})> get onStatusChanged => _statusCtl.stream;
  @override
  Stream<mdk.PlaybackState> get onStateChanged => _stateCtl.stream;
  @override
  Stream<({int error, String category, String detail})> get onEvent => _eventCtl.stream;
  @override
  int get positionMs => 0;
  @override
  int get bufferedMs => 0;
  @override
  bool get isLive => false;
  @override
  MdkMediaSnapshot readMediaSnapshot() => const MdkMediaSnapshot(
        durationMs: 60000,
        videoWidth: 1280,
        videoHeight: 720,
      );
  @override
  set media(String uri) {}
  @override
  set state(mdk.PlaybackState value) {}
  @override
  set playbackRate(double value) {}
  @override
  set volume(double value) {}
  @override
  set mute(bool value) {}
  @override
  set loop(int value) {}
  @override
  set videoDecoders(List<String> decoders) {}
  @override
  set activeAudioTracks(List<int> tracks) {}
  @override
  set activeSubtitleTracks(List<int> tracks) {}
  @override
  set activeVideoTracks(List<int> tracks) {}
  @override
  void setProperty(String key, String value) {}
  @override
  void setBufferRange({int min = -1, int max = -1, bool drop = false}) {}
  @override
  void setMediaForType(String uri, mdk.MediaType type) {}
  @override
  Future<int> prepare({int position = 0}) {
    final c = Completer<int>();
    _prepareCompleter = c;
    return c.future;
  }
  @override
  Future<int> seek({required int position, required mdk.SeekFlag flags}) async => 0;
  @override
  Future<int> updateTexture({int? width, int? height}) async {
    updateTextureCalls++;
    _inFlightTextures++;
    if (_inFlightTextures > maxConcurrentUpdateTexture) {
      maxConcurrentUpdateTexture = _inFlightTextures;
    }
    final c = Completer<int>();
    _textureCompleters.add(c);
    try {
      final texId = await c.future;
      events.add('texture_end:$texId');
      return texId;
    } finally {
      _inFlightTextures--;
    }
  }
  @override
  Future<void> disposeAsync() async {
    disposeAsyncCalled = true;
    events.add('disposeAsync');
    await _statusCtl.close();
    await _stateCtl.close();
    await _eventCtl.close();
    _textureId.dispose();
  }
}

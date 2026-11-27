// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/windows_window_bounds.dart';

import 'test_storage_helper.dart';

class _FakeWindowAdapter implements WindowsWindowPlatformAdapter {
  ({bool nativeApplied, bool restoredFromSaved}) startupStatus = (
    nativeApplied: false,
    restoredFromSaved: false,
  );
  List<Rect> workAreas = const <Rect>[Rect.fromLTWH(0, 0, 1920, 1040)];
  Rect? currentBounds = const Rect.fromLTWH(10, 10, 1280, 720);
  bool maximizedState = false;
  bool minimizedState = false;
  bool fullscreenState = false;

  final List<Rect> setBoundsCalls = <Rect>[];
  int centerCalls = 0;
  int maximizeCalls = 0;
  int saveNativeCalls = 0;

  @override
  Future<({bool nativeApplied, bool restoredFromSaved})>
      getStartupPlacementStatus() async => startupStatus;

  @override
  Future<List<Rect>> getDisplayWorkAreas() async => workAreas;

  @override
  Future<Rect?> getBounds() async => currentBounds;

  @override
  Future<void> setBounds(Rect bounds) async {
    setBoundsCalls.add(bounds);
    currentBounds = bounds;
  }

  @override
  Future<void> center() async {
    centerCalls++;
    if (workAreas.isNotEmpty) {
      currentBounds = WindowsWindowBounds.centeredInWorkArea(workAreas.first);
    }
  }

  @override
  Future<bool> isMaximized() async => maximizedState;

  @override
  Future<void> maximize() async {
    maximizeCalls++;
    maximizedState = true;
  }

  @override
  Future<bool> isMinimized() async => minimizedState;

  @override
  Future<bool> isFullScreen() async => fullscreenState;

  @override
  Future<void> saveNativePlacement() async {
    saveNativeCalls++;
  }
}

void main() {
  group('WindowsWindowBounds geometry & multi-monitor validation', () {
    test('first launch centers default 1280x720 in primary monitor work area', () {
      final resolved = WindowsWindowBounds.resolveForWorkAreas(
        saved: null,
        workAreas: const <Rect>[Rect.fromLTWH(0, 0, 1920, 1040)],
      );
      expect(resolved.left, closeTo(320, 0.5));
      expect(resolved.top, closeTo(160, 0.5));
      expect(resolved.width, 1280);
      expect(resolved.height, 720);
      expect(resolved.maximized, isFalse);
    });

    test('first launch clamps cleanly and centers on small high-DPI laptop display', () {
      // E.g. 1366x768 at 125% scaling -> ~1092x582 logical work area
      final resolved = WindowsWindowBounds.resolveForWorkAreas(
        saved: null,
        workAreas: const <Rect>[Rect.fromLTWH(0, 0, 1092, 582)],
      );
      expect(resolved.width, closeTo(1060, 0.5));
      expect(resolved.height, closeTo(550, 0.5));
      expect(resolved.left, closeTo(16, 0.5));
      expect(resolved.top, closeTo(16, 0.5));
      expect(resolved.isValid, isTrue);
    });

    test('subsequent launch preserves exact saved position including negative left secondary monitor', () {
      const saved = WindowsWindowBounds(
        left: -1520,
        top: 140,
        width: 1360,
        height: 820,
        maximized: false,
      );
      final resolved = WindowsWindowBounds.resolveForWorkAreas(
        saved: saved,
        workAreas: const <Rect>[
          Rect.fromLTWH(0, 0, 1920, 1040),
          Rect.fromLTWH(-1920, 0, 1920, 1040),
        ],
      );
      expect(resolved, saved);
    });

    test('falls back to primary center when previous external monitor was disconnected', () {
      const savedOnDisconnectedMonitor = WindowsWindowBounds(
        left: 2200,
        top: 120,
        width: 1280,
        height: 720,
        maximized: true,
      );
      final resolved = WindowsWindowBounds.resolveForWorkAreas(
        saved: savedOnDisconnectedMonitor,
        workAreas: const <Rect>[Rect.fromLTWH(0, 0, 1920, 1040)],
      );
      expect(resolved.left, closeTo(320, 0.5));
      expect(resolved.top, closeTo(160, 0.5));
      expect(resolved.width, 1280);
      expect(resolved.height, 720);
      expect(resolved.maximized, isFalse);
    });

    test('clamps off-top title bar back inside visible work area', () {
      const saved = WindowsWindowBounds(
        left: 240,
        top: -60,
        width: 1280,
        height: 720,
      );
      final resolved = WindowsWindowBounds.resolveForWorkAreas(
        saved: saved,
        workAreas: const <Rect>[Rect.fromLTWH(0, 0, 1920, 1040)],
      );
      expect(resolved.left, 240);
      expect(resolved.top, 0);
      expect(resolved.width, 1280);
      expect(resolved.height, 720);
    });

    test('JSON serialization rejects minimized sentinel and corrupt payloads', () {
      const valid = WindowsWindowBounds(
        left: 410.5,
        top: 125.0,
        width: 1400,
        height: 860,
        maximized: true,
      );
      expect(WindowsWindowBounds.tryParseJson(valid.toJsonString()), valid);
      expect(
        WindowsWindowBounds.tryParseJson(
          '{"left":-32000,"top":-32000,"width":160,"height":28,"maximized":false}',
        ),
        isNull,
      );
      expect(WindowsWindowBounds.tryParseJson('not-json'), isNull);
      expect(WindowsWindowBounds.tryParseJson(''), isNull);
    });
  });

  group('WindowsWindowBoundsController lifecycle & StorageService persistence', () {
    test('first launch centers via work area and persists subsequent drags/resizes', () async {
      final storage = await initTestStorage();
      final adapter = _FakeWindowAdapter();
      final controller = WindowsWindowBoundsController(
        storage: storage,
        adapter: adapter,
      );
      addTearDown(controller.dispose);

      expect(storage.windowsWindowBounds, isNull);
      await controller.restoreOnStartup();
      expect(adapter.setBoundsCalls, hasLength(1));
      expect(adapter.setBoundsCalls.single, const Rect.fromLTWH(320, 160, 1280, 720));
      expect(adapter.maximizeCalls, 0);

      // User drags and resizes window
      adapter.currentBounds = const Rect.fromLTWH(512, 188, 1344, 780);
      await controller.captureAndPersist(immediate: true);

      final saved = storage.windowsWindowBounds;
      expect(saved, isNotNull);
      expect(saved!.left, 512);
      expect(saved.top, 188);
      expect(saved.width, 1344);
      expect(saved.height, 780);
      expect(saved.maximized, isFalse);
      expect(adapter.saveNativeCalls, 1);
    });

    test('subsequent launch restores exact saved position, size, and maximized state', () async {
      final storage = await initTestStorage();
      await storage.setWindowsWindowBounds(
        const WindowsWindowBounds(
          left: 280,
          top: 96,
          width: 1440,
          height: 860,
          maximized: true,
        ),
      );
      final adapter = _FakeWindowAdapter();
      final controller = WindowsWindowBoundsController(
        storage: storage,
        adapter: adapter,
      );
      addTearDown(controller.dispose);

      await controller.restoreOnStartup();
      expect(adapter.setBoundsCalls.single, const Rect.fromLTWH(280, 96, 1440, 860));
      expect(adapter.maximizeCalls, 1);
      expect(adapter.saveNativeCalls, 1);
    });

    test('preserves normal bounds when maximized, minimized, or in player fullscreen', () async {
      final storage = await initTestStorage();
      final adapter = _FakeWindowAdapter()
        ..currentBounds = const Rect.fromLTWH(360, 140, 1280, 720);
      final controller = WindowsWindowBoundsController(
        storage: storage,
        adapter: adapter,
      );
      addTearDown(controller.dispose);

      // Capture normal window first
      await controller.captureAndPersist();
      expect(storage.windowsWindowBounds?.left, 360);
      expect(storage.windowsWindowBounds?.maximized, isFalse);

      // Maximize -> keeps normal rect, flips maximized to true
      adapter.maximizedState = true;
      adapter.currentBounds = const Rect.fromLTWH(-8, -8, 1936, 1056);
      await controller.captureAndPersist();
      expect(storage.windowsWindowBounds?.left, 360);
      expect(storage.windowsWindowBounds?.width, 1280);
      expect(storage.windowsWindowBounds?.maximized, isTrue);

      // Minimize -> completely ignored, keeps previous saved bounds
      adapter.minimizedState = true;
      adapter.currentBounds = const Rect.fromLTWH(-32000, -32000, 160, 28);
      await controller.captureAndPersist();
      expect(storage.windowsWindowBounds?.left, 360);
      expect(storage.windowsWindowBounds?.maximized, isTrue);

      // Player fullscreen -> completely ignored, keeps previous saved bounds
      adapter.minimizedState = false;
      adapter.maximizedState = false;
      adapter.fullscreenState = true;
      adapter.currentBounds = const Rect.fromLTWH(0, 0, 1920, 1080);
      await controller.captureAndPersist();
      expect(storage.windowsWindowBounds?.left, 360);
      expect(storage.windowsWindowBounds?.width, 1280);
    });

    test('skips redundant Dart reposition when native Win32 runner already applied placement', () async {
      final storage = await initTestStorage();
      await storage.setWindowsWindowBounds(
        const WindowsWindowBounds(
          left: 420,
          top: 110,
          width: 1300,
          height: 760,
        ),
      );
      final adapter = _FakeWindowAdapter()
        ..startupStatus = (nativeApplied: true, restoredFromSaved: true)
        ..currentBounds = const Rect.fromLTWH(420, 110, 1300, 760);
      final controller = WindowsWindowBoundsController(
        storage: storage,
        adapter: adapter,
      );
      addTearDown(controller.dispose);

      await controller.restoreOnStartup();
      expect(adapter.setBoundsCalls, isEmpty);
      expect(adapter.centerCalls, 0);
      expect(adapter.maximizeCalls, 0);
    });

    test('window bounds stay device-local and are excluded from cross-device backup export', () async {
      final storage = await initTestStorage();
      await storage.setWindowsWindowBounds(
        const WindowsWindowBounds(
          left: 333,
          top: 222,
          width: 1280,
          height: 720,
        ),
      );
      final exported = storage.exportBackupJson();
      expect(exported.contains(WindowsWindowBounds.prefKey), isFalse);
    });
  });
}

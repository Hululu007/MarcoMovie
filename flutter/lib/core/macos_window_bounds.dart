// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'storage_service.dart';

/// Persisted macOS normal (non-fullscreen, non-minimized) window bounds.
///
/// Coordinates use AppKit screen points (`origin` at the bottom-left of the
/// primary screen, `y` increasing upward) so they match `NSWindow.frame` and
/// `NSScreen.visibleFrame` 1:1 without DPI conversion drift.
@immutable
class MacosWindowBounds {
  static const String prefKey = 'macos_window_bounds_v1';
  static const String nativeDefaultsKey = 'marco_macos_window_frame_v1';
  static const Size defaultSize = Size(1280, 760);
  static const Size minimumSize = Size(720, 520);
  static const double minVisibleWidth = 180.0;
  static const double minVisibleHeight = 80.0;
  static const double minCoordGuard = -16000.0;
  static const double maxCoordGuard = 32768.0;
  static const double maxDimensionGuard = 16384.0;

  final double x;
  final double y;
  final double width;
  final double height;

  const MacosWindowBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  /// Top edge in AppKit coordinates (`y + height`, where the title bar and
  /// traffic-light buttons sit).
  double get topY => y + height;

  bool get isValid =>
      x.isFinite &&
      y.isFinite &&
      width.isFinite &&
      height.isFinite &&
      width >= minimumSize.width &&
      height >= minimumSize.height &&
      width <= maxDimensionGuard &&
      height <= maxDimensionGuard &&
      x > minCoordGuard &&
      y > minCoordGuard &&
      x < maxCoordGuard &&
      y < maxCoordGuard;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'x': double.parse(x.toStringAsFixed(1)),
        'y': double.parse(y.toStringAsFixed(1)),
        'width': double.parse(width.toStringAsFixed(1)),
        'height': double.parse(height.toStringAsFixed(1)),
      };

  String toJsonString() => jsonEncode(toJson());

  static MacosWindowBounds? tryParseMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final x = (map['x'] as num?)?.toDouble();
    final y = (map['y'] as num?)?.toDouble();
    final width = (map['width'] as num?)?.toDouble();
    final height = (map['height'] as num?)?.toDouble();
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    final candidate = MacosWindowBounds(
      x: x,
      y: y,
      width: width,
      height: height,
    );
    return candidate.isValid ? candidate : null;
  }

  static MacosWindowBounds? tryParseJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return tryParseMap(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Centers [preferredSize] inside AppKit [visibleFrame], clamping cleanly
  /// when the display is smaller than [preferredSize].
  static MacosWindowBounds centeredInVisibleFrame(
    Rect visibleFrame, {
    Size preferredSize = defaultSize,
  }) {
    final safeW = visibleFrame.width.isFinite && visibleFrame.width > 0
        ? visibleFrame.width
        : defaultSize.width;
    final safeH = visibleFrame.height.isFinite && visibleFrame.height > 0
        ? visibleFrame.height
        : defaultSize.height;
    final minW = math.min(minimumSize.width, safeW);
    final minH = math.min(minimumSize.height, safeH);
    final w = preferredSize.width <= safeW
        ? math.max(minW, preferredSize.width)
        : math.max(minW, safeW - 24.0).clamp(minW, safeW).toDouble();
    final h = preferredSize.height <= safeH
        ? math.max(minH, preferredSize.height)
        : math.max(minH, safeH - 24.0).clamp(minH, safeH).toDouble();
    final left = visibleFrame.left + (safeW - w) / 2.0;
    final bottom = visibleFrame.top + (safeH - h) / 2.0;
    return MacosWindowBounds(x: left, y: bottom, width: w, height: h);
  }

  /// Resolves safe initial AppKit bounds against currently connected screens'
  /// `visibleFrame` rectangles (`Rect.fromLTWH(minX, minY, width, height)`
  /// where `minY` is the bottom edge above the Dock and `minY + height` is the
  /// top edge below the menu bar).
  ///
  /// Guarantees that:
  /// - First launch centers cleanly on the primary screen.
  /// - Disconnecting an external monitor moves the window onto the primary
  ///   screen while preserving the user's preferred size (clamped to fit).
  /// - The title bar and red/yellow/green traffic lights at the top-left of the
  ///   window always remain strictly inside the screen's `visibleFrame`.
  static MacosWindowBounds resolveForVisibleFrames({
    required MacosWindowBounds? saved,
    required List<Rect> visibleFrames,
    Rect? primaryVisibleFrame,
  }) {
    final validFrames = visibleFrames
        .where(
          (r) =>
              r.left.isFinite &&
              r.top.isFinite &&
              r.width.isFinite &&
              r.height.isFinite &&
              r.width > 0 &&
              r.height > 0,
        )
        .toList(growable: false);
    final primary = (primaryVisibleFrame != null &&
            primaryVisibleFrame.width > 0 &&
            primaryVisibleFrame.height > 0)
        ? primaryVisibleFrame
        : (validFrames.isNotEmpty
            ? validFrames.first
            : const Rect.fromLTWH(0, 0, 1440, 875));

    if (saved == null || !saved.isValid) {
      return centeredInVisibleFrame(primary);
    }
    if (validFrames.isEmpty) {
      return saved;
    }

    Rect? bestFrame;
    double bestOverlapArea = -1;
    Rect bestIntersection = Rect.zero;
    final savedRect = saved.rect;

    for (final frame in validFrames) {
      final inter = savedRect.intersect(frame);
      if (inter.width <= 0 || inter.height <= 0) continue;
      final area = inter.width * inter.height;
      if (area > bestOverlapArea) {
        bestOverlapArea = area;
        bestFrame = frame;
        bestIntersection = inter;
      }
    }

    // Previous monitor disconnected (or insufficient visible overlap): keep user's
    // saved dimensions (clamped to primary screen) and center on primary display.
    if (bestFrame == null ||
        bestIntersection.width < 120.0 ||
        bestIntersection.height < minVisibleHeight) {
      return centeredInVisibleFrame(
        primary,
        preferredSize: Size(saved.width, saved.height),
      );
    }

    final minW = math.min(minimumSize.width, bestFrame.width);
    final minH = math.min(minimumSize.height, bestFrame.height);
    final clampedW = saved.width.clamp(minW, bestFrame.width).toDouble();
    final clampedH = saved.height.clamp(minH, bestFrame.height).toDouble();

    // Keep top-left traffic lights (x .. x + 78) and draggable title bar strip
    // strictly inside bestFrame horizontally.
    final minX = bestFrame.left;
    final maxX = math.max(
      bestFrame.left,
      bestFrame.right - math.min(minVisibleWidth, clampedW),
    );
    final clampedX = saved.x.clamp(minX, maxX).toDouble();

    // In AppKit coordinates, top edge of window is `y + clampedH`.
    // Keep top edge strictly <= bestFrame.bottom (which stores AppKit maxY)
    // and >= bestFrame.top + minVisibleHeight so titlebar & buttons are visible.
    final frameMinY = bestFrame.top;
    final frameMaxY = bestFrame.bottom;
    final minTopY = math.min(frameMaxY, frameMinY + math.min(minVisibleHeight, clampedH));
    final clampedTopY = (saved.y + clampedH).clamp(minTopY, frameMaxY).toDouble();
    final clampedY = clampedTopY - clampedH;

    return MacosWindowBounds(
      x: clampedX,
      y: clampedY,
      width: clampedW,
      height: clampedH,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MacosWindowBounds &&
      (other.x - x).abs() < 0.5 &&
      (other.y - y).abs() < 0.5 &&
      (other.width - width).abs() < 0.5 &&
      (other.height - height).abs() < 0.5;

  @override
  int get hashCode => Object.hash(
        x.round(),
        y.round(),
        width.round(),
        height.round(),
      );
}

@immutable
class MacosWindowNativeState {
  final bool restoredFromSaved;
  final bool isFullScreen;
  final bool isMiniaturized;
  final MacosWindowBounds? savedFrame;
  final MacosWindowBounds? currentFrame;
  final Size minSize;

  const MacosWindowNativeState({
    this.restoredFromSaved = false,
    this.isFullScreen = false,
    this.isMiniaturized = false,
    this.savedFrame,
    this.currentFrame,
    this.minSize = MacosWindowBounds.minimumSize,
  });
}

/// Platform bridge to `MainFlutterWindow` (`marco_movie/macos_window`) and
/// `window_manager`, abstracted for unit testing on any host OS.
abstract class MacosWindowPlatformAdapter {
  Future<MacosWindowNativeState?> getNativeState();
  Future<bool> saveNormalBounds();
  Future<bool> applyNormalBounds(MacosWindowBounds bounds);
  Future<void> setAppearanceMode(ThemeMode mode);
  Future<bool> revealInFinder(String path);
  Future<bool> isFullScreen();
  Future<bool> isMinimized();
  Future<Rect?> getWindowManagerBounds();
}

class DefaultMacosWindowPlatformAdapter implements MacosWindowPlatformAdapter {
  static const MethodChannel channel = MethodChannel('marco_movie/macos_window');

  const DefaultMacosWindowPlatformAdapter();

  static bool get _isMacOS => !kIsWeb && Platform.isMacOS;

  @override
  Future<MacosWindowNativeState?> getNativeState() async {
    if (!_isMacOS) return null;
    try {
      final raw = await channel.invokeMethod<dynamic>('getWindowBoundsState');
      if (raw is! Map) return null;
      final minW = (raw['minWidth'] as num?)?.toDouble() ??
          MacosWindowBounds.minimumSize.width;
      final minH = (raw['minHeight'] as num?)?.toDouble() ??
          MacosWindowBounds.minimumSize.height;
      return MacosWindowNativeState(
        restoredFromSaved: raw['restoredFromSaved'] == true,
        isFullScreen: raw['isFullScreen'] == true,
        isMiniaturized: raw['isMiniaturized'] == true,
        savedFrame: raw['savedFrame'] is Map
            ? MacosWindowBounds.tryParseMap(raw['savedFrame'] as Map)
            : null,
        currentFrame: raw['currentFrame'] is Map
            ? MacosWindowBounds.tryParseMap(raw['currentFrame'] as Map)
            : null,
        minSize: Size(minW, minH),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> saveNormalBounds() async {
    if (!_isMacOS) return false;
    try {
      final ok = await channel.invokeMethod<dynamic>('saveNormalBounds');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> applyNormalBounds(MacosWindowBounds bounds) async {
    if (!_isMacOS) return false;
    try {
      final ok = await channel.invokeMethod<dynamic>(
        'applyNormalBounds',
        bounds.toJson(),
      );
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setAppearanceMode(ThemeMode mode) async {
    if (!_isMacOS) return;
    final arg = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    try {
      await channel.invokeMethod<void>('setAppearance', arg);
    } catch (_) {}
  }

  @override
  Future<bool> revealInFinder(String path) async {
    if (!_isMacOS || path.trim().isEmpty) return false;
    try {
      final ok = await channel.invokeMethod<dynamic>(
        'revealInFinder',
        <String, dynamic>{'path': path},
      );
      if (ok == true) return true;
    } catch (_) {}
    try {
      final res = await Process.run('open', ['-R', path]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isFullScreen() async {
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isMinimized() async {
    try {
      return await windowManager.isMinimized();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Rect?> getWindowManagerBounds() async {
    try {
      return await windowManager.getBounds();
    } catch (_) {
      return null;
    }
  }
}

/// Coordinates macOS window bounds persistence and native title-bar appearance.
///
/// Primary restoration happens natively in `MainFlutterWindow.awakeFromNib()`
/// before the window is ordered on screen so cold launch never flickers. This
/// controller mirrors the normal frame into [StorageService], guards against
/// overwriting the normal frame while fullscreen or minimized, and keeps
/// `NSWindow.appearance` aligned with Light / Dark / System theme changes.
class MacosWindowBoundsController with WindowListener {
  static MacosWindowBoundsController? _shared;
  static MacosWindowBoundsController? get shared => _shared;

  final StorageService _storage;
  final MacosWindowPlatformAdapter _adapter;
  final bool _attachWindowManager;
  final Duration debounceDuration;

  Timer? _saveTimer;
  MacosWindowBounds? _lastNormalBounds;
  bool _inFullscreen = false;
  bool _minimized = false;
  bool _disposed = false;

  MacosWindowBoundsController({
    required StorageService storage,
    MacosWindowPlatformAdapter adapter =
        const DefaultMacosWindowPlatformAdapter(),
    bool attachWindowManager = true,
    this.debounceDuration = const Duration(milliseconds: 250),
  })  : _storage = storage,
        _adapter = adapter,
        _attachWindowManager = attachWindowManager {
    _lastNormalBounds = _storage.loadMacosWindowBounds();
    if (_attachWindowManager) {
      windowManager.addListener(this);
    }
  }

  static MacosWindowBoundsController installShared(
    StorageService storage, {
    MacosWindowPlatformAdapter adapter =
        const DefaultMacosWindowPlatformAdapter(),
    bool attachWindowManager = true,
  }) {
    _shared?.dispose();
    final ctrl = MacosWindowBoundsController(
      storage: storage,
      adapter: adapter,
      attachWindowManager: attachWindowManager,
    );
    _shared = ctrl;
    return ctrl;
  }

  MacosWindowBounds? get lastNormalBounds => _lastNormalBounds;
  bool get isFullScreen => _inFullscreen;
  bool get isMinimized => _minimized;

  /// Syncs with the native pre-show restoration state on startup.
  ///
  /// Never resizes or repositions the window if `MainFlutterWindow` already
  /// restored it before first show. Only falls back to applying a persisted
  /// `StorageService` frame if native defaults had no saved record yet.
  Future<void> syncOnStartup({ThemeMode? initialThemeMode}) async {
    if (_disposed) return;
    if (initialThemeMode != null) {
      await _adapter.setAppearanceMode(initialThemeMode);
    }
    final nativeState = await _adapter.getNativeState();
    if (_disposed) return;
    if (nativeState != null) {
      _inFullscreen = nativeState.isFullScreen;
      _minimized = nativeState.isMiniaturized;
      if (nativeState.savedFrame != null) {
        _lastNormalBounds = nativeState.savedFrame;
        await _storage.saveMacosWindowBounds(nativeState.savedFrame!);
      } else if (!nativeState.restoredFromSaved &&
          !_inFullscreen &&
          !_minimized &&
          _lastNormalBounds != null &&
          _lastNormalBounds!.isValid) {
        await _adapter.applyNormalBounds(_lastNormalBounds!);
      } else if (!_inFullscreen &&
          !_minimized &&
          nativeState.currentFrame != null &&
          nativeState.currentFrame!.isValid) {
        _lastNormalBounds = nativeState.currentFrame;
        await _storage.saveMacosWindowBounds(nativeState.currentFrame!);
      }
      return;
    }
    _inFullscreen = await _adapter.isFullScreen();
    _minimized = await _adapter.isMinimized();
  }

  Future<void> applyAppearanceMode(ThemeMode mode) =>
      _adapter.setAppearanceMode(mode);

  Future<bool> revealInFinder(String path) => _adapter.revealInFinder(path);

  void _scheduleCapture() {
    if (_disposed || _inFullscreen || _minimized) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(debounceDuration, () {
      unawaited(captureNow());
    });
  }

  Future<bool> captureNow() async {
    if (_disposed || _inFullscreen || _minimized) return false;
    final nativeState = await _adapter.getNativeState();
    if (_disposed) return false;
    if (nativeState != null) {
      _inFullscreen = nativeState.isFullScreen;
      _minimized = nativeState.isMiniaturized;
      if (_inFullscreen || _minimized) return false;
      final frame = nativeState.currentFrame;
      if (frame != null && frame.isValid) {
        _lastNormalBounds = frame;
        await _adapter.saveNormalBounds();
        await _storage.saveMacosWindowBounds(frame);
        return true;
      }
      return false;
    }
    if (await _adapter.isFullScreen() || await _adapter.isMinimized()) {
      return false;
    }
    final rect = await _adapter.getWindowManagerBounds();
    if (rect == null) return false;
    final candidate = MacosWindowBounds(
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    );
    if (!candidate.isValid) return false;
    _lastNormalBounds = candidate;
    await _storage.saveMacosWindowBounds(candidate);
    return true;
  }

  @override
  void onWindowMoved() => _scheduleCapture();

  @override
  void onWindowResized() => _scheduleCapture();

  @override
  void onWindowEnterFullScreen() {
    _saveTimer?.cancel();
    _inFullscreen = true;
  }

  @override
  void onWindowLeaveFullScreen() {
    _inFullscreen = false;
    _scheduleCapture();
  }

  @override
  void onWindowMinimize() {
    _saveTimer?.cancel();
    _minimized = true;
  }

  @override
  void onWindowRestore() {
    _minimized = false;
    _scheduleCapture();
  }

  @override
  void onWindowClose() {
    _saveTimer?.cancel();
    if (!_inFullscreen && !_minimized) {
      unawaited(captureNow());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_attachWindowManager) {
      windowManager.removeListener(this);
    }
    if (identical(_shared, this)) {
      _shared = null;
    }
  }
}

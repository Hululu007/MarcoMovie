// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'storage_service.dart';

/// Persisted Windows desktop window bounds (normal unmaximized frame + state).
///
/// Stored strictly per-device (never synced across devices) so each monitor
/// setup restores its own position cleanly.
@immutable
class WindowsWindowBounds {
  static const String prefKey = 'windows_window_bounds_v1';
  static const Size defaultSize = Size(1280, 720);
  static const Size minimumSize = Size(720, 520);
  static const double minVisibleWidth = 120.0;
  static const double minVisibleHeight = 80.0;
  static const double minCoordGuard = -16000.0;
  static const double maxCoordGuard = 32768.0;
  static const double maxDimensionGuard = 16384.0;

  final double left;
  final double top;
  final double width;
  final double height;
  final bool maximized;

  const WindowsWindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.maximized = false,
  });

  Rect get rect => Rect.fromLTWH(left, top, width, height);

  bool get isValid =>
      left.isFinite &&
      top.isFinite &&
      width.isFinite &&
      height.isFinite &&
      width >= minimumSize.width &&
      height >= minimumSize.height &&
      width <= maxDimensionGuard &&
      height <= maxDimensionGuard &&
      left > minCoordGuard &&
      top > minCoordGuard &&
      left < maxCoordGuard &&
      top < maxCoordGuard;

  WindowsWindowBounds copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
    bool? maximized,
  }) =>
      WindowsWindowBounds(
        left: left ?? this.left,
        top: top ?? this.top,
        width: width ?? this.width,
        height: height ?? this.height,
        maximized: maximized ?? this.maximized,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'left': double.parse(left.toStringAsFixed(1)),
        'top': double.parse(top.toStringAsFixed(1)),
        'width': double.parse(width.toStringAsFixed(1)),
        'height': double.parse(height.toStringAsFixed(1)),
        'maximized': maximized,
      };

  String toJsonString() => jsonEncode(toJson());

  static WindowsWindowBounds? tryParseJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final left = (decoded['left'] as num?)?.toDouble();
      final top = (decoded['top'] as num?)?.toDouble();
      final width = (decoded['width'] as num?)?.toDouble();
      final height = (decoded['height'] as num?)?.toDouble();
      final maximized = decoded['maximized'] == true;
      if (left == null || top == null || width == null || height == null) {
        return null;
      }
      final candidate = WindowsWindowBounds(
        left: left,
        top: top,
        width: width,
        height: height,
        maximized: maximized,
      );
      return candidate.isValid ? candidate : null;
    } catch (_) {
      return null;
    }
  }

  /// Computes a centered default rectangle inside [workArea], clamping size
  /// gracefully when the display work area is smaller than [preferredSize].
  static Rect centeredInWorkArea(
    Rect workArea, {
    Size preferredSize = defaultSize,
  }) {
    final safeWorkW = workArea.width.isFinite && workArea.width > 0
        ? workArea.width
        : defaultSize.width;
    final safeWorkH = workArea.height.isFinite && workArea.height > 0
        ? workArea.height
        : defaultSize.height;
    final minW = math.min(minimumSize.width, safeWorkW);
    final minH = math.min(minimumSize.height, safeWorkH);
    final w = preferredSize.width <= safeWorkW
        ? preferredSize.width
        : math.max(minW, safeWorkW - 32.0);
    final h = preferredSize.height <= safeWorkH
        ? preferredSize.height
        : math.max(minH, safeWorkH - 32.0);
    final x = workArea.left + (safeWorkW - w) / 2.0;
    final y = workArea.top + (safeWorkH - h) / 2.0;
    return Rect.fromLTWH(x, y, w, h);
  }

  /// Resolves safe initial bounds against the currently connected monitor
  /// [workAreas].
  ///
  /// - First launch (`saved == null` or invalid): centers inside the primary
  ///   monitor's work area.
  /// - Subsequent launches: restores [saved] on its matching monitor (including
  ///   negative coordinates on left/top secondary monitors) while clamping the
  ///   title bar into view; if the previous monitor was disconnected so overlap
  ///   drops below [minVisibleWidth] × [minVisibleHeight], falls back cleanly to
  ///   centering on the primary monitor.
  static WindowsWindowBounds resolveForWorkAreas({
    required WindowsWindowBounds? saved,
    required List<Rect> workAreas,
    Rect? primaryWorkArea,
  }) {
    final validAreas = workAreas
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
    final primary = (primaryWorkArea != null &&
            primaryWorkArea.width > 0 &&
            primaryWorkArea.height > 0)
        ? primaryWorkArea
        : (validAreas.isNotEmpty
            ? validAreas.first
            : const Rect.fromLTWH(0, 0, 1920, 1040));

    if (saved == null || !saved.isValid) {
      final centered = centeredInWorkArea(primary);
      return WindowsWindowBounds(
        left: centered.left,
        top: centered.top,
        width: centered.width,
        height: centered.height,
        maximized: false,
      );
    }

    if (validAreas.isEmpty) {
      return saved;
    }

    Rect? bestArea;
    double bestOverlapArea = -1;
    Rect bestIntersection = Rect.zero;
    final savedRect = saved.rect;

    for (final area in validAreas) {
      final inter = savedRect.intersect(area);
      if (inter.width <= 0 || inter.height <= 0) continue;
      final overlap = inter.width * inter.height;
      if (overlap > bestOverlapArea) {
        bestOverlapArea = overlap;
        bestArea = area;
        bestIntersection = inter;
      }
    }

    if (bestArea == null ||
        bestIntersection.width < minVisibleWidth ||
        bestIntersection.height < minVisibleHeight) {
      final centered = centeredInWorkArea(primary);
      return WindowsWindowBounds(
        left: centered.left,
        top: centered.top,
        width: centered.width,
        height: centered.height,
        maximized: false,
      );
    }

    final minW = math.min(minimumSize.width, bestArea.width);
    final minH = math.min(minimumSize.height, bestArea.height);
    final clampedW = saved.width.clamp(minW, bestArea.width).toDouble();
    final clampedH = saved.height.clamp(minH, bestArea.height).toDouble();

    final minLeft = bestArea.left - clampedW + minVisibleWidth;
    final maxLeft = bestArea.right - minVisibleWidth;
    final clampedLeft = minLeft <= maxLeft
        ? saved.left.clamp(minLeft, maxLeft).toDouble()
        : bestArea.left;

    final maxTop = math.max(bestArea.top, bestArea.bottom - minVisibleHeight);
    final clampedTop = saved.top.clamp(bestArea.top, maxTop).toDouble();

    return WindowsWindowBounds(
      left: clampedLeft,
      top: clampedTop,
      width: clampedW,
      height: clampedH,
      maximized: saved.maximized,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowsWindowBounds &&
      (other.left - left).abs() < 0.5 &&
      (other.top - top).abs() < 0.5 &&
      (other.width - width).abs() < 0.5 &&
      (other.height - height).abs() < 0.5 &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(
        left.round(),
        top.round(),
        width.round(),
        height.round(),
        maximized,
      );
}

/// Platform abstraction over `window_manager` and our native Win32 runner
/// placement channel so [WindowsWindowBoundsController] is 100% unit-testable.
abstract class WindowsWindowPlatformAdapter {
  Future<({bool nativeApplied, bool restoredFromSaved})>
      getStartupPlacementStatus();
  Future<List<Rect>> getDisplayWorkAreas();
  Future<Rect?> getBounds();
  Future<void> setBounds(Rect bounds);
  Future<void> center();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<bool> isMinimized();
  Future<bool> isFullScreen();
  Future<void> saveNativePlacement();
}

class DefaultWindowsWindowPlatformAdapter
    implements WindowsWindowPlatformAdapter {
  static const MethodChannel _nativeChannel = MethodChannel(
    'marco_movie/windows_window_bounds',
  );

  const DefaultWindowsWindowPlatformAdapter();

  @override
  Future<({bool nativeApplied, bool restoredFromSaved})>
      getStartupPlacementStatus() async {
    if (kIsWeb || !Platform.isWindows) {
      return (nativeApplied: false, restoredFromSaved: false);
    }
    try {
      final result = await _nativeChannel.invokeMethod<dynamic>(
        'getStartupPlacementStatus',
      );
      if (result is Map) {
        return (
          nativeApplied: result['nativeApplied'] == true,
          restoredFromSaved: result['restoredFromSaved'] == true,
        );
      }
    } catch (_) {}
    return (nativeApplied: false, restoredFromSaved: false);
  }

  @override
  Future<List<Rect>> getDisplayWorkAreas() async {
    if (kIsWeb || !Platform.isWindows) return const <Rect>[];
    try {
      final result = await _nativeChannel.invokeMethod<dynamic>(
        'getDisplayWorkAreas',
      );
      if (result is List) {
        final areas = <Rect>[];
        for (final entry in result) {
          if (entry is! Map) continue;
          final left = (entry['left'] as num?)?.toDouble();
          final top = (entry['top'] as num?)?.toDouble();
          final width = (entry['width'] as num?)?.toDouble();
          final height = (entry['height'] as num?)?.toDouble();
          if (left == null ||
              top == null ||
              width == null ||
              height == null ||
              width <= 0 ||
              height <= 0) {
            continue;
          }
          final rect = Rect.fromLTWH(left, top, width, height);
          if (entry['primary'] == true) {
            areas.insert(0, rect);
          } else {
            areas.add(rect);
          }
        }
        return areas;
      }
    } catch (_) {}
    return const <Rect>[];
  }

  @override
  Future<Rect?> getBounds() async {
    try {
      return await windowManager.getBounds();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setBounds(Rect bounds) async {
    await windowManager.setBounds(bounds);
  }

  @override
  Future<void> center() async {
    await windowManager.center();
  }

  @override
  Future<bool> isMaximized() async {
    try {
      return await windowManager.isMaximized();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> maximize() async {
    await windowManager.maximize();
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
  Future<bool> isFullScreen() async {
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> saveNativePlacement() async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await _nativeChannel.invokeMethod<void>('savePlacement');
    } catch (_) {}
  }
}

/// Restores, centers, and persists the Windows desktop window position & size.
class WindowsWindowBoundsController {
  static WindowsWindowBoundsController? _shared;

  static WindowsWindowBoundsController? get shared => _shared;

  final StorageService storage;
  final WindowsWindowPlatformAdapter adapter;

  WindowsWindowBounds? _lastNormalBounds;
  Timer? _debounceTimer;
  bool _restoring = false;
  bool _disposed = false;

  WindowsWindowBoundsController({
    required this.storage,
    WindowsWindowPlatformAdapter? adapter,
  }) : adapter = adapter ?? const DefaultWindowsWindowPlatformAdapter();

  static WindowsWindowBoundsController installShared(
    StorageService storage, {
    WindowsWindowPlatformAdapter? adapter,
  }) {
    _shared?.dispose();
    final instance = WindowsWindowBoundsController(
      storage: storage,
      adapter: adapter,
    );
    _shared = instance;
    return instance;
  }

  @visibleForTesting
  WindowsWindowBounds? get lastNormalBounds => _lastNormalBounds;

  /// Restores the saved Windows window bounds on startup, or centers on the
  /// primary monitor work area on first launch.
  Future<void> restoreOnStartup() async {
    if (_disposed) return;
    _restoring = true;
    try {
      final saved = storage.windowsWindowBounds;
      _lastNormalBounds = saved;
      final status = await adapter.getStartupPlacementStatus();

      // If the native Win32 runner already applied the exact saved placement
      // before first paint (or centered on first launch when no Dart bounds
      // exist either), avoid issuing a redundant Dart setBounds that could
      // introduce mixed-DPI jitter.
      if (status.nativeApplied && (status.restoredFromSaved || saved == null)) {
        if (_lastNormalBounds == null) {
          final maximized = await adapter.isMaximized();
          final minimized = await adapter.isMinimized();
          final fullscreen = await adapter.isFullScreen();
          if (!maximized && !minimized && !fullscreen) {
            final current = await adapter.getBounds();
            if (current != null) {
              final candidate = WindowsWindowBounds(
                left: current.left,
                top: current.top,
                width: current.width,
                height: current.height,
                maximized: false,
              );
              if (candidate.isValid) {
                _lastNormalBounds = candidate;
              }
            }
          }
        }
        return;
      }

      final workAreas = await adapter.getDisplayWorkAreas();
      if (saved == null) {
        if (workAreas.isNotEmpty) {
          final target = WindowsWindowBounds.resolveForWorkAreas(
            saved: null,
            workAreas: workAreas,
          );
          await adapter.setBounds(target.rect);
          _lastNormalBounds = target;
        } else {
          await adapter.center();
        }
        return;
      }

      final target = workAreas.isNotEmpty
          ? WindowsWindowBounds.resolveForWorkAreas(
              saved: saved,
              workAreas: workAreas,
            )
          : saved;
      _lastNormalBounds = target.copyWith(maximized: false);
      await adapter.setBounds(target.rect);
      if (target.maximized) {
        await adapter.maximize();
      }
      await adapter.saveNativePlacement();
    } catch (e) {
      debugPrint('WindowsWindowBoundsController.restoreOnStartup warning: $e');
    } finally {
      _restoring = false;
    }
  }

  /// Debounced capture called from `onWindowMoved` / `onWindowResized`.
  void scheduleCapture({
    Duration debounce = const Duration(milliseconds: 300),
  }) {
    if (_disposed || _restoring) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      if (!_disposed) {
        unawaited(captureAndPersist());
      }
    });
  }

  /// Captures the current window bounds & maximized state and persists them.
  ///
  /// Ignores minimized and player-fullscreen states so transient states never
  /// overwrite the user's normal desktop window bounds.
  Future<void> captureAndPersist({bool immediate = false}) async {
    if (_disposed || _restoring) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    try {
      if (await adapter.isMinimized() || await adapter.isFullScreen()) {
        return;
      }
      final maximized = await adapter.isMaximized();
      WindowsWindowBounds? toSave;
      if (maximized) {
        final base = _lastNormalBounds ?? storage.windowsWindowBounds;
        if (base != null && base.isValid) {
          toSave = base.copyWith(maximized: true);
        }
      } else {
        final rect = await adapter.getBounds();
        if (rect != null) {
          final candidate = WindowsWindowBounds(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            maximized: false,
          );
          if (candidate.isValid) {
            _lastNormalBounds = candidate;
            toSave = candidate;
          }
        }
      }
      if (toSave != null) {
        await storage.setWindowsWindowBounds(toSave);
      }
      if (immediate) {
        await adapter.saveNativePlacement();
      }
    } catch (e) {
      debugPrint('WindowsWindowBoundsController.captureAndPersist warning: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (identical(_shared, this)) {
      _shared = null;
    }
  }
}

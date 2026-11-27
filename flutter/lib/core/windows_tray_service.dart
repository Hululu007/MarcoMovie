import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native Windows system tray bridge (`marco_movie/windows_tray`).
///
/// Communicates with the Win32 `Shell_NotifyIconW` implementation hosted inside
/// `windows/runner/flutter_window.cpp`. On non-Windows platforms or headless
/// test runners without a registered handler, all methods degrade cleanly.
class WindowsTrayService {
  WindowsTrayService._();

  static const MethodChannel _channel = MethodChannel(
    'marco_movie/windows_tray',
  );

  /// Incremented whenever the window is hidden to the system tray so active
  /// playback routes (e.g. [PlayerScreen]) can pause audio immediately.
  static final ValueNotifier<int> hideToTrayRevision = ValueNotifier<int>(0);

  static final List<Future<void> Function()> _beforeExitHooks =
      <Future<void> Function()>[];

  static VoidCallback? _onRestore;
  static VoidCallback? _onQuit;
  static bool _handlerRegistered = false;
  static bool _inTray = false;
  static bool _nativeDestroyStarted = false;
  static int _exitSessionGen = 0;

  static bool get isInTray => _inTray;

  /// True once native window destruction has begun (or a bounded exit budget
  /// has transitioned into teardown). Late/timed-out async callbacks MUST check
  /// this flag before touching players, window handles, or Flutter channels.
  static bool get isNativeDestroyStarted => _nativeDestroyStarted;

  static int get exitSessionGen => _exitSessionGen;

  static void markNativeWindowDestroying() {
    _nativeDestroyStarted = true;
    _exitSessionGen++;
  }

  static void registerBeforeExitHook(Future<void> Function() hook) {
    if (!_beforeExitHooks.contains(hook)) {
      _beforeExitHooks.add(hook);
    }
  }

  static void unregisterBeforeExitHook(Future<void> Function() hook) {
    _beforeExitHooks.remove(hook);
  }

  /// Runs registered pre-exit hooks (e.g. saving active player watch progress
  /// and disposing MPV/MDK cleanly before native window teardown), bounded by
  /// [timeout].
  static Future<void> runBeforeExitHooks({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_beforeExitHooks.isEmpty) return;
    final snapshot = List<Future<void> Function()>.of(_beforeExitHooks);
    try {
      await Future.wait(
        snapshot.map((hook) async {
          try {
            await hook();
          } catch (e) {
            debugPrint('WindowsTrayService: beforeExitHook skipped: $e');
          }
        }),
      ).timeout(timeout);
    } catch (e) {
      debugPrint('WindowsTrayService: beforeExitHooks timed out: $e');
    }
  }

  /// Requests the native Windows runner to destroy the top-level window and
  /// `FlutterViewController` in explicit order on the UI thread before
  /// `CoUninitialize()`. Returns `true` if handled by the native runner.
  static Future<bool> destroyWindow() async {
    _inTray = false;
    if (kIsWeb) return false;
    if (!Platform.isWindows && defaultTargetPlatform != TargetPlatform.windows) {
      return false;
    }
    markNativeWindowDestroying();
    try {
      final result = await _channel.invokeMethod<bool>('destroyWindow');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static void attach({
    required VoidCallback onRestore,
    required VoidCallback onQuit,
  }) {
    _onRestore = onRestore;
    _onQuit = onQuit;
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'restore':
          _inTray = false;
          _onRestore?.call();
          break;
        case 'quit':
          _inTray = false;
          _onQuit?.call();
          break;
      }
      return null;
    });
  }

  static void detach() {
    _onRestore = null;
    _onQuit = null;
  }

  /// Notifies listeners (such as active players) and asks the native Windows
  /// shell to hide the main window into the bottom-right notification area.
  /// Returns `true` if native tray hide succeeded.
  static Future<bool> hideToTray({String tooltip = 'Marco Movie'}) async {
    hideToTrayRevision.value++;
    if (kIsWeb) return false;
    if (!Platform.isWindows && defaultTargetPlatform != TargetPlatform.windows) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>(
        'hideToTray',
        <String, Object?>{'tooltip': tooltip},
      );
      final ok = result == true;
      if (ok) _inTray = true;
      return ok;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> showFromTray() async {
    _inTray = false;
    try {
      await _channel.invokeMethod<void>('showFromTray');
    } catch (_) {}
  }

  static Future<void> removeTray() async {
    _inTray = false;
    try {
      await _channel.invokeMethod<void>('removeTray');
    } catch (_) {}
  }

  @visibleForTesting
  static void resetForTesting() {
    _inTray = false;
    _nativeDestroyStarted = false;
    _exitSessionGen = 0;
    _onRestore = null;
    _onQuit = null;
    _beforeExitHooks.clear();
  }
}

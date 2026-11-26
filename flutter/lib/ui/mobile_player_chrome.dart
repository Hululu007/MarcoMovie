import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/ohos_runtime.dart';

/// Owns the mobile system UI changes made by one player route.
class MobilePlayerChrome {
  static const MethodChannel iosSystemChromeChannel = MethodChannel(
    'marco_movie/system_chrome',
  );

  static const List<Duration> _orientationRetryDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(milliseconds: 1000),
    Duration(milliseconds: 2000),
    Duration(milliseconds: 4000),
  ];

  int _request = 0;
  int _immersiveRequest = 0;
  bool _closed = false;
  bool? _lastImmersive;
  Future<void>? _closing;
  ValueChanged<String>? _physicalOrientationListener;
  bool _monitoringOrientation = false;
  bool _hasUnrevokedNativeOrientationIntent = false;
  bool _orientationMonitoringDesired = false;
  bool _orientationMonitoringInFlight = false;
  bool _orientationRetryPaused = false;
  bool _hasOrientationHandler = false;
  int _orientationMonitoringEpoch = 0;
  int _orientationRetryAttempt = 0;
  Timer? _orientationRetryTimer;
  Future<void>? _orientationInFlightFuture;

  /// Latest immersive bar visibility applied by this player route.
  bool get isImmersive => _lastImmersive ?? false;

  Future<void> _notifyIosImmersive(bool immersive) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await iosSystemChromeChannel.invokeMethod<void>(
        'setImmersive',
        immersive,
      );
    } on MissingPluginException {
      // Host unit/widget tests may not register the native Runner channel.
    } catch (_) {}
  }

  Future<void> _notifyIosOrientation(String mode) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await iosSystemChromeChannel.invokeMethod<void>(
        'requestOrientation',
        mode,
      );
    } on MissingPluginException {
      // Host unit/widget tests may not register the native Runner channel.
    } catch (_) {}
  }

  Future<void> _invokeNativeOrientationMonitoring(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await iosSystemChromeChannel.invokeMethod<void>(
        'setOrientationMonitoring',
        enabled,
      );
    } on MissingPluginException {
      // Host unit/widget tests may not register the native Runner channel.
    } catch (_) {}
  }

  void _attachOrientationHandler() {
    if (_hasOrientationHandler) return;
    _hasOrientationHandler = true;
    iosSystemChromeChannel.setMethodCallHandler((call) async {
      if (call.method == 'physicalOrientationChanged' &&
          call.arguments is String) {
        _physicalOrientationListener?.call(call.arguments as String);
      }
    });
  }

  void _detachOrientationHandler() {
    if (!_hasOrientationHandler) return;
    _hasOrientationHandler = false;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      iosSystemChromeChannel.setMethodCallHandler(null);
    }
  }

  void _cancelOrientationRetryTimer() {
    _orientationRetryTimer?.cancel();
    _orientationRetryTimer = null;
  }

  void _scheduleOrientationRetry() {
    if (_closed ||
        _orientationRetryPaused ||
        !_orientationMonitoringDesired ||
        _monitoringOrientation ||
        _orientationRetryTimer != null) {
      return;
    }
    // Exponential backoff capped at the low steady-state 4s interval so an
    // arbitrarily long silent host-attachment gap still recovers once the new
    // controller mounts, without high-frequency polling and with immediate
    // cancellation on attach, background pause, or route exit.
    final index = _orientationRetryAttempt < _orientationRetryDelays.length
        ? _orientationRetryAttempt
        : _orientationRetryDelays.length - 1;
    if (_orientationRetryAttempt < _orientationRetryDelays.length) {
      _orientationRetryAttempt++;
    }
    final delay = _orientationRetryDelays[index];
    _orientationRetryTimer = Timer(delay, () {
      _orientationRetryTimer = null;
      if (_closed ||
          _orientationRetryPaused ||
          !_orientationMonitoringDesired ||
          _monitoringOrientation ||
          _orientationMonitoringInFlight) {
        return;
      }
      unawaited(_attemptEnableOrientationMonitoring());
    });
  }

  Future<void> _attemptEnableOrientationMonitoring() {
    final token = ++_orientationMonitoringEpoch;
    _orientationMonitoringInFlight = true;
    final future = _runEnableOrientationMonitoring(token);
    _orientationInFlightFuture = future;
    return future;
  }

  Future<void> _runEnableOrientationMonitoring(int token) async {
    try {
      await iosSystemChromeChannel.invokeMethod<void>(
        'setOrientationMonitoring',
        true,
      );
      if (_closed || !_orientationMonitoringDesired) {
        // Native accepted enable right after this route disabled or closed;
        // release native monitoring immediately so a dead route never leaks it.
        _monitoringOrientation = false;
        _hasUnrevokedNativeOrientationIntent = false;
        unawaited(_invokeNativeOrientationMonitoring(false));
        return;
      }
      if (token != _orientationMonitoringEpoch) {
        return;
      }
      _monitoringOrientation = true;
      _hasUnrevokedNativeOrientationIntent = true;
      _orientationRetryAttempt = 0;
      _cancelOrientationRetryTimer();
    } on MissingPluginException {
      // Host tests may not register the native Runner channel.
      if (token == _orientationMonitoringEpoch) {
        _monitoringOrientation = false;
        _hasUnrevokedNativeOrientationIntent = false;
        _orientationMonitoringDesired = false;
        _cancelOrientationRetryTimer();
      }
    } on PlatformException catch (error) {
      if (token == _orientationMonitoringEpoch) {
        // Keep _hasUnrevokedNativeOrientationIntent intact when a prior host
        // already succeeded so route exit still revokes native desired intent.
        _monitoringOrientation = false;
        if (!_closed &&
            _orientationMonitoringDesired &&
            error.code == 'host_unavailable') {
          _scheduleOrientationRetry();
        }
      }
    } catch (_) {
      if (token == _orientationMonitoringEpoch) {
        _monitoringOrientation = false;
      }
    } finally {
      if (token == _orientationMonitoringEpoch) {
        _orientationMonitoringInFlight = false;
        _orientationInFlightFuture = null;
      }
    }
  }

  /// Retries physical orientation monitoring when this route still desires it
  /// after an earlier recoverable `host_unavailable` gap, or reconciles the
  /// registration against the engine's current host controller after a
  /// lifecycle interruption ([forceHostReconcile] = `true`) when controller A
  /// may have been released and replaced by controller B.
  Future<void> retryOrientationMonitoringIfNeeded({
    bool resetBackoff = false,
    bool forceHostReconcile = false,
  }) async {
    _orientationRetryPaused = false;
    if (_closed ||
        !_orientationMonitoringDesired ||
        _orientationMonitoringInFlight) {
      return;
    }
    if (!forceHostReconcile && _monitoringOrientation) {
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    _cancelOrientationRetryTimer();
    if (resetBackoff) {
      _orientationRetryAttempt = 0;
    }
    _attachOrientationHandler();
    await _attemptEnableOrientationMonitoring();
  }

  /// Suspends any pending host-recovery retry timer while the app is inactive
  /// or backgrounded, preserving the route's intent to resume monitoring once
  /// foregrounded again.
  void pauseOrientationMonitoringRetry() {
    _orientationRetryPaused = true;
    _cancelOrientationRetryTimer();
  }

  /// Starts or stops listening for physical iOS device rotations so the player
  /// can smoothly auto-rotate between portrait companion mode and landscape
  /// fullscreen whenever the screen is not locked.
  Future<void> setOrientationMonitoring(
    bool enabled, {
    ValueChanged<String>? onPhysicalOrientation,
  }) async {
    if (_closed && enabled) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      _physicalOrientationListener = null;
      _orientationMonitoringDesired = false;
      _monitoringOrientation = false;
      _hasUnrevokedNativeOrientationIntent = false;
      _orientationRetryPaused = false;
      _cancelOrientationRetryTimer();
      return;
    }
    if (!enabled) {
      _cancelOrientationRetryTimer();
      _orientationMonitoringDesired = false;
      _orientationRetryPaused = false;
      _orientationRetryAttempt = 0;
      _physicalOrientationListener = null;
      ++_orientationMonitoringEpoch;
      _orientationMonitoringInFlight = false;
      _orientationInFlightFuture = null;
      _detachOrientationHandler();
      final shouldDisableOrientation =
          _monitoringOrientation || _hasUnrevokedNativeOrientationIntent;
      _monitoringOrientation = false;
      _hasUnrevokedNativeOrientationIntent = false;
      if (!shouldDisableOrientation) return;
      await _invokeNativeOrientationMonitoring(false);
      return;
    }

    _physicalOrientationListener = onPhysicalOrientation;
    _orientationMonitoringDesired = true;
    _orientationRetryPaused = false;
    _attachOrientationHandler();
    _cancelOrientationRetryTimer();
    _orientationRetryAttempt = 0;
    if (_monitoringOrientation) return;
    if (_orientationMonitoringInFlight) {
      await (_orientationInFlightFuture ?? Future<void>.value());
      return;
    }
    await _attemptEnableOrientationMonitoring();
  }

  Future<bool> setImmersive(bool immersive, {bool force = false}) async {
    if (_closed) return false;
    if (OhosRuntime.isSmartScreenHardware) return !_closed;
    if (!force && _lastImmersive == immersive) return true;
    final rev = ++_immersiveRequest;
    _lastImmersive = immersive;
    await Future.wait<void>([
      SystemChrome.setEnabledSystemUIMode(
        immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
      _notifyIosImmersive(immersive),
    ]);
    return !_closed && rev == _immersiveRequest;
  }

  /// Requests only a preferred orientation without modifying fullscreen
  /// immersive system-bar visibility. Used on iOS / iPadOS where multitasking
  /// window modes may ignore orientation requests while fullscreen playback
  /// still independently owns status-bar and Home-indicator hiding.
  Future<bool> setOrientation(bool landscape) async {
    if (_closed) return false;
    final request = ++_request;
    if (OhosRuntime.isSmartScreenHardware) {
      return !_closed && request == _request;
    }
    if (OhosRuntime.isOhos) {
      await OhosRuntime.setPreferredOrientation(
        landscape ? 'landscape' : 'portrait',
      );
    }
    await Future.wait<void>([
      SystemChrome.setPreferredOrientations(
        landscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      ),
      _notifyIosOrientation(landscape ? 'landscape' : 'portrait'),
    ]);
    return !_closed && request == _request;
  }

  Future<bool> setLandscape(bool landscape, {bool syncImmersive = true}) async {
    if (!syncImmersive) {
      return setOrientation(landscape);
    }
    if (_closed) return false;
    final request = ++_request;
    ++_immersiveRequest;
    if (OhosRuntime.isSmartScreenHardware) {
      return !_closed && request == _request;
    }
    if (OhosRuntime.isOhos) {
      await OhosRuntime.setPreferredOrientation(
        landscape ? 'landscape' : 'portrait',
      );
    }
    await Future.wait<void>([
      SystemChrome.setPreferredOrientations(
        landscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      ),
      _notifyIosOrientation(landscape ? 'landscape' : 'portrait'),
    ]);
    // A route exit or newer request must win over a delayed platform reply.
    if (_closed || request != _request) return false;
    _lastImmersive = landscape;
    await Future.wait<void>([
      SystemChrome.setEnabledSystemUIMode(
        landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
      _notifyIosImmersive(landscape),
    ]);
    return !_closed && request == _request;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    ++_request;
    ++_immersiveRequest;
    _lastImmersive = false;
    _cancelOrientationRetryTimer();
    _orientationMonitoringDesired = false;
    ++_orientationMonitoringEpoch;
    _orientationMonitoringInFlight = false;
    _orientationInFlightFuture = null;
    _physicalOrientationListener = null;
    _detachOrientationHandler();
    final shouldDisableOrientation =
        _monitoringOrientation || _hasUnrevokedNativeOrientationIntent;
    _monitoringOrientation = false;
    _hasUnrevokedNativeOrientationIntent = false;
    if (OhosRuntime.isSmartScreenHardware) {
      return _closing = Future<void>.value();
    }
    // Issue both restores before awaiting; pending entry continuations are
    // invalidated above and cannot hide the system bars after this restoration.
    return _closing = Future.wait<void>([
      if (shouldDisableOrientation) _invokeNativeOrientationMonitoring(false),
      if (OhosRuntime.isOhos) OhosRuntime.setPreferredOrientation('auto'),
      SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      _notifyIosOrientation('auto'),
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
      _notifyIosImmersive(false),
    ]).then((_) {});
  }
}

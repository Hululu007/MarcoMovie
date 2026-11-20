import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/ohos_runtime.dart';

/// Owns the mobile system UI changes made by one player route.
class MobilePlayerChrome {
  static const MethodChannel iosSystemChromeChannel = MethodChannel(
    'marco_movie/system_chrome',
  );

  int _request = 0;
  int _immersiveRequest = 0;
  bool _closed = false;
  bool? _lastImmersive;
  Future<void>? _closing;

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

  Future<bool> setLandscape(bool landscape) async {
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
    await SystemChrome.setPreferredOrientations(
      landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
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
    if (OhosRuntime.isSmartScreenHardware) {
      return _closing = Future<void>.value();
    }
    // Issue both restores before awaiting; pending entry continuations are
    // invalidated above and cannot hide the system bars after this restoration.
    return _closing = Future.wait<void>([
      if (OhosRuntime.isOhos) OhosRuntime.setPreferredOrientation('auto'),
      SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
      _notifyIosImmersive(false),
    ]).then((_) {});
  }
}

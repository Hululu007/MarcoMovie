import 'package:flutter/services.dart';
import '../core/ohos_runtime.dart';

/// Owns the mobile system UI changes made by one player route.
class MobilePlayerChrome {
  int _request = 0;
  bool _closed = false;
  Future<void>? _closing;

  Future<bool> setLandscape(bool landscape) async {
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
    await SystemChrome.setEnabledSystemUIMode(
      landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    return !_closed && request == _request;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    ++_request;
    if (OhosRuntime.isSmartScreenHardware) {
      return _closing = Future<void>.value();
    }
    // Issue both restores before awaiting; pending entry continuations are
    // invalidated above and cannot hide the system bars after this restoration.
    return _closing = Future.wait<void>([
      if (OhosRuntime.isOhos) OhosRuntime.setPreferredOrientation('auto'),
      SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    ]).then((_) {});
  }
}

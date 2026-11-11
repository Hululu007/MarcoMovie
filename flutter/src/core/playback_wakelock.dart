import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Zero-dependency cross-platform screen/system display wakelock during video
/// playback. Wired natively by `prepare_platform.py` on iOS, macOS, and Windows.
class PlaybackWakelock {
  static const MethodChannel _channel = MethodChannel('marco_movie/wakelock');
  static bool _enabled = false;

  static Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // Headless or unsupported runner; ignore cleanly.
    } on PlatformException {
      // Ignore platform errors to never disrupt playback.
    } catch (_) {}
  }
}

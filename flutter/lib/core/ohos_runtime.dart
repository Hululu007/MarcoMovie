// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'secure_credential_store.dart';

/// Device form-factor reported by HarmonyOS NEXT `@kit.BasicServicesKit`.
class OhosDeviceProfile {
  final String deviceType; // 'phone' | 'tablet' | '2in1' | 'tv'
  final String osFullName;
  final int sdkApiVersion;

  const OhosDeviceProfile({
    this.deviceType = 'phone',
    this.osFullName = '',
    this.sdkApiVersion = 12,
  });

  bool get isTv => deviceType.toLowerCase() == 'tv';
  bool get isTabletOr2In1 =>
      deviceType.toLowerCase() == 'tablet' ||
      deviceType.toLowerCase() == '2in1';
}

/// First-party bridge to `OhosSystemPlugin.ets` on HarmonyOS NEXT (`ohos`).
class OhosRuntime {
  static const MethodChannel systemChannel =
      MethodChannel('com.pilipala.marcomovie/ohos_system');

  static bool? debugIsOhosOverride;

  static String? debugDeviceTypeOverride;

  static bool get hasDebugOverride => debugIsOhosOverride != null;

  static OhosDeviceProfile _profile = const OhosDeviceProfile();
  static String? _filesDir;
  static String? _cacheDir;
  static String? _tempDir;
  static bool _initialized = false;

  /// Notifies the root shell immediately when the user toggles TV mode in Settings.
  static final ValueNotifier<int> uiModeRevision = ValueNotifier<int>(0);

  static bool get isOhos =>
      !kIsWeb && (debugIsOhosOverride ?? (Platform.operatingSystem == 'ohos'));

  static OhosDeviceProfile get deviceProfile => debugDeviceTypeOverride != null
      ? OhosDeviceProfile(
          deviceType: debugDeviceTypeOverride!,
          osFullName: _profile.osFullName,
          sdkApiVersion: _profile.sdkApiVersion,
        )
      : _profile;

  static bool get isSmartScreenHardware => isOhos && deviceProfile.isTv;

  /// Resolves whether the 10-foot living-room remote UI should be active.
  /// `uiModePreference`: `'auto'` (default), `'tv'`, or `'standard'`.
  static bool shouldUseTvUi(String uiModePreference) {
    final pref = uiModePreference.trim().toLowerCase();
    if (pref == 'tv') return true;
    if (pref == 'standard') return false;
    return isSmartScreenHardware;
  }

  static String? get filesDir => _filesDir;
  static String? get cacheDir => _cacheDir;
  static String? get tempDir => _tempDir;

  @visibleForTesting
  static void resetForTesting() {
    debugIsOhosOverride = null;
    debugDeviceTypeOverride = null;
    _profile = const OhosDeviceProfile();
    _filesDir = null;
    _cacheDir = null;
    _tempDir = null;
    _initialized = false;
  }

  static Future<void> ensureInitialized() async {
    if (!isOhos || _initialized) return;
    _initialized = true;
    if (Platform.environment.containsKey('FLUTTER_TEST') &&
        debugIsOhosOverride == null) {
      return;
    }
    try {
      final rawProfile =
          await systemChannel.invokeMapMethod<String, dynamic>('getDeviceProfile');
      if (rawProfile != null) {
        _profile = OhosDeviceProfile(
          deviceType: (rawProfile['deviceType']?.toString() ?? 'phone').trim(),
          osFullName: rawProfile['osFullName']?.toString() ?? '',
          sdkApiVersion: (rawProfile['sdkApiVersion'] is num)
              ? (rawProfile['sdkApiVersion'] as num).toInt()
              : 12,
        );
      }
    } catch (e) {
      debugPrint('OhosRuntime: getDeviceProfile fallback: $e');
    }

    try {
      final dirs =
          await systemChannel.invokeMapMethod<String, dynamic>('getDirectories');
      if (dirs != null) {
        _filesDir = dirs['filesDir']?.toString();
        _cacheDir = dirs['cacheDir']?.toString();
        _tempDir = dirs['tempDir']?.toString();
      }
    } catch (e) {
      debugPrint('OhosRuntime: getDirectories fallback: $e');
    }
  }

  static Future<({String name, String path, String content})?>
      pickConfigOrBackupFile() async {
    if (!isOhos) return null;
    try {
      final result =
          await systemChannel.invokeMapMethod<String, dynamic>('pickJsonFile');
      if (result == null) return null;
      final content = result['content']?.toString();
      if (content == null) return null;
      return (
        name: result['name']?.toString() ?? 'config.json',
        path: result['path']?.toString() ?? '',
        content: content,
      );
    } catch (e) {
      debugPrint('OhosRuntime: pickJsonFile failed: $e');
      return null;
    }
  }

  static Future<String?> saveTextFile({
    required String fileName,
    required String content,
  }) async {
    if (!isOhos) return null;
    try {
      return await systemChannel.invokeMethod<String>('saveTextFile', {
        'fileName': fileName,
        'content': content,
      });
    } catch (e) {
      debugPrint('OhosRuntime: saveTextFile failed: $e');
      return null;
    }
  }

  static Future<bool> openExternalUrl(String url) async {
    if (!isOhos) return false;
    try {
      final ok = await systemChannel
          .invokeMethod<bool>('openExternalUrl', {'url': url});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setKeepScreenOn(bool enabled) async {
    if (!isOhos) return;
    try {
      await systemChannel
          .invokeMethod<void>('setKeepScreenOn', {'enabled': enabled});
    } catch (_) {}
  }

  static Future<void> setPreferredOrientation(String mode) async {
    if (!isOhos || isSmartScreenHardware) return;
    try {
      await systemChannel
          .invokeMethod<void>('setPreferredOrientation', {'mode': mode});
    } catch (_) {}
  }
}

/// Hardware-backed HarmonyOS NEXT HUKS Asset Store implementation of [SecureStorageBackend].
class OhosSecureStorageBackend implements SecureStorageBackend {
  const OhosSecureStorageBackend();

  static final Map<String, String> _testFallback = <String, String>{};

  static bool get _isFlutterTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  static void clearTestFallback() => _testFallback.clear();

  @override
  Future<String?> read(String key) async {
    try {
      return await OhosRuntime.systemChannel
          .invokeMethod<String>('secureRead', {'key': key});
    } on MissingPluginException {
      if (_isFlutterTest) return _testFallback[key];
      rethrow;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await OhosRuntime.systemChannel.invokeMethod<void>(
        'secureWrite',
        {'key': key, 'value': value},
      );
    } on MissingPluginException {
      if (_isFlutterTest) {
        _testFallback[key] = value;
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await OhosRuntime.systemChannel
          .invokeMethod<void>('secureDelete', {'key': key});
    } on MissingPluginException {
      if (_isFlutterTest) {
        _testFallback.remove(key);
        return;
      }
      rethrow;
    }
  }
}

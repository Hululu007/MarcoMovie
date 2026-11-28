// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'secure_credential_store.dart';

enum OhosDocumentPurpose {
  subscription,
  live,
  backup,
}

class OhosPickedDocument {
  final String name;
  final String path;
  final Uint8List bytes;
  final int size;

  const OhosPickedDocument({
    required this.name,
    required this.path,
    required this.bytes,
    required this.size,
  });

  String decodeUtf8({bool allowMalformed = false}) =>
      utf8.decode(bytes, allowMalformed: allowMalformed);
}

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

  static Future<({String version, String buildNumber})?>
      getPackageInfo() async {
    if (!isOhos) return null;
    try {
      final raw =
          await systemChannel.invokeMapMethod<String, dynamic>('getPackageInfo');
      if (raw == null) return null;
      final version = raw['version']?.toString().trim() ?? '';
      final buildNumber = raw['buildNumber']?.toString().trim() ?? '';
      if (version.isEmpty) return null;
      return (version: version, buildNumber: buildNumber);
    } catch (e) {
      debugPrint('OhosRuntime: getPackageInfo failed: $e');
      return null;
    }
  }

  static List<String> extensionsForDocumentPurpose(OhosDocumentPurpose purpose) {
    return switch (purpose) {
      OhosDocumentPurpose.subscription => const <String>[
          '.json',
          '.zip',
          '.txt',
          '.m3u',
          '.m3u8',
        ],
      OhosDocumentPurpose.live => const <String>[
          '.m3u',
          '.m3u8',
          '.txt',
          '.json',
        ],
      OhosDocumentPurpose.backup => const <String>['.json'],
    };
  }

  static Future<String?> scanQrCode() async {
    if (!isOhos) return null;
    try {
      final res = await systemChannel.invokeMethod<String>('scanQrCode');
      final trimmed = (res ?? '').trim();
      return trimmed.isEmpty ? null : trimmed;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<OhosPickedDocument?> pickDocumentFile({
    required OhosDocumentPurpose purpose,
    required int maxBytes,
  }) async {
    if (!isOhos) return null;
    try {
      final result = await systemChannel.invokeMapMethod<String, dynamic>(
        'pickDocumentFile',
        <String, Object?>{
          'purpose': purpose.name,
          'extensions': extensionsForDocumentPurpose(purpose),
          'maxBytes': maxBytes,
          'asBytes': true,
        },
      );
      if (result == null) return null;
      final Uint8List rawBytes;
      final rawBytesValue = result['bytes'];
      if (rawBytesValue is Uint8List) {
        rawBytes = rawBytesValue;
      } else if (rawBytesValue is List) {
        rawBytes = Uint8List.fromList(
          rawBytesValue.map((e) => (e as num).toInt()).toList(growable: false),
        );
      } else if (result['content'] is String) {
        rawBytes = Uint8List.fromList(utf8.encode(result['content'] as String));
      } else {
        throw const FormatException('所选文件读取失败：缺少文件内容');
      }
      if (rawBytes.length > maxBytes) {
        final limitMb = (maxBytes / (1024 * 1024)).round();
        throw FormatException('所选文件超过 $limitMb MB 限制');
      }
      final name = (result['name']?.toString() ?? '').trim();
      final fallbackName = switch (purpose) {
        OhosDocumentPurpose.backup => 'backup.json',
        OhosDocumentPurpose.live => 'playlist.m3u',
        OhosDocumentPurpose.subscription => 'config.json',
      };
      return OhosPickedDocument(
        name: name.isNotEmpty ? name : fallbackName,
        path: result['path']?.toString() ?? '',
        bytes: rawBytes,
        size: rawBytes.length,
      );
    } on PlatformException catch (e) {
      final rawMsg = (e.message ?? '').trim();
      if (rawMsg.startsWith('FILE_TOO_LARGE:')) {
        throw FormatException(rawMsg.substring('FILE_TOO_LARGE:'.length));
      }
      throw FormatException(rawMsg.isNotEmpty ? rawMsg : '读取本地文件失败，请重试');
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
    int? maxBytes,
  }) async {
    if (!isOhos) return null;
    if (maxBytes != null) {
      final encoded = utf8.encode(content);
      if (encoded.length > maxBytes) {
        final rawMb = (maxBytes / (1024 * 1024)).round();
        final limitMb = rawMb < 1 ? 1 : rawMb;
        throw FormatException('导出文件超过 $limitMb MB 限制');
      }
    }
    try {
      return await systemChannel.invokeMethod<String>('saveTextFile', {
        'fileName': fileName,
        'content': content,
        if (maxBytes != null) 'maxBytes': maxBytes,
      });
    } on PlatformException catch (e) {
      final msg = (e.message ?? '').trim();
      if (msg.startsWith('FILE_TOO_LARGE:')) {
        throw FormatException(msg.substring('FILE_TOO_LARGE:'.length));
      }
      throw FormatException(msg.isNotEmpty ? msg : '保存本地文件失败，请重试');
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

  static FormatException _formatPlatformError(
    String action,
    PlatformException error,
  ) {
    final msg = (error.message ?? '').trim();
    if (msg.isNotEmpty) {
      return FormatException(msg);
    }
    final code = error.code.trim();
    return FormatException(
      code.isNotEmpty ? '系统安全存储$action失败 ($code)' : '系统安全存储$action失败，请稍后重试',
    );
  }

  @override
  Future<String?> read(String key) async {
    try {
      return await OhosRuntime.systemChannel
          .invokeMethod<String>('secureRead', {'key': key});
    } on MissingPluginException {
      if (_isFlutterTest) return _testFallback[key];
      rethrow;
    } on PlatformException catch (e) {
      throw _formatPlatformError('读取', e);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final ok = await OhosRuntime.systemChannel.invokeMethod<bool>(
        'secureWrite',
        {'key': key, 'value': value},
      );
      if (ok == false) {
        throw const FormatException('系统安全存储写入失败，请解锁设备后重试');
      }
    } on MissingPluginException {
      if (_isFlutterTest) {
        _testFallback[key] = value;
        return;
      }
      rethrow;
    } on PlatformException catch (e) {
      throw _formatPlatformError('写入', e);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      final ok = await OhosRuntime.systemChannel
          .invokeMethod<bool>('secureDelete', {'key': key});
      if (ok == false) {
        throw const FormatException('系统安全存储删除失败，请稍后重试');
      }
    } on MissingPluginException {
      if (_isFlutterTest) {
        _testFallback.remove(key);
        return;
      }
      rethrow;
    } on PlatformException catch (e) {
      throw _formatPlatformError('删除', e);
    }
  }
}

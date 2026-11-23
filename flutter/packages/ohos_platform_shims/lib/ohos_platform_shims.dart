library ohos_platform_shims;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

const String kOhosSystemChannelName = 'com.pilipala.marcomovie/ohos_system';
const String kOhosAvPlayerChannelName = 'com.pilipala.marcomovie/ohos_avplayer';
const String kOhosAvPlayerEventChannelPrefix =
    'com.pilipala.marcomovie/ohos_avplayer/events/';

String ohosAvPlayerEventChannelName(int playerId) =>
    '$kOhosAvPlayerEventChannelPrefix$playerId';

bool get isOhosRuntime => !kIsWeb && Platform.operatingSystem == 'ohos';

class OhosDeviceProfile {
  const OhosDeviceProfile({
    required this.deviceType,
    required this.osFullName,
    required this.sdkApiVersion,
  });

  factory OhosDeviceProfile.fromMap(Map<Object?, Object?> raw) {
    return OhosDeviceProfile(
      deviceType: (raw['deviceType']?.toString() ?? 'phone').toLowerCase(),
      osFullName: raw['osFullName']?.toString() ?? '',
      sdkApiVersion: (raw['sdkApiVersion'] as num?)?.toInt() ?? 12,
    );
  }

  final String deviceType;
  final String osFullName;
  final int sdkApiVersion;

  bool get isTv => deviceType == 'tv';
  bool get isTablet => deviceType == 'tablet';
  bool get isDesktop2In1 => deviceType == '2in1';
}

class OhosDirectories {
  const OhosDirectories({
    required this.filesDir,
    required this.cacheDir,
    required this.tempDir,
  });

  factory OhosDirectories.fromMap(Map<Object?, Object?> raw) {
    return OhosDirectories(
      filesDir: raw['filesDir']?.toString() ?? '',
      cacheDir: raw['cacheDir']?.toString() ?? '',
      tempDir: raw['tempDir']?.toString() ?? '',
    );
  }

  final String filesDir;
  final String cacheDir;
  final String tempDir;
}

class OhosPackageMetadata {
  const OhosPackageMetadata({
    required this.appName,
    required this.packageName,
    required this.version,
    required this.buildNumber,
  });

  factory OhosPackageMetadata.fromMap(Map<Object?, Object?> raw) {
    return OhosPackageMetadata(
      appName: raw['appName']?.toString() ?? 'Marco Movie',
      packageName: raw['packageName']?.toString() ?? 'com.pilipala.marcomovie',
      version: raw['version']?.toString() ?? '0.1.0',
      buildNumber: raw['buildNumber']?.toString() ?? '1000001',
    );
  }

  final String appName;
  final String packageName;
  final String version;
  final String buildNumber;
}

class OhosPickedTextFile {
  const OhosPickedTextFile({
    required this.name,
    required this.path,
    required this.content,
  });

  factory OhosPickedTextFile.fromMap(Map<Object?, Object?> raw) {
    return OhosPickedTextFile(
      name: raw['name']?.toString() ?? '',
      path: raw['path']?.toString() ?? '',
      content: raw['content']?.toString() ?? '',
    );
  }

  final String name;
  final String path;
  final String content;
}

class OhosSystemBridge {
  const OhosSystemBridge({
    MethodChannel channel = const MethodChannel(kOhosSystemChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<OhosDeviceProfile> getDeviceProfile() async {
    final raw =
        await _channel.invokeMapMethod<Object?, Object?>('getDeviceProfile');
    return OhosDeviceProfile.fromMap(raw ?? const <Object?, Object?>{});
  }

  Future<OhosDirectories> getDirectories() async {
    final raw =
        await _channel.invokeMapMethod<Object?, Object?>('getDirectories');
    return OhosDirectories.fromMap(raw ?? const <Object?, Object?>{});
  }

  Future<OhosPackageMetadata> getPackageInfo() async {
    final raw =
        await _channel.invokeMapMethod<Object?, Object?>('getPackageInfo');
    return OhosPackageMetadata.fromMap(raw ?? const <Object?, Object?>{});
  }

  Future<Map<String, Object>> prefsGetAll() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('prefsGetAll');
    if (raw == null) return <String, Object>{};
    final out = <String, Object>{};
    raw.forEach((key, value) {
      if (key != null && value != null) {
        out[key.toString()] = value;
      }
    });
    return out;
  }

  Future<bool> prefsSet({
    required String key,
    required String type,
    required Object? value,
  }) async {
    final ok = await _channel.invokeMethod<bool>('prefsSet', <String, Object?>{
      'key': key,
      'type': type,
      'value': value,
    });
    return ok ?? false;
  }

  Future<bool> prefsRemove(String key) async {
    final ok = await _channel.invokeMethod<bool>(
      'prefsRemove',
      <String, Object?>{'key': key},
    );
    return ok ?? false;
  }

  Future<bool> prefsClear() async {
    final ok = await _channel.invokeMethod<bool>('prefsClear');
    return ok ?? false;
  }

  Future<String?> secureRead(String key) {
    return _channel.invokeMethod<String>(
      'secureRead',
      <String, Object?>{'key': key},
    );
  }

  Future<bool> secureWrite(String key, String? value) async {
    final ok = await _channel.invokeMethod<bool>(
      'secureWrite',
      <String, Object?>{'key': key, 'value': value},
    );
    return ok ?? false;
  }

  Future<bool> secureDelete(String key) async {
    final ok = await _channel.invokeMethod<bool>(
      'secureDelete',
      <String, Object?>{'key': key},
    );
    return ok ?? false;
  }

  Future<OhosPickedTextFile?> pickJsonFile() async {
    final raw =
        await _channel.invokeMapMethod<Object?, Object?>('pickJsonFile');
    if (raw == null) return null;
    return OhosPickedTextFile.fromMap(raw);
  }

  Future<Map<Object?, Object?>?> pickDocumentFile({
    String purpose = 'subscription',
    List<String> extensions = const <String>[],
    int maxBytes = 16 * 1024 * 1024,
    bool asBytes = true,
  }) {
    return _channel.invokeMapMethod<Object?, Object?>(
      'pickDocumentFile',
      <String, Object?>{
        'purpose': purpose,
        'extensions': extensions,
        'maxBytes': maxBytes,
        'asBytes': asBytes,
      },
    );
  }

  Future<String?> saveTextFile({
    required String fileName,
    required String content,
  }) {
    return _channel.invokeMethod<String>(
      'saveTextFile',
      <String, Object?>{'fileName': fileName, 'content': content},
    );
  }

  Future<bool> openExternalUrl(String url) async {
    final ok = await _channel.invokeMethod<bool>(
      'openExternalUrl',
      <String, Object?>{'url': url},
    );
    return ok ?? false;
  }

  Future<bool> setKeepScreenOn(bool enabled) async {
    final ok = await _channel.invokeMethod<bool>(
      'setKeepScreenOn',
      <String, Object?>{'enabled': enabled},
    );
    return ok ?? false;
  }

  Future<bool> setPreferredOrientation(String mode) async {
    final ok = await _channel.invokeMethod<bool>(
      'setPreferredOrientation',
      <String, Object?>{'mode': mode},
    );
    return ok ?? false;
  }
}

class OhosCreatedPlayer {
  const OhosCreatedPlayer({
    required this.playerId,
    required this.textureId,
  });

  final int playerId;
  final int textureId;
}

class OhosTrackInfo {
  const OhosTrackInfo({
    required this.index,
    required this.trackType,
    required this.mimeType,
    required this.language,
    required this.bitrate,
    required this.width,
    required this.height,
    required this.title,
  });

  factory OhosTrackInfo.fromMap(Map<Object?, Object?> raw) {
    return OhosTrackInfo(
      index: (raw['index'] as num?)?.toInt() ?? 0,
      trackType: (raw['trackType'] as num?)?.toInt() ?? -1,
      mimeType: raw['mimeType']?.toString() ?? '',
      language: raw['language']?.toString() ?? '',
      bitrate: (raw['bitrate'] as num?)?.toInt() ?? 0,
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      title: raw['title']?.toString() ?? '',
    );
  }

  final int index;
  final int trackType;
  final String mimeType;
  final String language;
  final int bitrate;
  final int width;
  final int height;
  final String title;
}

class OhosAvPlayerBridge {
  const OhosAvPlayerBridge({
    MethodChannel channel = const MethodChannel(kOhosAvPlayerChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<OhosCreatedPlayer> create() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('create');
    if (raw == null) {
      throw StateError('OhosAvPlayer create returned null');
    }
    return OhosCreatedPlayer(
      playerId: (raw['playerId'] as num).toInt(),
      textureId: (raw['textureId'] as num).toInt(),
    );
  }

  Stream<Map<String, Object?>> events(int playerId) {
    return EventChannel(ohosAvPlayerEventChannelName(playerId))
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) {
      final raw = event as Map<Object?, Object?>;
      final out = <String, Object?>{};
      raw.forEach((key, value) {
        if (key != null) {
          out[key.toString()] = value;
        }
      });
      return out;
    });
  }

  Future<bool> open({
    required int playerId,
    required String url,
    Map<String, String> headers = const <String, String>{},
    int startPositionMs = 0,
    bool autoPlay = true,
  }) async {
    final ok = await _channel.invokeMethod<bool>('open', <String, Object?>{
      'playerId': playerId,
      'url': url,
      'headers': headers,
      'startPositionMs': startPositionMs,
      'autoPlay': autoPlay,
    });
    return ok ?? false;
  }

  Future<bool> play(int playerId) async {
    final ok = await _channel.invokeMethod<bool>(
      'play',
      <String, Object?>{'playerId': playerId},
    );
    return ok ?? false;
  }

  Future<bool> pause(int playerId) async {
    final ok = await _channel.invokeMethod<bool>(
      'pause',
      <String, Object?>{'playerId': playerId},
    );
    return ok ?? false;
  }

  Future<bool> stop(int playerId) async {
    final ok = await _channel.invokeMethod<bool>(
      'stop',
      <String, Object?>{'playerId': playerId},
    );
    return ok ?? false;
  }

  Future<bool> seek(int playerId, int positionMs) async {
    final ok = await _channel.invokeMethod<bool>('seek', <String, Object?>{
      'playerId': playerId,
      'positionMs': positionMs,
    });
    return ok ?? false;
  }

  Future<bool> setRate(int playerId, double rate) async {
    final ok = await _channel.invokeMethod<bool>('setRate', <String, Object?>{
      'playerId': playerId,
      'rate': rate,
    });
    return ok ?? false;
  }

  Future<bool> setVolume(int playerId, double volume) async {
    final ok = await _channel.invokeMethod<bool>('setVolume', <String, Object?>{
      'playerId': playerId,
      'volume': volume,
    });
    return ok ?? false;
  }

  Future<List<OhosTrackInfo>> getTracks(int playerId) async {
    final raw = await _channel.invokeListMethod<Object?>(
      'getTracks',
      <String, Object?>{'playerId': playerId},
    );
    if (raw == null) return const <OhosTrackInfo>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(OhosTrackInfo.fromMap)
        .toList(growable: false);
  }

  Future<bool> selectTrack(int playerId, int index) async {
    final ok = await _channel.invokeMethod<bool>(
      'selectTrack',
      <String, Object?>{'playerId': playerId, 'index': index},
    );
    return ok ?? false;
  }

  Future<bool> dispose(int playerId) async {
    final ok = await _channel.invokeMethod<bool>(
      'dispose',
      <String, Object?>{'playerId': playerId},
    );
    return ok ?? false;
  }
}

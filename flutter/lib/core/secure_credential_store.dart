import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_log.dart';

/// Abstract contract for platform-secure credential storage.
abstract class SecureCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Low-level key-value backend delegated by [DefaultSecureCredentialStore].
abstract class SecureStorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production backend powered by `flutter_secure_storage`:
/// - Windows: AES-GCM key wrapped by DPAPI (`CryptProtectData` / `CryptUnprotectData`, `useBackwardCompatibility: false`)
/// - iOS: Apple Keychain (`first_unlock`)
/// - macOS: Legacy file-based Apple Keychain (`first_unlock`, `useDataProtectionKeyChain: false` for ad-hoc signed builds)
/// - Android: EncryptedSharedPreferences / Android Keystore
class FlutterSecureStorageBackend implements SecureStorageBackend {
  final FlutterSecureStorage _storage;

  const FlutterSecureStorageBackend({
    FlutterSecureStorage storage = defaultStorage,
  }) : _storage = storage;

  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock,
      useDataProtectionKeyChain: false,
    ),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  static final Map<String, String> _unmockedTestFallback = <String, String>{};

  static bool get _isFlutterTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on MissingPluginException {
      if (_isFlutterTest) return _unmockedTestFallback[key];
      rethrow;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on MissingPluginException {
      if (_isFlutterTest) {
        _unmockedTestFallback[key] = value;
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on MissingPluginException {
      if (_isFlutterTest) {
        _unmockedTestFallback.remove(key);
        return;
      }
      rethrow;
    }
  }
}

/// In-memory implementation of [SecureCredentialStore] and [SecureStorageBackend] for tests.
class InMemorySecureCredentialStore
    implements SecureCredentialStore, SecureStorageBackend {
  final Map<String, String> _data = <String, String>{};

  InMemorySecureCredentialStore([Map<String, String>? initialData]) {
    if (initialData != null) {
      _data.addAll(initialData);
    }
  }

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @visibleForTesting
  Map<String, String> get rawData => Map<String, String>.unmodifiable(_data);
}

/// Platform-native credential store backed by [FlutterSecureStorage] (DPAPI on Windows,
/// Keychain on Apple) with safe one-way migration from legacy `secure_credentials.enc`.
class DefaultSecureCredentialStore implements SecureCredentialStore {
  static const String legacyFileName = 'secure_credentials.enc';
  static const String legacyBackupFileName = 'secure_credentials.enc.bak';
  static const String _legacyFormatPrefix = 'mm_sec_v1';

  final Directory? _dataDirectory;
  final SecureStorageBackend _backend;
  final Map<String, String?> _cache = <String, String?>{};

  bool _migrated = false;
  Future<void>? _migrationInFlight;
  bool _legacyMigrationFailed = false;
  String? _legacyBackupPath;

  DefaultSecureCredentialStore({
    Directory? dataDirectory,
    SecureStorageBackend backend = const FlutterSecureStorageBackend(),
  })  : _dataDirectory = dataDirectory,
        _backend = backend;

  @visibleForTesting
  static void clearTestBackends() {
    FlutterSecureStorageBackend._unmockedTestFallback.clear();
  }

  /// True when a legacy `secure_credentials.enc` file existed on disk, failed decryption
  /// or parsing, and was preserved as `secure_credentials.enc.bak`.
  bool get didLegacyMigrationFail => _legacyMigrationFailed;

  /// Path to the preserved `.bak` file if legacy migration failed.
  String? get legacyBackupPath => _legacyBackupPath;

  void acknowledgeLegacyMigrationFailure() {
    _legacyMigrationFailed = false;
  }

  Future<void> ensureInitialized() => _ensureMigrated();

  static Uint8List _deriveLegacyKey(Uint8List salt) {
    final host = Platform.isAndroid || Platform.isIOS
        ? 'mobile_marco_credential_key'
        : (Platform.localHostname.isNotEmpty
            ? Platform.localHostname
            : 'desktop_marco_credential_key');
    final seed = utf8.encode('marco_movie_secure_storage_seed:$host');
    final hmac = Hmac(sha256, seed);
    return Uint8List.fromList(hmac.convert(salt).bytes);
  }

  static Uint8List _legacyKeystream(Uint8List key, Uint8List iv, int length) {
    final result = Uint8List(length);
    var offset = 0;
    var counter = 0;
    while (offset < length) {
      final counterBytes = ByteData(4)..setUint32(0, counter, Endian.big);
      final blockInput = Uint8List(iv.length + 4)
        ..setRange(0, iv.length, iv)
        ..setRange(iv.length, iv.length + 4, counterBytes.buffer.asUint8List());
      final block = Hmac(sha256, key).convert(blockInput).bytes;
      final toCopy = min(block.length, length - offset);
      result.setRange(offset, offset + toCopy, block.sublist(0, toCopy));
      offset += toCopy;
      counter++;
    }
    return result;
  }

  /// Generates a legacy `mm_sec_v1:` payload exclusively for migration tests.
  @visibleForTesting
  static String encryptLegacyPayloadForTest(Map<String, String> entries) {
    final plainText = jsonEncode(entries);
    final rand = Random.secure();
    final salt = Uint8List(16);
    final iv = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      salt[i] = rand.nextInt(256);
      iv[i] = rand.nextInt(256);
    }
    final key = _deriveLegacyKey(salt);
    final plainBytes = Uint8List.fromList(utf8.encode(plainText));
    final ks = _legacyKeystream(key, iv, plainBytes.length);
    final cipher = Uint8List(plainBytes.length);
    for (var i = 0; i < plainBytes.length; i++) {
      cipher[i] = plainBytes[i] ^ ks[i];
    }
    final macInput = Uint8List(salt.length + iv.length + cipher.length)
      ..setRange(0, salt.length, salt)
      ..setRange(salt.length, salt.length + iv.length, iv)
      ..setRange(
        salt.length + iv.length,
        salt.length + iv.length + cipher.length,
        cipher,
      );
    final tag = Uint8List.fromList(Hmac(sha256, key).convert(macInput).bytes);

    String toHex(Uint8List bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$_legacyFormatPrefix:${toHex(salt)}:${toHex(iv)}:${toHex(tag)}:${toHex(cipher)}';
  }

  static Map<String, String>? _decryptLegacyEntries(Uint8List rawBytes) {
    if (rawBytes.isEmpty) return null;
    final String payload;
    try {
      payload = utf8.decode(rawBytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
    final parts = payload.trim().split(':');
    if (parts.length != 5 || parts[0] != _legacyFormatPrefix) {
      return null;
    }
    try {
      Uint8List fromHex(String hex) {
        if (hex.length.isOdd) {
          throw const FormatException('Odd hex length');
        }
        final result = Uint8List(hex.length ~/ 2);
        for (var i = 0; i < result.length; i++) {
          result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return result;
      }

      final salt = fromHex(parts[1]);
      final iv = fromHex(parts[2]);
      final tag = fromHex(parts[3]);
      final cipher = fromHex(parts[4]);
      if (salt.isEmpty || iv.isEmpty || tag.isEmpty) {
        return null;
      }

      final key = _deriveLegacyKey(salt);
      final macInput = Uint8List(salt.length + iv.length + cipher.length)
        ..setRange(0, salt.length, salt)
        ..setRange(salt.length, salt.length + iv.length, iv)
        ..setRange(
          salt.length + iv.length,
          salt.length + iv.length + cipher.length,
          cipher,
        );
      final expectedTag = Hmac(sha256, key).convert(macInput).bytes;

      if (tag.length != expectedTag.length) return null;
      var diff = 0;
      for (var i = 0; i < tag.length; i++) {
        diff |= tag[i] ^ expectedTag[i];
      }
      if (diff != 0) return null;

      final ks = _legacyKeystream(key, iv, cipher.length);
      final plain = Uint8List(cipher.length);
      for (var i = 0; i < cipher.length; i++) {
        plain[i] = cipher[i] ^ ks[i];
      }
      final decoded = jsonDecode(utf8.decode(plain, allowMalformed: false));
      if (decoded is! Map) return null;
      return <String, String>{
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value?.toString() ?? '',
      };
    } catch (e) {
      AppLog.instance.logError(
        'Legacy credential decryption failed: $e',
        source: 'SecureCredentialStore',
      );
      return null;
    }
  }

  Future<void> _ensureMigrated() {
    if (_migrated) return Future<void>.value();
    final existing = _migrationInFlight;
    if (existing != null) return existing;
    final future = _runMigration();
    _migrationInFlight = future;
    return future.whenComplete(() {
      if (identical(_migrationInFlight, future)) {
        _migrationInFlight = null;
      }
    });
  }

  Future<void> _runMigration() async {
    final dir = _dataDirectory;
    if (dir == null) {
      _migrated = true;
      return;
    }
    final legacyFile = File('${dir.path}/$legacyFileName');
    if (!await legacyFile.exists()) {
      _migrated = true;
      return;
    }

    final rawBytes = await legacyFile.readAsBytes();
    final entries = _decryptLegacyEntries(rawBytes);
    if (entries == null) {
      final bakFile = File('${dir.path}/$legacyBackupFileName');
      await _preserveLegacyAsBackup(legacyFile, bakFile, rawBytes);
      _legacyMigrationFailed = true;
      _legacyBackupPath = bakFile.path;
      _migrated = true;
      return;
    }

    // Write every legacy credential to platform secure storage BEFORE deleting old file.
    // Any write failure propagates out so `legacyFile` remains intact on disk.
    for (final entry in entries.entries) {
      if (entry.value.isNotEmpty) {
        await _backend.write(entry.key, entry.value);
        _cache[entry.key] = entry.value;
      }
    }

    if (await legacyFile.exists()) {
      await legacyFile.delete();
    }
    _migrated = true;
  }

  Future<void> _preserveLegacyAsBackup(
    File legacyFile,
    File bakFile,
    Uint8List rawBytes,
  ) async {
    try {
      if (await bakFile.exists()) {
        await bakFile.writeAsBytes(rawBytes, flush: true);
        if (await legacyFile.exists()) {
          await legacyFile.delete();
        }
      } else {
        await legacyFile.rename(bakFile.path);
      }
    } on FileSystemException {
      await bakFile.writeAsBytes(rawBytes, flush: true);
      if (await legacyFile.exists()) {
        await legacyFile.delete();
      }
    }
  }

  Future<void> _persist(String key, String? value) async {
    if (value == null) {
      await _backend.delete(key);
      _cache.remove(key);
    } else {
      await _backend.write(key, value);
      _cache[key] = value;
    }
  }

  @override
  Future<String?> read(String key) async {
    await _ensureMigrated();
    if (_cache.containsKey(key)) {
      return _cache[key];
    }
    final value = await _backend.read(key);
    if (value != null) {
      _cache[key] = value;
    }
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    await _ensureMigrated();
    await _persist(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _ensureMigrated();
    await _persist(key, null);
  }
}

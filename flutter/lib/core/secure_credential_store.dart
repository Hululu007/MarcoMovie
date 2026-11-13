import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Abstract contract for platform-secure credential storage.
abstract class SecureCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// In-memory implementation of [SecureCredentialStore] for tests and fallback.
class InMemorySecureCredentialStore implements SecureCredentialStore {
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

/// Default encrypted storage provider using authenticated encryption (CTR + HMAC-SHA256).
class DefaultSecureCredentialStore implements SecureCredentialStore {
  final Directory? _dataDirectory;
  final Map<String, String> _cache = <String, String>{};
  File? _storeFile;
  bool _initialized = false;

  DefaultSecureCredentialStore({Directory? dataDirectory})
      : _dataDirectory = dataDirectory;

  static const String _formatPrefix = 'mm_sec_v1';

  static Uint8List _deriveKey(Uint8List salt) {
    final host = Platform.isAndroid || Platform.isIOS
        ? 'mobile_marco_credential_key'
        : (Platform.localHostname.isNotEmpty ? Platform.localHostname : 'desktop_marco_credential_key');
    final seed = utf8.encode('marco_movie_secure_storage_seed:$host');
    final hmac = Hmac(sha256, seed);
    return Uint8List.fromList(hmac.convert(salt).bytes);
  }

  static Uint8List _keystream(Uint8List key, Uint8List iv, int length) {
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

  static String _encryptPayload(String plainText) {
    final rand = Random.secure();
    final salt = Uint8List(16);
    final iv = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      salt[i] = rand.nextInt(256);
      iv[i] = rand.nextInt(256);
    }
    final key = _deriveKey(salt);
    final plainBytes = Uint8List.fromList(utf8.encode(plainText));
    final ks = _keystream(key, iv, plainBytes.length);
    final cipher = Uint8List(plainBytes.length);
    for (var i = 0; i < plainBytes.length; i++) {
      cipher[i] = plainBytes[i] ^ ks[i];
    }
    // Tag over salt + iv + cipher
    final macInput = Uint8List(salt.length + iv.length + cipher.length)
      ..setRange(0, salt.length, salt)
      ..setRange(salt.length, salt.length + iv.length, iv)
      ..setRange(salt.length + iv.length, salt.length + iv.length + cipher.length, cipher);
    final tag = Uint8List.fromList(Hmac(sha256, key).convert(macInput).bytes);

    String toHex(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$_formatPrefix:${toHex(salt)}:${toHex(iv)}:${toHex(tag)}:${toHex(cipher)}';
  }

  static String? _decryptPayload(String payload) {
    final parts = payload.trim().split(':');
    if (parts.length != 5 || parts[0] != _formatPrefix) {
      return null;
    }
    try {
      Uint8List fromHex(String hex) {
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

      final key = _deriveKey(salt);
      final macInput = Uint8List(salt.length + iv.length + cipher.length)
        ..setRange(0, salt.length, salt)
        ..setRange(salt.length, salt.length + iv.length, iv)
        ..setRange(salt.length + iv.length, salt.length + iv.length + cipher.length, cipher);
      final expectedTag = Hmac(sha256, key).convert(macInput).bytes;

      var diff = 0;
      if (tag.length != expectedTag.length) return null;
      for (var i = 0; i < tag.length; i++) {
        diff |= tag[i] ^ expectedTag[i];
      }
      if (diff != 0) return null;

      final ks = _keystream(key, iv, cipher.length);
      final plain = Uint8List(cipher.length);
      for (var i = 0; i < cipher.length; i++) {
        plain[i] = cipher[i] ^ ks[i];
      }
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureLoaded() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = _dataDirectory;
      if (dir != null) {
        _storeFile = File('${dir.path}/secure_credentials.enc');
        if (await _storeFile!.exists()) {
          final raw = await _storeFile!.readAsString();
          final decrypted = _decryptPayload(raw);
          if (decrypted != null) {
            final decoded = jsonDecode(decrypted);
            if (decoded is Map) {
              for (final entry in decoded.entries) {
                _cache[entry.key.toString()] = entry.value.toString();
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    final file = _storeFile;
    if (file == null) return;
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final jsonStr = jsonEncode(_cache);
      final encrypted = _encryptPayload(jsonStr);
      final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(encrypted, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }
        await tmp.rename(file.path);
      }
    } catch (_) {}
  }

  @override
  Future<String?> read(String key) async {
    await _ensureLoaded();
    return _cache[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await _ensureLoaded();
    _cache[key] = value;
    await _persist();
  }

  @override
  Future<void> delete(String key) async {
    await _ensureLoaded();
    _cache.remove(key);
    await _persist();
  }
}

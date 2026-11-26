// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pkg_crypto;

/// Pure-Dart cryptographic and compression primitives matching the exact
/// security boundaries and wire formats of `shared/catpaw/drpy-worker.cjs`,
/// `drpy-rsa.cjs`, and the Guard plugin extractors.
///
/// Used by the in-process QuickJS-NG CatPaw/DRPY runtime on HarmonyOS NEXT
/// where no standalone Node.js binary is bundled.
class CatPawCrypto {
  static final Random _secureRandom = Random.secure();
  static const int maxZlibOutputBytes = 2 * 1024 * 1024;
  static const int maxCipherInputBytes = 6 * 1024 * 1024;

  static Uint8List randomBytes(int length) {
    if (length < 0 || length > 65536) {
      throw const FormatException('drpy_random_size');
    }
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _secureRandom.nextInt(256);
    }
    return out;
  }

  static Uint8List hashBytes(String algorithm, Uint8List input) {
    final normalized = algorithm.trim().toLowerCase().replaceAll('-', '');
    final pkg_crypto.Hash hasher;
    switch (normalized) {
      case 'sha256':
        hasher = pkg_crypto.sha256;
        break;
      case 'sha1':
        hasher = pkg_crypto.sha1;
        break;
      case 'md5':
        hasher = pkg_crypto.md5;
        break;
      case 'sha384':
        hasher = pkg_crypto.sha384;
        break;
      case 'sha512':
        hasher = pkg_crypto.sha512;
        break;
      default:
        throw const FormatException('drpy_crypto_invalid');
    }
    return Uint8List.fromList(hasher.convert(input).bytes);
  }

  static Uint8List zlibInflate(
    String mode,
    Uint8List input, {
    int maxOutputLength = maxZlibOutputBytes,
  }) {
    if (maxOutputLength <= 0 || maxOutputLength > 16 * 1024 * 1024) {
      throw const FormatException('drpy_crypto_invalid');
    }
    try {
      final Converter<List<int>, List<int>> decoder;
      switch (mode) {
        case 'inflate':
          decoder = ZLibDecoder(raw: false);
          break;
        case 'inflateRaw':
          decoder = ZLibDecoder(raw: true);
          break;
        case 'gunzip':
          decoder = gzip.decoder;
          break;
        default:
          throw const FormatException('drpy_crypto_invalid');
      }
      final sink = _BoundedBytesSink(maxOutputLength);
      final inputSink = decoder.startChunkedConversion(sink);
      inputSink.add(input);
      inputSink.close();
      return sink.takeBytes();
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('drpy_crypto_invalid');
    }
  }

  static String zlibInflateBase64(String mode, String inputB64) {
    if (inputB64.length > maxCipherInputBytes) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final bytes = _decodeLooseBase64(inputB64);
    final out = zlibInflate(mode, bytes);
    return base64Encode(out);
  }

  /// Faithful port of `shared/catpaw/drpy-rsa.cjs`.
  /// Accepts strictly canonical base64 DER SPKI/PKCS#8 keys with 1023/1024-bit
  /// RSA modulus and performs PKCS#1 v1.5 type-2 encrypt or decrypt.
  static String rsaPkcs1(String operation, String keyB64, String inputB64) {
    try {
      final encrypt = operation == 'encrypt';
      if (!encrypt && operation != 'decrypt') {
        throw const FormatException('drpy_crypto_invalid');
      }
      final der = _strictBase64(keyB64, 2048);
      final data = _strictBase64(inputB64, encrypt ? 117 : 1024);
      if (encrypt) {
        final pub = _parseSpkiPublicKey(der);
        final bits = pub.n.bitLength;
        if (bits != 1023 && bits != 1024) {
          throw const FormatException('drpy_crypto_invalid');
        }
        final encrypted = _rsaEncryptPkcs1Block(pub, data, 128);
        return base64Encode(encrypted);
      } else {
        final priv = _parsePkcs8PrivateKey(der);
        final bits = priv.n.bitLength;
        if (bits != 1023 && bits != 1024) {
          throw const FormatException('drpy_crypto_invalid');
        }
        if (data.length % 128 != 0) {
          throw const FormatException('drpy_crypto_invalid');
        }
        final output = BytesBuilder(copy: false);
        for (var offset = 0; offset < data.length; offset += 128) {
          final block = _rsaDecryptRawBlock(
            priv,
            Uint8List.sublistView(data, offset, offset + 128),
            128,
          );
          var sep = -1;
          for (var i = 2; i < block.length; i++) {
            if (block[i] == 0) {
              sep = i;
              break;
            }
          }
          if (block.length != 128 ||
              block[0] != 0 ||
              block[1] != 2 ||
              sep < 10 ||
              sep == 127) {
            throw const FormatException('drpy_crypto_invalid');
          }
          output.add(Uint8List.sublistView(block, sep + 1));
        }
        final result = output.takeBytes();
        if (result.length > 512) {
          throw const FormatException('drpy_crypto_invalid');
        }
        return base64Encode(result);
      }
    } catch (_) {
      throw const FormatException('drpy_crypto_invalid');
    }
  }

  /// Faithful port of `rsaPublicEncrypt` in `shared/catpaw/drpy-worker.cjs`.
  static String rsaPublicEncrypt(String pem, String dataB64) {
    try {
      if (pem.isEmpty || pem.length > 8192 || dataB64.length > 8192) {
        throw const FormatException('drpy_crypto_invalid');
      }
      final data = _decodeLooseBase64(dataB64);
      final pub = _parsePemPublicKey(pem);
      final bits = pub.n.bitLength;
      if (bits < 512 || bits > 4096) {
        throw const FormatException('drpy_crypto_invalid');
      }
      final keyBytes = (bits + 7) ~/ 8;
      if (data.length > keyBytes - 11) {
        throw const FormatException('drpy_crypto_invalid');
      }
      final encrypted = _rsaEncryptPkcs1Block(pub, data, keyBytes);
      return base64Encode(encrypted);
    } catch (_) {
      throw const FormatException('drpy_crypto_invalid');
    }
  }

  /// Faithful port of `nodeCipher` in `shared/catpaw/drpy-worker.cjs`.
  /// Supports `aes-128-cbc`, `aes-256-cbc`, `aes-128-ecb`, `aes-256-ecb`,
  /// `aes-256-gcm`, and `chacha20-poly1305`.
  static Map<String, String> nodeCipher({
    required String op,
    required String algo,
    required String keyB64,
    required String ivB64,
    required String dataB64,
    String tagB64 = '',
  }) {
    const allowed = {
      'aes-128-cbc',
      'aes-256-cbc',
      'aes-128-ecb',
      'aes-256-ecb',
      'aes-256-gcm',
      'chacha20-poly1305',
    };
    if (!allowed.contains(algo) || dataB64.length > maxCipherInputBytes) {
      throw const FormatException('drpy_crypto_invalid');
    }
    if (op != 'encrypt' && op != 'decrypt') {
      throw const FormatException('drpy_crypto_invalid');
    }
    try {
      final key = _decodeLooseBase64(keyB64);
      final iv = ivB64.isEmpty ? Uint8List(0) : _decodeLooseBase64(ivB64);
      final data = _decodeLooseBase64(dataB64);
      final tag = tagB64.isEmpty ? Uint8List(0) : _decodeLooseBase64(tagB64);

      switch (algo) {
        case 'aes-128-cbc':
          if (key.length != 16 || iv.length != 16) {
            throw const FormatException('drpy_crypto_invalid');
          }
          if (op == 'encrypt') {
            return {
              'data': base64Encode(_aesCbcEncrypt(key, iv, data)),
              'tag': '',
            };
          }
          return {'data': base64Encode(_aesCbcDecrypt(key, iv, data))};

        case 'aes-256-cbc':
          if (key.length != 32 || iv.length != 16) {
            throw const FormatException('drpy_crypto_invalid');
          }
          if (op == 'encrypt') {
            return {
              'data': base64Encode(_aesCbcEncrypt(key, iv, data)),
              'tag': '',
            };
          }
          return {'data': base64Encode(_aesCbcDecrypt(key, iv, data))};

        case 'aes-128-ecb':
          if (key.length != 16) {
            throw const FormatException('drpy_crypto_invalid');
          }
          if (op == 'encrypt') {
            return {'data': base64Encode(_aesEcbEncrypt(key, data)), 'tag': ''};
          }
          return {'data': base64Encode(_aesEcbDecrypt(key, data))};

        case 'aes-256-ecb':
          if (key.length != 32) {
            throw const FormatException('drpy_crypto_invalid');
          }
          if (op == 'encrypt') {
            return {'data': base64Encode(_aesEcbEncrypt(key, data)), 'tag': ''};
          }
          return {'data': base64Encode(_aesEcbDecrypt(key, data))};

        case 'aes-256-gcm':
          if (key.length != 32 || iv.isEmpty) {
            throw const FormatException('drpy_crypto_invalid');
          }
          if (op == 'encrypt') {
            final res = _aes256GcmEncrypt(key, iv, data);
            return {
              'data': base64Encode(res.ciphertext),
              'tag': base64Encode(res.tag),
            };
          }
          if (tag.length != 16) {
            throw const FormatException('drpy_crypto_invalid');
          }
          return {'data': base64Encode(_aes256GcmDecrypt(key, iv, data, tag))};

        case 'chacha20-poly1305':
          if (key.length != 32 || iv.length != 12) {
            throw const FormatException('drpy_crypto_invalid');
          }
          if (op == 'encrypt') {
            final res = _chacha20Poly1305Encrypt(key, iv, data);
            return {
              'data': base64Encode(res.ciphertext),
              'tag': base64Encode(res.tag),
            };
          }
          if (tag.length != 16) {
            throw const FormatException('drpy_crypto_invalid');
          }
          return {
            'data': base64Encode(_chacha20Poly1305Decrypt(key, iv, data, tag)),
          };
      }
      throw const FormatException('drpy_crypto_invalid');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('drpy_crypto_invalid');
    }
  }

  // ---------------------------------------------------------------------------
  // Base64 & constant-time helpers
  // ---------------------------------------------------------------------------

  static final RegExp _strictB64Pattern = RegExp(
    r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
  );

  static Uint8List _strictBase64(String value, int maxBytes) {
    if (value.isEmpty ||
        value.length > maxBytes * 2 ||
        !_strictB64Pattern.hasMatch(value)) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final result = base64Decode(value);
    if (result.isEmpty ||
        result.length > maxBytes ||
        base64Encode(result) != value) {
      throw const FormatException('drpy_crypto_invalid');
    }
    return result;
  }

  static Uint8List _decodeLooseBase64(String input) {
    if (input.isEmpty) return Uint8List(0);
    final stripped = input
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    final rem = stripped.length % 4;
    final padded = rem == 0 ? stripped : stripped + ('=' * (4 - rem));
    return base64Decode(padded);
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ---------------------------------------------------------------------------
  // AES-128 / AES-256 (FIPS 197) + CBC / ECB / GCM
  // ---------------------------------------------------------------------------

  static const List<int> _sbox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];

  static const List<int> _invSbox = [
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
  ];

  static const List<int> _rcon = [
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
  ];

  static ({Uint8List roundKeys, int rounds}) _aesExpandKey(Uint8List key) {
    final nk = key.length ~/ 4; // 4 for AES-128, 8 for AES-256
    final nr = nk + 6; // 10 for AES-128, 14 for AES-256
    final totalBytes = (nr + 1) * 16;
    final w = Uint8List(totalBytes);
    w.setRange(0, key.length, key);

    final temp = Uint8List(4);
    var i = nk;
    while (i * 4 < totalBytes) {
      final prev = (i - 1) * 4;
      temp[0] = w[prev];
      temp[1] = w[prev + 1];
      temp[2] = w[prev + 2];
      temp[3] = w[prev + 3];
      if (i % nk == 0) {
        final t0 = temp[0];
        temp[0] = _sbox[temp[1]] ^ _rcon[i ~/ nk];
        temp[1] = _sbox[temp[2]];
        temp[2] = _sbox[temp[3]];
        temp[3] = _sbox[t0];
      } else if (nk > 6 && i % nk == 4) {
        temp[0] = _sbox[temp[0]];
        temp[1] = _sbox[temp[1]];
        temp[2] = _sbox[temp[2]];
        temp[3] = _sbox[temp[3]];
      }
      final base = i * 4;
      final back = (i - nk) * 4;
      w[base] = w[back] ^ temp[0];
      w[base + 1] = w[back + 1] ^ temp[1];
      w[base + 2] = w[back + 2] ^ temp[2];
      w[base + 3] = w[back + 3] ^ temp[3];
      i++;
    }
    return (roundKeys: w, rounds: nr);
  }

  static int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)) & 0xff;

  static int _gfMul(int a, int b) {
    var p = 0;
    var aa = a;
    var bb = b;
    for (var i = 0; i < 8; i++) {
      if ((bb & 1) != 0) p ^= aa;
      final hi = aa & 0x80;
      aa = (aa << 1) & 0xff;
      if (hi != 0) aa ^= 0x1b;
      bb >>= 1;
    }
    return p;
  }

  static Uint8List _aesEncryptBlock(
    Uint8List input,
    int inputOffset,
    Uint8List w,
    int nr,
  ) {
    final s = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      s[i] = input[inputOffset + i] ^ w[i];
    }
    for (var round = 1; round <= nr; round++) {
      // SubBytes
      for (var i = 0; i < 16; i++) {
        s[i] = _sbox[s[i]];
      }
      // ShiftRows
      var t = s[1];
      s[1] = s[5];
      s[5] = s[9];
      s[9] = s[13];
      s[13] = t;

      t = s[2];
      s[2] = s[10];
      s[10] = t;
      t = s[6];
      s[6] = s[14];
      s[14] = t;

      t = s[15];
      s[15] = s[11];
      s[11] = s[7];
      s[7] = s[3];
      s[3] = t;

      // MixColumns (all rounds except last)
      if (round < nr) {
        for (var c = 0; c < 4; c++) {
          final idx = c * 4;
          final a0 = s[idx];
          final a1 = s[idx + 1];
          final a2 = s[idx + 2];
          final a3 = s[idx + 3];
          final xorAll = a0 ^ a1 ^ a2 ^ a3;
          s[idx] = a0 ^ xorAll ^ _xtime(a0 ^ a1);
          s[idx + 1] = a1 ^ xorAll ^ _xtime(a1 ^ a2);
          s[idx + 2] = a2 ^ xorAll ^ _xtime(a2 ^ a3);
          s[idx + 3] = a3 ^ xorAll ^ _xtime(a3 ^ a0);
        }
      }
      // AddRoundKey
      final base = round * 16;
      for (var i = 0; i < 16; i++) {
        s[i] ^= w[base + i];
      }
    }
    return s;
  }

  static Uint8List _aesDecryptBlock(
    Uint8List input,
    int inputOffset,
    Uint8List w,
    int nr,
  ) {
    final s = Uint8List(16);
    final lastBase = nr * 16;
    for (var i = 0; i < 16; i++) {
      s[i] = input[inputOffset + i] ^ w[lastBase + i];
    }
    for (var round = nr - 1; round >= 0; round--) {
      // InvShiftRows
      var t = s[13];
      s[13] = s[9];
      s[9] = s[5];
      s[5] = s[1];
      s[1] = t;

      t = s[2];
      s[2] = s[10];
      s[10] = t;
      t = s[6];
      s[6] = s[14];
      s[14] = t;

      t = s[3];
      s[3] = s[7];
      s[7] = s[11];
      s[11] = s[15];
      s[15] = t;

      // InvSubBytes
      for (var i = 0; i < 16; i++) {
        s[i] = _invSbox[s[i]];
      }
      // AddRoundKey
      final base = round * 16;
      for (var i = 0; i < 16; i++) {
        s[i] ^= w[base + i];
      }
      // InvMixColumns (all rounds except round 0)
      if (round > 0) {
        for (var c = 0; c < 4; c++) {
          final idx = c * 4;
          final a0 = s[idx];
          final a1 = s[idx + 1];
          final a2 = s[idx + 2];
          final a3 = s[idx + 3];
          s[idx] =
              _gfMul(a0, 0x0e) ^
              _gfMul(a1, 0x0b) ^
              _gfMul(a2, 0x0d) ^
              _gfMul(a3, 0x09);
          s[idx + 1] =
              _gfMul(a0, 0x09) ^
              _gfMul(a1, 0x0e) ^
              _gfMul(a2, 0x0b) ^
              _gfMul(a3, 0x0d);
          s[idx + 2] =
              _gfMul(a0, 0x0d) ^
              _gfMul(a1, 0x09) ^
              _gfMul(a2, 0x0e) ^
              _gfMul(a3, 0x0b);
          s[idx + 3] =
              _gfMul(a0, 0x0b) ^
              _gfMul(a1, 0x0d) ^
              _gfMul(a2, 0x09) ^
              _gfMul(a3, 0x0e);
        }
      }
    }
    return s;
  }

  static Uint8List _pkcs7Pad(Uint8List data) {
    final padLen = 16 - (data.length % 16);
    final out = Uint8List(data.length + padLen);
    out.setRange(0, data.length, data);
    out.fillRange(data.length, out.length, padLen);
    return out;
  }

  static Uint8List _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty || data.length % 16 != 0) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final padLen = data.last;
    if (padLen < 1 || padLen > 16 || padLen > data.length) {
      throw const FormatException('drpy_crypto_invalid');
    }
    var bad = 0;
    for (var i = data.length - padLen; i < data.length; i++) {
      bad |= data[i] ^ padLen;
    }
    if (bad != 0) throw const FormatException('drpy_crypto_invalid');
    return Uint8List.fromList(Uint8List.sublistView(data, 0, data.length - padLen));
  }

  static Uint8List _aesEcbEncrypt(Uint8List key, Uint8List plaintext) {
    final exp = _aesExpandKey(key);
    final padded = _pkcs7Pad(plaintext);
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      final enc = _aesEncryptBlock(padded, offset, exp.roundKeys, exp.rounds);
      out.setRange(offset, offset + 16, enc);
    }
    return out;
  }

  static Uint8List _aesEcbDecrypt(Uint8List key, Uint8List ciphertext) {
    if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final exp = _aesExpandKey(key);
    final out = Uint8List(ciphertext.length);
    for (var offset = 0; offset < ciphertext.length; offset += 16) {
      final dec = _aesDecryptBlock(ciphertext, offset, exp.roundKeys, exp.rounds);
      out.setRange(offset, offset + 16, dec);
    }
    return _pkcs7Unpad(out);
  }

  static Uint8List _aesCbcEncrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List plaintext,
  ) {
    final exp = _aesExpandKey(key);
    final padded = _pkcs7Pad(plaintext);
    final out = Uint8List(padded.length);
    final prev = Uint8List.fromList(iv);
    final block = Uint8List(16);
    for (var offset = 0; offset < padded.length; offset += 16) {
      for (var i = 0; i < 16; i++) {
        block[i] = padded[offset + i] ^ prev[i];
      }
      final enc = _aesEncryptBlock(block, 0, exp.roundKeys, exp.rounds);
      out.setRange(offset, offset + 16, enc);
      prev.setRange(0, 16, enc);
    }
    return out;
  }

  static Uint8List _aesCbcDecrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
  ) {
    if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final exp = _aesExpandKey(key);
    final out = Uint8List(ciphertext.length);
    final prev = Uint8List.fromList(iv);
    for (var offset = 0; offset < ciphertext.length; offset += 16) {
      final dec = _aesDecryptBlock(ciphertext, offset, exp.roundKeys, exp.rounds);
      for (var i = 0; i < 16; i++) {
        out[offset + i] = dec[i] ^ prev[i];
      }
      prev.setRange(0, 16, ciphertext, offset);
    }
    return _pkcs7Unpad(out);
  }

  // NIST SP 800-38D AES-256-GCM
  static Uint8List _gf128Mul(Uint8List x, Uint8List y) {
    final z = Uint8List(16);
    final v = Uint8List.fromList(y);
    for (var i = 0; i < 128; i++) {
      final byteIdx = i >> 3;
      final bitMask = 0x80 >> (i & 7);
      if ((x[byteIdx] & bitMask) != 0) {
        for (var j = 0; j < 16; j++) {
          z[j] ^= v[j];
        }
      }
      final lsb = (v[15] & 1) != 0;
      for (var j = 15; j > 0; j--) {
        v[j] = ((v[j] >> 1) | ((v[j - 1] & 1) << 7)) & 0xff;
      }
      v[0] >>= 1;
      if (lsb) v[0] ^= 0xe1;
    }
    return z;
  }

  static Uint8List _ghash(Uint8List h, Uint8List data) {
    var y = Uint8List(16);
    final block = Uint8List(16);
    for (var offset = 0; offset < data.length; offset += 16) {
      block.fillRange(0, 16, 0);
      final take = min(16, data.length - offset);
      for (var i = 0; i < take; i++) {
        block[i] = data[offset + i];
      }
      for (var i = 0; i < 16; i++) {
        y[i] ^= block[i];
      }
      y = _gf128Mul(y, h);
    }
    return y;
  }

  static void _inc32(Uint8List counter) {
    var val =
        ((counter[12] << 24) |
            (counter[13] << 16) |
            (counter[14] << 8) |
            counter[15]) +
        1;
    counter[12] = (val >> 24) & 0xff;
    counter[13] = (val >> 16) & 0xff;
    counter[14] = (val >> 8) & 0xff;
    counter[15] = val & 0xff;
  }

  static void _putUint64BE(Uint8List target, int offset, int value) {
    for (var i = 7; i >= 0; i--) {
      target[offset + i] = value & 0xff;
      value >>>= 8;
    }
  }

  static Uint8List _gcmComputeJ0(Uint8List h, Uint8List iv) {
    if (iv.length == 12) {
      final j0 = Uint8List(16);
      j0.setRange(0, 12, iv);
      j0[15] = 1;
      return j0;
    }
    final paddedLen = ((iv.length + 15) ~/ 16) * 16;
    final buf = Uint8List(paddedLen + 16);
    buf.setRange(0, iv.length, iv);
    _putUint64BE(buf, paddedLen + 8, iv.length * 8);
    return _ghash(h, buf);
  }

  static Uint8List _gcmComputeTag(
    Uint8List h,
    Uint8List j0Encrypted,
    Uint8List ciphertext,
  ) {
    final paddedLen = ((ciphertext.length + 15) ~/ 16) * 16;
    final ghashInput = Uint8List(paddedLen + 16);
    ghashInput.setRange(0, ciphertext.length, ciphertext);
    // AAD length = 0 (bytes paddedLen..paddedLen+8 stay 0)
    _putUint64BE(ghashInput, paddedLen + 8, ciphertext.length * 8);
    final s = _ghash(h, ghashInput);
    final tag = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      tag[i] = j0Encrypted[i] ^ s[i];
    }
    return tag;
  }

  static Uint8List _gcmCtrTransform(
    Uint8List roundKeys,
    int rounds,
    Uint8List j0,
    Uint8List input,
  ) {
    final counter = Uint8List.fromList(j0);
    final out = Uint8List(input.length);
    for (var offset = 0; offset < input.length; offset += 16) {
      _inc32(counter);
      final ks = _aesEncryptBlock(counter, 0, roundKeys, rounds);
      final take = min(16, input.length - offset);
      for (var i = 0; i < take; i++) {
        out[offset + i] = input[offset + i] ^ ks[i];
      }
    }
    return out;
  }

  static ({Uint8List ciphertext, Uint8List tag}) _aes256GcmEncrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List plaintext,
  ) {
    final exp = _aesExpandKey(key);
    final h = _aesEncryptBlock(Uint8List(16), 0, exp.roundKeys, exp.rounds);
    final j0 = _gcmComputeJ0(h, iv);
    final j0Enc = _aesEncryptBlock(j0, 0, exp.roundKeys, exp.rounds);
    final ciphertext = _gcmCtrTransform(
      exp.roundKeys,
      exp.rounds,
      j0,
      plaintext,
    );
    final tag = _gcmComputeTag(h, j0Enc, ciphertext);
    return (ciphertext: ciphertext, tag: tag);
  }

  static Uint8List _aes256GcmDecrypt(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
    Uint8List tag,
  ) {
    final exp = _aesExpandKey(key);
    final h = _aesEncryptBlock(Uint8List(16), 0, exp.roundKeys, exp.rounds);
    final j0 = _gcmComputeJ0(h, iv);
    final j0Enc = _aesEncryptBlock(j0, 0, exp.roundKeys, exp.rounds);
    final expectedTag = _gcmComputeTag(h, j0Enc, ciphertext);
    if (!_constantTimeEquals(expectedTag, tag)) {
      throw const FormatException('drpy_crypto_invalid');
    }
    return _gcmCtrTransform(exp.roundKeys, exp.rounds, j0, ciphertext);
  }

  // ---------------------------------------------------------------------------
  // ChaCha20-Poly1305 (RFC 8439)
  // ---------------------------------------------------------------------------

  static int _rotl32(int v, int shift) =>
      ((v << shift) & 0xffffffff) | ((v & 0xffffffff) >>> (32 - shift));

  static void _quarterRound(Uint32List s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl32(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl32(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl32(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl32(s[b] ^ s[c], 7);
  }

  static int _readU32LE(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static Uint8List _chacha20Block(Uint8List key, int counter, Uint8List nonce) {
    final state = Uint32List(16);
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    for (var i = 0; i < 8; i++) {
      state[4 + i] = _readU32LE(key, i * 4);
    }
    state[12] = counter & 0xffffffff;
    state[13] = _readU32LE(nonce, 0);
    state[14] = _readU32LE(nonce, 4);
    state[15] = _readU32LE(nonce, 8);

    final working = Uint32List.fromList(state);
    for (var i = 0; i < 10; i++) {
      _quarterRound(working, 0, 4, 8, 12);
      _quarterRound(working, 1, 5, 9, 13);
      _quarterRound(working, 2, 6, 10, 14);
      _quarterRound(working, 3, 7, 11, 15);
      _quarterRound(working, 0, 5, 10, 15);
      _quarterRound(working, 1, 6, 11, 12);
      _quarterRound(working, 2, 7, 8, 13);
      _quarterRound(working, 3, 4, 9, 14);
    }

    final out = Uint8List(64);
    for (var i = 0; i < 16; i++) {
      final word = (working[i] + state[i]) & 0xffffffff;
      out[i * 4] = word & 0xff;
      out[i * 4 + 1] = (word >> 8) & 0xff;
      out[i * 4 + 2] = (word >> 16) & 0xff;
      out[i * 4 + 3] = (word >> 24) & 0xff;
    }
    return out;
  }

  static Uint8List _chacha20Xor(
    Uint8List key,
    int initialCounter,
    Uint8List nonce,
    Uint8List input,
  ) {
    final out = Uint8List(input.length);
    var counter = initialCounter;
    for (var offset = 0; offset < input.length; offset += 64) {
      final ks = _chacha20Block(key, counter++, nonce);
      final take = min(64, input.length - offset);
      for (var i = 0; i < take; i++) {
        out[offset + i] = input[offset + i] ^ ks[i];
      }
    }
    return out;
  }

  static final BigInt _poly1305Clamp = BigInt.parse(
    '0ffffffc0ffffffc0ffffffc0fffffff',
    radix: 16,
  );
  static final BigInt _poly1305Prime = (BigInt.one << 130) - BigInt.from(5);

  static BigInt _leBytesToBigInt(Uint8List bytes, int offset, int length) {
    var result = BigInt.zero;
    for (var i = length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[offset + i]);
    }
    return result;
  }

  static Uint8List _poly1305Mac(Uint8List otk, Uint8List message) {
    final r = _leBytesToBigInt(otk, 0, 16) & _poly1305Clamp;
    final s = _leBytesToBigInt(otk, 16, 16);
    var acc = BigInt.zero;
    for (var offset = 0; offset < message.length; offset += 16) {
      final take = min(16, message.length - offset);
      final n =
          _leBytesToBigInt(message, offset, take) + (BigInt.one << (8 * take));
      acc = ((acc + n) * r) % _poly1305Prime;
    }
    acc += s;
    final tag = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      tag[i] = (acc & BigInt.from(0xff)).toInt();
      acc >>= 8;
    }
    return tag;
  }

  static Uint8List _chacha20Poly1305Tag(
    Uint8List key,
    Uint8List nonce,
    Uint8List ciphertext,
  ) {
    final otk = _chacha20Block(key, 0, nonce);
    final padLen = (16 - (ciphertext.length % 16)) % 16;
    final macData = Uint8List(ciphertext.length + padLen + 16);
    macData.setRange(0, ciphertext.length, ciphertext);
    // AAD len = 0 (8 bytes at ciphertext.length + padLen remain 0)
    var ctLen = ciphertext.length;
    final lenOffset = ciphertext.length + padLen + 8;
    for (var i = 0; i < 8; i++) {
      macData[lenOffset + i] = ctLen & 0xff;
      ctLen >>>= 8;
    }
    return _poly1305Mac(otk, macData);
  }

  static ({Uint8List ciphertext, Uint8List tag}) _chacha20Poly1305Encrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List plaintext,
  ) {
    final ciphertext = _chacha20Xor(key, 1, nonce, plaintext);
    final tag = _chacha20Poly1305Tag(key, nonce, ciphertext);
    return (ciphertext: ciphertext, tag: tag);
  }

  static Uint8List _chacha20Poly1305Decrypt(
    Uint8List key,
    Uint8List nonce,
    Uint8List ciphertext,
    Uint8List tag,
  ) {
    final expectedTag = _chacha20Poly1305Tag(key, nonce, ciphertext);
    if (!_constantTimeEquals(expectedTag, tag)) {
      throw const FormatException('drpy_crypto_invalid');
    }
    return _chacha20Xor(key, 1, nonce, ciphertext);
  }

  // ---------------------------------------------------------------------------
  // ASN.1 DER & RSA PKCS#1 v1.5
  // ---------------------------------------------------------------------------

  static const List<int> _rsaEncryptionOid = [
    0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
  ];

  static _RsaPublicKey _parsePemPublicKey(String pem) {
    final trimmed = pem.trim();
    final isPkcs1 = trimmed.contains('BEGIN RSA PUBLIC KEY');
    final isSpki = trimmed.contains('BEGIN PUBLIC KEY');
    if (!isPkcs1 && !isSpki) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final b64 = trimmed
        .replaceAll(RegExp(r'-----BEGIN [A-Z ]+-----'), '')
        .replaceAll(RegExp(r'-----END [A-Z ]+-----'), '')
        .replaceAll(RegExp(r'\s+'), '');
    final der = base64Decode(b64);
    return isPkcs1 ? _parsePkcs1PublicKey(der) : _parseSpkiPublicKey(der);
  }

  static _RsaPublicKey _parseSpkiPublicKey(Uint8List der) {
    final root = _Asn1Reader(der).readElement(0x30);
    if (root.trailingBytes != 0) throw const FormatException('drpy_crypto_invalid');
    final seq = _Asn1Reader(root.content);
    final algId = seq.readElement(0x30);
    final algReader = _Asn1Reader(algId.content);
    final oid = algReader.readElement(0x06);
    if (!_listEquals(oid.content, _rsaEncryptionOid)) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final bitString = seq.readElement(0x03);
    if (bitString.content.isEmpty || bitString.content[0] != 0) {
      throw const FormatException('drpy_crypto_invalid');
    }
    return _parsePkcs1PublicKey(Uint8List.sublistView(bitString.content, 1));
  }

  static _RsaPublicKey _parsePkcs1PublicKey(Uint8List der) {
    final root = _Asn1Reader(der).readElement(0x30);
    if (root.trailingBytes != 0) throw const FormatException('drpy_crypto_invalid');
    final seq = _Asn1Reader(root.content);
    final n = _asn1PositiveBigInt(seq.readElement(0x02).content);
    final e = _asn1PositiveBigInt(seq.readElement(0x02).content);
    if (n <= BigInt.one || e < BigInt.from(3) || e.isEven) {
      throw const FormatException('drpy_crypto_invalid');
    }
    return _RsaPublicKey(n, e);
  }

  static _RsaPrivateKey _parsePkcs8PrivateKey(Uint8List der) {
    final root = _Asn1Reader(der).readElement(0x30);
    if (root.trailingBytes != 0) throw const FormatException('drpy_crypto_invalid');
    final seq = _Asn1Reader(root.content);
    final version = _asn1PositiveBigInt(seq.readElement(0x02).content);
    if (version != BigInt.zero) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final algId = seq.readElement(0x30);
    final algReader = _Asn1Reader(algId.content);
    final oid = algReader.readElement(0x06);
    if (!_listEquals(oid.content, _rsaEncryptionOid)) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final octet = seq.readElement(0x04);
    final privRoot = _Asn1Reader(octet.content).readElement(0x30);
    final privSeq = _Asn1Reader(privRoot.content);
    privSeq.readElement(0x02); // version
    final n = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
    final e = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
    final d = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
    BigInt? p, q, dP, dQ, qInv;
    if (privSeq.hasMore) {
      p = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
      q = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
      dP = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
      dQ = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
      qInv = _asn1PositiveBigInt(privSeq.readElement(0x02).content);
    }
    return _RsaPrivateKey(n: n, e: e, d: d, p: p, q: q, dP: dP, dQ: dQ, qInv: qInv);
  }

  static Uint8List _rsaEncryptPkcs1Block(
    _RsaPublicKey pub,
    Uint8List message,
    int blockSize,
  ) {
    final psLen = blockSize - message.length - 3;
    if (psLen < 8) throw const FormatException('drpy_crypto_invalid');
    final em = Uint8List(blockSize);
    em[0] = 0x00;
    em[1] = 0x02;
    for (var i = 0; i < psLen; i++) {
      em[2 + i] = 1 + _secureRandom.nextInt(255);
    }
    em[2 + psLen] = 0x00;
    em.setRange(3 + psLen, blockSize, message);
    final m = _beBytesToBigInt(em);
    if (m >= pub.n) throw const FormatException('drpy_crypto_invalid');
    final c = m.modPow(pub.e, pub.n);
    return _bigIntToBeBytes(c, blockSize);
  }

  static Uint8List _rsaDecryptRawBlock(
    _RsaPrivateKey priv,
    Uint8List cipherBlock,
    int blockSize,
  ) {
    final c = _beBytesToBigInt(cipherBlock);
    if (c >= priv.n) throw const FormatException('drpy_crypto_invalid');
    final BigInt m;
    if (priv.p != null &&
        priv.q != null &&
        priv.dP != null &&
        priv.dQ != null &&
        priv.qInv != null) {
      final m1 = c.modPow(priv.dP!, priv.p!);
      final m2 = c.modPow(priv.dQ!, priv.q!);
      var diff = (m1 - m2) % priv.p!;
      if (diff.isNegative) diff += priv.p!;
      final h = (priv.qInv! * diff) % priv.p!;
      m = m2 + h * priv.q!;
    } else {
      m = c.modPow(priv.d, priv.n);
    }
    return _bigIntToBeBytes(m, blockSize);
  }

  static BigInt _asn1PositiveBigInt(Uint8List bytes) {
    if (bytes.isEmpty || (bytes[0] & 0x80) != 0) {
      throw const FormatException('drpy_crypto_invalid');
    }
    return _beBytesToBigInt(bytes);
  }

  static BigInt _beBytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntToBeBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    if (v != BigInt.zero) throw const FormatException('drpy_crypto_invalid');
    return out;
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _BoundedBytesSink implements Sink<List<int>> {
  final int maxBytes;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  _BoundedBytesSink(this.maxBytes);

  @override
  void add(List<int> data) {
    if (_builder.length + data.length > maxBytes) {
      throw const FormatException('drpy_crypto_invalid');
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

class _RsaPublicKey {
  final BigInt n;
  final BigInt e;
  const _RsaPublicKey(this.n, this.e);
}

class _RsaPrivateKey {
  final BigInt n;
  final BigInt e;
  final BigInt d;
  final BigInt? p;
  final BigInt? q;
  final BigInt? dP;
  final BigInt? dQ;
  final BigInt? qInv;
  const _RsaPrivateKey({
    required this.n,
    required this.e,
    required this.d,
    this.p,
    this.q,
    this.dP,
    this.dQ,
    this.qInv,
  });
}

class _Asn1Element {
  final int tag;
  final Uint8List content;
  final int trailingBytes;
  const _Asn1Element(this.tag, this.content, this.trailingBytes);
}

class _Asn1Reader {
  final Uint8List _data;
  int _offset = 0;

  _Asn1Reader(this._data);

  bool get hasMore => _offset < _data.length;

  _Asn1Element readElement(int expectedTag) {
    if (_offset >= _data.length) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final tag = _data[_offset++];
    if (tag != expectedTag) {
      throw const FormatException('drpy_crypto_invalid');
    }
    if (_offset >= _data.length) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final firstLen = _data[_offset++];
    int length;
    if ((firstLen & 0x80) == 0) {
      length = firstLen;
    } else {
      final count = firstLen & 0x7f;
      if (count == 0 || count > 4 || _offset + count > _data.length) {
        throw const FormatException('drpy_crypto_invalid');
      }
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | _data[_offset++];
      }
    }
    if (_offset + length > _data.length) {
      throw const FormatException('drpy_crypto_invalid');
    }
    final content = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return _Asn1Element(tag, content, _data.length - _offset);
  }
}

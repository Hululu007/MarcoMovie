import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class ParsedBindTarget {
  final String baseEndpointUrl;
  final String bindUrl;
  final String syncUrl;
  final Uint8List key;

  const ParsedBindTarget({
    required this.baseEndpointUrl,
    required this.bindUrl,
    required this.syncUrl,
    required this.key,
  });
}

/// Pure HMAC-SHA256 authenticated encryption (`marco-bind-box-v1`) and QR URI
/// codecs matching Java `com.pilipala.source.WebdavBindCrypto` and Swift
/// `WebdavBindCrypto` byte-for-byte.
class WebdavBindCrypto {
  WebdavBindCrypto._();

  static const String bindSchemeFragment = 'marco-bind=v1';
  static const String alg = 'marco-bind-box-v1';
  static const int keyBytes = 32;
  static const int nonceBytes = 16;
  static const String _encInfo = 'marco-bind-v1-enc';
  static const String _macInfo = 'marco-bind-v1-mac';
  static const String _macLabel = 'marco-bind-box-v1';

  static Uint8List generateKey() {
    final rng = Random.secure();
    final key = Uint8List(keyBytes);
    for (var i = 0; i < keyBytes; i++) {
      key[i] = rng.nextInt(256);
    }
    return key;
  }

  static String encodeBase64UrlNoPad(List<int> data) {
    return base64Url.encode(data).replaceAll('=', '');
  }

  static Uint8List decodeBase64Url(String text) {
    final normalized = base64Url.normalize(text.trim());
    return Uint8List.fromList(base64Url.decode(normalized));
  }

  static String buildBindQrUrl(String baseEndpointUrl, Uint8List key) {
    var cleanBase = baseEndpointUrl.trim();
    if (cleanBase.isEmpty) {
      throw ArgumentError('Missing baseEndpointUrl');
    }
    if (key.length != keyBytes) {
      throw ArgumentError('Expected 32-byte key');
    }
    final hashIdx = cleanBase.indexOf('#');
    if (hashIdx >= 0) {
      cleanBase = cleanBase.substring(0, hashIdx);
    }
    return '$cleanBase#$bindSchemeFragment&k=${encodeBase64UrlNoPad(key)}';
  }

  static ParsedBindTarget? parseBindQrInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return null;

    var endpoint = '';
    var keyB64 = '';

    if (trimmed.toLowerCase().startsWith('marcomovie://bind')) {
      final parsedUri = Uri.tryParse(trimmed);
      if (parsedUri == null) return null;
      endpoint = (parsedUri.queryParameters['u'] ?? '').trim();
      keyB64 = (parsedUri.queryParameters['k'] ?? '').trim();
    } else {
      final hashIdx = trimmed.indexOf('#');
      if (hashIdx < 0) return null;
      endpoint = trimmed.substring(0, hashIdx).trim();
      final frag = trimmed.substring(hashIdx + 1).trim();
      for (final part in frag.split('&')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = Uri.decodeComponent(part.substring(0, eq));
        final val = Uri.decodeComponent(part.substring(eq + 1));
        if (name == 'k') {
          keyB64 = val.trim();
        }
      }
    }

    if (endpoint.isEmpty || keyB64.isEmpty) return null;
    late final Uint8List key;
    try {
      key = decodeBase64Url(keyB64);
    } catch (_) {
      return null;
    }
    if (key.length != keyBytes) return null;

    final uri = Uri.tryParse(endpoint);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') || uri.host.trim().isEmpty) {
      return null;
    }

    var base = endpoint;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/bind')) {
      base = base.substring(0, base.length - '/bind'.length);
    } else if (base.endsWith('/sync')) {
      base = base.substring(0, base.length - '/sync'.length);
    }

    return ParsedBindTarget(
      baseEndpointUrl: base,
      bindUrl: '$base/bind',
      syncUrl: '$base/sync',
      key: key,
    );
  }

  static String sealJson(Uint8List key, Map<String, Object?> payload) {
    final rng = Random.secure();
    final nonce = Uint8List(nonceBytes);
    for (var i = 0; i < nonceBytes; i++) {
      nonce[i] = rng.nextInt(256);
    }
    return sealPlaintextWithNonce(key, nonce, jsonEncode(payload));
  }

  static String sealPlaintextWithNonce(
    Uint8List key,
    Uint8List nonce,
    String plaintextJson,
  ) {
    if (key.length != keyBytes) {
      throw ArgumentError('Expected 32-byte key');
    }
    if (nonce.length != nonceBytes) {
      throw ArgumentError('Expected 16-byte nonce');
    }
    final pt = utf8.encode(plaintextJson);
    final encKey = _hmacSha256(key, utf8.encode(_encInfo));
    final macKey = _hmacSha256(key, utf8.encode(_macInfo));
    final ct = _xorCtr(encKey, nonce, pt);
    final tag = _computeTag(macKey, nonce, ct);
    return jsonEncode({
      'v': 1,
      'alg': alg,
      'n': encodeBase64UrlNoPad(nonce),
      'c': encodeBase64UrlNoPad(ct),
      't': encodeBase64UrlNoPad(tag),
    });
  }

  static Map<String, dynamic> openJson(Uint8List key, String envelopeJson) {
    final plaintext = openPlaintext(key, envelopeJson);
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected JSON object');
    }
    return decoded;
  }

  static String openPlaintext(Uint8List key, String envelopeJson) {
    if (key.length != keyBytes) {
      throw const FormatException('Invalid bind key length');
    }
    final decoded = jsonDecode(envelopeJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected envelope JSON object');
    }
    if (decoded['v'] != 1 || decoded['alg'] != alg) {
      throw const FormatException('Unsupported bind envelope version or algorithm');
    }
    final nStr = decoded['n'];
    final cStr = decoded['c'];
    final tStr = decoded['t'];
    if (nStr is! String || cStr is! String || tStr is! String) {
      throw const FormatException('Malformed bind envelope fields');
    }
    final nonce = decodeBase64Url(nStr);
    final ct = decodeBase64Url(cStr);
    final tag = decodeBase64Url(tStr);
    if (nonce.length != nonceBytes || tag.length != 32) {
      throw const FormatException('Malformed bind envelope sizes');
    }
    final macKey = _hmacSha256(key, utf8.encode(_macInfo));
    final expectedTag = _computeTag(macKey, nonce, ct);
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= expectedTag[i] ^ tag[i];
    }
    if (diff != 0) {
      throw const FormatException('Bind MAC verification failed');
    }
    final encKey = _hmacSha256(key, utf8.encode(_encInfo));
    final pt = _xorCtr(encKey, nonce, ct);
    return utf8.decode(pt);
  }

  static Uint8List _computeTag(
    Uint8List macKey,
    Uint8List nonce,
    Uint8List ct,
  ) {
    final label = utf8.encode(_macLabel);
    final input = Uint8List(label.length + nonce.length + ct.length)
      ..setAll(0, label)
      ..setAll(label.length, nonce)
      ..setAll(label.length + nonce.length, ct);
    return _hmacSha256(macKey, input);
  }

  static Uint8List _xorCtr(
    Uint8List encKey,
    Uint8List nonce,
    List<int> data,
  ) {
    final out = Uint8List(data.length);
    final blockInput = Uint8List(nonce.length + 4)..setAll(0, nonce);
    var offset = 0;
    var counter = 0;
    while (offset < data.length) {
      blockInput[nonce.length] = (counter >> 24) & 0xff;
      blockInput[nonce.length + 1] = (counter >> 16) & 0xff;
      blockInput[nonce.length + 2] = (counter >> 8) & 0xff;
      blockInput[nonce.length + 3] = counter & 0xff;
      final ks = _hmacSha256(encKey, blockInput);
      final take = min(ks.length, data.length - offset);
      for (var i = 0; i < take; i++) {
        out[offset + i] = data[offset + i] ^ ks[i];
      }
      offset += take;
      counter++;
    }
    return out;
  }

  static Uint8List _hmacSha256(List<int> key, List<int> message) {
    final mac = Hmac(sha256, key);
    return Uint8List.fromList(mac.convert(message).bytes);
  }
}

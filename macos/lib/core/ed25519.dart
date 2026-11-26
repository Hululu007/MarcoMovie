import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Pure Dart implementation of RFC 8032 Ed25519 signature verification.
/// Uses native [BigInt] arithmetic and [package:crypto] for SHA-512 with zero external dependencies.
class Ed25519 {
  static final BigInt _q = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _l = (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d =
      (-BigInt.from(121665) * _inv(BigInt.from(121666))) % _q;
  static final BigInt _i =
      _expmod(BigInt.two, (_q - BigInt.one) ~/ BigInt.from(4), _q);

  static final List<BigInt> _by = [
    _recoverX((BigInt.from(4) * _inv(BigInt.from(5))) % _q),
    (BigInt.from(4) * _inv(BigInt.from(5))) % _q,
  ];

  static BigInt _inv(BigInt x) => _expmod(x, _q - BigInt.two, _q);
  static BigInt _expmod(BigInt base, BigInt exp, BigInt mod) =>
      base.modPow(exp, mod);

  static BigInt _recoverX(BigInt y) {
    final xx = ((y * y - BigInt.one) * _inv(_d * y * y + BigInt.one)) % _q;
    var x = _expmod(xx, (_q + BigInt.from(3)) ~/ BigInt.from(8), _q);
    if ((x * x - xx) % _q != BigInt.zero) x = (x * _i) % _q;
    if (x.isOdd) x = _q - x;
    return x;
  }

  static List<BigInt> _edwards(List<BigInt> p, List<BigInt> q) {
    final x1 = p[0], y1 = p[1], x2 = q[0], y2 = q[1];
    final x3 =
        ((x1 * y2 + x2 * y1) * _inv(BigInt.one + _d * x1 * x2 * y1 * y2)) % _q;
    final y3 =
        ((y1 * y2 + x1 * x2) * _inv(BigInt.one - _d * x1 * x2 * y1 * y2)) % _q;
    return [(x3 + _q) % _q, (y3 + _q) % _q];
  }

  static List<BigInt> _scalarMult(List<BigInt> p, BigInt e) {
    if (e == BigInt.zero) return [BigInt.zero, BigInt.one];
    var q = _scalarMult(p, e ~/ BigInt.two);
    q = _edwards(q, q);
    if (e.isOdd) q = _edwards(q, p);
    return q;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  static List<BigInt>? _decodePoint(Uint8List s) {
    if (s.length != 32) return null;
    var y = _bytesToBigInt(s);
    final sign = (y >> 255).toInt() & 1;
    y = y & ((BigInt.one << 255) - BigInt.one);
    var x = _recoverX(y);
    if ((x & BigInt.one).toInt() != sign) x = _q - x;
    return [x, y];
  }

  /// Verifies an Ed25519 signature over [message] against [publicKey].
  /// Returns `true` if and only if the signature is mathematically valid.
  static bool verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    if (signature.length != 64 || publicKey.length != 32) return false;
    final rPoint = _decodePoint(signature.sublist(0, 32));
    final aPoint = _decodePoint(publicKey);
    if (rPoint == null || aPoint == null) return false;

    final s = _bytesToBigInt(signature.sublist(32, 64));
    if (s >= _l) return false;

    final hashInput = Uint8List(32 + 32 + message.length)
      ..setRange(0, 32, signature.sublist(0, 32))
      ..setRange(32, 64, publicKey)
      ..setRange(64, 64 + message.length, message);

    final hDigest = sha512.convert(hashInput);
    final k = _bytesToBigInt(Uint8List.fromList(hDigest.bytes));

    final v1 = _scalarMult(_by, s);
    final v2 = _edwards(rPoint, _scalarMult(aPoint, k % _l));

    return v1[0] == v2[0] && v1[1] == v2[1];
  }
}

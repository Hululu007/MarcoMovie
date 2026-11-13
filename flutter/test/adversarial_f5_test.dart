import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/ed25519.dart';

Uint8List fromHex(String hex) {
  final res = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < res.length; i++) {
    res[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return res;
}

String toHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  group('Adversarial F5: Ed25519 Signature Verification & Manifest Tamper Resistance', () {
    const configuredPubKeyHex =
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
    final officialPubKeyBytes = fromHex(configuredPubKeyHex);

    setUp(() {
      expect(AppUpdate.defaultUpdatePublicKeyHex, isEmpty);
      AppUpdate.debugPublicKeyHexOverride = configuredPubKeyHex;
    });

    tearDown(() {
      AppUpdate.debugPublicKeyHexOverride = null;
    });

    // Vector 1 valid pair for known reference
    final v1Msg = Uint8List(0);
    final v1SigHex =
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';
    final v1SigBytes = fromHex(v1SigHex);

    test('Adversarial 1: 100 randomly forged 64-byte signatures are all rejected', () {
      final rng = Random(42);
      final dummyMsg = utf8.encode('{"version":"0.5.25","windows":{"size":100}}');

      for (var i = 0; i < 100; i++) {
        final forgedSig = Uint8List(64);
        for (var j = 0; j < 64; j++) {
          forgedSig[j] = rng.nextInt(256);
        }

        final isValid = Ed25519.verify(
          publicKey: officialPubKeyBytes,
          message: dummyMsg,
          signature: forgedSig,
        );
        expect(isValid, isFalse, reason: 'Random forged signature #$i must be rejected');
      }
    });

    test('Adversarial 2: Single-bit flips across R and S components all fail verification', () {
      // Test bit flips on valid Vector 1 signature
      for (var byteIdx in [0, 15, 31, 32, 47, 63]) {
        for (var bit = 0; bit < 8; bit++) {
          final mutatedSig = Uint8List.fromList(v1SigBytes);
          mutatedSig[byteIdx] ^= (1 << bit);

          final isValid = Ed25519.verify(
            publicKey: officialPubKeyBytes,
            message: v1Msg,
            signature: mutatedSig,
          );
          expect(
            isValid,
            isFalse,
            reason: 'Bit flip at byte $byteIdx bit $bit must invalidate signature',
          );
        }
      }
    });

    test('Adversarial 3: Truncated and oversized signatures are rejected', () {
      final dummyMsg = utf8.encode('test');
      for (var len in [0, 1, 16, 31, 32, 63, 65, 128, 256]) {
        final sig = Uint8List(len);
        final isValid = Ed25519.verify(
          publicKey: officialPubKeyBytes,
          message: dummyMsg,
          signature: sig,
        );
        expect(isValid, isFalse, reason: 'Signature of length $len must be rejected');
      }
    });

    test('Adversarial 4: Corrupted Base64 strings in manifest signature', () {
      final malformedStrings = [
        '',
        '   ',
        'not_base64!!!',
        '==invalid==',
        'A',
        'AA',
        'AAA',
        base64Encode(Uint8List(32)), // 32 bytes instead of 64
        base64Encode(Uint8List(63)), // 63 bytes
        base64Encode(Uint8List(65)), // 65 bytes
        '${base64Encode(v1SigBytes)}extra',
      ];

      for (final badSig in malformedStrings) {
        final manifest = {
          'version': '0.5.25',
          'signature': badSig,
        };
        final verified = AppUpdate.verifyManifestSignature(manifest);
        expect(verified, isFalse, reason: 'Bad signature "$badSig" must return false');
      }
    });

    test('Adversarial 5: Non-canonical scalar S >= L is rejected immediately', () {
      // RFC 8032 scalar field order L = 2^252 + 27742317777372353535851937790883648493
      // When s >= L, Ed25519 must return false.
      final lHex = 'edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010';
      final lBytes = fromHex(lHex); // little endian representation of L

      final sigWithS_L = Uint8List(64);
      sigWithS_L.setRange(0, 32, v1SigBytes.sublist(0, 32));
      sigWithS_L.setRange(32, 64, lBytes);

      final isValid = Ed25519.verify(
        publicKey: officialPubKeyBytes,
        message: v1Msg,
        signature: sigWithS_L,
      );
      expect(isValid, isFalse, reason: 'Signature with s == L must be rejected');

      // Also test S = 2^256 - 1 (all 0xFF)
      final sigWithS_Max = Uint8List(64);
      sigWithS_Max.setRange(0, 32, v1SigBytes.sublist(0, 32));
      sigWithS_Max.fillRange(32, 64, 0xFF);

      final isValidMax = Ed25519.verify(
        publicKey: officialPubKeyBytes,
        message: v1Msg,
        signature: sigWithS_Max,
      );
      expect(isValidMax, isFalse, reason: 'Signature with s == 2^256-1 must be rejected');
    });

    test('Adversarial 6: Canonical JSON tamper resistance - altering version, URL, or hash', () {
      final baseManifest = {
        'version': '0.5.25',
        'platform': 'windows',
        'windows': {
          'url': 'https://marcotv.wlj9919.top/movie/releases/v0.5.25.exe',
          'sha256': 'a' * 64,
          'size': 50000000,
        },
      };

      final canonical = AppUpdate.canonicalizeJson(baseManifest);

      // Verify tampering: modifying any field in baseManifest changes canonical JSON
      final tamperedVersion = Map<String, dynamic>.from(baseManifest)..['version'] = '0.5.26';
      expect(AppUpdate.canonicalizeJson(tamperedVersion), isNot(equals(canonical)));

      final tamperedUrl = {
        'version': '0.5.25',
        'platform': 'windows',
        'windows': {
          'url': 'https://evil-server.example/malware.exe',
          'sha256': 'a' * 64,
          'size': 50000000,
        },
      };
      expect(AppUpdate.canonicalizeJson(tamperedUrl), isNot(equals(canonical)));

      final injectedKey = Map<String, dynamic>.from(baseManifest)..['backdoor'] = true;
      expect(AppUpdate.canonicalizeJson(injectedKey), isNot(equals(canonical)));

      final trailingWhitespace = {
        'version': '0.5.25 ',
        'platform': 'windows',
        'windows': {
          'url': 'https://marcotv.wlj9919.top/movie/releases/v0.5.25.exe',
          'sha256': 'a' * 64,
          'size': 50000000,
        },
      };
      expect(AppUpdate.canonicalizeJson(trailingWhitespace), isNot(equals(canonical)));
    });

    test('Adversarial 7: Rogue Ed25519 private key signature rejected against official key', () {
      // Attacker generates their own Ed25519 keypair and signs a malicious update manifest
      // Vector 2 key represents the attacker's rogue key:
      final roguePubKeyHex = '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c';
      final rogueSig = fromHex(
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );
      final msg = Uint8List.fromList([0x72]);

      // Verified with rogue public key -> valid
      expect(
        Ed25519.verify(
          publicKey: fromHex(roguePubKeyHex),
          message: msg,
          signature: rogueSig,
        ),
        isTrue,
      );

      // Verified with official client public key -> MUST FAIL
      expect(
        Ed25519.verify(
          publicKey: officialPubKeyBytes,
          message: msg,
          signature: rogueSig,
        ),
        isFalse,
        reason: 'Rogue signed signature must fail when verified against official public key',
      );
    });

    test('Adversarial 8: AppUpdate.check skips rogue-signed mirror update manifest and tries fallback', () async {
      final rogueSigB64 = base64Encode(fromHex(
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      ));

      var calls = 0;
      final mockClient = MockClient((request) async {
        calls++;
        if (request.url.path.contains('updates/windows.json')) {
          return http.Response(
            jsonEncode({
              'versionName': '0.5.99',
              'notes': 'Rogue update',
              'signature': rogueSigB64,
              'windows': {
                'url': 'https://marcotv.wlj9919.top/movie/releases/MarcoMovie-0.5.99-windows-setup.exe',
                'sha256': '2' * 64,
                'size': 45678901,
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      await expectLater(
        AppUpdate.check(client: mockClient, platform: 'windows'),
        throwsA(isA<HttpException>()),
      );
      expect(calls, 2);
    });

    test('Adversarial 9: Mismatched public key length or malformed point fails safely', () {
      final badKeys = [
        Uint8List(0),
        Uint8List(16),
        Uint8List(31),
        Uint8List(33),
        Uint8List(64),
      ];

      for (final k in badKeys) {
        expect(
          Ed25519.verify(
            publicKey: k,
            message: v1Msg,
            signature: v1SigBytes,
          ),
          isFalse,
          reason: 'Public key with invalid length ${k.length} must return false without crash',
        );
      }
    });
  });
}

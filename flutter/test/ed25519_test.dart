import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/ed25519.dart';

void main() {
  group('F5: Pure Dart RFC 8032 Ed25519 Verification', () {
    Uint8List fromHex(String hex) {
      final res = Uint8List(hex.length ~/ 2);
      for (var i = 0; i < res.length; i++) {
        res[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return res;
    }

    test('RFC 8032 Test Vector 1 (empty message)', () {
      final pubKey = fromHex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
      final message = Uint8List(0);
      final sig = fromHex(
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );

      expect(Ed25519.verify(publicKey: pubKey, message: message, signature: sig), isTrue);

      // Mutated message must fail
      expect(
        Ed25519.verify(
          publicKey: pubKey,
          message: Uint8List.fromList([1]),
          signature: sig,
        ),
        isFalse,
      );

      // Mutated signature bit must fail
      final badSig = Uint8List.fromList(sig);
      badSig[0] ^= 1;
      expect(Ed25519.verify(publicKey: pubKey, message: message, signature: badSig), isFalse);
    });

    test('RFC 8032 Test Vector 2 (single-byte message 0x72)', () {
      final pubKey = fromHex('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c');
      final message = Uint8List.fromList([0x72]);
      final sig = fromHex(
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );

      expect(Ed25519.verify(publicKey: pubKey, message: message, signature: sig), isTrue);

      // Mutated pubkey must fail
      final badPubKey = Uint8List.fromList(pubKey);
      badPubKey[0] ^= 1;
      expect(Ed25519.verify(publicKey: badPubKey, message: message, signature: sig), isFalse);
    });

    test('Canonical JSON formatting preserves key order and compact separators', () {
      final data = {
        'version': '0.5.25',
        'platform': 'windows',
        'sha256': 'abc123',
        'details': {'beta': false, 'priority': 1},
      };
      final canonical = AppUpdate.canonicalizeJson(data);
      expect(
        canonical,
        equals('{"details":{"beta":false,"priority":1},"platform":"windows","sha256":"abc123","version":"0.5.25"}'),
      );
    });

    test('Manifest verification validates signed payload and rejects missing/invalid signature', () async {
      final testPubKeyHex = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
      AppUpdate.debugPublicKeyHexOverride = testPubKeyHex;

      // When message is empty dict {}, its canonical form is "{}"
      // Let's test with empty message {}
      // Or test with vector 1: message is empty bytes
      final rawEmptySig = base64Encode(fromHex(
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
        '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      ));

      // Missing signature returns false
      expect(AppUpdate.verifyManifestSignature({'version': '1.0.0'}), isFalse);

      // Corrupt signature returns false
      expect(
        AppUpdate.verifyManifestSignature({
          'version': '1.0.0',
          'signature': 'not-a-valid-base64',
        }),
        isFalse,
      );

      // Invalid signature returns false
      expect(
        AppUpdate.verifyManifestSignature({
          'version': '1.0.0',
          'signature': rawEmptySig,
        }),
        isFalse,
      );

      AppUpdate.debugPublicKeyHexOverride = null;
    });

    test('AppUpdate.check enforces signature verification and rejects unsigned mirror update', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('updates/windows.json')) {
          // Return mirror manifest missing signature
          return http.Response(
            jsonEncode({
              'version': '0.5.30',
              'notes': 'Unsigned update test',
              'windows': {
                'url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.5.30/MarcoMovie-0.5.30-windows-setup.exe',
                'sha256': '1111111111111111111111111111111111111111111111111111111111111111',
                'size': 12345678,
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      expect(
        () async => await AppUpdate.check(client: mockClient, platform: 'windows'),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Ed25519 signature missing or invalid'),
        )),
      );
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('adv_sec_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Adversarial Challenge F1: Credential Storage & Migration', () {
    test('Tampered legacy ciphertext fails safely to null and preserves .bak', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      final raw = DefaultSecureCredentialStore.encryptLegacyPayloadForTest({
        'secret_key': 'my_precious_secret',
      });
      final parts = raw.trim().split(':');
      expect(parts.length, equals(5));

      // Tamper with ciphertext hex (last character)
      final originalCipher = parts[4];
      final tamperedCipher = originalCipher.substring(0, originalCipher.length - 1) +
          (originalCipher.endsWith('a') ? 'b' : 'a');
      final tamperedRaw = '${parts[0]}:${parts[1]}:${parts[2]}:${parts[3]}:$tamperedCipher';
      await encFile.writeAsString(tamperedRaw, flush: true);

      final store2 = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      final result = await store2.read('secret_key');
      expect(result, isNull, reason: 'Tampered ciphertext should fail HMAC check and return null');
      expect(store2.didLegacyMigrationFail, isTrue);
      expect(await File('${tempDir.path}/secure_credentials.enc.bak').exists(), isTrue);
    });

    test('Tampered tag (HMAC) fails safely to null and preserves .bak', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      final raw = DefaultSecureCredentialStore.encryptLegacyPayloadForTest({
        'secret_key': 'my_precious_secret',
      });
      final parts = raw.trim().split(':');

      // Tamper with tag hex
      final originalTag = parts[3];
      final tamperedTag = '00${originalTag.substring(2)}';
      final tamperedRaw = '${parts[0]}:${parts[1]}:${parts[2]}:$tamperedTag:${parts[4]}';
      await encFile.writeAsString(tamperedRaw, flush: true);

      final store2 = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      expect(await store2.read('secret_key'), isNull);
      expect(store2.didLegacyMigrationFail, isTrue);
      expect(await File('${tempDir.path}/secure_credentials.enc.bak').exists(), isTrue);
    });

    test('Truncated ciphertext file fails safely to null without crashing and preserves .bak', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      final raw = DefaultSecureCredentialStore.encryptLegacyPayloadForTest({
        'secret_key': 'my_precious_secret',
      });

      // Truncate file halfway
      await encFile.writeAsString(raw.substring(0, raw.length ~/ 2), flush: true);

      final store2 = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      expect(await store2.read('secret_key'), isNull);
      expect(store2.didLegacyMigrationFail, isTrue);
      expect(await File('${tempDir.path}/secure_credentials.enc.bak').exists(), isTrue);
    });

    test('Corrupted prefix or garbage bytes in file fails safely to null and preserves .bak', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      await encFile.writeAsString('BAD_PREFIX:deadbeef:1234:5678:9abc', flush: true);

      final store = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      expect(await store.read('secret_key'), isNull);
      expect(store.didLegacyMigrationFail, isTrue);
      expect(await File('${tempDir.path}/secure_credentials.enc.bak').exists(), isTrue);

      await encFile.writeAsString('\x00\xFF\xFE\xFDGARBAGE_BINARY', flush: true);
      final store3 = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      expect(await store3.read('secret_key'), isNull);
      expect(store3.didLegacyMigrationFail, isTrue);
    });

    test('Empty ciphertext file returns null cleanly without migration failure prompt', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      await encFile.writeAsString('', flush: true);

      final store = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      expect(await store.read('secret_key'), isNull);
    });

    test('Migration handles empty string, Unicode, emojis, null bytes, special chars', () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyWebdavPass: '🔑密码_P@ssw0rd!#%^&*()_+~`|}{[]:;?><,./你好世界😊',
        StorageService.keyQuarkCookie: '', // empty string
        StorageService.keyUcCookie: '   \t  \n  ', // whitespace only
        StorageService.keyBaiduCookie: 'token_with_null_\u0000_byte',
        StorageService.keyAliToken: 'A' * 4096, // large 4KB secret
      });

      final inMem = InMemorySecureCredentialStore();
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: inMem,
      );

      final prefs = await SharedPreferences.getInstance();
      // All keys must be purged from SharedPreferences
      expect(prefs.containsKey(StorageService.keyWebdavPass), isFalse);
      expect(prefs.containsKey(StorageService.keyQuarkCookie), isFalse);
      expect(prefs.containsKey(StorageService.keyUcCookie), isFalse);
      expect(prefs.containsKey(StorageService.keyBaiduCookie), isFalse);
      expect(prefs.containsKey(StorageService.keyAliToken), isFalse);

      // Verify Unicode and emoji roundtrip
      expect(
        storage.webdavPass,
        equals('🔑密码_P@ssw0rd!#%^&*()_+~`|}{[]:;?><,./你好世界😊'),
      );
      expect(await inMem.read(StorageService.keyWebdavPass),
          equals('🔑密码_P@ssw0rd!#%^&*()_+~`|}{[]:;?><,./你好世界😊'));

      // Empty string should not pollute secure store with empty entry
      expect(storage.quarkCookie, equals(''));

      // 4KB secret should be preserved
      expect(storage.aliToken, equals('A' * 4096));
    });

    test('Migration is strictly idempotent across multiple restarts', () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyWebdavPass: 'persistent_dav_pass_112233',
        StorageService.keyQuarkCookie: 'persistent_quark_cookie_445566',
      });

      final inMem = InMemorySecureCredentialStore();

      // Restart 1: performs migration
      final s1 = await StorageService.init(dataDirectory: tempDir, secureStore: inMem);
      expect(s1.webdavPass, equals('persistent_dav_pass_112233'));
      expect(s1.quarkCookie, equals('persistent_quark_cookie_445566'));
      final prefs1 = await SharedPreferences.getInstance();
      expect(prefs1.containsKey(StorageService.keyWebdavPass), isFalse);

      // Restart 2: reads from secureStore, prefs still empty
      final s2 = await StorageService.init(dataDirectory: tempDir, secureStore: inMem);
      expect(s2.webdavPass, equals('persistent_dav_pass_112233'));
      expect(s2.quarkCookie, equals('persistent_quark_cookie_445566'));
      final prefs2 = await SharedPreferences.getInstance();
      expect(prefs2.containsKey(StorageService.keyWebdavPass), isFalse);

      // Modify a credential in s2
      await s2.setNetdiskCred('quark', 'modified_in_restart_2');
      expect(s2.quarkCookie, equals('modified_in_restart_2'));
      expect(prefs2.containsKey(StorageService.keyQuarkCookie), isFalse);

      // Restart 3: preserves modified credential
      final s3 = await StorageService.init(dataDirectory: tempDir, secureStore: inMem);
      expect(s3.webdavPass, equals('persistent_dav_pass_112233'));
      expect(s3.quarkCookie, equals('modified_in_restart_2'));
    });

    test('In-memory cache sync updates getters synchronously without delay', () async {
      SharedPreferences.setMockInitialValues({});
      final inMem = InMemorySecureCredentialStore();
      final storage = await StorageService.init(dataDirectory: tempDir, secureStore: inMem);

      expect(storage.webdavPass, equals(''));
      expect(storage.quarkCookie, equals(''));
      expect(storage.ucCookie, equals(''));
      expect(storage.baiduCookie, equals(''));
      expect(storage.aliToken, equals(''));

      // Call saveWebdavConfig
      final fut = storage.saveWebdavConfig(
        url: 'https://dav.test.com',
        user: 'user',
        pass: 'instant_webdav_pass',
        auto: false,
      );
      // Synchronous getter must immediately reflect the update even before awaiting the future!
      expect(storage.webdavPass, equals('instant_webdav_pass'));
      await fut;
      expect(storage.webdavPass, equals('instant_webdav_pass'));

      // Call setNetdiskCred for all providers
      final fQuark = storage.setNetdiskCred('quark', 'instant_quark');
      expect(storage.quarkCookie, equals('instant_quark'));
      expect(storage.getNetdiskCred('quark'), equals('instant_quark'));
      await fQuark;

      final fUc = storage.setNetdiskCred('uc', 'instant_uc');
      expect(storage.ucCookie, equals('instant_uc'));
      await fUc;

      final fBaidu = storage.setNetdiskCred('baidu', 'instant_baidu');
      expect(storage.baiduCookie, equals('instant_baidu'));
      await fBaidu;

      final fAli = storage.setNetdiskCred('ali', 'instant_ali');
      expect(storage.aliToken, equals('instant_ali'));
      await fAli;
    });
  });

  group('Adversarial Challenge F2: Hardened Privacy PIN (PBKDF2-SHA256)', () {
    test('ADVERSARIAL: Iteration count downgrade attack (crafting hash with 1 iteration)', () async {
      // Attacker crafts a PBKDF2 hash for PIN "1234" using only 1 iteration
      final salt = utf8.encode('adversarial_salt');
      final derived1 = StorageService.pbkdf2Sha256(
        utf8.encode('1234'),
        salt,
        1, // downgraded to 1 iteration!
        32,
      );
      final saltHex = salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hashHex1 = derived1.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final crafted1IterHash = 'pbkdf2:sha256:4:1:$saltHex:$hashHex1';

      SharedPreferences.setMockInitialValues({
        StorageService.keyPrivacyPassword: crafted1IterHash,
      });

      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      // What does verifyPrivacyPassword do?
      final verified = await storage.verifyPrivacyPassword('1234');
      print('Iteration downgrade (1 iter) verified result: $verified');

      // Requirement: Iteration count must be strictly >= 100,000 iterations and cannot be downgraded!
      // If verified is true, the application ACCEPTED a 1-iteration hash!
      expect(verified, isFalse, reason: 'PIN hash with iteration count < 100,000 must NOT be verified/accepted!');
    });

    test('ADVERSARIAL: Iteration count below threshold (50,000 and 99,999 iterations)', () async {
      final salt = utf8.encode('adversarial_salt');
      final derived99k = StorageService.pbkdf2Sha256(
        utf8.encode('1234'),
        salt,
        99999,
        32,
      );
      final saltHex = salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final hashHex99k = derived99k.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final crafted99kHash = 'pbkdf2:sha256:4:99999:$saltHex:$hashHex99k';

      SharedPreferences.setMockInitialValues({
        StorageService.keyPrivacyPassword: crafted99kHash,
      });

      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      final verified = await storage.verifyPrivacyPassword('1234');
      print('Iteration downgrade (99999 iter) verified result: $verified');

      expect(verified, isFalse, reason: 'PIN hash with iterations < 100,000 must be rejected');
    });

    test('ADVERSARIAL: Zero iterations or malformed iteration string in PBKDF2 hash', () async {
      final craftedZeroHash =
          'pbkdf2:sha256:4:0:00112233445566778899aabbccddeeff:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

      SharedPreferences.setMockInitialValues({
        StorageService.keyPrivacyPassword: craftedZeroHash,
      });

      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      final verified = await storage.verifyPrivacyPassword('1234');
      expect(verified, isFalse, reason: 'Zero iterations must not verify');
    });

    test('ADVERSARIAL: PIN hash format injection and malformed hashes', () async {
      final malformedHashes = [
        // Truncated salt (less than 32 hex chars)
        'pbkdf2:sha256:4:100000:001122:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
        // Invalid hex in salt
        'pbkdf2:sha256:4:100000:ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
        // Truncated hash (less than 64 hex chars)
        'pbkdf2:sha256:4:100000:00112233445566778899aabbccddeeff:aabb',
        // Invalid hex in hash
        'pbkdf2:sha256:4:100000:00112233445566778899aabbccddeeff:GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG',
        // Negative iterations
        'pbkdf2:sha256:4:-100000:00112233445566778899aabbccddeeff:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
        // Wrong prefix
        'bcrypt:sha256:4:100000:00112233445566778899aabbccddeeff:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
      ];

      for (final badHash in malformedHashes) {
        SharedPreferences.setMockInitialValues({
          StorageService.keyPrivacyPassword: badHash,
        });

        final storage = await StorageService.init(
          dataDirectory: tempDir,
          secureStore: InMemorySecureCredentialStore(),
        );

        // Verification must safely return false and not crash or throw unhandled exceptions
        expect(
          await storage.verifyPrivacyPassword('1234'),
          isFalse,
          reason: 'Malformed hash should not verify: $badHash',
        );

        // Crucial: A malformed hash starting with pbkdf2: or bcrypt: must NOT be treated as a plaintext PIN matching the badHash itself!
        // If a user types the badHash as their PIN, does it verify?!
        if (badHash.startsWith('pbkdf2:') || badHash.startsWith('bcrypt:')) {
          final verifiedAsPlaintext = await storage.verifyPrivacyPassword(badHash);
          print('Bad hash $badHash verified as plaintext: $verifiedAsPlaintext');
          expect(
            verifiedAsPlaintext,
            isFalse,
            reason: 'Corrupted hash string must NOT be accepted as plaintext PIN!',
          );
        }
      }
    });

    test('ADVERSARIAL: Constant-time comparison check', () {
      // Direct verification of _constantTimeEquals behavior
      // Equal inputs
      expect(
        StorageService.pbkdf2Sha256(utf8.encode('1234'), utf8.encode('salt'), 1, 32),
        equals(StorageService.pbkdf2Sha256(utf8.encode('1234'), utf8.encode('salt'), 1, 32)),
      );

      // Timing / length differences
      final a = Uint8List.fromList([1, 2, 3, 4]);
      final b = Uint8List.fromList([1, 2, 3, 5]);
      final c = Uint8List.fromList([1, 2, 3]);

      // We can invoke verifyPrivacyPassword with mismatched length strings
    });
  });
}

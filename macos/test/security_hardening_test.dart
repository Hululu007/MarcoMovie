import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:marco_movie/core/lan_sync_server.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/cloud_sync_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('sec_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('F1: Platform-Secure Credential Storage & Migration', () {
    test('DefaultSecureCredentialStore persists via flutter_secure_storage and migrates legacy .enc file', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      await encFile.writeAsString(
        DefaultSecureCredentialStore.encryptLegacyPayloadForTest({
          'legacy_key': 'migrated_secret_value',
        }),
        flush: true,
      );

      final store = DefaultSecureCredentialStore(dataDirectory: tempDir);
      expect(await store.read('legacy_key'), equals('migrated_secret_value'));
      expect(await encFile.exists(), isFalse);

      await store.write('test_key', 'super_secret_value_123');
      final readBack = await store.read('test_key');
      expect(readBack, equals('super_secret_value_123'));
      expect(await encFile.exists(), isFalse);

      // Verify fresh instance reads persisted secret from flutter_secure_storage
      final storeReloaded = DefaultSecureCredentialStore(dataDirectory: tempDir);
      expect(
        await storeReloaded.read('test_key'),
        equals('super_secret_value_123'),
      );

      // Verify deletion
      await storeReloaded.delete('test_key');
      expect(await storeReloaded.read('test_key'), isNull);
    });

    test('Startup migration migrates plaintext credentials from SharedPreferences to secure store', () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyWebdavPass: 'legacy_dav_pass_9988',
        StorageService.keyQuarkCookie: 'legacy_quark_cookie_abc',
        StorageService.keyUcCookie: 'legacy_uc_cookie_def',
        StorageService.keyBaiduCookie: 'legacy_baidu_cookie_xyz',
        StorageService.keyAliToken: 'legacy_ali_token_123',
        StorageService.keyWebdavUrl: 'https://dav.example/',
        StorageService.keyWebdavUser: 'user@example.com',
      });

      final inMemorySecure = InMemorySecureCredentialStore();
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: inMemorySecure,
      );

      // Plaintext must be cleared from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(StorageService.keyWebdavPass), isFalse);
      expect(prefs.containsKey(StorageService.keyQuarkCookie), isFalse);
      expect(prefs.containsKey(StorageService.keyUcCookie), isFalse);
      expect(prefs.containsKey(StorageService.keyBaiduCookie), isFalse);
      expect(prefs.containsKey(StorageService.keyAliToken), isFalse);

      // Non-sensitive preferences remain intact
      expect(prefs.getString(StorageService.keyWebdavUrl), equals('https://dav.example/'));
      expect(prefs.getString(StorageService.keyWebdavUser), equals('user@example.com'));

      // Secure store has received the secrets
      expect(await inMemorySecure.read(StorageService.keyWebdavPass), equals('legacy_dav_pass_9988'));
      expect(await inMemorySecure.read(StorageService.keyQuarkCookie), equals('legacy_quark_cookie_abc'));
      expect(await inMemorySecure.read(StorageService.keyUcCookie), equals('legacy_uc_cookie_def'));
      expect(await inMemorySecure.read(StorageService.keyBaiduCookie), equals('legacy_baidu_cookie_xyz'));
      expect(await inMemorySecure.read(StorageService.keyAliToken), equals('legacy_ali_token_123'));

      // Synchronous getters return the credentials
      expect(storage.webdavPass, equals('legacy_dav_pass_9988'));
      expect(storage.quarkCookie, equals('legacy_quark_cookie_abc'));
      expect(storage.ucCookie, equals('legacy_uc_cookie_def'));
      expect(storage.baiduCookie, equals('legacy_baidu_cookie_xyz'));
      expect(storage.aliToken, equals('legacy_ali_token_123'));
      expect(storage.getNetdiskCred('quark'), equals('legacy_quark_cookie_abc'));

      // Writing new credentials persists to secure store and keeps SharedPreferences clear
      await storage.saveWebdavConfig(
        url: 'https://dav.example/',
        user: 'user@example.com',
        pass: 'new_dav_secret_456',
        auto: true,
      );
      expect(storage.webdavPass, equals('new_dav_secret_456'));
      expect(await inMemorySecure.read(StorageService.keyWebdavPass), equals('new_dav_secret_456'));
      expect(prefs.containsKey(StorageService.keyWebdavPass), isFalse);

      await storage.setNetdiskCred('quark', 'updated_quark_cookie_999');
      expect(storage.quarkCookie, equals('updated_quark_cookie_999'));
      expect(await inMemorySecure.read(StorageService.keyQuarkCookie), equals('updated_quark_cookie_999'));
      expect(prefs.containsKey(StorageService.keyQuarkCookie), isFalse);
    });
  });

  group('F2: Hardened Privacy PIN (PBKDF2-SHA256)', () {
    test('PBKDF2 test vector matches standard RFC/Python derivation', () {
      final derived = StorageService.pbkdf2Sha256(
        utf8.encode('1234'),
        utf8.encode('saltsaltsaltsalt'),
        100000,
        32,
      );
      final hex = derived.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hex, equals('5cf4a02537fc3a2c1e3e55d35709f68310c4581d849251daa8a8a23320f51536'));
    });

    test('setPrivacyPassword creates salted PBKDF2 hash with 100000 iterations', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      await storage.setPrivacyPassword('5678');
      final saved = storage.privacyPassword;
      expect(saved, startsWith('pbkdf2:sha256:4:100000:'));

      final parts = saved.split(':');
      expect(parts.length, equals(6));
      expect(parts[2], equals('4')); // length
      expect(parts[3], equals('100000')); // iterations
      expect(parts[4].length, equals(32)); // 16-byte hex salt
      expect(parts[5].length, equals(64)); // 32-byte hex derived key

      expect(storage.privacyPasswordLength, equals(4));
      expect(await storage.verifyPrivacyPassword('5678'), isTrue);
      expect(await storage.verifyPrivacyPassword('0000'), isFalse);
      expect(await storage.verifyPrivacyPassword('56789'), isFalse);
    });

    test('Legacy SHA-256 PIN hash verifies and automatically upgrades to PBKDF2', () async {
      final legacyPin = '2468';
      final legacyHash = sha256.convert(utf8.encode('mm_pin_v1:$legacyPin')).toString();
      final legacyStored = 'sha256:${legacyPin.length}:$legacyHash';

      SharedPreferences.setMockInitialValues({
        StorageService.keyPrivacyPassword: legacyStored,
      });

      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      expect(storage.privacyPassword, equals(legacyStored));
      expect(storage.privacyPasswordLength, equals(4));

      // Wrong PIN fails and does not upgrade
      expect(await storage.verifyPrivacyPassword('1111'), isFalse);
      expect(storage.privacyPassword, equals(legacyStored));

      // Correct PIN verifies and triggers automatic upgrade
      expect(await storage.verifyPrivacyPassword('2468'), isTrue);
      await pumpEventQueue();

      expect(storage.privacyPassword, startsWith('pbkdf2:sha256:4:100000:'));
      expect(await storage.verifyPrivacyPassword('2468'), isTrue);
    });

    test('Ancient plaintext PIN verifies and automatically upgrades to PBKDF2', () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyPrivacyPassword: '9999',
      });

      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      expect(storage.privacyPasswordLength, equals(4));
      expect(await storage.verifyPrivacyPassword('1234'), isFalse);
      expect(await storage.verifyPrivacyPassword('9999'), isTrue);
      await pumpEventQueue();

      expect(storage.privacyPassword, startsWith('pbkdf2:sha256:4:100000:'));
      expect(await storage.verifyPrivacyPassword('9999'), isTrue);
    });
  });

  group('F3: Cleartext HTTP WebDAV Warning Dialog', () {
    test('isCleartextHttpWithPassword triggers warning for cleartext http with password', () {
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('http://dav.example', 'secret'), isTrue);
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('HTTP://DAV.EXAMPLE', 'secret'), isTrue);
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('http://192.168.1.10:5005/dav/', 'secret'), isTrue);
    });

    test('isCleartextHttpWithPassword ignores HTTPS, empty password, or scheme-less URLs', () {
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('https://dav.example', 'secret'), isFalse);
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('http://dav.example', ''), isFalse);
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('dav.example', 'secret'), isFalse);
      expect(CloudSyncSettingsPanel.isCleartextHttpWithPassword('', 'secret'), isFalse);
    });
  });

  group('F8: LAN Sync Server Socket Closure & Expiration', () {
    test('rejects expired session with HTTP 410 Gone and closes socket', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      final server = await LanSyncServer.start(
        storage,
        ttl: const Duration(milliseconds: -100),
        bindAddress: InternetAddress.loopbackIPv4,
      );

      expect(server.isExpired, isTrue);

      final resp = await http.get(Uri.parse(server.addressForHost('127.0.0.1')));
      expect(resp.statusCode, equals(HttpStatus.gone));
      expect(resp.body, contains('已过期'));

      await pumpEventQueue();
      expect(server.isClosed, isTrue);

      expect(
        () => http.get(Uri.parse(server.addressForHost('127.0.0.1'))),
        throwsA(anyOf(isA<SocketException>(), isA<http.ClientException>())),
      );
    });

    test('active expiration timer automatically closes socket after TTL', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
      );

      final server = await LanSyncServer.start(
        storage,
        ttl: const Duration(milliseconds: 100),
        bindAddress: InternetAddress.loopbackIPv4,
      );

      expect(server.isClosed, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.isClosed, isTrue);

      expect(
        () => http.get(Uri.parse(server.addressForHost('127.0.0.1'))),
        throwsA(anyOf(isA<SocketException>(), isA<http.ClientException>())),
      );
    });

    test('isAllowedPeerAddress correctly filters LAN vs WAN addresses', () {
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('127.0.0.1')), isTrue);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('::1')), isTrue);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('192.168.1.1')), isTrue);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('10.0.0.1')), isTrue);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('172.16.0.1')), isTrue);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('100.64.0.1')), isTrue);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('8.8.8.8')), isFalse);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('1.1.1.1')), isFalse);
      expect(LanSyncServer.isAllowedPeerAddress(InternetAddress('203.0.113.1')), isFalse);
    });
  });
}

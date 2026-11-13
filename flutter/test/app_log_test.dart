import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/app_log.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppLog 6-Pass Redaction Tests', () {
    test('Pass 1: Redacts Authorization Bearer and Basic headers', () {
      const input = 'Headers: {Authorization: Bearer secret_token_xyz, Accept: */*}';
      final redacted = AppLog.redact(input);
      expect(redacted, contains('Authorization: Bearer [REDACTED]'));
      expect(redacted, isNot(contains('secret_token_xyz')));

      const basicInput = 'Authorization: Basic dXNlcjpwYXNz';
      expect(AppLog.redact(basicInput), contains('Authorization: Basic [REDACTED]'));
    });

    test('Pass 2: Redacts Cookie and Set-Cookie headers', () {
      const input = 'Cookie: session_id=12345; user=marco\nSet-Cookie: token=abc; path=/';
      final redacted = AppLog.redact(input);
      expect(redacted, contains('Cookie: [REDACTED]'));
      expect(redacted, contains('Set-Cookie: [REDACTED]'));
      expect(redacted, isNot(contains('12345')));
      expect(redacted, isNot(contains('abc')));
    });

    test('Pass 3: Redacts embedded HTTP userinfo credentials', () {
      const input = 'Connecting to https://user:super_secret_pw@dav.jianguoyun.com/dav/';
      final redacted = AppLog.redact(input);
      expect(redacted, contains('https://user:[REDACTED]@dav.jianguoyun.com/dav/'));
      expect(redacted, isNot(contains('super_secret_pw')));
    });

    test('Pass 4: Redacts sensitive URL query parameters while preserving regular params', () {
      const input =
          'GET https://site.example/play?id=9988&token=myToken123&sign=xyz789&key=myKey&page=2&secret=s456&auth=a1&session=sess789';
      final redacted = AppLog.redact(input);
      expect(redacted, contains('id=9988'));
      expect(redacted, contains('token=[REDACTED]'));
      expect(redacted, contains('sign=[REDACTED]'));
      expect(redacted, contains('key=[REDACTED]'));
      expect(redacted, contains('secret=[REDACTED]'));
      expect(redacted, contains('auth=[REDACTED]'));
      expect(redacted, contains('session=[REDACTED]'));
      expect(redacted, contains('page=2'));
      expect(redacted, isNot(contains('myToken123')));
      expect(redacted, isNot(contains('xyz789')));
      expect(redacted, isNot(contains('myKey')));
      expect(redacted, isNot(contains('s456')));
    });

    test('Pass 5: Redacts JSON credential keys', () {
      const input =
          '{"url": "https://foo.test", "password": "secret_pass", "apiKey": "k123", "pin": "9999", "accessToken": "tok1", "normal": "val"}';
      final redacted = AppLog.redact(input);
      expect(redacted, contains('"password": "[REDACTED]"'));
      expect(redacted, contains('"apiKey": "[REDACTED]"'));
      expect(redacted, contains('"pin": "[REDACTED]"'));
      expect(redacted, contains('"accessToken": "[REDACTED]"'));
      expect(redacted, contains('"normal": "val"'));
      expect(redacted, isNot(contains('secret_pass')));
      expect(redacted, isNot(contains('k123')));
      expect(redacted, isNot(contains('9999')));
    });

    test('Pass 6: Redacts key-value credential lines', () {
      const input = 'Credentials:\npassword: mysecretpassword\napiKey: secretkey123';
      final redacted = AppLog.redact(input);
      expect(redacted, contains('password: [REDACTED]'));
      expect(redacted, contains('apiKey: [REDACTED]'));
      expect(redacted, isNot(contains('mysecretpassword')));
      expect(redacted, isNot(contains('secretkey123')));
    });
  });

  group('AppLog Circular Buffer & Rotation Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('app_log_test_');
      AppLog.init(logDirectory: tempDir);
      AppLog.instance.clear();
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Writes errors to log file and reloads exported logs', () async {
      final logger = AppLog.instance;
      logger.logError('First error message', source: 'Test');
      logger.logError('Second error message', source: 'Test');

      final logs = await logger.exportLogsFormatted();
      expect(logs, contains('First error message'));
      expect(logs, contains('Second error message'));

      final active = File('${tempDir.path}/error.log');
      expect(active.existsSync(), isTrue);
    });

    test('Rotates file when exceeding 512KB and caps total disk size to <= 1MB', () async {
      final logger = AppLog.instance;
      // Write ~1.2 MB of data across 60 entries (each ~20KB)
      final largeChunk = 'A' * 20000;
      for (int i = 0; i < 60; i++) {
        logger.logError('Log entry $i: $largeChunk', source: 'Stress');
      }

      final active = File('${tempDir.path}/error.log');
      final old = File('${tempDir.path}/error.log.old');
      expect(active.existsSync(), isTrue);
      expect(old.existsSync(), isTrue);

      final totalDiskBytes = active.lengthSync() + old.lengthSync();
      // Total disk size strictly <= maxTotalBytes (1MB) + leeway for 1 entry
      expect(totalDiskBytes, lessThanOrEqualTo(AppLog.maxTotalBytes + 35000));

      final exported = await logger.exportLogsFormatted();
      expect(exported, contains('Stress'));
      expect(exported, contains('Log entry 59'));
    });
  });

  group('Diagnostics Bundle Generation Tests', () {
    test('Generates bundle with system info and redacted logs', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      AppLog.instance.logError(
        'Connection failed to https://api.test/v1?token=supersecret&id=123',
        source: 'Worker',
      );

      final bundle = await AppLog.generateDiagnosticsBundle(
        storage: storage,
        currentAppVersion: '0.5.25',
        platformOverride: 'windows',
        osVersionOverride: 'Windows 11 Test',
        localeOverride: 'zh_CN',
      );

      expect(bundle, contains('MARCO MOVIE DIAGNOSTICS BUNDLE'));
      expect(bundle, contains('App: Marco Movie v0.5.25'));
      expect(bundle, contains('Platform: windows (Windows 11 Test)'));
      expect(bundle, contains('Locale: zh_CN'));
      expect(bundle, contains('token=[REDACTED]'));
      expect(bundle, contains('id=123'));
      expect(bundle, isNot(contains('supersecret')));
    });
  });
}

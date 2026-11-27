import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('非鸿蒙共享备份路径应能恢复旧版本已导出的文件', () async {
    OhosRuntime.debugIsOhosOverride = false;
    addTearDown(OhosRuntime.resetForTesting);
    SharedPreferences.setMockInitialValues({});
    final source = await StorageService.init();
    final ext = 'x' * (4 * 1024 * 1024 + 1024);
    final entries = List.generate(8, (i) {
      final uri = 'https://fixture.invalid/$i';
      final cfg = jsonEncode({'sites': [
        {'key': 'site_$i', 'name': '站 $i', 'api': uri, 'type': 1, 'ext': ext}
      ]});
      return SubscriptionEntry(id: 'sub_$i', name: '订阅 $i', url: uri, rawContent: cfg);
    });
    await source.saveSubscriptions(entries);
    final payload = source.exportBackupJson();
    final bytes = utf8.encode(payload).length;
    expect(bytes, greaterThan(32 * 1024 * 1024));
    print('exported UTF-8 bytes=$bytes');
    SharedPreferences.setMockInitialValues({});
    final destination = await StorageService.init();
    await destination.importBackupJson(payload);
    expect(destination.getSubscriptions().length, entries.length);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

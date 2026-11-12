import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mm_storage_migration_test_');
    StorageService.debugOverrideDataDirectory = tempDir;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    StorageService.debugOverrideDataDirectory = null;
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  group('D4: Storage Migration & Atomic JSON Files', () {
    test('atomic write persists valid JSON and leaves no temporary files', () async {
      final storage = await StorageService.init();
      final subs = [
        const SubscriptionEntry(
          id: 'sub_1',
          name: '订阅1',
          rawContent: '{"sites":[{"key":"s1","name":"站点1","type":1,"api":"https://s1.example/vod"}]}',
        ),
      ];

      await storage.saveSubscriptions(subs);

      final subFile = File('${tempDir.path}/subscriptions.json');
      expect(await subFile.exists(), isTrue);

      final content = await subFile.readAsString();
      final decoded = jsonDecode(content) as List;
      expect(decoded.length, 1);
      expect(decoded.first['id'], 'sub_1');

      // Verify no leftover .tmp files
      final tmpFiles = tempDir
          .listSync()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(tmpFiles, isEmpty);
    });

    test('startup migration moves subscriptions from SharedPreferences to subscriptions.json', () async {
      const rawSubs = [
        {
          'id': 'legacy_sub_1',
          'name': '迁移源',
          'url': 'https://legacy.example/sub.json',
          'rawContent': '{"sites":[]}',
          'enabled': true,
        }
      ];

      SharedPreferences.setMockInitialValues({
        StorageService.keySubscriptions: jsonEncode(rawSubs),
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(StorageService.keySubscriptions), isTrue);

      final storage = await StorageService.init();

      // Subscriptions file exists and has content
      final subFile = File('${tempDir.path}/subscriptions.json');
      expect(await subFile.exists(), isTrue);
      expect(storage.getSubscriptions().first.id, 'legacy_sub_1');

      // SharedPreferences key was removed upon migration
      expect(prefs.containsKey(StorageService.keySubscriptions), isFalse);
    });

    test('startup migration synthesizes legacy_primary from config_raw_json', () async {
      const legacyRaw = '{"sites":[{"key":"legacy","name":"旧版源","type":1,"api":"https://legacy.example/api"}]}';
      SharedPreferences.setMockInitialValues({
        StorageService.keyRawConfig: legacyRaw,
        StorageService.keyOrigin: 'https://legacy.example/index.json',
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(StorageService.keyRawConfig), isTrue);

      final storage = await StorageService.init();

      final subFile = File('${tempDir.path}/subscriptions.json');
      expect(await subFile.exists(), isTrue);

      final subs = storage.getSubscriptions();
      expect(subs.length, 1);
      expect(subs.first.id, 'legacy_primary');
      expect(subs.first.url, 'https://legacy.example/index.json');

      expect(prefs.containsKey(StorageService.keyRawConfig), isFalse);
    });

    test('startup migration moves watch_history from SharedPreferences to watch_history.json', () async {
      final rawHist = [
        {
          'site': 'site1',
          'id': 'vid1',
          'title': '测试影片',
          'position': 50000,
          'duration': 1200000,
          'updated': 2000,
        }
      ];

      SharedPreferences.setMockInitialValues({
        StorageService.keyWatchHistory: jsonEncode(rawHist),
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(StorageService.keyWatchHistory), isTrue);

      final storage = await StorageService.init();

      final histFile = File('${tempDir.path}/watch_history.json');
      expect(await histFile.exists(), isTrue);

      final hist = storage.getWatchHistory();
      expect(hist.length, 1);
      expect(hist.first.id, 'vid1');

      expect(prefs.containsKey(StorageService.keyWatchHistory), isFalse);
    });

    test('corrupted watch_history.json is quarantined to watch_history_corrupt_<ts>.json and write-locked', () async {
      final histFile = File('${tempDir.path}/watch_history.json');
      await histFile.writeAsString('{"corrupted": true, [malformed');

      final storage = await StorageService.init();

      expect(storage.isHistoryCorrupted, isFalse);
      final hist = storage.getWatchHistory();
      expect(hist, isEmpty);

      // Quarantined and locked
      expect(storage.isHistoryCorrupted, isTrue);
      expect(storage.historyCorruptionNotifier.value, isTrue);

      final corruptFiles = tempDir
          .listSync()
          .where((f) => f.path.contains('watch_history_corrupt_'))
          .toList();
      expect(corruptFiles, isNotEmpty);

      // Destructive overwrites are prevented
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'v_ignore',
          title: '不应写入的条目',
        ),
      );

      final histAfter = storage.getWatchHistory();
      expect(histAfter, isEmpty);
    });

    test('custom dataDirectory injection works hermetically', () async {
      StorageService.debugOverrideDataDirectory = null;
      final customSubDir = await Directory.systemTemp.createTemp('mm_custom_data_');
      addTearDown(() => customSubDir.delete(recursive: true));

      final storage = await StorageService.init(dataDirectory: customSubDir);
      await storage.saveSubscriptions([
        const SubscriptionEntry(id: 'custom_1', name: '独立源', rawContent: '{}'),
      ]);

      expect(await File('${customSubDir.path}/subscriptions.json').exists(), isTrue);
      expect(await File('${tempDir.path}/subscriptions.json').exists(), isFalse);
    });
  });

  group('D4: Playback Progress Write Throttling', () {
    test('in-memory state and revision notifier update in real-time on every progress tick', () async {
      final storage = await StorageService.init();
      var revisionNotified = 0;
      storage.watchHistoryRevision.addListener(() {
        revisionNotified++;
      });

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid1',
          title: '测试片1',
          position: 10000,
          duration: 60000,
          updated: 1000,
        ),
        immediate: false,
      );

      expect(storage.getWatchHistory().first.position, 10000);
      expect(revisionNotified, 1);

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid1',
          title: '测试片1',
          position: 15000,
          duration: 60000,
          updated: 2000,
        ),
        immediate: false,
      );

      expect(storage.getWatchHistory().first.position, 15000);
      expect(revisionNotified, 2);
    });

    test('continuous playback disk writes are throttled to at most once per 30 seconds', () async {
      final storage = await StorageService.init();
      final histFile = File('${tempDir.path}/watch_history.json');

      // First tick (time 0) writes to disk
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid1',
          title: '连续播放测试',
          position: 1000,
          duration: 100000,
          updated: 1000,
        ),
        immediate: false,
      );

      expect(await histFile.exists(), isTrue);
      final firstDiskContent = await histFile.readAsString();
      expect(firstDiskContent.contains('1000'), isTrue);

      // Second tick after 5 seconds: in-memory updates, but disk is throttled
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid1',
          title: '连续播放测试',
          position: 5000,
          duration: 100000,
          updated: 5000,
        ),
        immediate: false,
      );

      // In-memory has 5000
      expect(storage.getWatchHistory().first.position, 5000);

      // Disk still has old throttled content (1000)
      final secondDiskContent = await histFile.readAsString();
      expect(secondDiskContent.contains('"position":5000'), isFalse);

      // Calling flushPendingHistory() immediately commits pending progress to disk
      await storage.flushPendingHistory();
      final flushedDiskContent = await histFile.readAsString();
      expect(flushedDiskContent.contains('"position":5000'), isTrue);
    });

    test('immediate: true flushes pending progress immediately to disk', () async {
      final storage = await StorageService.init();
      final histFile = File('${tempDir.path}/watch_history.json');

      // Initial tick
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid1',
          title: '即时写入测试',
          position: 1000,
          duration: 100000,
          updated: 1000,
        ),
        immediate: false,
      );

      // Paused / completed with immediate: true
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid1',
          title: '即时写入测试',
          position: 25000,
          duration: 100000,
          updated: 25000,
        ),
        immediate: true,
      );

      final diskContent = await histFile.readAsString();
      expect(diskContent.contains('"position":25000'), isTrue);
    });
  });
}

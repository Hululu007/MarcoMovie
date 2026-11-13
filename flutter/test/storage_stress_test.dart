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
    tempDir = await Directory.systemTemp.createTemp('mm_storage_stress_test_');
    StorageService.debugOverrideDataDirectory = tempDir;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    StorageService.debugOverrideDataDirectory = null;
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException catch (e) {
        // Ignore transient Windows temp cleanup lock in teardown.
        expect(e, isA<FileSystemException>());
        expect(e.message, isNotEmpty);
      }
    }
  });

  group('Stress 1: Atomic Write Robustness', () {
    test('existing leftover .tmp files do not impede atomic writes', () async {
      final storage = await StorageService.init();

      // Pre-seed multiple leftover .tmp files
      final leftover1 = File('${tempDir.path}/subscriptions.json.tmp');
      await leftover1.writeAsString('stale tmp content 1');
      final leftover2 = File('${tempDir.path}/subscriptions.json.9999999999.tmp');
      await leftover2.writeAsString('stale tmp content 2');
      final leftover3 = File('${tempDir.path}/watch_history.json.tmp');
      await leftover3.writeAsString('stale tmp content 3');

      // Now perform writes
      final subs = [
        const SubscriptionEntry(
          id: 'sub_atomic_1',
          name: '原子测试源',
          rawContent: '{"sites":[{"key":"s1","name":"站点1","type":1,"api":"https://s1.example"}]}',
        ),
      ];
      await storage.saveSubscriptions(subs);

      const histEntry = WatchHistoryEntry(
        site: 's1',
        id: 'vid1',
        title: '测试片',
        position: 1234,
      );
      await storage.upsertWatchHistory(histEntry, immediate: true);

      // Verify destination files exist and are readable
      final subFile = File('${tempDir.path}/subscriptions.json');
      final histFile = File('${tempDir.path}/watch_history.json');
      expect(await subFile.exists(), isTrue);
      expect(await histFile.exists(), isTrue);

      final decodedSubs = jsonDecode(await subFile.readAsString()) as List;
      expect(decodedSubs.first['id'], 'sub_atomic_1');

      final decodedHist = jsonDecode(await histFile.readAsString()) as List;
      expect(decodedHist.first['id'], 'vid1');
    });

    test('rapid consecutive overwrites cleanly update destination file', () async {
      final storage = await StorageService.init();
      final subFile = File('${tempDir.path}/subscriptions.json');

      // Overwrite 20 times in sequence
      for (int i = 0; i < 20; i++) {
        final subs = [
          SubscriptionEntry(
            id: 'sub_$i',
            name: '源_$i',
            rawContent: '{"count": $i}',
          ),
        ];
        await storage.saveSubscriptions(subs);

        final content = await subFile.readAsString();
        final decoded = jsonDecode(content) as List;
        expect(decoded.first['id'], 'sub_$i');
      }

      // Check that no transient .tmp files remain created during writes
      final activeTmpFiles = tempDir
          .listSync()
          .where((f) => f.path.contains('.tmp') && !f.path.contains('stale'))
          .toList();
      expect(activeTmpFiles, isEmpty);
    });

    test('large subscription atomic write (>1MB) succeeds and leaves no tmp files', () async {
      final storage = await StorageService.init();
      final subFile = File('${tempDir.path}/subscriptions.json');

      // Generate ~1.5MB of subscription raw payload
      final largePayload = List.generate(
        150,
        (i) => '{"key":"site_$i","name":"站点_$i","api":"https://site.example/$i","data":"${"A" * 10000}"}',
      ).join(',');
      final subs = [
        SubscriptionEntry(
          id: 'sub_large',
          name: '超大订阅源',
          rawContent: '{"sites":[$largePayload]}',
        ),
      ];

      await storage.saveSubscriptions(subs);

      expect(await subFile.exists(), isTrue);
      final writtenContent = await subFile.readAsString();
      expect(writtenContent.length, greaterThan(1000000));

      final activeTmpFiles = tempDir
          .listSync()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(activeTmpFiles, isEmpty);
    });
  });

  group('Stress 2: Crash / Corruption Quarantine', () {
    test('malformed JSON syntax is quarantined to watch_history_corrupt_<ts>.json and write-locked', () async {
      const corruptContent = '{"invalid_json": true, [malformed';
      final histFile = File('${tempDir.path}/watch_history.json');
      await histFile.writeAsString(corruptContent);

      final storage = await StorageService.init();

      expect(storage.isHistoryCorrupted, isFalse);
      final entries = storage.getWatchHistory();
      expect(entries, isEmpty);

      // Quarantine state activated
      expect(storage.isHistoryCorrupted, isTrue);
      expect(storage.historyCorruptionNotifier.value, isTrue);

      // Quarantined file check
      final corruptFiles = tempDir
          .listSync()
          .where((f) => f.path.contains('watch_history_corrupt_'))
          .toList();
      expect(corruptFiles.length, 1);
      final quarantinedText = await File(corruptFiles.first.path).readAsString();
      expect(quarantinedText, corruptContent);

      // Attempting upsert must be a no-op (write-locked to protect corrupt file)
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(site: 's1', id: 'v1', title: '应该被忽略'),
        immediate: true,
      );

      // History remains empty and file was not overwritten
      expect(storage.getWatchHistory(), isEmpty);
      expect(await histFile.readAsString(), corruptContent);

      // Clearing history resets corruption lock and re-enables writes
      await storage.clearWatchHistory();
      expect(storage.isHistoryCorrupted, isFalse);
      expect(storage.historyCorruptionNotifier.value, isFalse);

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(site: 's1', id: 'v_new', title: '新片'),
        immediate: true,
      );
      expect(storage.getWatchHistory().length, 1);
      expect(storage.getWatchHistory().first.id, 'v_new');
    });

    test('non-array JSON object is quarantined as corruption', () async {
      const corruptObject = '{"site": "s1", "id": "v1", "error": "not an array"}';
      final histFile = File('${tempDir.path}/watch_history.json');
      await histFile.writeAsString(corruptObject);

      final storage = await StorageService.init();
      final entries = storage.getWatchHistory();
      expect(entries, isEmpty);

      expect(storage.isHistoryCorrupted, isTrue);
      expect(storage.historyCorruptionNotifier.value, isTrue);

      final corruptFiles = tempDir
          .listSync()
          .where((f) => f.path.contains('watch_history_corrupt_'))
          .toList();
      expect(corruptFiles, isNotEmpty);
      expect(await File(corruptFiles.first.path).readAsString(), corruptObject);
    });

    test('empty (0 bytes) or whitespace-only file is safely handled without false corruption', () async {
      final histFile = File('${tempDir.path}/watch_history.json');
      await histFile.writeAsString('   \n  ');

      final storage = await StorageService.init();
      final entries = storage.getWatchHistory();
      expect(entries, isEmpty);

      // 0 bytes or whitespace should NOT be considered corrupted
      expect(storage.isHistoryCorrupted, isFalse);
      expect(storage.historyCorruptionNotifier.value, isFalse);

      // Writes work normally
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(site: 's1', id: 'v1', title: '正常影片'),
        immediate: true,
      );
      expect(storage.getWatchHistory().length, 1);
    });

    test('non-UTF8 corrupted bytes behavior test', () async {
      final histFile = File('${tempDir.path}/watch_history.json');
      // Write non-UTF-8 bytes [0xFF, 0xFE, 0xFD]
      await histFile.writeAsBytes([0xFF, 0xFE, 0xFD, 0x00, 0xAA]);

      final storage = await StorageService.init();
      final entries = storage.getWatchHistory();
      expect(entries, isEmpty);

      // Verify whether it quarantined:
      final corruptFiles = tempDir
          .listSync()
          .where((f) => f.path.contains('watch_history_corrupt_'))
          .toList();

      // Now attempt an upsert:
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(site: 's1', id: 'vid_overwrite', title: '覆盖写入'),
        immediate: true,
      );

      // Check if original corrupted file was preserved byte-for-byte without any destructive overwrite:
      final remaining = await histFile.readAsBytes();
      
      expect(storage.isHistoryCorrupted, isTrue, reason: 'Non-UTF8 corrupted file must set isHistoryCorrupted=true');
      expect(corruptFiles, isNotEmpty, reason: 'Non-UTF8 corrupted file must be quarantined to watch_history_corrupt_<ts>.json');
      expect(remaining, equals([0xFF, 0xFE, 0xFD, 0x00, 0xAA]), reason: 'Non-UTF8 corrupted file must not be overwritten destructively');
    });

    test('corrupted watch_history in SharedPreferences triggers corruption quarantine', () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyWatchHistory: '{invalid json prefs',
      });

      final storage = await StorageService.init();
      final entries = storage.getWatchHistory();
      expect(entries, isEmpty);

      expect(storage.isHistoryCorrupted, isTrue);
      expect(storage.historyCorruptionNotifier.value, isTrue);
    });
  });

  group('Stress 3: Startup Migration & Fallback', () {
    test('clean migration from SharedPreferences to JSON files retains downgrade mirrors', () async {
      final rawSubs = [
        {
          'id': 'sub_mig_1',
          'name': '迁移测试源',
          'rawContent': '{"sites":[]}',
          'enabled': true,
        }
      ];
      final rawHist = [
        {
          'site': 's_mig',
          'id': 'v_mig_1',
          'title': '历史迁移片',
          'position': 3000,
        }
      ];

      SharedPreferences.setMockInitialValues({
        StorageService.keySubscriptions: jsonEncode(rawSubs),
        StorageService.keyWatchHistory: jsonEncode(rawHist),
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(StorageService.keySubscriptions), isTrue);
      expect(prefs.containsKey(StorageService.keyWatchHistory), isTrue);

      final storage = await StorageService.init();

      // Files created
      final subFile = File('${tempDir.path}/subscriptions.json');
      final histFile = File('${tempDir.path}/watch_history.json');
      expect(await subFile.exists(), isTrue);
      expect(await histFile.exists(), isTrue);

      // Values present in getters
      expect(storage.getSubscriptions().first.id, 'sub_mig_1');
      expect(storage.getWatchHistory().first.id, 'v_mig_1');

      // SharedPreferences mirrors retained for downgrade safety (M-F3)
      expect(prefs.containsKey(StorageService.keySubscriptions), isTrue);
      expect(prefs.containsKey(StorageService.keyWatchHistory), isTrue);
    });

    test('fallback reading from SharedPreferences when JSON files are missing', () async {
      // Do not run StorageService.init() migration, create StorageService directly
      final rawSubs = [
        {
          'id': 'sub_fb_1',
          'name': '降级读取源',
          'rawContent': '{"sites":[]}',
        }
      ];
      final rawHist = [
        {
          'site': 's_fb',
          'id': 'v_fb_1',
          'title': '降级历史片',
          'position': 8888,
        }
      ];

      SharedPreferences.setMockInitialValues({
        StorageService.keySubscriptions: jsonEncode(rawSubs),
        StorageService.keyWatchHistory: jsonEncode(rawHist),
      });

      final prefs = await SharedPreferences.getInstance();
      final storage = StorageService(prefs, dataDirectory: tempDir);

      // No JSON files exist
      expect(await File('${tempDir.path}/subscriptions.json').exists(), isFalse);
      expect(await File('${tempDir.path}/watch_history.json').exists(), isFalse);

      // Fallback works seamlessly
      final subs = storage.getSubscriptions();
      expect(subs.length, 1);
      expect(subs.first.id, 'sub_fb_1');

      final hist = storage.getWatchHistory();
      expect(hist.length, 1);
      expect(hist.first.id, 'v_fb_1');
    });

    test('empty subscriptions in JSON file overrides stale config_raw_json in SharedPreferences', () async {
      // User explicitly deleted all subscriptions, so subscriptions.json is empty '[]'
      final subFile = File('${tempDir.path}/subscriptions.json');
      await subFile.writeAsString('[]');

      // Stale legacy config in prefs
      SharedPreferences.setMockInitialValues({
        StorageService.keyRawConfig: '{"sites":[{"key":"stale","name":"旧源"}]}',
      });

      final storage = await StorageService.init();

      // Should return null (no revived stale config)
      final config = storage.loadSavedConfig();
      expect(config, isNull);
    });
  });

  group('Stress 4: Playback Progress Throttling', () {
    test('50 rapid progress updates emit 50 revision notifications while throttling disk writes to 1', () async {
      final storage = await StorageService.init();
      final histFile = File('${tempDir.path}/watch_history.json');

      var revisionCount = 0;
      storage.watchHistoryRevision.addListener(() {
        revisionCount++;
      });

      // 50 rapid updates
      for (int i = 1; i <= 50; i++) {
        await storage.upsertWatchHistory(
          WatchHistoryEntry(
            site: 'site_throttle',
            id: 'video_1',
            title: '节流测试影片',
            position: i * 1000,
            duration: 100000,
            updated: 1000 + i * 10,
          ),
          immediate: false,
        );

        // In-memory position is updated immediately on every tick
        expect(storage.getWatchHistory().first.position, i * 1000);
      }

      // All 50 revisions notified
      expect(revisionCount, 50);

      // Disk was throttled: it only wrote the first tick (position: 1000)
      expect(await histFile.exists(), isTrue);
      final diskContentBeforeFlush = await histFile.readAsString();
      expect(diskContentBeforeFlush.contains('"position":1000'), isTrue);
      expect(diskContentBeforeFlush.contains('"position":50000'), isFalse);

      // Now explicit flush commits latest position (50000) to disk
      await storage.flushPendingHistory();
      final diskContentAfterFlush = await histFile.readAsString();
      expect(diskContentAfterFlush.contains('"position":50000'), isTrue);
    });

    test('immediate: true on pause or exit bypasses 30s throttle immediately', () async {
      final storage = await StorageService.init();
      final histFile = File('${tempDir.path}/watch_history.json');

      // Playback tick 1 (starts throttling window)
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site_throttle',
          id: 'video_2',
          title: '即时测试影片',
          position: 1000,
          duration: 60000,
          updated: 1000,
        ),
        immediate: false,
      );

      // Tick 2 (throttled)
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site_throttle',
          id: 'video_2',
          title: '即时测试影片',
          position: 2000,
          duration: 60000,
          updated: 2000,
        ),
        immediate: false,
      );
      expect((await histFile.readAsString()).contains('"position":2000'), isFalse);

      // Pause event with immediate: true
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site_throttle',
          id: 'video_2',
          title: '即时测试影片',
          position: 2500,
          duration: 60000,
          updated: 2500,
        ),
        immediate: true,
      );

      // Immediately written to disk
      expect((await histFile.readAsString()).contains('"position":2500'), isTrue);
    });

    test('multi-video interleaved progress updates maintain accurate in-memory order and flush correctly', () async {
      final storage = await StorageService.init();
      final histFile = File('${tempDir.path}/watch_history.json');

      // Update Video A, Video B, Video C
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid_A',
          title: '影片A',
          position: 10000,
          updated: 1000,
        ),
        immediate: false,
      );

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid_B',
          title: '影片B',
          position: 20000,
          updated: 2000,
        ),
        immediate: false,
      );

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'site1',
          id: 'vid_C',
          title: '影片C',
          position: 30000,
          updated: 3000,
        ),
        immediate: false,
      );

      // In-memory cache should have all 3, ordered by updated descending (C, B, A)
      final inMemory = storage.getWatchHistory();
      expect(inMemory.length, 3);
      expect(inMemory[0].id, 'vid_C');
      expect(inMemory[1].id, 'vid_B');
      expect(inMemory[2].id, 'vid_A');

      // Flush to disk
      await storage.flushPendingHistory();
      final diskEntries = (jsonDecode(await histFile.readAsString()) as List)
          .map((m) => m['id'])
          .toList();
      expect(diskEntries, ['vid_C', 'vid_B', 'vid_A']);
    });

    test('concurrent asynchronous mutations via Future.wait are safely serialized', () async {
      final storage = await StorageService.init();

      // Launch 30 concurrent upserts across 3 different items
      await Future.wait([
        for (int i = 0; i < 30; i++)
          storage.upsertWatchHistory(
            WatchHistoryEntry(
              site: 'site_concurrent',
              id: 'vid_${i % 3}',
              title: '并发测试影片 ${i % 3}',
              position: (i + 1) * 500,
              updated: 1000 + i,
            ),
            immediate: (i == 29),
          ),
      ]);

      final history = storage.getWatchHistory();
      expect(history.length, 3);
      // All 3 items should be present with their highest updated positions
      final ids = history.map((e) => e.id).toSet();
      expect(ids, containsAll(['vid_0', 'vid_1', 'vid_2']));
    });
  });
}

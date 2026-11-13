import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _TrackingPrefsStore extends InMemorySharedPreferencesStore {
  _TrackingPrefsStore(Map<String, Object> initial, {required this.events})
      : super.withData(initial);

  final List<String> events;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    events.add('prefs.set:$key');
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    events.add('prefs.remove:$key');
    return super.remove(key);
  }
}

class _FaultyMemoryFileStore extends InMemoryStorageFileStore {
  _FaultyMemoryFileStore({
    Map<String, List<int>>? initialFiles,
    this.failRenameTimes = 0,
    this.failReadSubscriptions = false,
    this.events,
  }) : super(initialFiles);

  int failRenameTimes;
  bool failReadSubscriptions;
  final List<String>? events;
  int renameAttempts = 0;
  int deleteCalls = 0;

  @override
  List<int> readBytesSync(String fileName) {
    if (failReadSubscriptions && fileName == 'subscriptions.json') {
      throw const FileSystemException(
        'The process cannot access the file because it is being used by another process',
        'subscriptions.json',
      );
    }
    return super.readBytesSync(fileName);
  }

  @override
  Future<void> writeStringAndFlush(String fileName, String content) async {
    events?.add('file.writeTmp:$fileName');
    await super.writeStringAndFlush(fileName, content);
  }

  @override
  Future<void> rename(String fromFileName, String toFileName) async {
    renameAttempts++;
    events?.add('file.rename:$fromFileName->$toFileName#$renameAttempts');
    if (failRenameTimes > 0) {
      failRenameTimes--;
      throw FileSystemException('Simulated rename lock failure', toFileName);
    }
    await super.rename(fromFileName, toFileName);
  }

  @override
  Future<void> deleteFile(String fileName) async {
    deleteCalls++;
    events?.add('file.delete:$fileName');
    await super.deleteFile(fileName);
  }
}

class _FaultyDiskFileStore extends DiskStorageFileStore {
  _FaultyDiskFileStore(super.directory, {required this.alwaysFailRename});

  final bool alwaysFailRename;
  int renameAttempts = 0;
  int deleteCalls = 0;

  @override
  Future<void> rename(String fromFileName, String toFileName) async {
    renameAttempts++;
    if (alwaysFailRename) {
      throw FileSystemException('Simulated Windows rename error', toFileName);
    }
    await super.rename(fromFileName, toFileName);
  }

  @override
  Future<void> deleteFile(String fileName) async {
    deleteCalls++;
    await super.deleteFile(fileName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('B8: Corrupted or unreadable subscriptions protection', () {
    test(
      'corrupt subscriptions.json is quarantined, never caches empty list, and rejects overwrites',
      () async {
        const corruptRaw = '{"broken": true, [not valid json';
        final fileStore = InMemoryStorageFileStore({
          'subscriptions.json': utf8.encode(corruptRaw),
        });
        SharedPreferences.setMockInitialValues(<String, Object>{
          StorageService.keySubscriptions: jsonEncode([
            const SubscriptionEntry(
              id: 'stale_mirror',
              name: '旧镜像',
              rawContent: '{"sites":[]}',
            ).toJson(),
          ]),
        });

        final storage = await StorageService.init(
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );

        expect(storage.getSubscriptions(), isEmpty);
        expect(storage.isSubscriptionsCorrupted, isTrue);
        expect(storage.subscriptionsCorruptionNotifier.value, isTrue);
        expect(storage.hasCachedSubscriptions, isFalse);

        // Quarantined copy exists with exact original corrupt bytes
        final quarantined = fileStore
            .listFileNamesSync()
            .where((f) => f.startsWith('subscriptions_corrupt_') && f.endsWith('.json'))
            .toList();
        expect(quarantined, hasLength(1));
        expect(fileStore.readStringOrNull(quarantined.single), corruptRaw);

        // Original corrupt file is preserved intact
        expect(fileStore.readStringOrNull('subscriptions.json'), corruptRaw);

        // Saving or upserting while write-protected must be rejected
        await expectLater(
          storage.saveSubscriptions(const [
            SubscriptionEntry(
              id: 'overwrite_attempt',
              name: '覆盖尝试',
              rawContent: '{"sites":[]}',
            ),
          ]),
          throwsStateError,
        );
        await expectLater(
          storage.upsertSubscriptions(const [
            SubscriptionEntry(
              id: 'upsert_attempt',
              name: '更新尝试',
              rawContent: '{"sites":[]}',
            ),
          ]),
          throwsStateError,
        );

        // Corrupt file still untouched after rejected writes
        expect(fileStore.readStringOrNull('subscriptions.json'), corruptRaw);
        expect(storage.hasCachedSubscriptions, isFalse);
      },
    );

    test(
      'transient file read error sets write-protection without caching empty list or overwriting file',
      () async {
        final originalValidJson = jsonEncode([
          const SubscriptionEntry(
            id: 'protected_sub',
            name: '受保护订阅',
            rawContent: '{"sites":[{"key":"s1","name":"S1","type":1,"api":"https://s1.example/api"}]}',
          ).toJson(),
        ]);
        final fileStore = _FaultyMemoryFileStore(
          initialFiles: {
            'subscriptions.json': utf8.encode(originalValidJson),
          },
          failReadSubscriptions: true,
        );
        SharedPreferences.setMockInitialValues(<String, Object>{});

        final storage = await StorageService.init(
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );

        expect(storage.getSubscriptions(), isEmpty);
        expect(storage.isSubscriptionsCorrupted, isTrue);
        expect(storage.hasCachedSubscriptions, isFalse);

        await expectLater(
          storage.saveSubscriptions(const []),
          throwsStateError,
        );

        // Unlocking simulated antivirus lock proves original file was never overwritten
        fileStore.failReadSubscriptions = false;
        expect(fileStore.readStringOrNull('subscriptions.json'), originalValidJson);
      },
    );

    testWidgets(
      'AdaptiveShell prompts user once when subscriptions.json is corrupted',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final fileStore = InMemoryStorageFileStore({
          'subscriptions.json': utf8.encode('<<<corrupted-subscriptions>>>'),
        });
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );
        addTearDown(() {
          storage.cancelPendingHistoryFlush();
          storage.cancelPendingAutoSync();
        });

        final client = CmsClient(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('订阅数据异常'), findsOneWidget);

        // Dismiss dialog
        await tester.tap(find.text('好'));
        await tester.pumpAndSettle();
        expect(find.text('订阅数据异常'), findsNothing);

        // Subsequent reads/notifications must NOT prompt a second time
        storage.getSubscriptions();
        storage.subscriptionsCorruptionNotifier.value = false;
        storage.subscriptionsCorruptionNotifier.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('订阅数据异常'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('B8: Atomic write retry, preserved .tmp & original file, and prefs order', () {
    test(
      'when rename fails after 3 retries on memory store, .tmp and original file both remain and prefs is untouched',
      () async {
        final originalJson = jsonEncode([
          const SubscriptionEntry(
            id: 'orig',
            name: '原始订阅',
            rawContent: '{"sites":[]}',
          ).toJson(),
        ]);
        final events = <String>[];
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final prefsStore = _TrackingPrefsStore(
          <String, Object>{
            'flutter.${StorageService.keySubscriptions}': originalJson,
          },
          events: events,
        );
        SharedPreferencesStorePlatform.instance = prefsStore;
        addTearDown(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

        final fileStore = _FaultyMemoryFileStore(
          initialFiles: {'subscriptions.json': utf8.encode(originalJson)},
          events: events,
        );
        final prefs = await SharedPreferences.getInstance();
        final storage = StorageService(
          prefs,
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );

        expect(storage.getSubscriptions().single.id, 'orig');
        events.clear();

        // Fail initial rename + all 3 retries (4 attempts total)
        fileStore.failRenameTimes = 10;
        const attemptedSubs = [
          SubscriptionEntry(
            id: 'new_sub',
            name: '新订阅',
            rawContent: '{"sites":[{"key":"k","name":"N","type":1,"api":"https://k.example/api"}]}',
          ),
        ];

        await expectLater(
          storage.saveSubscriptions(attemptedSubs),
          throwsA(isA<FileSystemException>()),
        );

        // 1 initial attempt + 3 retries = 4 rename attempts; 0 target deletes
        expect(fileStore.renameAttempts, 4);
        expect(fileStore.deleteCalls, 0);

        // Original file is completely intact
        expect(fileStore.readStringOrNull('subscriptions.json'), originalJson);

        // .tmp file is preserved with the new content
        final tmpFiles = fileStore
            .listFileNamesSync()
            .where((name) => name.startsWith('subscriptions.json.') && name.endsWith('.tmp'))
            .toList();
        expect(tmpFiles, hasLength(1));
        final tmpDecoded = jsonDecode(fileStore.readStringOrNull(tmpFiles.single)!) as List;
        expect(tmpDecoded.single['id'], 'new_sub');

        // prefs was NEVER touched because file write did not succeed
        expect(
          events.where((e) => e.contains(StorageService.keySubscriptions)),
          isEmpty,
        );
        expect(prefs.getString(StorageService.keySubscriptions), originalJson);
      },
    );

    test(
      'when rename fails on real DiskStorageFileStore, both .tmp and original subscriptions.json remain on disk',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('mm_b8_rename_fail_');
        addTearDown(() async {
          if (await tempDir.exists()) {
            try {
              await tempDir.delete(recursive: true);
            } on Object catch (e) {
              assert(e.toString().isNotEmpty);
            }
          }
        });

        final origFile = File('${tempDir.path}/subscriptions.json');
        final origContent = jsonEncode([
          const SubscriptionEntry(
            id: 'disk_orig',
            name: '磁盘原订阅',
            rawContent: '{"sites":[]}',
          ).toJson(),
        ]);
        await origFile.writeAsString(origContent, flush: true);

        SharedPreferences.setMockInitialValues(<String, Object>{
          StorageService.keySubscriptions: origContent,
        });
        final prefs = await SharedPreferences.getInstance();
        final diskStore = _FaultyDiskFileStore(tempDir, alwaysFailRename: true);
        final storage = StorageService(
          prefs,
          dataDirectory: tempDir,
          fileStore: diskStore,
          secureStore: InMemorySecureCredentialStore(),
        );

        await expectLater(
          storage.saveSubscriptions(const [
            SubscriptionEntry(
              id: 'disk_new',
              name: '磁盘新订阅',
              rawContent: '{"sites":[]}',
            ),
          ]),
          throwsA(isA<FileSystemException>()),
        );

        expect(diskStore.renameAttempts, 4);
        expect(diskStore.deleteCalls, 0);
        expect(await origFile.exists(), isTrue);
        expect(await origFile.readAsString(), origContent);

        final tmpFiles = tempDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.tmp'))
            .toList();
        expect(tmpFiles, hasLength(1));
        expect(await tmpFiles.single.readAsString(), contains('disk_new'));
      },
    );

    test(
      'saveSubscriptions writes file and completes rename BEFORE touching SharedPreferences, succeeding on transient retry',
      () async {
        final events = <String>[];
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final prefsStore = _TrackingPrefsStore(
          <String, Object>{},
          events: events,
        );
        SharedPreferencesStorePlatform.instance = prefsStore;
        addTearDown(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

        final fileStore = _FaultyMemoryFileStore(
          failRenameTimes: 2, // Fails twice, succeeds on retry #2 (3rd attempt)
          events: events,
        );
        final prefs = await SharedPreferences.getInstance();
        final storage = StorageService(
          prefs,
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );
        events.clear();

        await storage.saveSubscriptions(const [
          SubscriptionEntry(
            id: 'ordered_sub',
            name: '顺序验证源',
            rawContent: '{"sites":[]}',
          ),
        ]);

        expect(fileStore.renameAttempts, 3);
        final lastRenameIdx = events.lastIndexWhere((e) => e.startsWith('file.rename:'));
        final firstPrefsIdx = events.indexWhere(
          (e) => e.contains(StorageService.keySubscriptions),
        );
        expect(lastRenameIdx, greaterThanOrEqualTo(0));
        expect(firstPrefsIdx, greaterThan(lastRenameIdx));
        expect(
          prefs.getString(StorageService.keySubscriptions),
          contains('ordered_sub'),
        );
      },
    );
  });

  group('M-F3: Migration only when file absent & downgrade prefs mirrors', () {
    test(
      'migration from prefs never overwrites existing subscriptions.json or watch_history.json',
      () async {
        final existingSubsJson = jsonEncode([
          const SubscriptionEntry(
            id: 'newer_file_sub',
            name: '新文件订阅',
            rawContent: '{"sites":[{"key":"new","name":"New","type":1,"api":"https://new.example/api"}]}',
          ).toJson(),
        ]);
        final stalePrefsSubsJson = jsonEncode([
          const SubscriptionEntry(
            id: 'stale_prefs_sub',
            name: '旧Prefs订阅',
            rawContent: '{"sites":[{"key":"old","name":"Old","type":1,"api":"https://old.example/api"}]}',
          ).toJson(),
        ]);

        final existingHistJson = jsonEncode([
          const WatchHistoryEntry(
            site: 'new',
            id: 'file_vid',
            title: '文件里的最新历史',
            position: 99000,
            updated: 9000,
          ).toJson(),
        ]);
        final stalePrefsHistJson = jsonEncode([
          const WatchHistoryEntry(
            site: 'old',
            id: 'prefs_vid',
            title: 'Prefs里的旧历史',
            position: 1000,
            updated: 100,
          ).toJson(),
        ]);

        final fileStore = InMemoryStorageFileStore({
          'subscriptions.json': utf8.encode(existingSubsJson),
          'watch_history.json': utf8.encode(existingHistJson),
        });

        SharedPreferences.setMockInitialValues(<String, Object>{
          StorageService.keySubscriptions: stalePrefsSubsJson,
          StorageService.keyWatchHistory: stalePrefsHistJson,
        });

        final storage = await StorageService.init(
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );

        expect(storage.getSubscriptions().map((s) => s.id).toList(), ['newer_file_sub']);
        expect(fileStore.readStringOrNull('subscriptions.json'), existingSubsJson);

        expect(storage.getWatchHistory().map((h) => h.id).toList(), ['file_vid']);
        expect(fileStore.readStringOrNull('watch_history.json'), existingHistJson);
      },
    );

    test(
      'writing subscriptions and watch_history mirrors latest JSON to SharedPreferences for downgrade',
      () async {
        final fileStore = InMemoryStorageFileStore();
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );
        final prefs = await SharedPreferences.getInstance();

        await storage.saveConfig(
          '{"sites":[{"key":"downgrade_site","name":"回退源","type":1,"api":"https://dg.example/api"}]}',
        );
        await storage.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'downgrade_site',
            id: 'ep_1',
            title: '回退测试片',
            position: 42000,
            updated: 5000,
          ),
          immediate: true,
        );

        final mirroredSubs = prefs.getString(StorageService.keySubscriptions);
        final mirroredHist = prefs.getString(StorageService.keyWatchHistory);
        expect(mirroredSubs, isNotNull);
        expect(mirroredSubs, fileStore.readStringOrNull('subscriptions.json'));
        expect(mirroredHist, isNotNull);
        expect(mirroredHist, fileStore.readStringOrNull('watch_history.json'));
      },
    );
  });

  group('M-F2 & Queue: mergeSyncPayload selectedSiteKey guard & importBackupJson queue', () {
    test(
      'mergeSyncPayload retains original selectedSiteKey when synced sites are unavailable and selects available site when present',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          StorageService.keySelectedSite: 'original_kept_key',
        });
        final storage = await StorageService.init();

        // 1. Remote subscription contains ONLY an unavailable site (unported csp_ spider)
        const onlyUnsupportedRaw =
            '{"sites":[{"key":"bad_csp","name":"未移植源","type":3,"api":"csp_UnportedUnavailableTest"}]}';
        final remotePayloadUnsupported = jsonEncode({
          'schema': StorageService.syncSchema,
          'version': StorageService.syncVersion,
          'updated': 1000,
          'watch_history': const <Object>[],
          'favorites': const <Object>[],
          'subscriptions': [
            {
              'id': 'remote_1',
              'name': '云端仅不可用源',
              'url': 'https://cloud1.example/sub.json',
              'rawContent': onlyUnsupportedRaw,
              'enabled': true,
              'updatedAt': 1000,
            },
          ],
          'tombstones': const <String, int>{},
        });

        await storage.mergeSyncPayload(remotePayloadUnsupported, nowMs: 1000);
        // Must retain original value instead of switching to unavailable 'bad_csp'
        expect(storage.selectedSiteKey, 'original_kept_key');

        // 2. Remote subscription now includes [unavailable_site, available_site]
        const mixedRaw =
            '{"sites":[{"key":"bad_csp","name":"未移植源","type":3,"api":"csp_UnportedUnavailableTest"},{"key":"good_cms","name":"可用源","type":1,"api":"https://good.example/api"}]}';
        final remotePayloadMixed = jsonEncode({
          'schema': StorageService.syncSchema,
          'version': StorageService.syncVersion,
          'updated': 2000,
          'watch_history': const <Object>[],
          'favorites': const <Object>[],
          'subscriptions': [
            {
              'id': 'remote_1',
              'name': '云端混合源',
              'url': 'https://cloud1.example/sub.json',
              'rawContent': mixedRaw,
              'enabled': true,
              'updatedAt': 2000,
            },
          ],
          'tombstones': const <String, int>{},
        });

        await storage.mergeSyncPayload(remotePayloadMixed, nowMs: 2000);
        expect(storage.selectedSiteKey, 'good_cms');
      },
    );

    test(
      'importBackupJson executes sequentially on the same mutation queue as subscription and history edits',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final source = await StorageService.init();
        await source.saveConfig(
          '{"sites":[{"key":"backup_site","name":"备份源","type":1,"api":"https://backup.example/api"}]}',
          origin: 'https://backup.example/config.json',
        );
        await source.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'backup_site',
            id: 'bk_vid',
            title: '备份影片',
            position: 30000,
            updated: 3000,
          ),
          immediate: true,
        );
        final backupJson = source.exportBackupJson();

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final events = <String>[];
        final fileStore = _FaultyMemoryFileStore(
          failRenameTimes: 1, // Forces first write to await a 20ms backoff inside queue
          events: events,
        );
        final target = await StorageService.init(
          fileStore: fileStore,
          secureStore: InMemorySecureCredentialStore(),
        );
        addTearDown(() {
          target.cancelPendingHistoryFlush();
          target.cancelPendingAutoSync();
        });

        final order = <String>[];
        final f1 = target
            .upsertSubscriptions([
              const SubscriptionEntry(
                id: 'queued_first',
                name: '先入队源',
                rawContent: '{"sites":[{"key":"q1","name":"Q1","type":1,"api":"https://q1.example/api"}]}',
              ),
            ])
            .then((_) => order.add('upsertSubscriptions'));
        final f2 = target
            .importBackupJson(backupJson)
            .then((_) => order.add('importBackupJson'));
        final f3 = target
            .upsertWatchHistory(
              const WatchHistoryEntry(
                site: 'backup_site',
                id: 'after_import',
                title: '导入后影片',
                position: 60000,
                updated: 9000,
              ),
              immediate: true,
            )
            .then((_) => order.add('upsertWatchHistory'));

        await Future.wait([f1, f2, f3]);

        // Strict FIFO completion proves importBackupJson ran on _mutationQueue
        expect(
          order,
          equals(['upsertSubscriptions', 'importBackupJson', 'upsertWatchHistory']),
        );
        expect(target.loadSavedConfig()?.sites.single.key, 'backup_site');
        expect(
          target.getWatchHistory().map((e) => e.id).toList(),
          equals(['after_import', 'bk_vid']),
        );
      },
    );
  });
}

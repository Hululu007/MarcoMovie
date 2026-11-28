import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/python_source_sessions.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/subscription_refresh_service.dart';

class _InterruptibleFileStore extends InMemoryStorageFileStore {
  bool failWriteMidway = false;
  bool failRename = false;
  int writeAttempts = 0;

  @override
  Future<void> writeStringAndFlush(String fileName, String content) async {
    writeAttempts++;
    if (failWriteMidway && fileName.endsWith('.tmp')) {
      // Simulate truncated partial write before I/O failure.
      await super.writeStringAndFlush(fileName, content.substring(0, 12));
      throw FileSystemException('Simulated interrupted write (disk full)', fileName);
    }
    await super.writeStringAndFlush(fileName, content);
  }

  @override
  Future<void> rename(String fromFileName, String toFileName) async {
    if (failRename) {
      throw FileSystemException('Simulated atomic rename interruption', toFileName);
    }
    await super.rename(fromFileName, toFileName);
  }
}

class _FakePythonSession extends PythonNativeSession {
  _FakePythonSession(this.proxy);
  final Uri proxy;
  int closedCount = 0;

  @override
  Future<Object?> invoke(
    String id,
    String method,
    List<Object?> args,
    Duration budget,
  ) async {
    return {'method': method, 'proxy': proxy.toString()};
  }

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<void> close() async {
    closedCount++;
  }
}

const String _validV1Json = '''
{
  "sites": [
    {
      "key": "vod_v1",
      "name": "稳定影院 V1",
      "type": 1,
      "api": "https://v1.example/api.php/provide/vod"
    }
  ]
}
''';

const String _validV2Json = '''
{
  "sites": [
    {
      "key": "vod_v2",
      "name": "升级影院 V2",
      "type": 1,
      "api": "https://v2.example/api.php/provide/vod"
    },
    {
      "key": "vod_4k",
      "name": "4K 专线 V2",
      "type": 1,
      "api": "https://4k.example/api.php/provide/vod"
    }
  ]
}
''';

const String _subBValidV1Json = '''
{
  "sites": [
    {
      "key": "sub_b_v1",
      "name": "备用影院 B1",
      "type": 1,
      "api": "https://b1.example/api.php/provide/vod"
    }
  ]
}
''';

http.Response _utf8Response(String body, int statusCode) => http.Response.bytes(
      utf8.encode(body),
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Future<StorageService> _createSeededStorage({
  StorageFileStore? fileStore,
  List<SubscriptionEntry>? entries,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final storage = await StorageService.init(
    fileStore: fileStore ?? InMemoryStorageFileStore(),
    secureStore: InMemorySecureCredentialStore(),
  );
  await storage.upsertSubscriptions(
    entries ??
        const [
          SubscriptionEntry(
            id: 'sub_a',
            name: '主订阅 A',
            url: 'https://sub.example/a.json',
            group: '常用秒播',
            format: 'JSON',
            enabled: true,
            rawContent: _validV1Json,
            siteCount: 1,
            liveCount: 0,
            updatedAt: 1000,
          ),
        ],
  );
  return storage;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(JsSourceHost.closeAll);

  group('Batch 2 Item 6 — Staged & atomic subscription refresh', () {
    test('network disconnect preserves previous valid subscription and config', () async {
      final storage = await _createSeededStorage();
      final client = CmsClient(
        client: MockClient((request) async {
          throw const SocketException('Network is unreachable');
        }),
      );
      final service = StagedSubscriptionRefreshService(
        storage: storage,
        client: client,
      );

      final summary = await service.refreshAll();
      expect(summary.updatedCount, 0);
      expect(summary.failedCount, 1);
      expect(summary.results.single.previousKept, isTrue);
      expect(summary.summaryText, contains('已保留上次有效配置'));

      // Previous valid config remains completely usable.
      final activeConfig = storage.loadSavedConfig();
      expect(activeConfig, isNotNull);
      expect(activeConfig!.sites.map((s) => s.key), ['vod_v1']);
      expect(storage.getSubscriptions().single.rawContent.trim(), _validV1Json.trim());
    });

    test('bad configs (HTML 404, broken JSON, empty object) are rejected in staging before switching', () async {
      final badPayloads = <String, String>{
        'html_404': '<!DOCTYPE html><html><head><title>404 Not Found</title></head><body>Not Found</body></html>',
        'broken_json': '{"sites": [{"key": "broken", "name": "截断...',
        'empty_json': '{"sites": [], "lives": []}',
        'blank': '   ',
      };

      for (final entry in badPayloads.entries) {
        final storage = await _createSeededStorage();
        final client = CmsClient(
          client: MockClient((request) async {
            return _utf8Response(entry.value, 200);
          }),
        );
        final service = StagedSubscriptionRefreshService(
          storage: storage,
          client: client,
        );

        final summary = await service.refreshAll();
        expect(
          summary.updatedCount,
          0,
          reason: 'Bad payload "${entry.key}" must not commit',
        );
        expect(summary.failedCount, 1, reason: 'Bad payload "${entry.key}" must fail');
        expect(summary.results.single.previousKept, isTrue);

        // Previous valid config stays active and unmodified.
        final saved = storage.loadSavedConfig();
        expect(saved, isNotNull);
        expect(saved!.sites.map((s) => s.key), ['vod_v1']);
        expect(storage.getSubscriptions().single.siteCount, 1);
      }
    });

    test('interrupted tmp write cleans up partial .tmp and leaves previous config intact', () async {
      final fileStore = _InterruptibleFileStore();
      final storage = await _createSeededStorage(fileStore: fileStore);
      final beforeDisk = fileStore.readStringOrNull('subscriptions.json');
      expect(beforeDisk, contains('vod_v1'));

      // Interrupt writeStringAndFlush midway.
      fileStore.failWriteMidway = true;

      final client = CmsClient(
        client: MockClient((request) async => _utf8Response(_validV2Json, 200)),
      );
      final service = StagedSubscriptionRefreshService(
        storage: storage,
        client: client,
      );

      final summary = await service.refreshAll();
      expect(summary.commitFailed, isTrue);
      expect(summary.updatedCount, 0);
      expect(summary.failedCount, 1);
      expect(summary.summaryText, contains('写入中断'));
      expect(summary.summaryText, contains('已保留上次有效配置'));

      // Truncated .tmp was cleaned up and original subscriptions.json is untouched.
      final leftoverTmps = fileStore
          .listFileNamesSync()
          .where((name) => name.endsWith('.tmp'))
          .toList();
      expect(leftoverTmps, isEmpty);
      expect(fileStore.readStringOrNull('subscriptions.json'), beforeDisk);

      // In-memory and reloadable config still serves v1!
      expect(storage.loadSavedConfig()!.sites.map((s) => s.key), ['vod_v1']);
      expect(storage.getSubscriptions().single.rawContent.trim(), _validV1Json.trim());
    });

    test('interrupted atomic rename preserves previous valid config on disk and in memory', () async {
      final fileStore = _InterruptibleFileStore();
      final storage = await _createSeededStorage(fileStore: fileStore);
      final beforeDisk = fileStore.readStringOrNull('subscriptions.json');

      fileStore.failRename = true;
      final client = CmsClient(
        client: MockClient((request) async => _utf8Response(_validV2Json, 200)),
      );
      final service = StagedSubscriptionRefreshService(
        storage: storage,
        client: client,
      );

      final summary = await service.refreshAll();
      expect(summary.commitFailed, isTrue);
      expect(summary.updatedCount, 0);
      expect(fileStore.readStringOrNull('subscriptions.json'), beforeDisk);
      expect(storage.loadSavedConfig()!.sites.map((s) => s.key), ['vod_v1']);
    });

    test('refresh while playing keeps pinned JS and Python sessions alive until playback unpins', () async {
      // 1. JS playback session pin survival across retainSessions(..., preservePinned: true)
      const jsEntry = 'pkg://playing/source.js';
      const jsCode = 'let count=0; export default {home(){return ++count;}};';

      final unpinPlayingJs = JsSourceHost.pinForPlayback('playing_site');
      expect(
        await JsSourceHost.invoke(
          entry: jsEntry,
          modules: const {jsEntry: jsCode},
          sessionKey: 'playing_site',
          method: 'home',
          arguments: const [],
        ),
        '1',
      );
      expect(
        await JsSourceHost.invoke(
          entry: jsEntry,
          modules: const {jsEntry: jsCode},
          sessionKey: 'idle_old_site',
          method: 'home',
          arguments: const [],
        ),
        '1',
      );

      // Subscription refresh replaces sites with 'new_site_v2' while 'playing_site' is playing.
      await JsSourceHost.retainSessions(
        const {'new_site_v2'},
        preservePinned: true,
      );

      // Idle old session was evicted, but the actively playing session stays alive!
      expect(
        await JsSourceHost.callCached(
          sessionKey: 'idle_old_site',
          method: 'home',
          arguments: const [],
        ),
        isNull,
      );
      expect(
        await JsSourceHost.callCached(
          sessionKey: 'playing_site',
          method: 'home',
          arguments: const [],
        ),
        '2',
      );

      // Once playback ends and releases its pin, the retired session auto-evicts cleanly.
      unpinPlayingJs();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await JsSourceHost.callCached(
          sessionKey: 'playing_site',
          method: 'home',
          arguments: const [],
        ),
        isNull,
      );

      // 2. Python playback session pin survival across retainSessions(..., preservePinned: true)
      final pyPool = PythonSourceSessions();
      addTearDown(pyPool.close);
      final created = <String, _FakePythonSession>{};

      Future<String> invokePy(String key) => pyPool.invoke(
            sessionKey: key,
            expectedGeneration: pyPool.generation,
            open: (proxy, _) async {
              final s = _FakePythonSession(proxy);
              created[key] = s;
              return s;
            },
            method: 'home',
            arguments: const [],
          );

      final unpinPlayingPy = pyPool.pinForPlayback('py_playing');
      await invokePy('py_playing');
      await invokePy('py_idle');
      expect(pyPool.activeCount, 2);

      // Refresh removes both keys from new subscription while py_playing is pinned.
      pyPool.retainSessions(const {'py_new_v2'}, preservePinned: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(created['py_idle']!.closedCount, 1);
      expect(created['py_playing']!.closedCount, 0);
      expect(pyPool.ownsProxyUrl('py_playing', created['py_playing']!.proxy), isTrue);
      expect(
        await pyPool.callCached(
          sessionKey: 'py_playing',
          method: 'home',
          arguments: const [],
        ),
        isNotNull,
      );

      // Unpinning immediately revokes the retired Python playback session.
      unpinPlayingPy();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(created['py_playing']!.closedCount, 1);
      expect(pyPool.activeCount, 0);
    });

    test('batch staged refresh atomically upgrades valid subscriptions while isolating failures and skipping local entries', () async {
      final storage = await _createSeededStorage(
        entries: const [
          SubscriptionEntry(
            id: 'sub_a',
            name: '主订阅 A',
            url: 'https://sub.example/a.json',
            group: '4K网盘',
            format: 'JSON',
            enabled: true,
            rawContent: _validV1Json,
            siteCount: 1,
            liveCount: 0,
            updatedAt: 1000,
          ),
          SubscriptionEntry(
            id: 'sub_b',
            name: '备用订阅 B',
            url: 'https://sub.example/b.json',
            group: '备用线路',
            format: 'JSON',
            enabled: true,
            rawContent: _subBValidV1Json,
            siteCount: 1,
            liveCount: 0,
            updatedAt: 1000,
          ),
          SubscriptionEntry(
            id: 'sub_local',
            name: '本地导入配置',
            url: '',
            group: '本地',
            format: 'JSON',
            enabled: true,
            rawContent: '{"sites":[{"key":"local_site","name":"本地源","type":1,"api":"https://local.example/api"}]}',
            siteCount: 1,
            liveCount: 0,
            updatedAt: 1000,
          ),
        ],
      );

      final client = CmsClient(
        client: MockClient((request) async {
          if (request.url.path == '/a.json') {
            return _utf8Response(_validV2Json, 200);
          }
          if (request.url.path == '/b.json') {
            return _utf8Response('<html><title>502 Bad Gateway</title></html>', 502);
          }
          return _utf8Response('not found', 404);
        }),
      );

      final service = StagedSubscriptionRefreshService(
        storage: storage,
        client: client,
      );
      final summary = await service.refreshAll();

      expect(summary.updatedCount, 1);
      expect(summary.failedCount, 1);
      expect(summary.skippedCount, 1);
      expect(summary.hasUpdates, isTrue);
      expect(summary.hasFailures, isTrue);

      final subs = {for (final s in storage.getSubscriptions()) s.id: s};
      // Sub A switched atomically to v2 while preserving custom metadata (group/name/id).
      expect(subs['sub_a']!.group, '4K网盘');
      expect(subs['sub_a']!.name, '主订阅 A');
      expect(subs['sub_a']!.siteCount, 2);
      // Sub B kept its previous valid v1 config!
      expect(subs['sub_b']!.rawContent.trim(), _subBValidV1Json.trim());
      // Local sub untouched!
      expect(subs['sub_local']!.siteCount, 1);

      final mergedKeys = storage.loadSavedConfig()!.sites.map((s) => s.key).toSet();
      expect(mergedKeys, containsAll(['vod_v2', 'vod_4k', 'sub_b_v1', 'local_site']));
      expect(mergedKeys, isNot(contains('vod_v1')));
    });
  });
}

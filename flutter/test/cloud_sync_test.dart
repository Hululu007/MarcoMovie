import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/lan_sync_server.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const publicSubJsonA = '''
{
  "sites": [
    {"key": "siteA", "name": "公开源甲", "type": 1, "api": "https://a.example/api.php/provide/vod/"},
    {"key": "privInline", "name": "内嵌私密源", "type": 1, "api": "https://priv.example/api", "isPrivate": true}
  ]
}
''';

  const publicSubJsonB = '''
{
  "sites": [
    {"key": "siteB", "name": "公开源乙", "type": 1, "api": "https://b.example/api.php/provide/vod/"}
  ]
}
''';

  const privateSubJson = '''
{
  "sites": [
    {"key": "secretSite", "name": "私密专线", "type": 1, "api": "https://secret.example/api"}
  ]
}
''';

  test(
    'merges watch history, favorites, tombstones, and WebDAV MKCOL retry',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final deviceA = await StorageService.init();

      expect(
        StorageService.resolveWebdavFileUrl('https://dav.example/dav/MarcoMovie/'),
        'https://dav.example/dav/MarcoMovie/marco-movie-sync.json',
      );
      expect(
        StorageService.resolveLanSyncEndpoint('127.0.0.1:41234/configure/abcd'),
        'http://127.0.0.1:41234/configure/abcd/sync',
      );

      await deviceA.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'siteA',
          id: 'v1',
          title: '剧集甲',
          episode: '第1集',
          index: 0,
          position: 120000,
          duration: 2400000,
          updated: 1000,
        ),
      );
      const siteA = CmsSite(
        key: 'siteA',
        name: 'A',
        type: 1,
        api: 'https://a.example/api',
      );
      await deviceA.toggleFavorite(
        siteA,
        const CmsVideo(id: 'favA', title: '收藏甲'),
      );

      final remoteFromB = jsonEncode({
        'schema': 'marco-movie-sync',
        'version': 1,
        'updated': 2000,
        'watch_history': [
          {
            'site': 'siteA',
            'id': 'v1',
            'title': '剧集甲',
            'episode': '第2集',
            'index': 1,
            'position': 850000,
            'duration': 2400000,
            'updated': 2000,
          },
          {
            'site': 'siteB',
            'id': 'v2',
            'title': '电影乙',
            'episode': '正片',
            'index': 0,
            'position': 300000,
            'duration': 5400000,
            'updated': 1500,
          },
        ],
        'favorites': [
          {
            'site': 'siteB',
            'id': 'favB',
            'title': '收藏乙',
            'poster': '',
            'updated': 1800,
          },
        ],
        'tombstones': <String, int>{'add:siteB\nfavB': 1800},
      });

      String? cloudBlob = remoteFromB;
      var folderCreated = false;
      var mkcolCalled = false;
      final mkcolSequence = <String>[];
      final mockWebdav = MockClient((req) async {
        if (req.method == 'GET') {
          if (cloudBlob == null) return http.Response('', 404);
          return http.Response.bytes(utf8.encode(cloudBlob!), 200);
        }
        if (req.method == 'MKCOL') {
          mkcolCalled = true;
          folderCreated = true;
          mkcolSequence.add(req.url.path);
          return http.Response('', 201);
        }
        if (req.method == 'PUT') {
          if (req.url.path == '/dav/marco-movie-sync.json' ||
              req.url.path == '/marco-movie-sync.json') {
            return http.Response('', 404);
          }
          if (!folderCreated) {
            return http.Response('', 409);
          }
          cloudBlob = utf8.decode(req.bodyBytes);
          return http.Response('', 204);
        }
        return http.Response('', 405);
      });

      await deviceA.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'alice',
        pass: 'secret',
        auto: false,
        syncSubs: true,
      );

      final resA = await deviceA.syncWithWebdav(client: mockWebdav);
      expect(mkcolCalled, isTrue);
      expect(mkcolSequence, contains('/dav/'));
      expect(mkcolSequence, contains('/dav/MarcoMovie/'));
      expect(
        mkcolSequence.indexOf('/dav/'),
        lessThan(mkcolSequence.indexOf('/dav/MarcoMovie/')),
      );
      expect(resA.historyCount, 2);
      expect(resA.favoriteCount, 2);
      final histA = deviceA.getWatchHistory();
      expect(histA.first.id, 'v1');
      expect(histA.first.episode, '第2集');
      expect(histA.first.position, 850000);
      expect(histA.last.id, 'v2');

      final lanRemotePayload = jsonEncode({
        'schema': 'marco-movie-sync',
        'version': 2,
        'updated': 5200,
        'watch_history': [
          {
            'site': 'siteA',
            'id': 'v1',
            'title': '剧集甲',
            'episode': '第3集',
            'index': 2,
            'position': 400000,
            'duration': 2400000,
            'updated': 5200,
          },
        ],
        'favorites': const [],
        'tombstones': <String, int>{
          'hist:siteB\nv2': 5000,
          'fav:siteB\nfavB': 5100,
        },
      });

      final mockLan = MockClient((req) async {
        return http.Response.bytes(utf8.encode(lanRemotePayload), 200);
      });

      final lanRes = await deviceA.syncWithLanPeer(
        'http://127.0.0.1:34567/configure/0123456789abcdef0123456789abcdef',
        client: mockLan,
      );
      expect(lanRes.historyCount, 1);
      expect(lanRes.favoriteCount, 1);
      expect(deviceA.getWatchHistory().first.episode, '第3集');
      expect(deviceA.getFavorites().map((f) => f.id).toList(), ['favA']);
    },
  );

  test(
    'syncs public subscriptions to empty device, isolates private space, and preserves cloud subs when opted out',
    () async {
      // 1. Device A has 1 public subscription (containing 1 public site + 1 inline private site)
      //    and 1 full private subscription + private favorite.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final deviceA = await StorageService.init();
      await deviceA.saveConfig(
        publicSubJsonA,
        origin: 'https://a.example/sub.json',
        customName: '家庭主力源',
      );
      await deviceA.saveConfig(
        privateSubJson,
        origin: 'https://secret.example/sub.json',
        group: '隐私空间',
        isPrivate: true,
        customName: '私密源',
      );
      final cfgA = deviceA.loadSavedConfig()!;
      final pubSiteA = cfgA.publicSupportedSites.single;
      final privSiteA = cfgA.privateSupportedSites.firstWhere(
        (s) => s.key == 'secretSite',
      );
      await deviceA.toggleFavorite(
        pubSiteA,
        const CmsVideo(id: 'pubFav1', title: '公开电影'),
      );
      await deviceA.toggleFavorite(
        privSiteA,
        const CmsVideo(id: 'privFav1', title: '私密电影'),
      );
      await deviceA.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'siteA',
          id: 'pubHist1',
          title: '公开剧集',
          position: 90000,
          duration: 1800000,
          updated: 3000,
        ),
      );
      await deviceA.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'secretSite',
          id: 'privHist1',
          title: '私密剧集',
          position: 90000,
          duration: 1800000,
          updated: 3100,
        ),
      );

      String? cloudPayload;
      final cloudClient = MockClient((req) async {
        if (req.method == 'GET') {
          if (cloudPayload == null) return http.Response('', 404);
          return http.Response.bytes(utf8.encode(cloudPayload!), 200);
        }
        if (req.method == 'PUT') {
          cloudPayload = utf8.decode(req.bodyBytes);
          return http.Response('', 204);
        }
        return http.Response('', 405);
      });

      await deviceA.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'u',
        pass: 'p',
        auto: false,
        syncSubs: true,
      );
      final pushA = await deviceA.syncWithWebdav(client: cloudClient);
      expect(pushA.subscriptionCount, 1);
      expect(cloudPayload, isNotNull);
      expect(cloudPayload!.contains('secretSite'), isFalse);
      expect(cloudPayload!.contains('privInline'), isFalse);
      expect(cloudPayload!.contains('privFav1'), isFalse);
      expect(cloudPayload!.contains('privHist1'), isFalse);

      // 2. Brand-new Device B connects to WebDAV and pulls subscriptions + history + favorites in one step.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final deviceB = await StorageService.init();
      await deviceB.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'u',
        pass: 'p',
        auto: false,
        syncSubs: true,
      );
      final pullB = await deviceB.syncWithWebdav(client: cloudClient);
      expect(pullB.subscriptionsChanged, isTrue);
      expect(pullB.subscriptionCount, 1);
      expect(pullB.historyCount, 1);
      expect(pullB.favoriteCount, 1);
      final cfgB = deviceB.loadSavedConfig();
      expect(cfgB, isNotNull);
      expect(cfgB!.publicSupportedSites.map((s) => s.key).toList(), ['siteA']);
      expect(deviceB.selectedSiteKey, 'siteA');

      // 3. Device C opts OUT of subscription sync (webdavSyncSubs: false):
      //    it pulls history & favorites ONLY, does NOT import cloud subscriptions locally,
      //    and does NOT wipe Device A/B's subscriptions from cloudPayload!
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final deviceC = await StorageService.init();
      await deviceC.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'u',
        pass: 'p',
        auto: false,
        syncSubs: false,
      );
      final pullC = await deviceC.syncWithWebdav(client: cloudClient);
      expect(pullC.subscriptionsChanged, isFalse);
      expect(pullC.historyCount, 1);
      expect(pullC.favoriteCount, 1);
      expect(deviceC.getSubscriptions(), isEmpty);
      final afterOptOutCloud = jsonDecode(cloudPayload!) as Map<String, dynamic>;
      expect((afterOptOutCloud['subscriptions'] as List).length, 1);

      // 4. Device B deletes the public subscription -> records sub:<syncKey> tombstone -> Device A removes public sub while keeping its private sub intact!
      final subOnB = deviceB.getSubscriptions().single;
      await deviceB.removeSubscription(subOnB.id);
      await deviceB.syncWithWebdav(client: cloudClient);

      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageService.keySubscriptions: jsonEncode(
          deviceA.getSubscriptions().map((s) => s.toJson()).toList(),
        ),
        StorageService.keyWebdavUrl: 'https://dav.example/dav/MarcoMovie/',
        StorageService.keyWebdavUser: 'u',
        StorageService.keyWebdavPass: 'p',
        StorageService.keyWebdavAuto: false,
        StorageService.keyWebdavSyncSubs: true,
      });
      final deviceAReloaded = await StorageService.init();
      final resAfterDelete = await deviceAReloaded.syncWithWebdav(
        client: cloudClient,
      );
      expect(resAfterDelete.subscriptionsChanged, isTrue);
      expect(resAfterDelete.subscriptionCount, 0);
      final remainingA = deviceAReloaded.getSubscriptions();
      expect(remainingA.length, 1);
      expect(remainingA.single.isEffectivelyPrivate, isTrue);
    },
  );

  test(
    'performs live loopback LAN peer-to-peer bidirectional sync including subscriptions',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final hostStorage = await StorageService.init();
      await hostStorage.saveConfig(
        publicSubJsonA,
        origin: 'https://a.example/sub.json',
        customName: '客厅电视源',
      );
      await hostStorage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'siteA',
          id: 'epHost',
          title: '客厅在看',
          position: 600000,
          duration: 3600000,
          updated: 4000,
        ),
      );

      var hostCallbackSubsChanged = false;
      final server = await LanSyncServer.start(
        hostStorage,
        bindAddress: InternetAddress.loopbackIPv4,
        onSynced: ({
          required historyCount,
          required favoriteCount,
          required subscriptionCount,
          required changed,
          required subscriptionsChanged,
        }) {
          hostCallbackSubsChanged = subscriptionsChanged;
        },
      );
      addTearDown(server.close);

      // Snapshot host prefs before switching mock storage to peer device
      final hostPrefsSnapshot = <String, Object>{
        StorageService.keySubscriptions: jsonEncode(
          hostStorage.getSubscriptions().map((s) => s.toJson()).toList(),
        ),
        StorageService.keyWatchHistory: jsonEncode(
          hostStorage.getWatchHistory().map((e) => e.toJson()).toList(),
        ),
      };

      SharedPreferences.setMockInitialValues(<String, Object>{});
      final peerStorage = await StorageService.init();
      await peerStorage.saveConfig(
        publicSubJsonB,
        origin: 'https://b.example/sub.json',
        customName: '手机订阅源',
      );
      await peerStorage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'siteB',
          id: 'epPeer',
          title: '手机在看',
          position: 300000,
          duration: 2400000,
          updated: 4500,
        ),
      );
      final peerPayload = peerStorage.exportSyncPayload(nowMs: 4600);

      // Restore host mock preferences so server mutates hostStorage's store, then apply response to peerStorage
      SharedPreferences.setMockInitialValues(hostPrefsSnapshot);
      final hostLive = await StorageService.init();
      final liveServer = await LanSyncServer.start(
        hostLive,
        bindAddress: InternetAddress.loopbackIPv4,
        onSynced: ({
          required historyCount,
          required favoriteCount,
          required subscriptionCount,
          required changed,
          required subscriptionsChanged,
        }) {
          hostCallbackSubsChanged = subscriptionsChanged;
        },
      );
      addTearDown(liveServer.close);

      final httpResp = await http.post(
        Uri.parse(liveServer.syncEndpointForHost('127.0.0.1')),
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: utf8.encode(peerPayload),
      );
      expect(httpResp.statusCode, 200);
      expect(hostCallbackSubsChanged, isTrue);
      expect(hostLive.getSubscriptions().length, 2);
      expect(hostLive.getWatchHistory().length, 2);

      // Now apply returned merged payload onto a fresh new tablet device
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final tabletStorage = await StorageService.init();
      final tabletMerged = await tabletStorage.mergeSyncPayload(
        utf8.decode(httpResp.bodyBytes),
      );
      expect(tabletMerged.subscriptionsChanged, isTrue);
      expect(tabletMerged.subscriptionCount, 2);
      expect(tabletMerged.historyCount, 2);
      expect(
        tabletStorage
            .loadSavedConfig()!
            .publicSupportedSites
            .map((s) => s.key)
            .toSet(),
        {'siteA', 'siteB'},
      );
    },
  );

  test('normalizes Jianguoyun and WebDAV file URLs consistently', () {
    expect(
      StorageService.resolveWebdavFileUrl('https://dav.jianguoyun.com/dav/'),
      'https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json',
    );
    expect(
      StorageService.resolveWebdavFileUrl('https://dav.jianguoyun.com/dav'),
      'https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json',
    );
    expect(
      StorageService.resolveWebdavFileUrl('dav.jianguoyun.com/dav/'),
      'https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json',
    );
    expect(
      StorageService.resolveWebdavFileUrl(
        'https://dav.jianguoyun.com/dav/我的坚果云/',
      ),
      'https://dav.jianguoyun.com/dav/我的坚果云/marco-movie-sync.json',
    );
    expect(
      StorageService.resolveWebdavFileUrl(
        'https://dav.jianguoyun.com/dav/a/x.json',
      ),
      'https://dav.jianguoyun.com/dav/a/x.json',
    );
    expect(
      StorageService.resolveWebdavFileUrl('https://nas.local:5006/'),
      'https://nas.local:5006/marco-movie-sync.json',
    );
  });

  test(
    'provides actionable diagnostic message on WebDAV write failure',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();

      final mock404 = MockClient((req) async {
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'MKCOL') return http.Response('', 201);
        if (req.method == 'PUT') return http.Response('', 404);
        return http.Response('', 405);
      });

      await storage.saveWebdavConfig(
        url: 'https://dav.jianguoyun.com/dav/',
        user: 'alice',
        pass: 'secret',
        auto: false,
        syncSubs: true,
      );

      await expectLater(
        storage.syncWithWebdav(client: mock404),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('目标文件夹不存在或不可写。坚果云请在地址后加一个文件夹名'),
          ),
        ),
      );

      final mock405 = MockClient((req) async {
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'PUT') return http.Response('', 405);
        return http.Response('', 405);
      });

      await expectLater(
        storage.syncWithWebdav(client: mock405),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('服务器不允许写入'),
          ),
        ),
      );

      final mock423 = MockClient((req) async {
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'PUT') return http.Response('', 423);
        return http.Response('', 405);
      });

      await expectLater(
        storage.syncWithWebdav(client: mock423),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('文件被锁定'),
          ),
        ),
      );

      final mock507 = MockClient((req) async {
        if (req.method == 'GET') return http.Response('', 404);
        if (req.method == 'PUT') return http.Response('', 507);
        return http.Response('', 405);
      });

      await expectLater(
        storage.syncWithWebdav(client: mock507),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('空间不足'),
          ),
        ),
      );
    },
  );

  test(
    'WebDAV ETag concurrency: If-None-Match for absent file, If-Match for existing, graceful fallback, and 412 retry',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();
      await storage.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'alice',
        pass: 'secret',
        auto: false,
        syncSubs: false,
      );

      // 1. Initial push when remote file is absent (404) -> must send 'If-None-Match: *'
      String? sentIfNoneMatch;
      String? sentIfMatch;
      String? storedBlob;
      const currentEtag = '"etag-100"';

      final mockAbsent = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response('', 404);
        }
        if (req.method == 'PUT') {
          sentIfNoneMatch = req.headers['if-none-match'];
          sentIfMatch = req.headers['if-match'];
          storedBlob = utf8.decode(req.bodyBytes);
          return http.Response('', 201, headers: {'etag': currentEtag});
        }
        return http.Response('', 405);
      });

      await storage.syncWithWebdav(client: mockAbsent);
      expect(sentIfNoneMatch, equals('*'));
      expect(sentIfMatch, isNull);

      // 2. Subsequent sync with existing file returning ETag -> must send 'If-Match: "etag-100"'
      sentIfNoneMatch = null;
      sentIfMatch = null;
      final mockExistingWithEtag = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response(
            storedBlob ?? '',
            200,
            headers: {'etag': currentEtag},
          );
        }
        if (req.method == 'PUT') {
          sentIfNoneMatch = req.headers['if-none-match'];
          sentIfMatch = req.headers['if-match'];
          storedBlob = utf8.decode(req.bodyBytes);
          return http.Response('', 204, headers: {'etag': '"etag-101"'});
        }
        return http.Response('', 405);
      });

      await storage.syncWithWebdav(client: mockExistingWithEtag);
      expect(sentIfNoneMatch, isNull);
      expect(sentIfMatch, equals(currentEtag));

      // 3. Server does not provide ETag -> graceful fallback to unconditional PUT
      sentIfNoneMatch = null;
      sentIfMatch = null;
      final mockNoEtag = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response(storedBlob ?? '', 200);
        }
        if (req.method == 'PUT') {
          sentIfNoneMatch = req.headers['if-none-match'];
          sentIfMatch = req.headers['if-match'];
          storedBlob = utf8.decode(req.bodyBytes);
          return http.Response('', 204);
        }
        return http.Response('', 405);
      });

      await storage.syncWithWebdav(client: mockNoEtag);
      expect(sentIfNoneMatch, isNull);
      expect(sentIfMatch, isNull);

      // 4. HTTP 412 Precondition Failed triggers retry loop (GET -> merge -> PUT)
      var attempts = 0;
      var getCount = 0;
      final mock412Retry = MockClient((req) async {
        if (req.method == 'GET') {
          getCount++;
          return http.Response(
            storedBlob ?? '',
            200,
            headers: {'etag': getCount == 1 ? '"etag-old"' : '"etag-new"'},
          );
        }
        if (req.method == 'PUT') {
          attempts++;
          if (attempts == 1) {
            expect(req.headers['if-match'], equals('"etag-old"'));
            return http.Response('', 412);
          }
          expect(req.headers['if-match'], equals('"etag-new"'));
          storedBlob = utf8.decode(req.bodyBytes);
          return http.Response('', 204);
        }
        return http.Response('', 405);
      });

      await storage.syncWithWebdav(client: mock412Retry);
      expect(attempts, 2);
      expect(getCount, 2);

      // 5. HTTP 412 persists beyond maxRetries (2) -> throws FormatException with diagnosis
      final mock412Persistent = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response(
            storedBlob ?? '',
            200,
            headers: {'etag': '"etag-stale"'},
          );
        }
        if (req.method == 'PUT') {
          return http.Response('', 412);
        }
        return http.Response('', 405);
      });

      await expectLater(
        storage.syncWithWebdav(client: mock412Persistent),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('WebDAV 写入冲突 (HTTP 412)'),
          ),
        ),
      );
    },
  );

  test(
    'preserves private site watch history locally and re-reads fresh local state before merge writeback',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();

      await storage.saveConfig(
        publicSubJsonA,
        origin: 'https://a.example/sub.json',
      );
      await storage.saveConfig(
        privateSubJson,
        origin: 'https://secret.example/sub.json',
        isPrivate: true,
      );

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'siteA',
          id: 'v_pub',
          title: '公开剧集',
          position: 10000,
          duration: 60000,
          updated: 1000,
        ),
      );
      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'secretSite',
          id: 'v_priv',
          title: '私密剧集',
          position: 25000,
          duration: 90000,
          updated: 2000,
        ),
      );

      final pubHist = storage.getWatchHistory();
      expect(pubHist.map((e) => e.site).toList(), equals(['siteA']));

      final allHist = storage.getWatchHistory(forPrivate: true);
      expect(allHist.map((e) => e.site).toSet(), containsAll(['siteA', 'secretSite']));

      final exportedJson = storage.exportSyncPayload();
      expect(exportedJson.contains('secretSite'), isFalse);
      expect(exportedJson.contains('privInline'), isFalse);

      final remotePayload = jsonEncode({
        'schema': 'marco-movie-sync',
        'version': 2,
        'updated': 3000,
        'watch_history': [
          {
            'site': 'siteA',
            'id': 'v_pub_remote',
            'title': '远端公开剧集',
            'position': 50000,
            'duration': 60000,
            'updated': 3000,
          },
        ],
        'favorites': <dynamic>[],
        'tombstones': <String, int>{},
      });

      final mergeRes = await storage.mergeSyncPayload(remotePayload);
      expect(mergeRes.historyCount, 2);

      final allHistAfter = storage.getWatchHistory(forPrivate: true);
      expect(allHistAfter.any((e) => e.site == 'secretSite'), isTrue);
      expect(allHistAfter.any((e) => e.id == 'v_pub_remote'), isTrue);
      expect(allHistAfter.any((e) => e.id == 'v_pub'), isTrue);
    },
  );

  test(
    'protects against watch history JSON corruption, backs up raw string, and locks out destructive overwrites',
    () async {
      const corruptRaw = '{"corrupted": true, [malformed JSON...';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'watch_history': corruptRaw,
      });
      final storage = await StorageService.init();

      expect(storage.isHistoryCorrupted, isFalse);
      expect(storage.historyCorruptionNotifier.value, isFalse);

      final hist = storage.getWatchHistory();
      expect(hist, isEmpty);
      expect(storage.isHistoryCorrupted, isTrue);
      expect(storage.historyCorruptionNotifier.value, isTrue);

      final prefs = await SharedPreferences.getInstance();
      final backupKeys =
          prefs.getKeys().where((k) => k.startsWith('watch_history_corrupt_')).toList();
      expect(backupKeys, isNotEmpty);
      expect(prefs.getString(backupKeys.first), equals(corruptRaw));
      expect(prefs.getBool('watch_history_corrupted'), isTrue);

      await storage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 'siteA',
          id: 'v_new',
          title: '试图覆盖的条目',
        ),
      );
      expect(prefs.getString('watch_history'), equals(corruptRaw));

      await expectLater(
        storage.mergeSyncPayload(
          jsonEncode({
            'schema': 'marco-movie-sync',
            'version': 2,
            'updated': 5000,
            'watch_history': <dynamic>[],
            'favorites': <dynamic>[],
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('本地观看历史数据损坏'),
          ),
        ),
      );
    },
  );

  test(
    'scheduleAutoWebdavSync handles concurrent calls via _resyncRequested without throwing StateError',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();
      await storage.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'alice',
        pass: 'secret',
        auto: true,
        syncSubs: false,
      );

      expect(() {
        storage.scheduleAutoWebdavSync();
        storage.scheduleAutoWebdavSync(immediate: true);
        storage.scheduleAutoWebdavSync(immediate: true);
      }, returnsNormally);

      storage.cancelPendingAutoSync();
    },
  );
}

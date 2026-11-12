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
      final mockWebdav = MockClient((req) async {
        if (req.method == 'GET') {
          if (cloudBlob == null) return http.Response('', 404);
          return http.Response.bytes(utf8.encode(cloudBlob!), 200);
        }
        if (req.method == 'MKCOL') {
          mkcolCalled = true;
          folderCreated = true;
          return http.Response('', 201);
        }
        if (req.method == 'PUT') {
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
}

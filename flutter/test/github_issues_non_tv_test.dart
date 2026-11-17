import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_share.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/quark_drive.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';

import 'test_storage_helper.dart';

void main() {
  test(
    'Issue #57: prepare_platform.py injects user-selected.read-write entitlement for macOS',
    () {
      final script = File('prepare_platform.py').existsSync()
          ? File('prepare_platform.py').readAsStringSync()
          : File('flutter/prepare_platform.py').readAsStringSync();
      expect(
        script,
        contains('com.apple.security.files.user-selected.read-write'),
      );
    },
  );

  test(
    'Issue #31: Quark & UC share resolvers include >=15 MiB disguised .mp3 videos and ignore tiny audio',
    () async {
      final quarkClient = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'data': {'stoken': 'st_ok', 'title': 'Disguised Share'},
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/detail')) {
          return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'data': {
                'list': [
                  {
                    'fid': 'fid_ep1_mp3',
                    'file_name': 'S01E01.mp3',
                    'dir': false,
                    'file_type': 1,
                    'category': 2,
                    'size': 350 * 1024 * 1024, // 350 MiB disguised video
                    'share_fid_token': 'tok_ep1',
                  },
                  {
                    'fid': 'fid_ost_mp3',
                    'file_name': 'theme_song.mp3',
                    'dir': false,
                    'file_type': 1,
                    'category': 2,
                    'size': 4 * 1024 * 1024, // 4 MiB real song -> ignored
                    'share_fid_token': 'tok_ost',
                  },
                ],
              },
              'metadata': {'_total': 2},
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final episodes = await QuarkDriveClient.listPublicShareEpisodes(
        'https://pan.quark.cn/s/abcd1234efgh',
        httpClient: quarkClient,
      );
      expect(episodes.length, 1);
      expect(episodes.single.name, contains('S01E01.mp3'));

      // Also verify CloudShareClient (UC) with >=15 MiB .mp3 disguised video
      final ucClient = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'stoken': 'uc_tok'},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path.endsWith('/detail')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'list': [
                  {
                    'fid': 'uc_vid_mp3',
                    'file_name': '01.mp3',
                    'dir': false,
                    'file_type': 1,
                    'category': 2,
                    'size': 120 * 1024 * 1024,
                    'share_fid_token': 'uc_tok_1',
                  },
                  {
                    'fid': 'uc_tiny_mp3',
                    'file_name': 'bgm.mp3',
                    'dir': false,
                    'file_type': 1,
                    'category': 2,
                    'size': 3 * 1024 * 1024,
                    'share_fid_token': 'uc_tok_2',
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });
      final cloud = CloudShareClient(
        credentialReader: (_) async => '',
        client: ucClient,
      );
      final ucEps = await cloud.listShare('https://drive.uc.cn/s/xyz98765');
      expect(ucEps.length, 1);
      expect(ucEps.single.name, contains('01.mp3'));
    },
  );

  test(
    'Issue #44: webdavSyncHistory=false syncs public subscriptions while isolating local & remote watch history',
    () async {
      final parentStorage = await initTestStorage(
        fileStore: InMemoryStorageFileStore(),
        secureStore: InMemorySecureCredentialStore(),
      );
      const sharedSubJson =
          '{"sites":[{"key":"s1","name":"共享源","type":1,"api":"https://vod.example/api.php/provide/vod/"}]}';
      await parentStorage.saveSubscriptions([
        const SubscriptionEntry(
          id: 'sub_shared',
          name: '家庭共享源',
          url: 'https://config.example/family.json',
          rawContent: sharedSubJson,
          enabled: true,
          updatedAt: 1000,
        ),
      ]);
      await parentStorage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 's1',
          id: 'vid_parent_only',
          title: '父母没看过的剧',
          index: 2,
          episode: '第03集',
          position: 95000,
          duration: 180000,
          updated: 2000,
        ),
        immediate: true,
        triggerSync: false,
      );
      await parentStorage.toggleFavorite(
        const CmsSite(
          key: 's1',
          name: '共享源',
          type: 1,
          api: 'https://vod.example/api.php/provide/vod/',
        ),
        const CmsVideo(
          id: 'fav_parent_only',
          title: '私人收藏片单',
        ),
      );

      final initialCloudPayload = parentStorage.exportSyncPayload(nowMs: 3000);

      // Elder device has its own isolated storage and enables subscription sync ONLY (webdavSyncHistory = false)
      final elderStorage = await initTestStorage(
        fileStore: InMemoryStorageFileStore(),
        secureStore: InMemorySecureCredentialStore(),
      );
      await elderStorage.setWebdavSyncSubs(true);
      await elderStorage.setWebdavSyncHistory(false);
      await elderStorage.upsertWatchHistory(
        const WatchHistoryEntry(
          site: 's1',
          id: 'vid_elder_local',
          title: '长辈自己的戏曲',
          index: 0,
          episode: '第01集',
          position: 42000,
          duration: 120000,
          updated: 2500,
        ),
        immediate: true,
        triggerSync: false,
      );

      final merged = await elderStorage.mergeSyncPayload(
        initialCloudPayload,
        nowMs: 4000,
      );

      // 1. Elder device received the shared subscription!
      expect(merged.subscriptionCount, 1);
      expect(elderStorage.getSubscriptions().single.name, '家庭共享源');

      // 2. Elder device did NOT import parent's watch history or favorites!
      final elderHist = elderStorage.getWatchHistory();
      expect(elderHist.map((e) => e.id).toList(), ['vid_elder_local']);
      expect(elderStorage.getFavorites(forPrivate: false), isEmpty);

      // 3. The payload written back to WebDAV still preserves parent's remote watch history & favorites!
      final writtenBack = jsonDecode(merged.payloadJson) as Map<String, dynamic>;
      final cloudHist = (writtenBack['watch_history'] as List).cast<Map>();
      final cloudFavs = (writtenBack['favorites'] as List).cast<Map>();
      expect(cloudHist.map((e) => e['id']).toList(), ['vid_parent_only']);
      expect(cloudFavs.map((f) => f['id']).toList(), ['fav_parent_only']);
    },
  );
}

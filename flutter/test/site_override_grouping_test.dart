import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';

import 'test_storage_helper.dart';

void main() {
  const sampleSubscriptionRaw = '''
{
  "sites": [
    {
      "key": "cms_alpha",
      "name": "极速一号",
      "type": 1,
      "api": "https://cms-alpha.example/api.php/provide/vod/",
      "searchable": 1
    },
    {
      "key": "cms_beta",
      "name": "极速二号",
      "type": 1,
      "api": "https://cms-beta.example/api.php/provide/vod/",
      "searchable": 1
    },
    {
      "key": "jar_legacy",
      "name": "旧版插件源",
      "type": 3,
      "api": "csp_UnknownLegacyJar",
      "jar": "https://cms-alpha.example/custom.jar",
      "searchable": 1
    }
  ]
}
''';

  test(
    'manual single/batch grouping, field editing, deletion, restore, and subscription refresh survival',
    () async {
      final storage = await initTestStorage();
      final initial = await storage.saveConfig(
        sampleSubscriptionRaw,
        origin: 'https://sub.example/config.json',
      );
      expect(initial.sites.length, 3);
      final legacyBefore = initial.sites.firstWhere((s) => s.key == 'jar_legacy');
      expect(legacyBefore.supported, isFalse);

      // 1. Batch manual grouping
      final alpha = initial.sites.firstWhere((s) => s.key == 'cms_alpha');
      final beta = initial.sites.firstWhere((s) => s.key == 'cms_beta');
      await storage.updateSitesGroupBatch([alpha, beta], '主力高清');

      var loaded = storage.loadSavedConfig()!;
      expect(
        loaded.sites.firstWhere((s) => s.key == 'cms_alpha').group,
        '主力高清',
      );
      expect(
        loaded.sites.firstWhere((s) => s.key == 'cms_beta').group,
        '主力高清',
      );

      // 2. Single-line manual edit: convert unsupported JAR site to standard HTTP JSON CMS + custom playUrl/ext/searchable
      await storage.saveSiteOverride(
        legacyBefore,
        const SiteOverride(
          name: '修复后直连源',
          group: '备用线路',
          api: 'https://repaired.example/api.php/provide/vod/',
          playUrl: 'https://parse.example/?url=',
          ext: 'token=abc',
          searchable: false,
        ),
      );

      loaded = storage.loadSavedConfig()!;
      final repaired = loaded.sites.firstWhere((s) => s.key == 'jar_legacy');
      expect(repaired.name, '修复后直连源');
      expect(repaired.group, '备用线路');
      expect(repaired.api, 'https://repaired.example/api.php/provide/vod/');
      expect(repaired.sourceApi, 'csp_UnknownLegacyJar');
      expect(repaired.playUrl, 'https://parse.example/?url=');
      expect(repaired.ext, 'token=abc');
      expect(repaired.searchable, isFalse);
      expect(repaired.type, 1);
      expect(repaired.supported, isTrue);
      expect(storage.hasSiteOverride(repaired), isTrue);
      expect(storage.getOriginalSite(repaired)?.name, '旧版插件源');

      // 3. Re-saving / refreshing the subscription preserves overrides and groups via stable sourceApi identity
      await storage.saveConfig(
        sampleSubscriptionRaw,
        origin: 'https://sub.example/config.json',
      );
      loaded = storage.loadSavedConfig()!;
      expect(loaded.sites.firstWhere((s) => s.key == 'cms_alpha').group, '主力高清');
      final repairedAfterRefresh =
          loaded.sites.firstWhere((s) => s.key == 'jar_legacy');
      expect(repairedAfterRefresh.name, '修复后直连源');
      expect(
        repairedAfterRefresh.api,
        'https://repaired.example/api.php/provide/vod/',
      );
      expect(repairedAfterRefresh.supported, isTrue);

      // 4. Single & batch deletion + removed site inspection + single & full restore
      await storage.removeSite(storage.siteIdentityOf(beta));
      await storage.removeSitesBatch([repairedAfterRefresh]);
      loaded = storage.loadSavedConfig()!;
      expect(loaded.sites.map((s) => s.key).toList(), ['cms_alpha']);

      final removedList = storage.getRemovedSiteEntries(privateMode: false);
      expect(removedList.map((e) => e.site.key).toSet(), {'cms_beta', 'jar_legacy'});
      // Even while deleted, the override name is retained in getRemovedSiteEntries
      expect(
        removedList.firstWhere((e) => e.site.key == 'jar_legacy').site.name,
        '修复后直连源',
      );

      final betaEntry = removedList.firstWhere((e) => e.site.key == 'cms_beta');
      await storage.restoreSite(betaEntry.identity);
      loaded = storage.loadSavedConfig()!;
      expect(loaded.sites.map((s) => s.key).toSet(), {'cms_alpha', 'cms_beta'});

      await storage.resetRemovedSites(privateMode: false);
      loaded = storage.loadSavedConfig()!;
      expect(loaded.sites.length, 3);

      // 5. Reset single-line override back to subscription original
      final currentRepaired =
          loaded.sites.firstWhere((s) => s.key == 'jar_legacy');
      await storage.saveSiteOverride(currentRepaired, null);
      loaded = storage.loadSavedConfig()!;
      final reverted = loaded.sites.firstWhere((s) => s.key == 'jar_legacy');
      expect(reverted.name, '旧版插件源');
      expect(reverted.api, 'csp_UnknownLegacyJar');
      expect(reverted.supported, isFalse);
    },
  );

  test(
    'backup export/import preserves public site overrides and blocks privacy-boundary group spoofing',
    () async {
      final storage1 = await initTestStorage();
      final cfg = await storage1.saveConfig(
        sampleSubscriptionRaw,
        origin: 'https://sub.example/config.json',
      );
      final alpha = cfg.sites.firstWhere((s) => s.key == 'cms_alpha');

      // Public site cannot be moved into a group containing 隐私 or 私密
      await expectLater(
        storage1.saveSiteOverride(alpha, const SiteOverride(group: '我的隐私分组')),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        storage1.updateSitesGroupBatch([alpha], '私密收藏'),
        throwsA(isA<FormatException>()),
      );

      await storage1.saveSiteOverride(
        alpha,
        const SiteOverride(
          name: '一号自定义名',
          group: '家庭影院',
          playUrl: 'https://parse.example/?v=',
        ),
      );
      final backupJson = storage1.exportBackupJson();
      expect(jsonDecode(backupJson), isA<Map>());

      final storage2 = await initTestStorage();
      final restored = await storage2.importBackupJson(backupJson);
      expect(restored, isNotNull);
      final restoredAlpha =
          restored!.sites.firstWhere((s) => s.key == 'cms_alpha');
      expect(restoredAlpha.name, '一号自定义名');
      expect(restoredAlpha.group, '家庭影院');
      expect(restoredAlpha.playUrl, 'https://parse.example/?v=');
    },
  );
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const combinedSubJson = '''
  {
    "sites": [
      {"key": "pub_site_1", "name": "公开站点1", "type": 1, "api": "https://pub1.example/vod"},
      {"key": "priv_site_1", "name": "私密站点1", "type": 1, "api": "https://priv1.example/vod", "isPrivate": true}
    ]
  }
  ''';

  final singleSubscription = [
    SubscriptionEntry(
      id: 'sub_main',
      name: '主要订阅',
      url: 'https://subs.example/main.json',
      rawContent: combinedSubJson,
      format: 'JSON',
      enabled: true,
    ),
  ];

  final initialHistoryJson = jsonEncode([
    {
      'site': 'pub_site_1',
      'id': 'vid_pub_1',
      'title': '公开影片1',
      'episode': '第1集',
      'updated': 1000,
    },
    {
      'site': 'priv_site_1',
      'id': 'vid_priv_1',
      'title': '私密影片1',
      'episode': '第1集',
      'updated': 2000,
    },
  ]);

  test('D2: Calling getWatchHistory() 1000 times triggers CmsParser.parseConfig at most once', () async {
    SharedPreferences.setMockInitialValues({
      StorageService.keySubscriptions: jsonEncode(singleSubscription.map((s) => s.toJson()).toList()),
      StorageService.keyWatchHistory: initialHistoryJson,
    });

    final storage = await StorageService.init();
    CmsParser.resetParseConfigCallCount();

    // Call getWatchHistory 1000 times
    for (int i = 0; i < 1000; i++) {
      final history = storage.getWatchHistory();
      expect(history.length, 1);
      expect(history.first.site, 'pub_site_1');
    }

    // Config was parsed at most once across all 1000 invocations
    expect(CmsParser.parseConfigCallCount, lessThanOrEqualTo(1));
  });

  test('D2: Cache invalidation on subscription/order write causes re-parse on next read', () async {
    SharedPreferences.setMockInitialValues({
      StorageService.keySubscriptions: jsonEncode(singleSubscription.map((s) => s.toJson()).toList()),
      StorageService.keyWatchHistory: initialHistoryJson,
    });

    final storage = await StorageService.init();
    CmsParser.resetParseConfigCallCount();

    // First read triggers initial parse (single subscription -> exactly 1 parse)
    final hist1 = storage.getWatchHistory();
    expect(hist1.length, 1);
    final countAfterFirstRead = CmsParser.parseConfigCallCount;
    expect(countAfterFirstRead, 1);

    // Repeated read uses memory cache without re-parsing
    final hist2 = storage.getWatchHistory();
    expect(hist2.length, 1);
    expect(CmsParser.parseConfigCallCount, countAfterFirstRead);

    // 1. Mutate subscriptions via upsertSubscriptions
    await storage.upsertSubscriptions([
      SubscriptionEntry(
        id: 'sub_pub_new',
        name: '新增订阅',
        url: 'https://subs.example/new.json',
        rawContent: '''{"sites":[{"key":"pub_site_3","name":"公开站点3","type":1,"api":"https://pub3.example/vod"}]}''',
        format: 'JSON',
        enabled: true,
      ),
    ]);

    // Next read must re-parse because cache was invalidated
    final countAfterUpsert = CmsParser.parseConfigCallCount;
    expect(countAfterUpsert, greaterThan(countAfterFirstRead));

    // 2. Mutate site order via reorderSites
    await storage.reorderSites(['["sub_pub_new","pub_site_3","https://pub3.example/vod"]']);
    // Reading config causes re-parse
    storage.loadSavedConfig();
    final countAfterReorder = CmsParser.parseConfigCallCount;
    expect(countAfterReorder, greaterThan(countAfterUpsert));

    // 3. Mutate via deleteSubscription
    await storage.deleteSubscription('sub_pub_new');
    final countAfterDelete = CmsParser.parseConfigCallCount;
    expect(countAfterDelete, greaterThan(countAfterReorder));
  });

  test('D2: Private site filtering returns identical results with and without cache', () async {
    SharedPreferences.setMockInitialValues({
      StorageService.keySubscriptions: jsonEncode(singleSubscription.map((s) => s.toJson()).toList()),
      StorageService.keyWatchHistory: initialHistoryJson,
    });

    final storage = await StorageService.init();

    // 1. First read (uncached -> computes private keys & history cache)
    final history1 = storage.getWatchHistory();
    expect(history1.length, 1);
    expect(history1.first.site, 'pub_site_1');
    expect(history1.first.id, 'vid_pub_1');

    // 2. Second read (from memory cache)
    final history2 = storage.getWatchHistory();
    expect(history2.length, 1);
    expect(history2.first.site, history1.first.site);
    expect(history2.first.id, history1.first.id);

    // 3. Upsert a private site entry directly: must be rejected / filtered
    await storage.upsertWatchHistory(
      WatchHistoryEntry(
        site: 'priv_site_1',
        id: 'vid_priv_2',
        title: '私密影片2',
        episode: '第2集',
        updated: 3000,
      ),
    );
    expect(storage.getWatchHistory().length, 1);
    expect(storage.getWatchHistory().first.site, 'pub_site_1');

    // 4. Upsert a public site entry: cache updates synchronously
    await storage.upsertWatchHistory(
      WatchHistoryEntry(
        site: 'pub_site_1',
        id: 'vid_pub_2',
        title: '公开影片2',
        episode: '第2集',
        updated: 4000,
      ),
    );
    final historyAfterUpsert = storage.getWatchHistory();
    expect(historyAfterUpsert.length, 2);
    expect(historyAfterUpsert.map((e) => e.id).toList(), ['vid_pub_2', 'vid_pub_1']);

    // 5. Invalidate config cache and verify uncached re-computation produces identical output
    await storage.reorderSites([]);
    final historyAfterInvalidation = storage.getWatchHistory();
    expect(historyAfterInvalidation.length, 2);
    expect(historyAfterInvalidation.map((e) => e.id).toList(), ['vid_pub_2', 'vid_pub_1']);
  });
}

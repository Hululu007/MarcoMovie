import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'M-W5 & 9d: AdaptiveShell onWindowClose flushes history before sync, deduplicates dispose flush, and calls setPreventClose(false) on dispose',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();
      final client = CmsClient();
      final events = <String>[];
      final preventCloseCalls = <bool>[];
      var historyFlushCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            storage: storage,
            client: client,
            onSetPreventCloseForTest: (prevent) async {
              preventCloseCalls.add(prevent);
              events.add('setPreventClose:$prevent');
            },
            onFlushHistoryForTest: () async {
              historyFlushCalls++;
              events.add('flushHistory');
            },
            onFlushSyncForTest: (_) async {
              events.add('flushSync');
            },
            onCloseHostForTest: () async {
              events.add('closeHost');
            },
            onCloseScriptsForTest: () async {
              events.add('closeScripts');
            },
            onDestroyWindowForTest: () async {
              events.add('destroy');
            },
          ),
        ),
      );
      await tester.pump();

      final dynamic shellState = tester.state(find.byType(AdaptiveShell));
      await (shellState.onWindowClose() as Future<void>);

      expect(
        events,
        equals([
          'setPreventClose:true',
          'flushHistory',
          'flushSync',
          'closeHost',
          'closeScripts',
          'setPreventClose:false',
          'destroy',
        ]),
      );

      // Dispose AdaptiveShell: must call setPreventClose(false) AND NOT re-run flushPendingHistory (9d)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(historyFlushCalls, 1);
      expect(preventCloseCalls.last, isFalse);
      expect(
        preventCloseCalls.where((v) => v == false).length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  testWidgets(
    'M-W7: AdaptiveShell does not trigger immediate sync on AppLifecycleState.inactive',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();
      await storage.saveWebdavConfig(
        url: 'https://dav.example/dav/MarcoMovie/',
        user: 'alice',
        pass: 'secret',
        auto: true,
        syncSubs: false,
      );
      storage.setWebdavClientForTesting(
        MockClient((req) async => http.Response('', 204)),
      );
      storage.cancelPendingAutoSync();

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            storage: storage,
            client: CmsClient(),
            onSetPreventCloseForTest: (_) async {},
          ),
        ),
      );
      await tester.pump();
      storage.cancelPendingAutoSync();

      // Desktop focus loss sends AppLifecycleState.inactive -> must NOT schedule immediate sync
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(storage.hasPendingAutoSyncForTesting, isFalse);

      // Backgrounding sends AppLifecycleState.paused -> schedules auto sync
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(storage.hasPendingAutoSyncForTesting, isTrue);

      storage.cancelPendingAutoSync();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'M-W7: playback throttles WebDAV auto-pushes to at most once every 5 minutes',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = await StorageService.init();
      await storage.saveWebdavConfig(
        url: 'https://throttle-dav.example/dav/MarcoMovie/',
        user: 'alice',
        pass: 'secret',
        auto: true,
        syncSubs: false,
      );
      var syncPutCount = 0;
      storage.setWebdavClientForTesting(
        MockClient((req) async {
          if (req.method == 'GET') return http.Response('', 404);
          if (req.method == 'PUT') {
            syncPutCount++;
            return http.Response('', 201);
          }
          return http.Response('', 201);
        }),
      );
      storage.cancelPendingAutoSync();

      const now = 1000000;
      storage.scheduleAutoWebdavSync(immediate: false, nowMs: now);
      await tester.pump(const Duration(seconds: 4));
      expect(syncPutCount, 1);

      final firstPushMs = storage.lastHistoryAutoPushMsForTesting;
      // Simulate playback saves at +15s, +60s, +180s -> must NOT push before 5 minutes
      storage.scheduleAutoWebdavSync(
        immediate: false,
        nowMs: firstPushMs + 15000,
      );
      storage.scheduleAutoWebdavSync(
        immediate: false,
        nowMs: firstPushMs + 60000,
      );
      storage.scheduleAutoWebdavSync(
        immediate: false,
        nowMs: firstPushMs + 180000,
      );
      await tester.pump(const Duration(minutes: 4));
      expect(syncPutCount, 1);

      // Once 5 minutes elapse since the first push, the throttled push executes
      await tester.pump(const Duration(minutes: 1, seconds: 5));
      expect(syncPutCount, 2);

      storage.cancelPendingAutoSync();
    },
  );
}

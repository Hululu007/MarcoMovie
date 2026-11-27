import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/main.dart' show AppScrollBehavior;
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/cloud_sync_panel.dart';
import 'package:marco_movie/ui/desktop_horizontal_scroller.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _FailingSecureBackend implements SecureStorageBackend {
  final Map<String, String> data = <String, String>{};
  int failOnWriteNumber;
  bool failAllWrites;
  bool failAllDeletes = false;
  int _writeCount = 0;

  _FailingSecureBackend({
    this.failOnWriteNumber = -1,
    this.failAllWrites = false,
  });

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    _writeCount++;
    if (failAllWrites || _writeCount == failOnWriteNumber) {
      throw StateError('Simulated secure storage write failure');
    }
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failAllDeletes) {
      throw StateError('Simulated secure storage delete failure');
    }
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M-F4: flutter_secure_storage migration, .bak preservation & _persist throw', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('r2_mf4_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('FlutterSecureStorageBackend configures Windows DPAPI and Apple Keychain options', () {
      const storage = FlutterSecureStorageBackend.defaultStorage;
      expect(
        storage.wOptions.toMap()['useBackwardCompatibility'],
        equals('false'),
      );
      expect(
        storage.iOptions.toMap()['accessibility'],
        equals('first_unlock'),
      );
      expect(
        storage.mOptions.toMap()['accessibility'],
        equals('first_unlock'),
      );
      expect(
        storage.mOptions.toMap()['useDataProtectionKeyChain'],
        equals('false'),
        reason: 'Ad-hoc signed macOS builds must use legacy file-based Keychain to avoid -34018',
      );
    });

    test('Migrates legacy secure_credentials.enc only deleting old file after write succeeds', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      await encFile.writeAsString(
        DefaultSecureCredentialStore.encryptLegacyPayloadForTest({
          StorageService.keyWebdavPass: 'dav_secret_migrated',
          StorageService.keyQuarkCookie: 'quark_cookie_migrated',
        }),
        flush: true,
      );

      // 1. Mid-migration failure must throw on direct read AND must not crash StorageService.init(),
      //    while keeping secure_credentials.enc intact on disk for next startup retry.
      final flakyBackend = _FailingSecureBackend(failOnWriteNumber: 2);
      final failingStore = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: flakyBackend,
      );
      await expectLater(
        failingStore.read(StorageService.keyWebdavPass),
        throwsStateError,
      );
      SharedPreferences.setMockInitialValues({});
      final survivingStorage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: DefaultSecureCredentialStore(
          dataDirectory: tempDir,
          backend: _FailingSecureBackend(failAllWrites: true),
        ),
        pbkdf2Runner: <T>(c) => Future<T>.sync(c),
      );
      expect(survivingStorage.webdavPass, isEmpty);
      expect(
        await encFile.exists(),
        isTrue,
        reason: 'Old legacy file must remain untouched when new backend write fails',
      );

      // 2. Subsequent startup with healthy backend completes migration and deletes old file
      final healthyBackend = InMemorySecureCredentialStore();
      final healthyStore = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: healthyBackend,
      );
      expect(
        await healthyStore.read(StorageService.keyWebdavPass),
        equals('dav_secret_migrated'),
      );
      expect(
        await healthyStore.read(StorageService.keyQuarkCookie),
        equals('quark_cookie_migrated'),
      );
      expect(await encFile.exists(), isFalse);
      expect(healthyStore.didLegacyMigrationFail, isFalse);
    });

    test('Decryption failure preserves legacy file as .bak and triggers user re-entry notice', () async {
      final encFile = File('${tempDir.path}/secure_credentials.enc');
      await encFile.writeAsString(
        'mm_sec_v1:00112233445566778899aabbccddeeff:00112233445566778899aabbccddeeff:deadbeef:cafebabe',
        flush: true,
      );

      SharedPreferences.setMockInitialValues({});
      final store = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: InMemorySecureCredentialStore(),
      );
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: store,
        pbkdf2Runner: <T>(c) => Future<T>.sync(c),
      );

      final bakFile = File('${tempDir.path}/secure_credentials.enc.bak');
      expect(await encFile.exists(), isFalse);
      expect(await bakFile.exists(), isTrue);
      expect(storage.credentialMigrationFailureNotifier.value, isTrue);
      expect(storage.consumeCredentialMigrationFailureNotice(), isTrue);
      expect(storage.consumeCredentialMigrationFailureNotice(), isFalse);
    });

    test('_persist failure throws and StorageService preserves previous secret without deleting prefs', () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyWebdavPass: 'initial_prefs_secret',
      });
      final backend = _FailingSecureBackend(failAllWrites: true);
      final store = DefaultSecureCredentialStore(
        dataDirectory: tempDir,
        backend: backend,
      );

      // Startup migration fails to write -> prefs secret MUST NOT be deleted
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: store,
        pbkdf2Runner: <T>(c) => Future<T>.sync(c),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(StorageService.keyWebdavPass),
        equals('initial_prefs_secret'),
      );

      // Explicit write failure MUST throw and roll back cache
      await expectLater(
        storage.saveWebdavConfig(
          url: 'https://dav.example/',
          user: 'u',
          pass: 'new_secret_that_fails',
          auto: false,
        ),
        throwsStateError,
      );
      expect(storage.webdavPass, equals('initial_prefs_secret'));

      backend.failAllDeletes = true;
      await expectLater(store.delete('any_key'), throwsStateError);
    });
  });

  group('M-F5: Desktop-only mouse scroll drag + mouse drag text selection in inputs', () {
    test('AppScrollBehavior includes unknown on all platforms and mouse only on desktop', () {
      const behavior = AppScrollBehavior();

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(behavior.dragDevices, contains(PointerDeviceKind.unknown));
        expect(behavior.dragDevices, contains(PointerDeviceKind.mouse));
        expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(behavior.dragDevices, contains(PointerDeviceKind.unknown));
        expect(behavior.dragDevices, isNot(contains(PointerDeviceKind.mouse)));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        expect(behavior.dragDevices, contains(PointerDeviceKind.unknown));
        expect(behavior.dragDevices, isNot(contains(PointerDeviceKind.mouse)));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Mouse drag selects text inside TextField, TextFormField, and CupertinoTextField on desktop', (tester) async {
      final textCtrl = TextEditingController(text: 'HelloMarcoMovieSelection');
      final formCtrl = TextEditingController(text: 'FormFieldDragSelectionTest');
      final searchCtrl = TextEditingController(text: 'CupertinoSearchDragSelect');
      final listController = ScrollController();
      addTearDown(() {
        textCtrl.dispose();
        formCtrl.dispose();
        searchCtrl.dispose();
        listController.dispose();
      });

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Scaffold(
              body: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextSelectionMouseGuard(
                      child: TextField(
                        key: const ValueKey('guarded-textfield'),
                        controller: textCtrl,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextSelectionMouseGuard(
                      child: TextFormField(
                        key: const ValueKey('guarded-textformfield'),
                        controller: formCtrl,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: AppleSearchField(
                      controller: searchCtrl,
                    ),
                  ),
                  SizedBox(
                    height: 60,
                    child: ListView.builder(
                      key: const ValueKey('desktop-draggable-list'),
                      controller: listController,
                      scrollDirection: Axis.horizontal,
                      itemCount: 30,
                      itemBuilder: (_, i) => SizedBox(
                        width: 100,
                        child: Center(child: Text('Item $i')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Mouse drag inside TextField selects characters
        final tfRect = tester.getRect(find.byKey(const ValueKey('guarded-textfield')));
        final start1 = Offset(tfRect.left + 8, tfRect.center.dy);
        final gesture1 = await tester.startGesture(
          start1,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 50));
        await gesture1.moveTo(Offset(tfRect.left + 160, tfRect.center.dy));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture1.up();
        await tester.pumpAndSettle();

        expect(textCtrl.selection.isValid, isTrue);
        expect(
          textCtrl.selection.isCollapsed,
          isFalse,
          reason: 'Mouse drag inside TextField must create a non-collapsed text selection',
        );
        expect(
          textCtrl.selection.end - textCtrl.selection.start,
          greaterThan(2),
        );

        // 2. Mouse drag inside TextFormField selects characters
        final tffRect = tester.getRect(find.byKey(const ValueKey('guarded-textformfield')));
        final gesture2 = await tester.startGesture(
          Offset(tffRect.left + 8, tffRect.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 50));
        await gesture2.moveTo(Offset(tffRect.left + 160, tffRect.center.dy));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture2.up();
        await tester.pumpAndSettle();

        expect(formCtrl.selection.isCollapsed, isFalse);
        expect(formCtrl.selection.end - formCtrl.selection.start, greaterThan(2));

        // 3. Desktop scrollable ListView still supports mouse drag scrolling
        expect(listController.offset, equals(0.0));
        await tester.drag(
          find.byKey(const ValueKey('desktop-draggable-list')),
          const Offset(-250, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(listController.offset, greaterThan(100.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Diagonal mouse drag inside modal sheet multiline input selects text without scrolling ancestor sheet', (tester) async {
      final multilineCtrl = TextEditingController(
        text: 'Line1 MarcoMovie\nLine2 DesktopSelection\nLine3 SheetScrollGuard\nLine4 EndOfText',
      );
      final sheetScrollCtrl = ScrollController();
      final stripScrollCtrl = ScrollController();
      addTearDown(() {
        multilineCtrl.dispose();
        sheetScrollCtrl.dispose();
        stripScrollCtrl.dispose();
      });

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const ValueKey('open-sheet'),
                    onPressed: () {
                      showAppleModalSheet<void>(
                        context: ctx,
                        title: '测试弹窗文本选择',
                        builder: (_) => SingleChildScrollView(
                          controller: sheetScrollCtrl,
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: TextSelectionMouseGuard(
                                  child: CupertinoTextField(
                                    key: const ValueKey('sheet-multiline-input'),
                                    controller: multilineCtrl,
                                    maxLines: 5,
                                    minLines: 4,
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: 48,
                                child: DesktopHorizontalScroller(
                                  controller: stripScrollCtrl,
                                  child: ListView.builder(
                                    key: const ValueKey('sheet-horizontal-strip'),
                                    controller: stripScrollCtrl,
                                    scrollDirection: Axis.horizontal,
                                    itemCount: 30,
                                    itemBuilder: (_, i) => SizedBox(
                                      width: 90,
                                      child: Center(child: Text('Chip $i')),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 900),
                            ],
                          ),
                        ),
                      );
                    },
                    child: const Text('打开弹窗'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-sheet')));
        await tester.pumpAndSettle();

        final inputRect = tester.getRect(find.byKey(const ValueKey('sheet-multiline-input')));
        final drag = await tester.startGesture(
          Offset(inputRect.left + 12, inputRect.top + 14),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 40));
        // Move diagonally (both dx and dy > slop) so an unguarded vertical SingleChildScrollView would steal it
        await drag.moveBy(const Offset(120, 42));
        await tester.pump(const Duration(milliseconds: 40));
        await drag.up();
        await tester.pumpAndSettle();

        expect(
          sheetScrollCtrl.offset,
          equals(0.0),
          reason: 'Ancestor modal sheet SingleChildScrollView must not steal diagonal mouse drag',
        );
        expect(multilineCtrl.selection.isCollapsed, isFalse);
        expect(multilineCtrl.selection.end - multilineCtrl.selection.start, greaterThan(4));

        // Meanwhile DesktopHorizontalScroller inside the sheet still supports mouse drag scrolling
        await tester.drag(
          find.byKey(const ValueKey('sheet-horizontal-strip')),
          const Offset(-220, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(stripScrollCtrl.offset, greaterThan(80.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('M-F6: PBKDF2 Isolate.run & UI loading indicator', () {
    test('Real Isolate.run executes setPrivacyPassword, verifyPrivacyPassword, and legacy upgrade', () async {
      const legacyPin = '3579';
      final legacyHash = sha256.convert(utf8.encode('mm_pin_v1:$legacyPin')).toString();
      SharedPreferences.setMockInitialValues({
        StorageService.keyPrivacyPassword: 'sha256:4:$legacyHash',
      });

      // Uses default Isolate.run runner!
      final storage = await StorageService.init(
        fileStore: InMemoryStorageFileStore(),
        secureStore: InMemorySecureCredentialStore(),
      );

      expect(await storage.verifyPrivacyPassword('0000'), isFalse);
      expect(await storage.verifyPrivacyPassword('3579'), isTrue);
      expect(storage.privacyPassword, startsWith('pbkdf2:sha256:4:100000:'));

      await storage.setPrivacyPassword('8642');
      expect(await storage.verifyPrivacyPassword('8642'), isTrue);
      expect(await storage.verifyPrivacyPassword('3579'), isFalse);
    });

    testWidgets('PIN dialog displays loading indicator while PBKDF2 runs asynchronously', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Completer<void>? gate;
      final storage = await initTestStorage(
        pbkdf2Runner: <T>(computation) async {
          final activeGate = gate;
          if (activeGate != null) {
            await activeGate.future;
          }
          return computation();
        },
      );
      await storage.setPrivacyPassword('1234');
      await storage.saveConfig(
        '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
      );

      gate = Completer<void>();
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(storage: storage, client: client)),
      );
      await tester.pump(const Duration(milliseconds: 400));

      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('home-brand-logo')));
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.pump(const Duration(milliseconds: 400));

      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
      }
      await tester.pump();

      // Loading indicator must be visible while background PBKDF2 is running
      expect(find.byKey(const ValueKey('privacy-pin-loading')), findsOneWidget);
      expect(find.text('正在验证密码…'), findsOneWidget);

      gate.complete();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('privacy-pin-loading')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('M-F7: Sheet-owned ScrollControllers prevent multi-attach during exit animation', () {
    testWidgets('Reopening search sheet and source picker during exit animation does not throw', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final storage = await initTestStorage(
        initialPrefs: {
          StorageService.keySearchHistory: jsonEncode(['流浪地球', '三体', '让子弹飞']),
        },
      );
      await storage.saveConfig(
        jsonEncode({
          'sites': [
            {'key': 's1', 'name': '测试源', 'type': 1, 'api': 'https://a.example/api', 'group': '主力'},
            {'key': 's2', 'name': '备用源', 'type': 1, 'api': 'https://b.example/api', 'group': '专线'},
          ],
        }),
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(storage: storage, client: client)),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // 1. Open Global Search sheet -> pop -> immediately reopen mid-transition
      await tester.tap(find.byKey(const ValueKey('home-search-button')));
      await tester.pump(const Duration(milliseconds: 120));
      Navigator.of(tester.element(find.byType(AdaptiveShell))).pop();
      await tester.pump(const Duration(milliseconds: 40)); // still animating out!
      await tester.tap(find.byKey(const ValueKey('home-search-button')), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(AdaptiveShell))).pop();
      await tester.pump(const Duration(milliseconds: 400));

      // 2. Open Source Picker sheet -> pop -> immediately reopen mid-transition
      await tester.tap(find.text('测试源').first);
      await tester.pump(const Duration(milliseconds: 120));
      Navigator.of(tester.element(find.byType(AdaptiveShell))).pop();
      await tester.pump(const Duration(milliseconds: 40)); // still animating out!
      await tester.tap(find.text('测试源').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(AdaptiveShell))).pop();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Minor 6a & 6b: Unified 3.0x speed cap & cleartext HTTP warning only on change', () {
    test('StorageService playSpeed and backup restore unify upper limit at 3.0x', () async {
      final storage = await initTestStorage();
      expect(StorageService.maxPlaySpeed, equals(3.0));
      await storage.setPlaySpeed(2.75);
      expect(storage.playSpeed, equals(2.75));
      await storage.setPlaySpeed(3.0);
      expect(storage.playSpeed, equals(3.0));
      await storage.setPlaySpeed(4.5);
      expect(storage.playSpeed, equals(3.0));

      final backup = CmsParser.encodeBackupPayload(
        origin: 'https://a.example/cfg.json',
        rawConfig: jsonEncode({
          'sites': [
            {'key': 's1', 'name': '测试源', 'type': 1, 'api': 'https://a.example/api'},
          ],
        }),
        settings: {StorageService.keyPlaySpeed: 2.75},
      );
      await storage.importBackupJson(backup);
      expect(storage.playSpeed, equals(2.75));
    });

    test('Cleartext HTTP warning triggers only when URL or password changed', () {
      expect(
        CloudSyncSettingsPanel.shouldPromptCleartextHttpWarning(
          url: 'http://dav.example:5005/dav/',
          password: 'secret',
          savedUrl: '',
          savedPassword: '',
        ),
        isTrue,
      );
      // Unchanged URL & password -> should NOT prompt again
      expect(
        CloudSyncSettingsPanel.shouldPromptCleartextHttpWarning(
          url: 'http://dav.example:5005/dav/',
          password: 'secret',
          savedUrl: 'http://dav.example:5005/dav/',
          savedPassword: 'secret',
        ),
        isFalse,
      );
      // Changed password -> prompts again
      expect(
        CloudSyncSettingsPanel.shouldPromptCleartextHttpWarning(
          url: 'http://dav.example:5005/dav/',
          password: 'new_secret',
          savedUrl: 'http://dav.example:5005/dav/',
          savedPassword: 'secret',
        ),
        isTrue,
      );
      // Changed URL -> prompts again
      expect(
        CloudSyncSettingsPanel.shouldPromptCleartextHttpWarning(
          url: 'http://dav2.example:5005/dav/',
          password: 'secret',
          savedUrl: 'http://dav.example:5005/dav/',
          savedPassword: 'secret',
        ),
        isTrue,
      );
    });
  });

  group('Batch-1 Follow-ups (7.a - 7.e)', () {
    test('7.a: Cleans up leftover .tmp files on startup and reloads subscriptions without restart', () async {
      final tempDir = await Directory.systemTemp.createTemp('r2_7a_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final staleSubTmp = File('${tempDir.path}/subscriptions.json.170000.tmp');
      final staleHistTmp = File('${tempDir.path}/watch_history.json.170001.tmp');
      final staleCredTmp = File('${tempDir.path}/secure_credentials.enc.170002.tmp');
      final keepOther = File('${tempDir.path}/keep_note.txt');
      await staleSubTmp.writeAsString('partial');
      await staleHistTmp.writeAsString('partial');
      await staleCredTmp.writeAsString('partial');
      await keepOther.writeAsString('keep');

      final subFile = File('${tempDir.path}/subscriptions.json');
      await subFile.writeAsString('{CORRUPT_JSON', flush: true);

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init(
        dataDirectory: tempDir,
        secureStore: InMemorySecureCredentialStore(),
        pbkdf2Runner: <T>(c) => Future<T>.sync(c),
      );

      // Leftover .tmp files must be removed on init
      expect(await staleSubTmp.exists(), isFalse);
      expect(await staleHistTmp.exists(), isFalse);
      expect(await staleCredTmp.exists(), isFalse);
      expect(await keepOther.exists(), isTrue);

      // Trigger quarantine + write protection
      expect(storage.getSubscriptions(), isEmpty);
      expect(storage.isSubscriptionsCorrupted, isTrue);

      // Repair subscriptions.json on disk and recover via reloadSubscriptionsFromDisk()
      final repaired = [
        SubscriptionEntry(
          id: 'sub_ok',
          name: '修复订阅',
          url: 'https://ok.example/cfg.json',
          rawContent: jsonEncode({
            'sites': [
              {'key': 'ok_site', 'name': '可用站', 'type': 1, 'api': 'https://ok.example/api'},
            ],
          }),
          updatedAt: 1700000000,
        ),
      ];
      await subFile.writeAsString(
        jsonEncode(repaired.map((e) => e.toJson()).toList()),
        flush: true,
      );

      final recovered = await storage.reloadSubscriptionsFromDisk();
      expect(recovered, isTrue);
      expect(storage.isSubscriptionsCorrupted, isFalse);
      expect(storage.getSubscriptions().map((s) => s.id), contains('sub_ok'));
    });

    testWidgets('7.a UI: Corruption alert exposes 重新加载订阅 action', (tester) async {
      final fileStore = InMemoryStorageFileStore();
      fileStore.writeBytesSync(
        'subscriptions.json',
        utf8.encode('{BROKEN_JSON'),
      );
      final storage = await initTestStorage(fileStore: fileStore);
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(storage: storage, client: client)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const ValueKey('reload-subscriptions-action')), findsOneWidget);

      // Fix in-memory file and tap 重新加载订阅
      final validSubs = jsonEncode([
        SubscriptionEntry(
          id: 's1',
          name: '已恢复源',
          url: 'https://ok.example/sub.json',
          rawContent: jsonEncode({
            'sites': [
              {'key': 'restored', 'name': '已恢复片源', 'type': 1, 'api': 'https://ok.example/api'},
            ],
          }),
          updatedAt: 1700000000,
        ).toJson(),
      ]);
      fileStore.writeBytesSync('subscriptions.json', utf8.encode(validSubs));

      await tester.tap(find.byKey(const ValueKey('reload-subscriptions-action')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(storage.isSubscriptionsCorrupted, isFalse);
      expect(storage.getSubscriptions().single.id, equals('s1'));
      await tester.pumpWidget(const SizedBox());
    });

    test('7.b: importBackupJson and site fallbacks only select available (supported) sites', () async {
      final storage = await initTestStorage();
      final rawMixCfg = jsonEncode({
        'sites': [
          {'key': 'jar_bad', 'name': '不可用JAR', 'type': 3, 'api': 'https://bad.example/a.jar'},
          {'key': 'cms_good', 'name': '可用CMS', 'type': 1, 'api': 'https://good.example/api'},
        ],
      });
      final backupJson = CmsParser.encodeBackupPayload(
        origin: 'https://mix.example/sub.json',
        rawConfig: rawMixCfg,
        settings: {
          StorageService.keySubscriptions: [
            SubscriptionEntry(
              id: 'sub1',
              name: '混合订阅',
              url: 'https://mix.example/sub.json',
              rawContent: rawMixCfg,
              updatedAt: 1700000000,
            ).toJson(),
          ],
          StorageService.keySelectedSite: 'jar_bad',
          StorageService.keyPreferredSite: 'jar_bad',
        },
      );

      await storage.importBackupJson(backupJson);
      expect(
        storage.selectedSiteKey,
        equals('cms_good'),
        reason: 'importBackupJson must reject unsupported selected_site_key and select available site',
      );
      expect(
        storage.preferredSiteKey,
        isEmpty,
        reason: 'importBackupJson must not set preferredSiteKey to an unsupported site',
      );
    });

    test('7.c: push:// and mmshare:// report accurate reason instead of missing parser config', () async {
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('not used', 404),
        ),
      );
      const site = CmsSite(
        key: 'cms_push',
        name: '推送测试源',
        type: 1,
        api: 'https://cms.example/api.php/provide/vod/',
      );

      await expectLater(
        () => client.resolveEpisodeForPlayback(
          site,
          const CmsEpisode(
            name: '磁力源',
            url: 'push://magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('磁力'),
              isNot(contains('缺少可用解析配置')),
            ),
          ),
        ),
      );

      await expectLater(
        () => client.resolveEpisodeForPlayback(
          site,
          const CmsEpisode(
            name: '未知网盘',
            url: 'mmshare://115pan/share_id_123',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('网盘分享'),
              isNot(contains('缺少可用解析配置')),
            ),
          ),
        ),
      );
    });

    testWidgets('7.d: PlayerEpisodePickerSheet caches line availability for 1500+ episodes across rebuilds', (tester) async {
      final episodes = List<CmsEpisode>.generate(
        1500,
        (i) => CmsEpisode(
          name: '第${i + 1}集',
          url: 'https://vip.example/watch/${i + 1}.html',
        ),
        growable: false,
      );
      final lines = <CmsLine>[
        CmsLine(name: '千集大线路', episodes: episodes),
      ];

      var calls = 0;
      String? countingChecker(CmsEpisode ep) {
        calls++;
        return '该线路需要解析器';
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerEpisodePickerSheet(
              lines: lines,
              initialLineIndex: 0,
              activeLineIndex: 0,
              activeEpisodeIndex: 0,
              episodeUnavailableReason: countingChecker,
              onSelect: (_, __) {},
            ),
          ),
        ),
      );
      await tester.pump();

      final initialCalls = calls;
      // Initial mount scans line once (1500) + visible grid items (<= 40)
      expect(initialCalls, lessThanOrEqualTo(1550));

      // Trigger multiple rebuilds: switch group 41-80, toggle sort order, rebuild parent
      calls = 0;
      await tester.tap(find.text('41-80'));
      await tester.pump();
      await tester.tap(find.text('正序'));
      await tester.pump();
      await tester.tap(find.text('倒序'));
      await tester.pump();

      // 3 rebuilds * <= 40 visible items = <= 120 calls (vs 4,500+ without caching!)
      expect(
        calls,
        lessThan(150),
        reason: 'Cached line availability must prevent O(N) scan of 1500 episodes on build',
      );
    });

    test('7.e: cms_parser checks xml only in URL path, not host (e.g. xmflv / xmlvod hosts)', () {
      final cfgHostXml = CmsParser.parseConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'xmflv_host',
              'name': 'XMFLV站点',
              'api': 'https://xmflv.example/api.php/provide/vod/',
            },
            {
              'key': 'xml_host_2',
              'name': 'XML域名JSON接口',
              'api': 'https://api.xmlvod.example/api.php/provide/vod/?ac=list',
            },
            {
              'key': 'true_xml_path',
              'name': '真实XML路径接口',
              'api': 'https://cms.example/api.php/provide/vod/at/xml/',
            },
          ],
        }),
      );

      final byKey = {for (final s in cfgHostXml.sites) s.key: s};
      expect(byKey['xmflv_host']!.type, equals(1));
      expect(byKey['xml_host_2']!.type, equals(1));
      expect(byKey['true_xml_path']!.type, equals(0));
    });
  });
}

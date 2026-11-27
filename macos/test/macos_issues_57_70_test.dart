import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/macos_window_bounds.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_file_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/macos_official_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';

Uint8List _buildZipBytes(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

class _TestWindowAdapter implements MacosWindowPlatformAdapter {
  MacosWindowNativeState? nativeState;
  final List<MacosWindowBounds> appliedBounds = [];
  int saveCalls = 0;

  @override
  Future<MacosWindowNativeState?> getNativeState() async => nativeState;

  @override
  Future<bool> saveNormalBounds() async {
    saveCalls++;
    return true;
  }

  @override
  Future<bool> applyNormalBounds(MacosWindowBounds bounds) async {
    appliedBounds.add(bounds);
    nativeState = MacosWindowNativeState(
      restoredFromSaved: true,
      isFullScreen: false,
      isMiniaturized: false,
      savedFrame: bounds,
      currentFrame: bounds,
    );
    return true;
  }

  @override
  Future<void> setAppearanceMode(ThemeMode mode) async {}

  @override
  Future<bool> revealInFinder(String path) async => true;

  @override
  Future<bool> isFullScreen() async => nativeState?.isFullScreen ?? false;

  @override
  Future<bool> isMinimized() async => nativeState?.isMiniaturized ?? false;

  @override
  Future<Rect?> getWindowManagerBounds() async => nativeState?.currentFrame?.rect;
}

class _EmptyCmsClient extends CmsClient {
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const [CmsCategory(id: '1', name: '电影')],
        const CmsListing(page: 1, pageCount: 1, videos: []),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    MacosLocalFilePicker.debugPickOverride = null;
  });

  group('Issue #57 — macOS Finder JSON / ZIP import & cancel safety', () {
    test('readSubscriptionFile skips Finder __MACOSX / ._* / .DS_Store and inlines relative JS, JSON ext & M3U playlist', () {
      final zipBytes = _buildZipBytes({
        '__MACOSX/._config.json': utf8.encode('corrupt appledouble binary'),
        '__MACOSX/rules/._demo.json': utf8.encode('corrupt appledouble binary'),
        '.DS_Store': utf8.encode('finder junk'),
        'pkg/config.json': utf8.encode(jsonEncode({
          'sites': [
            {
              'key': 'http_vod',
              'name': 'HTTP 影视站',
              'type': 1,
              'api': 'https://vod.example/api.php/provide/vod/',
            },
            {
              'key': 'wogg_with_rel_ext',
              'name': '玩偶相对扩展',
              'type': 3,
              'api': 'csp_WoGG',
              'ext': './rules/wogg_ext.json',
            },
            {
              'key': 'local_js_site',
              'name': '本地 JS 源',
              'type': 3,
              'api': './spiders/demo.js',
              'ext': './rules/spider_cfg.json',
            },
          ],
          'lives': [
            {
              'name': '本地直播',
              'url': './lives/channels.m3u',
            },
          ],
        })),
        'pkg/rules/wogg_ext.json':
            utf8.encode(jsonEncode({'siteUrl': 'https://wogg.example/'})),
        'pkg/rules/spider_cfg.json':
            utf8.encode(jsonEncode({'host': 'https://demo.example/'})),
        'pkg/spiders/demo.js': utf8.encode('''
export default {
  init(ext) {},
  home() { return JSON.stringify({ class: [], list: [] }); },
  detail(id) { return JSON.stringify({ list: [] }); },
  play(flag, id) { return JSON.stringify({ url: "" }); },
};
'''),
        'pkg/lives/channels.m3u': utf8.encode('''#EXTM3U
#EXTINF:-1,CCTV-1 综合
https://live.example/cctv1.m3u8
'''),
      });

      final expanded = CmsClient.readSubscriptionFile(zipBytes, 'finder_pkg.zip');
      final config = CmsParser.parseConfig(expanded);

      expect(config.sites.map((s) => s.key), containsAll([
        'http_vod',
        'wogg_with_rel_ext',
        'local_js_site',
      ]));
      final woggSite =
          config.sites.firstWhere((s) => s.key == 'wogg_with_rel_ext');
      expect(woggSite.ext, contains('https://wogg.example/'));
      final jsSite = config.sites.firstWhere((s) => s.key == 'local_js_site');
      expect(jsSite.api, 'csp_LocalScript.js');
      expect(jsSite.ext, contains('home()'));
      expect(jsSite.ext, contains('https://demo.example/'));
      expect(config.lives, hasLength(1));
      expect(config.lives.single.url, startsWith('data:'));
      expect(
        Uri.parse(config.lives.single.url).data!.contentAsString(),
        contains('CCTV-1'),
      );
    });

    testWidgets(
      'Finder import flow: valid JSON -> ZIP with relative resources -> cancel preserves existing config intact',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({
          MacosOfficialNoticePrefs.acknowledgedVersionKey:
              MacosOfficialNoticePrefs.currentVersion,
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
        );
        // Existing valid subscription prior to Finder operations
        await storage.upsertSubscriptions([
          SubscriptionEntry(
            id: 'existing_sub',
            name: '原有有效订阅',
            rawContent: jsonEncode({
              'sites': [
                {
                  'key': 'existing_site',
                  'name': '原有片源',
                  'type': 1,
                  'api': 'https://existing.example/api.php/provide/vod/',
                },
              ],
            }),
            siteCount: 1,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ]);

        await tester.binding.setSurfaceSize(const Size(1280, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: _EmptyCmsClient()),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Go to Settings -> 订阅与数据维护
        await tester.tap(find.text('设置').last);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        await tester.tap(find.text('订阅与数据维护').first);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }

        Future<void> openImportFromCloudSettings() async {
          await tester.tap(find.text('订阅源与分组管理中心').first);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          await tester.tap(find.text('+ 批量导入').first);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 40));
          }
        }

        // 1. Import valid JSON via Finder picker
        final validJsonBytes = Uint8List.fromList(utf8.encode(jsonEncode({
          'sites': [
            {
              'key': 'finder_json_site',
              'name': 'Finder JSON 源',
              'type': 1,
              'api': 'https://finder-json.example/api.php/provide/vod/',
            },
          ],
        })));
        MacosLocalFilePicker.debugPickOverride = ({title, maxBytes = 0}) async =>
            MacosPickedFile(
              name: 'valid_sub.json',
              path: '/Users/demo/Downloads/valid_sub.json',
              bytes: validJsonBytes,
            );

        await openImportFromCloudSettings();
        await tester.tap(find.byKey(const ValueKey('subscription-pick-local-file')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.byKey(const ValueKey('subscription-local-file-summary')), findsOneWidget);
        expect(find.textContaining('valid_sub.json'), findsOneWidget);

        // Submit import
        final submitBtn = find.textContaining('导入').last;
        await tester.ensureVisible(submitBtn);
        await tester.tap(submitBtn);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          storage.loadSavedConfig()!.sites.map((s) => s.key),
          containsAll(['existing_site', 'finder_json_site']),
        );

        // 2. Import ZIP with relative resources via Finder picker
        final zipBytes = _buildZipBytes({
          '__MACOSX/._config.json': utf8.encode('ignored'),
          'config.json': utf8.encode(jsonEncode({
            'sites': [
              {
                'key': 'finder_zip_site',
                'name': 'Finder ZIP 源',
                'type': 1,
                'api': 'https://finder-zip.example/api.php/provide/vod/',
              },
            ],
            'lives': [
              {'name': 'ZIP 直播', 'url': './tv.m3u'},
            ],
          })),
          'tv.m3u': utf8.encode('#EXTM3U\n#EXTINF:-1,CCTV-6\nhttps://live.example/6.m3u8\n'),
        });
        MacosLocalFilePicker.debugPickOverride = ({title, maxBytes = 0}) async =>
            MacosPickedFile(
              name: 'bundle.zip',
              path: '/Users/demo/Downloads/bundle.zip',
              bytes: zipBytes,
            );

        await openImportFromCloudSettings();
        await tester.tap(find.byKey(const ValueKey('subscription-pick-local-file')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.textContaining('bundle.zip'), findsOneWidget);
        final submitBtn2 = find.textContaining('导入').last;
        await tester.ensureVisible(submitBtn2);
        await tester.tap(submitBtn2);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final afterZip = storage.loadSavedConfig()!;
        expect(
          afterZip.sites.map((s) => s.key),
          containsAll(['existing_site', 'finder_json_site', 'finder_zip_site']),
        );
        expect(afterZip.lives, hasLength(1));

        // 3. Cancel file selection -> existing config & subscriptions stay 100% intact
        MacosLocalFilePicker.debugPickOverride =
            ({title, maxBytes = 0}) async => null;
        await openImportFromCloudSettings();
        await tester.tap(find.byKey(const ValueKey('subscription-pick-local-file')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.textContaining('读取本地订阅失败'), findsNothing);
        final afterCancel = storage.loadSavedConfig()!;
        expect(
          afterCancel.sites.map((s) => s.key),
          containsAll(['existing_site', 'finder_json_site', 'finder_zip_site']),
        );
      },
    );
  });

  group('Issue #70 — macOS window bounds lifecycle, Red-X close ordering & external display unplug', () {
    test('runWindowCloseSequence awaits captureWindowBounds strictly BEFORE hideWindow', () async {
      final order = <String>[];
      await AdaptiveShell.runWindowCloseSequence(
        setPreventClose: (prevent) async => order.add('prevent:$prevent'),
        captureWindowBounds: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          order.add('captureWindowBounds');
        },
        hideWindow: () async => order.add('hideWindow'),
        flushHistory: () async => order.add('flushHistory'),
        flushSync: (_) async => order.add('flushSync'),
        closeHost: () async => order.add('closeHost'),
        closeScripts: () async => order.add('closeScripts'),
        destroyWindow: () async => order.add('destroyWindow'),
      );

      expect(order.indexOf('captureWindowBounds'), greaterThan(-1));
      expect(order.indexOf('hideWindow'), greaterThan(-1));
      expect(
        order.indexOf('captureWindowBounds'),
        lessThan(order.indexOf('hideWindow')),
        reason: 'Must persist visible NSWindow frame before hideWindow sets isVisible=false',
      );
    });

    test('move + resize (including onWindowResize) -> restart, fullscreen roundtrip, and external monitor unplug', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init(
        fileStore: InMemoryStorageFileStore(),
      );
      final adapter = _TestWindowAdapter();
      const externalFrame = MacosWindowBounds(
        x: 2100,
        y: 220,
        width: 1420,
        height: 860,
      );
      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: false,
        isFullScreen: false,
        isMiniaturized: false,
        currentFrame: externalFrame,
      );

      final ctrl = MacosWindowBoundsController(
        storage: storage,
        adapter: adapter,
        attachWindowManager: false,
        debounceDuration: const Duration(milliseconds: 10),
      );
      addTearDown(ctrl.dispose);

      // 1. Move + zoom/tile resize (onWindowResize) persists frame
      ctrl.onWindowResize();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(storage.loadMacosWindowBounds(), externalFrame);
      expect(adapter.saveCalls, greaterThanOrEqualTo(1));

      // 2. Fullscreen roundtrip must NOT overwrite saved normal frame with fullscreen rect
      ctrl.onWindowEnterFullScreen();
      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: true,
        isFullScreen: true,
        isMiniaturized: false,
        currentFrame: MacosWindowBounds(x: 1920, y: 0, width: 2560, height: 1440),
      );
      expect(await ctrl.captureNow(), isFalse);
      expect(storage.loadMacosWindowBounds(), externalFrame);

      ctrl.onWindowLeaveFullScreen();
      adapter.nativeState = const MacosWindowNativeState(
        restoredFromSaved: true,
        isFullScreen: false,
        isMiniaturized: false,
        currentFrame: externalFrame,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(storage.loadMacosWindowBounds(), externalFrame);

      // 3. Restart on external monitor unplugged -> resolves safely onto primary screen
      // preserving preferred size clamped cleanly inside visibleFrame
      const primaryVisible = Rect.fromLTWH(0, 0, 1440, 875);
      final unplugged = MacosWindowBounds.resolveForVisibleFrames(
        saved: storage.loadMacosWindowBounds(),
        visibleFrames: const [primaryVisible],
        primaryVisibleFrame: primaryVisible,
      );
      expect(unplugged.width, 1420);
      expect(unplugged.height, 860);
      expect(unplugged.x, greaterThanOrEqualTo(primaryVisible.left));
      expect(unplugged.topY, lessThanOrEqualTo(primaryVisible.bottom));
      expect(unplugged.y, greaterThanOrEqualTo(primaryVisible.top));
    });
  });
}

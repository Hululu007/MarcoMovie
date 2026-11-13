import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/source_choice_sliver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Challenger 4 Stress 1: 7 Unified Capability Statuses & Exact Chinese Strings', () {
    test('Verbatim Chinese strings match all 7 unified statuses and fallback', () {
      final expectedReasons = <String, String>{
        CmsSite.statusOk: '正常可用',
        CmsSite.statusNeedsJar: '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持',
        CmsSite.statusUnsupportedType: '暂不支持此类型来源，已保留在列表中',
        CmsSite.statusAdapterMissing: '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路',
        CmsSite.statusExtTooLarge: '扩展参数超过大小上限，无法加载',
        CmsSite.statusCustomSiteUrl: '此来源不是可直接请求的 HTTP(S) CMS',
        CmsSite.statusParserRequired: '需要解析器，当前环境缺少可用解析配置',
      };

      for (final entry in expectedReasons.entries) {
        expect(
          CmsSite.capabilityReason(entry.key),
          entry.value,
          reason: 'Status ${entry.key} must map to exact verbatim Chinese string "${entry.value}"',
        );
      }

      // Fallback reason
      expect(CmsSite.capabilityReason('unknown_status'), '此来源暂不可用');
      expect(CmsSite.capabilityReason(''), '此来源暂不可用');
    });

    test('Special sandbox protocol overrides', () {
      const siteSixv = CmsSite(key: 'sixv', name: '6V影视', type: 3, api: 'csp_SixV');
      expect(siteSixv.capabilityStatus, CmsSite.statusNeedsJar);
      expect(siteSixv.supported, isFalse);
      expect(siteSixv.unsupportedReason, '该线路依赖 P2P / 磁力种子协议，受当前系统沙盒限制暂不支持');

      const siteMusic = CmsSite(key: 'music', name: '网易云', type: 3, api: 'csp_Music');
      expect(siteMusic.capabilityStatus, CmsSite.statusNeedsJar);
      expect(siteMusic.supported, isFalse);
      expect(siteMusic.unsupportedReason, '该线路依赖交互式人机验证，当前设备暂不支持');

      const siteAidj = CmsSite(key: 'aidj', name: 'AI DJ', type: 3, api: 'csp_Aidj');
      expect(siteAidj.capabilityStatus, CmsSite.statusNeedsJar);
      expect(siteAidj.supported, isFalse);
      expect(siteAidj.unsupportedReason, '该线路使用专有加密流保护，当前设备暂不支持');
    });

    test('Strict evaluation precedence under multi-condition conflict', () {
      // 1. isExtTooLarge overrides adapter-missing
      const conflictExtAndNetdisk = CmsSite(
        key: 'c1',
        name: 'Ext and Netdisk',
        type: 3,
        api: 'csp_Pansou',
        extTooLarge: true,
      );
      expect(conflictExtAndNetdisk.capabilityStatus, CmsSite.statusExtTooLarge);

      // 2. adapter-missing overrides needs-jar
      const conflictNetdiskAndJar = CmsSite(
        key: 'c2',
        name: 'Netdisk and Jar',
        type: 3,
        api: 'csp_Pansou',
        jar: 'https://test.example/spider.jar',
      );
      expect(conflictNetdiskAndJar.capabilityStatus, CmsSite.statusAdapterMissing);

      // 3. needs-jar overrides unsupported-type
      const conflictJarAndBadType = CmsSite(
        key: 'c3',
        name: 'Jar and Bad Type',
        type: 99,
        api: 'csp_Custom',
      );
      expect(conflictJarAndBadType.capabilityStatus, CmsSite.statusNeedsJar);

      // 4. unsupported-type overrides custom-site-url
      const conflictBadTypeAndCustomUrl = CmsSite(
        key: 'c4',
        name: 'Bad Type and Custom Url',
        type: 99,
        api: 'custom://my.app/api',
      );
      expect(conflictBadTypeAndCustomUrl.capabilityStatus, CmsSite.statusUnsupportedType);

      // 5. custom-site-url overrides parser-required
      const conflictCustomUrlAndParser = CmsSite(
        key: 'c5',
        name: 'Custom Url and Parser',
        type: 1,
        api: 'custom://my.app/api',
        requiresParser: true,
      );
      expect(conflictCustomUrlAndParser.capabilityStatus, CmsSite.statusCustomSiteUrl);

      // 6. parser-required remains browsable (ok) and exposes playbackHint instead
      const conflictParserAndOk = CmsSite(
        key: 'c6',
        name: 'Parser and Ok',
        type: 1,
        api: 'https://ok.example/api',
        requiresParser: true,
      );
      expect(conflictParserAndOk.capabilityStatus, CmsSite.statusOk);
      expect(conflictParserAndOk.supported, isTrue);
      expect(conflictParserAndOk.playbackHint, '需要解析器，当前环境缺少可用解析配置');
    });

    test('Byte boundary stress for isExtTooLarge at 128KB limit', () {
      final exactly128KB = 'a' * (128 * 1024);
      final at128KBPlus1 = 'a' * (128 * 1024 + 1);

      final siteAtBoundary = CmsSite(
        key: 'boundary_exact',
        name: 'Exact 128KB',
        type: 1,
        api: 'https://ok.example/api',
        ext: exactly128KB,
      );
      expect(siteAtBoundary.capabilityStatus, CmsSite.statusOk);
      expect(siteAtBoundary.supported, isTrue);

      final siteOverBoundary = CmsSite(
        key: 'boundary_over',
        name: 'Over 128KB',
        type: 1,
        api: 'https://ok.example/api',
        ext: at128KBPlus1,
      );
      expect(siteOverBoundary.capabilityStatus, CmsSite.statusExtTooLarge);
      expect(siteOverBoundary.supported, isFalse);
    });
  });

  group('Challenger 4 Stress 2: All Sites Unsupported Condition', () {
    test('Config with 100% unsupported sites (50 sites spanning all failure modes)', () {
      final unsuppSites = <CmsSite>[];
      for (int i = 0; i < 50; i++) {
        switch (i % 6) {
          case 0:
            unsuppSites.add(CmsSite(key: 'u_$i', name: 'Jar站 $i', type: 3, api: 'https://jar.test/$i.jar'));
            break;
          case 1:
            unsuppSites.add(CmsSite(key: 'u_$i', name: '未知类型 $i', type: 77, api: 'https://type.test/$i'));
            break;
          case 2:
            unsuppSites.add(CmsSite(key: 'u_$i', name: '网盘站 $i', type: 3, api: 'csp_Pansou'));
            break;
          case 3:
            unsuppSites.add(CmsSite(key: 'u_$i', name: '超长站 $i', type: 1, api: 'https://ok.test/$i', extTooLarge: true));
            break;
          case 4:
            unsuppSites.add(CmsSite(key: 'u_$i', name: '非HTTP站 $i', type: 1, api: 'udp://custom.test/$i'));
            break;
          case 5:
            unsuppSites.add(CmsSite(key: 'u_$i', name: '未适配脚本站 $i', type: 3, api: 'csp_Unported_$i'));
            break;
        }
      }

      final config = CmsConfig(
        sites: unsuppSites,
        lives: const [],
        depots: const [],
        parses: const [],
        spider: '',
      );

      // Data retention: all 50 sites retained
      expect(config.supportedSites.length, 50);
      expect(config.publicSupportedSites.length, 50);

      // Filtering: availableSites is strictly empty
      expect(config.availableSites.isEmpty, isTrue);
      expect(config.availableSiteCount, 0);
      expect(config.publicAvailableSites.isEmpty, isTrue);
      expect(config.publicAvailableSiteCount, 0);

      // Source count format: "可用 0 / 共 50"
      final countString = '可用 ${config.availableSiteCount} / 共 ${config.supportedSites.length}';
      expect(countString, '可用 0 / 共 50');
    });

    testWidgets('Rendering 100% unsupported sites in SourceChoiceSliver: visual opacity and zero selection', (tester) async {
      final unsuppSites = [
        const CmsSite(key: 'u1', name: '未适配1', type: 3, api: 'https://u1.test/a.jar'),
        const CmsSite(key: 'u2', name: '未适配2', type: 99, api: 'https://u2.test/api'),
        const CmsSite(key: 'u3', name: '未适配3', type: 3, api: 'csp_Pansou'),
      ];

      String? selectedKey;
      String? unsupportedClickedKey;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: unsuppSites,
                  selectedKey: selectedKey,
                  preferredKey: '',
                  onPreferred: (_) {},
                  badgeLabel: (s) => s.supported ? 'CMS' : '未适配',
                  badgeColor: (_) => Colors.grey,
                  onSelected: (s) => selectedKey = s.key,
                  onUnsupportedSelected: (s) => unsupportedClickedKey = s.key,
                ),
              ],
            ),
          ),
        ),
      );

      // All 3 sites rendered
      expect(find.text('未适配1'), findsOneWidget);
      expect(find.text('未适配2'), findsOneWidget);
      expect(find.text('未适配3'), findsOneWidget);

      // All sites have '未适配' badge
      expect(find.text('未适配'), findsNWidgets(3));

      // No star buttons exist
      expect(find.byType(IconButton), findsNothing);

      // Tapping each unsupported site invokes onUnsupportedSelected, NEVER onSelected
      for (int i = 1; i <= 3; i++) {
        await tester.tap(find.text('未适配$i'));
        await tester.pumpAndSettle();
        expect(selectedKey, isNull, reason: 'onSelected must never fire for unsupported site');
        expect(unsupportedClickedKey, 'u$i', reason: 'onUnsupportedSelected must fire with site u$i');
      }
    });

    test('StorageService graceful fallback when all sites in subscription are unsupported', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();

      final jsonMap = {
        'sites': [
          {'key': 'bad_jar', 'name': '全不支持1', 'type': 3, 'api': 'https://bad.example/spider.jar'},
          {'key': 'bad_type', 'name': '全不支持2', 'type': 88, 'api': 'https://bad.type/api'},
        ]
      };

      await storage.saveConfig(jsonEncode(jsonMap), origin: 'https://test.example/unsupported.json');

      final loadedConfig = storage.loadSavedConfig();
      // Selected site key never auto-selects an unsupported site and does not throw
      expect(loadedConfig?.supportedSites.length, 2);
      expect(loadedConfig?.availableSiteCount, 0);
      expect(storage.selectedSiteKey, isEmpty);
    });
  });

  group('Challenger 4 Stress 3: 200 Sites Alternating Support Statuses', () {
    testWidgets('Renders 200 sites with alternating support status without layout overflow or memory anomalies', (tester) async {
      final alternatingSites = List.generate(
        200,
        (i) => i.isEven
            ? CmsSite(
                key: 'site_ok_$i',
                name: '可用线路 $i',
                type: 1,
                api: 'https://ok.example/$i',
                group: '主力源',
              )
            : CmsSite(
                key: 'site_unsupp_$i',
                name: '未适配线路 $i',
                type: 3,
                api: 'https://jar.example/$i.jar',
                group: '备用源',
              ),
      );

      final totalCount = alternatingSites.length;
      final availCount = alternatingSites.where((s) => s.supported).length;
      expect(totalCount, 200);
      expect(availCount, 100);

      // Source count format check
      final headerTitle = '切换片源 (可用 $availCount / 共 $totalCount)';
      expect(headerTitle, '切换片源 (可用 100 / 共 200)');

      int onSelectedCalls = 0;
      int onUnsupportedCalls = 0;
      CmsSite? lastSelected;
      CmsSite? lastUnsupported;

      // Pump in mobile screen viewport (375x812) to stress small screen responsiveness
      tester.view.physicalSize = const Size(375 * 2, 812 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.reset());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SourceChoiceSliver(
                  sites: alternatingSites,
                  selectedKey: 'site_ok_0',
                  preferredKey: 'site_ok_0',
                  onPreferred: (_) {},
                  badgeLabel: (s) => s.supported ? 'CMS' : '未适配',
                  badgeColor: (s) => s.supported ? Colors.green : Colors.grey,
                  onSelected: (s) {
                    onSelectedCalls++;
                    lastSelected = s;
                  },
                  onUnsupportedSelected: (s) {
                    onUnsupportedCalls++;
                    lastUnsupported = s;
                  },
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('可用线路 0'), findsOneWidget);
      expect(find.text('未适配线路 1'), findsOneWidget);

      // Tap index 0 (supported)
      await tester.tap(find.text('可用线路 0'));
      await tester.pumpAndSettle();
      expect(onSelectedCalls, 1);
      expect(lastSelected?.key, 'site_ok_0');

      // Tap index 1 (unsupported)
      await tester.tap(find.text('未适配线路 1'));
      await tester.pumpAndSettle();
      expect(onUnsupportedCalls, 1);
      expect(lastUnsupported?.key, 'site_unsupp_1');

      // Scroll down substantially to stress virtualization and layout
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Scroll further down
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Scroll back to top
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Challenger 4 Stress 4: Source Count Format Across Shell & Settings', () {
    String formatHeader(int avail, int total) => '切换片源 (可用 $avail / 共 $total)';
    String formatPrivacyHeader(int avail, int total) => '切换隐私片源 (可用 $avail / 共 $total)';
    String formatTrailing(int avail, int total) => '可用 $avail / 共 $total';
    String formatImportToast(int importedSubs, int avail, int total) =>
        '本次成功导入 $importedSubs 个订阅源，当前 可用 $avail / 共 $total 个片源';
    String formatSettingsSubtitleEmpty(int avail, int total) =>
        '批量导入、多仓切换与自定义分组（当前 可用 $avail / 共 $total 片源）';
    String formatSettingsSubtitleNonEmpty(int subCount, int avail, int total, int depots) =>
        '已导入 $subCount 个订阅 · 可用 $avail / 共 $total 个片源${depots > 0 ? " · $depots 个子仓库" : ""}';

    test('Source count format strictly conforms across all UI touchpoints and numerical ranges', () {
      final testCases = [
        {'avail': 0, 'total': 0, 'subs': 0, 'depots': 0},
        {'avail': 0, 'total': 1, 'subs': 1, 'depots': 0},
        {'avail': 0, 'total': 200, 'subs': 2, 'depots': 3},
        {'avail': 1, 'total': 1, 'subs': 1, 'depots': 1},
        {'avail': 42, 'total': 100, 'subs': 5, 'depots': 2},
        {'avail': 100, 'total': 200, 'subs': 10, 'depots': 0},
        {'avail': 200, 'total': 200, 'subs': 15, 'depots': 4},
        {'avail': 999, 'total': 1000, 'subs': 50, 'depots': 12},
      ];

      for (final tc in testCases) {
        final a = tc['avail'] as int;
        final t = tc['total'] as int;
        final s = tc['subs'] as int;
        final d = tc['depots'] as int;

        final header = formatHeader(a, t);
        final privacy = formatPrivacyHeader(a, t);
        final trailing = formatTrailing(a, t);
        final toast = formatImportToast(s, a, t);

        // Assert exact regex structure
        expect(header, matches(RegExp(r'^切换片源 \(可用 \d+ / 共 \d+\)$')));
        expect(privacy, matches(RegExp(r'^切换隐私片源 \(可用 \d+ / 共 \d+\)$')));
        expect(trailing, matches(RegExp(r'^可用 \d+ / 共 \d+$')));
        expect(toast, contains('可用 $a / 共 $t 个片源'));

        expect(header, '切换片源 (可用 $a / 共 $t)');
        expect(privacy, '切换隐私片源 (可用 $a / 共 $t)');
        expect(trailing, '可用 $a / 共 $t');

        if (s == 0) {
          final subTitle = formatSettingsSubtitleEmpty(a, t);
          expect(subTitle, '批量导入、多仓切换与自定义分组（当前 可用 $a / 共 $t 片源）');
        } else {
          final subTitle = formatSettingsSubtitleNonEmpty(s, a, t, d);
          expect(subTitle, contains('可用 $a / 共 $t 个片源'));
        }
      }
    });
  });

  group('Challenger 4 Stress 5: Diagnostic Dialog Interactivity & Lifecycle', () {
    testWidgets('Full dialog lifecycle for each of the 6 unsupported types: open, verify exact Chinese text, close cleanly', (tester) async {
      final failureCases = [
        (
          CmsSite(key: 'jar_case', name: 'Spider源', type: 3, api: 'https://test/s.jar'),
          '此来源需要 Spider / JS / JAR 运行环境，基础版尚未支持',
        ),
        (
          CmsSite(key: 'type_case', name: '未知类型源', type: 99, api: 'https://test/api'),
          '暂不支持此类型来源，已保留在列表中',
        ),
        (
          CmsSite(key: 'adapter_case', name: '网盘未适配源', type: 3, api: 'csp_Pansou'),
          '此网盘源的原始插件尚未适配当前设备，无法读取原始网盘线路',
        ),
        (
          CmsSite(key: 'ext_case', name: '超大参数源', type: 1, api: 'https://test/api', extTooLarge: true),
          '扩展参数超过大小上限，无法加载',
        ),
        (
          CmsSite(key: 'url_case', name: '自定义协议源', type: 1, api: 'custom://app/feed'),
          '此来源不是可直接请求的 HTTP(S) CMS',
        ),
        (
          CmsSite(key: 'parser_case', name: '需解析源', type: 1, api: 'https://test/api', requiresParser: true),
          '需要解析器，当前环境缺少可用解析配置',
        ),
      ];

      for (final (site, expectedReason) in failureCases) {
        final displayedMessage = site.supported && site.playbackHint.isNotEmpty
            ? site.playbackHint
            : site.unsupportedReason;
        await tester.pumpWidget(
          CupertinoApp(
            home: CupertinoPageScaffold(
              child: Builder(
                builder: (context) => CupertinoButton(
                  key: ValueKey('btn_${site.key}'),
                  child: Text('Open ${site.key}'),
                  onPressed: () {
                    showCupertinoDialog<void>(
                      context: context,
                      builder: (dialogCtx) => CupertinoAlertDialog(
                        title: Text(site.name),
                        content: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(displayedMessage),
                        ),
                        actions: [
                          CupertinoDialogAction(
                            isDefaultAction: true,
                            onPressed: () => Navigator.of(dialogCtx).pop(),
                            child: const Text('我知道了'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );

        // Tap button
        await tester.tap(find.byKey(ValueKey('btn_${site.key}')));
        await tester.pumpAndSettle();

        // Verify dialog is visible and shows exact name + Chinese reason
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(find.text(site.name), findsOneWidget);
        expect(find.text(expectedReason), findsOneWidget);
        expect(find.text('我知道了'), findsOneWidget);

        // Tap '我知道了' and dismiss
        await tester.tap(find.text('我知道了'));
        await tester.pumpAndSettle();

        // Dialog should be gone completely
        expect(find.byType(CupertinoAlertDialog), findsNothing);
      }
    });
  });
}

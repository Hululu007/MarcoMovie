import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/device_quality_profiler.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/ios_mpv_profile.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/add_resource_library_sheet.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_filter_sheet.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:marco_movie/ui/motion/aurora_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

CmsClient _dummyClient() => CmsClient(
      client: MockClient((_) async => http.Response('{"class":[],"list":[]}', 200)),
    );

void main() {
  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setThermalThrottledForTest(null);
    IosLiquidGlassBridge.setMajorVersionForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 0.68;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('iOS Feedback #2 — Resource library icon-first Home Screen grid & unified distinct icons', () {
    testWidgets(
      'bare app icons (no per-tile card), 4 per row on iPhone, symmetric margins on every width, all 13 tiles',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();

        const allIds = [
          'emby',
          'jellyfin',
          'plex',
          'webdav',
          'smb',
          'alistNas',
          'quarkDrive',
          'ucDrive',
          'baiduDrive',
          'aliDrive',
          'localDevice',
          'manualInput',
          'localPack',
        ];

        // (viewport, text scale, expected columns, expected icon size)
        const viewports = <(Size, double, int, double)>[
          (Size(320, 844), 1.0, 4, 52),
          (Size(375, 812), 1.0, 4, 57),
          (Size(390, 844), 1.0, 4, 60),
          (Size(440, 956), 1.0, 4, 64),
          (Size(320, 844), 1.3, 4, 52),
          (Size(320, 844), 2.0, 3, 64),
          (Size(507, 900), 1.0, 5, 64),
          (Size(768, 1024), 1.0, 6, 64),
        ];

        for (final (size, scale, expectedCols, expectedIcon) in viewports) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                ),
                child: child!,
              ),
              home: IosSettingsScaffold(
                title: '添加资源库',
                body: AddResourceLibraryView(
                  storage: storage,
                  client: _dummyClient(),
                  onLibraryAdded: () {},
                ),
              ),
            ),
          );
          await tester.pump();
          final at = '${size.width}pt @${scale}x';

          for (var s = 0; s < 4; s++) {
            expect(
              find.byKey(ValueKey('add-lib-section-$s-cols-$expectedCols')),
              findsOneWidget,
              reason: 'Expected $expectedCols columns in section $s at $at',
            );
          }

          // The grid block is centered: symmetric left/right margins.
          final grid = tester.getRect(
            find.byKey(ValueKey('add-lib-section-0-cols-$expectedCols')),
          );
          expect(
            (grid.left - (size.width - grid.right)).abs(),
            lessThan(0.5),
            reason: 'Grid margins must be symmetric at $at',
          );

          // 个人网盘 has 4 tiles: on 4-column iPhone widths it is one full row
          // whose outer tiles and icons are symmetric.
          if (expectedCols == 4) {
            final quarkRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-quarkDrive')));
            final aliRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-aliDrive')));
            expect((quarkRect.left - (size.width - aliRect.right)).abs(), lessThan(0.5));
            expect((quarkRect.top - aliRect.top).abs(), lessThan(0.5));
            final quarkIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-quarkDrive')));
            final aliIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-aliDrive')));
            expect(
              (quarkIcon.left - (size.width - aliIcon.right)).abs(),
              lessThan(0.5),
              reason: 'Icon margins must be symmetric at $at',
            );
            // Evenly distributed columns: equal icon pitch.
            final ucIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-ucDrive')));
            final baiduIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-baiduDrive')));
            final pitch1 = ucIcon.left - quarkIcon.left;
            final pitch2 = baiduIcon.left - ucIcon.left;
            final pitch3 = aliIcon.left - baiduIcon.left;
            expect((pitch1 - pitch2).abs(), lessThan(0.5));
            expect((pitch2 - pitch3).abs(), lessThan(0.5));
          }

          // Icon is centered within its tile cell.
          final embyTile = tester.getRect(find.byKey(const ValueKey('add-lib-tile-emby')));
          final embyIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-emby')));
          expect((embyIcon.center.dx - embyTile.center.dx).abs(), lessThan(0.5));
          expect(embyIcon.width, closeTo(expectedIcon, 0.5), reason: 'icon size at $at');
          expect(embyIcon.height, closeTo(expectedIcon, 0.5));

          for (final id in allIds) {
            final tile = find.byKey(ValueKey('add-lib-tile-$id'));
            expect(tile, findsOneWidget);
            expect(find.byKey(ValueKey('add-lib-icon-$id')), findsOneWidget);
            // No per-tile card box: nothing decorated / filled / shadowed
            // behind the tile — only the icon painter itself.
            expect(
              find.descendant(of: tile, matching: find.byType(DecoratedBox)),
              findsNothing,
              reason: 'Tile $id must not wrap a decorated card at $at',
            );
            expect(
              find.descendant(of: tile, matching: find.byType(Container)),
              findsNothing,
            );
            expect(
              find.descendant(of: tile, matching: find.byType(ColoredBox)),
              findsNothing,
            );
            expect(
              find.descendant(of: tile, matching: find.byType(PhysicalModel)),
              findsNothing,
            );
            expect(
              find.descendant(of: tile, matching: find.byType(InkWell)),
              findsNothing,
            );
            expect(
              find.ancestor(of: tile, matching: find.byType(DecoratedBox)).evaluate().where(
                    (e) => find
                        .descendant(of: find.byWidget(e.widget), matching: find.byKey(const ValueKey('add-lib-section-0')))
                        .evaluate()
                        .isEmpty,
                  ),
              isEmpty,
              reason: 'No decorated wrapper between the section and tile $id',
            );
          }

          expect(tester.takeException(), isNull, reason: 'overflow at $at');
        }

        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS Feedback #3 — Filter sheet empty & bare-ordinal category sanitization', () {
    test('sanitizeIosFilterCategories drops blank/invisible/orphan entries and reattaches bare ordinals', () {
      const raw = <CmsCategory>[
        CmsCategory(id: 'orphan0', name: '①'),
        CmsCategory(id: 'blank1', name: '   '),
        CmsCategory(id: 'zw1', name: '\u200B\uFEFF'),
        CmsCategory(id: 'punct1', name: '···'),
        CmsCategory(id: '', name: '无ID分类'),
        CmsCategory(id: 'm1', name: '热门电影①'),
        CmsCategory(id: 'm2', name: '②'),
        CmsCategory(id: 'm3', name: '③'),
        CmsCategory(id: 'm3', name: '③'), // duplicate ID
        CmsCategory(id: 'h0', name: '好莱坞'),
        CmsCategory(id: 'h1', name: '①'),
        CmsCategory(id: 'h2', name: '②'),
        CmsCategory(id: 'h3', name: '③'),
        CmsCategory(id: 'h4', name: '④'),
        CmsCategory(id: 'h5', name: '⑤'),
        CmsCategory(id: 'hk0', name: '港台经典'),
        CmsCategory(id: 'hk1', name: '(1)'),
      ];

      final cleaned = sanitizeIosFilterCategories(raw);
      expect(
        cleaned.map((c) => '${c.id}:${c.name}').toList(),
        equals(<String>[
          'm1:热门电影①',
          'm2:热门电影②',
          'm3:热门电影③',
          'h0:好莱坞',
          'h1:好莱坞①',
          'h2:好莱坞②',
          'h3:好莱坞③',
          'h4:好莱坞④',
          'h5:好莱坞⑤',
          'hk0:港台经典',
          'hk1:港台经典(1)',
        ]),
      );
    });

    test('sanitizeIosFilterChoices & sanitizeIosFilterStringOptions eliminate empty/duplicate/redundant options', () {
      const rawChoices = <IosNativeFilterCategory>[
        IosNativeFilterCategory(id: '', label: '全部', kind: 'all'),
        IosNativeFilterCategory(id: '', label: '全部', kind: 'all'),
        IosNativeFilterCategory(id: 'bad_all', label: '全部', kind: 'cat'),
        IosNativeFilterCategory(id: 'empty_id', label: '   ', kind: 'cat'),
        IosNativeFilterCategory(id: '', label: '空ID类别', kind: 'cat'),
        IosNativeFilterCategory(id: '10', label: '国剧盛典①', kind: 'cat'),
        IosNativeFilterCategory(id: '11', label: '②', kind: 'cat'),
        IosNativeFilterCategory(id: '12', label: '\u200B', kind: 'cat'),
        IosNativeFilterCategory(id: '13', label: '③', kind: 'cat'), // blank broke sequence -> orphan dropped
      ];

      final choices = sanitizeIosFilterChoices(rawChoices);
      expect(
        choices.map((c) => '${c.kind}:${c.id}:${c.label}').toList(),
        equals(<String>[
          'all::全部',
          'cat:10:国剧盛典①',
          'cat:11:国剧盛典②',
        ]),
      );

      final areas = sanitizeIosFilterStringOptions(
        const ['中国大陆', '', '   ', '\u200B', '---', '中国大陆', '日本'],
      );
      expect(areas, equals(const ['中国大陆', '日本']));
    });

    testWidgets(
      'IosCatalogFilterSheetBody renders sanitized continuation labels and zero bare-ordinal or empty buttons',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: IosCatalogFilterSheetBody(
                title: '片库筛选',
                categories: <IosNativeFilterCategory>[
                  IosNativeFilterCategory(id: '', label: '全部', kind: 'all'),
                  IosNativeFilterCategory(id: 'bad0', label: '   ', kind: 'cat'),
                  IosNativeFilterCategory(id: 'm1', label: '热门电影①', kind: 'cat'),
                  IosNativeFilterCategory(id: 'm2', label: '②', kind: 'cat'),
                  IosNativeFilterCategory(id: 'm3', label: '③', kind: 'cat'),
                ],
                initialCategoryId: 'm3',
                initialGenreLabel: '',
                areas: <String>['中国大陆', '', '   ', '日本'],
                initialArea: '',
                years: <String>['2025', '', '2024'],
                initialYear: '',
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('热门电影①'), findsOneWidget);
        expect(find.text('热门电影②'), findsOneWidget);
        expect(find.text('热门电影③'), findsAtLeastNWidgets(1));
        expect(find.text('②'), findsNothing);
        expect(find.text('③'), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('ios-filter-summary'))).data,
          '热门电影③',
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS Feedback #4 — iPad Pro 2020 / iPadOS 15.4 thermal & GPU hot-path fixes', () {
    test('AppleAmbientBackground breath animation policy disables infinite 120Hz ticker on iOS while keeping dark macOS intact', () {
      expect(
        AppleAmbientBackground.shouldAnimateBreath(
          useAuroraShader: false,
          animate: true,
          showAmbientArtwork: true,
          isWindowsDesktop: false,
          isIosPlatform: true,
          isDark: true,
          lifecycleResumed: true,
          isCurrentRoute: true,
          reduceMotion: false,
        ),
        isFalse,
      );
      expect(
        AppleAmbientBackground.shouldAnimateBreath(
          useAuroraShader: false,
          animate: true,
          showAmbientArtwork: true,
          isWindowsDesktop: false,
          isIosPlatform: false,
          isDark: true,
          lifecycleResumed: true,
          isCurrentRoute: true,
          reduceMotion: false,
        ),
        isTrue,
      );
      // Light mode, background, occluded route, or reduceMotion must also stop breathing.
      expect(
        AppleAmbientBackground.shouldAnimateBreath(
          useAuroraShader: false,
          animate: true,
          showAmbientArtwork: true,
          isWindowsDesktop: false,
          isIosPlatform: false,
          isDark: false,
          lifecycleResumed: true,
          isCurrentRoute: true,
          reduceMotion: false,
        ),
        isFalse,
      );
      expect(
        AppleAmbientBackground.shouldAnimateBreath(
          useAuroraShader: false,
          animate: true,
          showAmbientArtwork: true,
          isWindowsDesktop: false,
          isIosPlatform: false,
          isDark: true,
          lifecycleResumed: false,
          isCurrentRoute: true,
          reduceMotion: false,
        ),
        isFalse,
      );
    });

    testWidgets(
      'AppleAmbientBackground skips ShaderMask on iOS and GlassworkBackdrop degrades live on thermalThrottled without reparenting child',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        IosLiquidGlassBridge.setThermalThrottledForTest(false);
        GlassworkBackdrop.intensity.value = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Stack(
              children: const [
                AppleAmbientBackground(
                  preset: 'obsidian',
                  artwork: ColoredBox(color: Colors.indigo),
                  blurSigma: 72,
                ),
                Center(
                  child: GlassworkBackdrop(
                    radius: 24,
                    child: SizedBox(
                      key: ValueKey('glass-child'),
                      width: 120,
                      height: 48,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        // iOS uses lightweight gradient fade instead of ShaderMask(dstIn) + sigma 72 blur.
        expect(find.byType(ShaderMask), findsNothing);
        expect(find.byType(ImageFiltered), findsOneWidget);

        // On iOS < 26 when not thermally throttled, BackdropFilter stays enabled.
        final beforeFilter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
        expect(beforeFilter.enabled, isTrue);

        // When native iOS reports thermal throttling (.serious / .critical), BackdropFilter
        // immediately disables while keeping child mounted at the same element depth.
        final childElemBefore = tester.element(find.byKey(const ValueKey('glass-child')));
        IosLiquidGlassBridge.setThermalThrottledForTest(true);
        await tester.pump();

        final afterFilter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
        expect(afterFilter.enabled, isFalse);
        expect(
          identical(
            childElemBefore,
            tester.element(find.byKey(const ValueKey('glass-child'))),
          ),
          isTrue,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosLiquidGlassBridge parses thermalThrottled/majorVersion from capabilities and handles thermalStateChanged pushes',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'capabilities') {
            return <String, dynamic>{
              'available': false,
              'majorVersion': 15,
              'reduceTransparency': false,
              'sceneActive': true,
              'thermalThrottled': false,
            };
          }
          return null;
        });

        final avail = await IosLiquidGlassBridge.ensureInitialized();
        expect(avail, isFalse);
        expect(IosLiquidGlassBridge.majorVersion, 15);
        expect(IosLiquidGlassBridge.thermalThrottled, isFalse);

        const codec = StandardMethodCodec();
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          IosLiquidGlassBridge.channel.name,
          codec.encodeMethodCall(const MethodCall('thermalStateChanged', true)),
          (_) {},
        );
        expect(IosLiquidGlassBridge.thermalThrottled, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'AuroraBackground stops its ticker on iOS thermal throttling',
      (tester) async {
        IosLiquidGlassBridge.setThermalThrottledForTest(false);
        await tester.pumpWidget(
          const MaterialApp(
            home: AuroraBackground(active: true, strength: 0.7),
          ),
        );
        final state = tester.state<AuroraBackgroundState>(
          find.byType(AuroraBackground),
        );
        expect(state.isTickerRunning, isTrue);

        IosLiquidGlassBridge.setThermalThrottledForTest(true);
        await tester.pump();
        expect(state.isTickerRunning, isFalse);

        IosLiquidGlassBridge.setThermalThrottledForTest(false);
        await tester.pump();
        expect(state.isTickerRunning, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test('DeviceQualityProfiler identifies iPad Pro 2020 (A12Z) and disables Anime4K / large buffer', () {
      expect(
        DeviceQualityProfiler.friendlyModelName('iPad8,10', isPad: true),
        'iPad Pro 11" (2020)',
      );
      expect(
        DeviceQualityProfiler.friendlyModelName('iPad8,12', isPad: true),
        'iPad Pro 12.9" (2020)',
      );

      final rec = DeviceQualityProfiler.recommend(
        const DeviceHardwareSnapshot(
          machineIdentifier: 'iPad8,10',
          modelName: 'iPad Pro 11" (2020)',
          physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
          processorCount: 8,
          supportsHdrDisplay: true,
          potentialEdrHeadroom: 1.0,
          osVersion: '15.4',
          isPad: true,
          lowPowerMode: false,
          thermalState: IosThermalState.nominal,
        ),
      );
      expect(rec.tier, DeviceHardwareTier.efficiency);
      expect(rec.iosAnime4kLightweightEnabled, isFalse);
      expect(rec.iosLargeBufferEnabled, isFalse);
    });

    test('IosMpvProfile lowPowerThermalMode disables per-frame hdr-compute-peak and dithering', () {
      final normal = IosMpvProfile.buildMpvProperties(
        hdrToneMapping: IosHdrToneMappingMode.auto,
        lowPowerThermalMode: false,
      );
      expect(normal['hdr-compute-peak'], 'yes');
      expect(normal['dither-depth'], 'auto');
      expect(normal.containsKey('video-sync'), isFalse);

      final cool = IosMpvProfile.buildMpvProperties(
        hdrToneMapping: IosHdrToneMappingMode.auto,
        lowPowerThermalMode: true,
      );
      expect(cool['hdr-compute-peak'], 'no');
      expect(cool['dither-depth'], 'no');
      expect(cool['video-sync'], 'audio');
    });
  });
}

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

  group('iOS Feedback #2 — Resource library symmetric layout & unified distinct icons', () {
    testWidgets(
      'cards and icons maintain symmetric left/right margins across 2, 3, and 4 columns with all 13 distinct tiles',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();

        const viewports = <(Size, int)>[
          (Size(320, 844), 2),
          (Size(390, 844), 3),
          (Size(507, 900), 3),
          (Size(768, 1024), 4),
        ];

        for (final (size, expectedCols) in viewports) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          await tester.pumpWidget(
            MaterialApp(
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

          expect(
            find.byKey(ValueKey('add-lib-section-0-cols-$expectedCols')),
            findsOneWidget,
            reason: 'Expected $expectedCols columns at width ${size.width}',
          );

          // Full row in group 0 (Emby, Jellyfin, Plex): for 3-col check outer cards & icons.
          if (expectedCols == 3) {
            final embyRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-emby')));
            final plexRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-plex')));
            final leftMargin = embyRect.left;
            final rightMargin = size.width - plexRect.right;
            expect(
              (leftMargin - rightMargin).abs(),
              lessThan(0.5),
              reason: 'Card margins must be symmetric at ${size.width}px ($leftMargin vs $rightMargin)',
            );

            final embyIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-emby')));
            final plexIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-plex')));
            final iconLeftMargin = embyIcon.left;
            final iconRightMargin = size.width - plexIcon.right;
            expect(
              (iconLeftMargin - iconRightMargin).abs(),
              lessThan(0.5),
              reason: 'Icon margins must be symmetric at ${size.width}px ($iconLeftMargin vs $iconRightMargin)',
            );
            expect(embyIcon.width, closeTo(54.0, 0.5));
            expect(embyIcon.height, closeTo(54.0, 0.5));
          }

          // For 4-col (iPad portrait 768px), group 2 (个人网盘) has 4 full tiles: quark..ali.
          if (expectedCols == 4) {
            final quarkRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-quarkDrive')));
            final aliRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-aliDrive')));
            expect(
              (quarkRect.left - (size.width - aliRect.right)).abs(),
              lessThan(0.5),
            );
            final quarkIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-quarkDrive')));
            final aliIcon = tester.getRect(find.byKey(const ValueKey('add-lib-icon-aliDrive')));
            expect(
              (quarkIcon.left - (size.width - aliIcon.right)).abs(),
              lessThan(0.5),
            );
          }

          // For 2-col (320px), first row of group 0 is Emby + Jellyfin.
          if (expectedCols == 2) {
            final embyRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-emby')));
            final jellyRect = tester.getRect(find.byKey(const ValueKey('add-lib-tile-jellyfin')));
            expect(
              (embyRect.left - (size.width - jellyRect.right)).abs(),
              lessThan(0.5),
            );
          }

          // Every tile renders a unified 60x60 icon canvas.
          for (final id in const [
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
          ]) {
            expect(find.byKey(ValueKey('add-lib-tile-$id')), findsOneWidget);
            expect(find.byKey(ValueKey('add-lib-icon-$id')), findsOneWidget);
          }

          expect(tester.takeException(), isNull);
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

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_search_page.dart';
import 'package:marco_movie/ui/ios_settings.dart';
import 'package:marco_movie/ui/poster_image.dart';

import 'test_storage_helper.dart';

class _DuoTestCmsClient extends CmsClient {
  @override
  Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo video, {
    bool forceRefresh = false,
  }) async {
    return CmsVideo(
      id: video.id,
      title: video.title,
      year: video.year,
      area: video.area,
      remarks: video.remarks,
      description: video.description.isEmpty
          ? '用于验证 iPhone Duo 外屏、内屏展开与分屏布局的剧情简介文本。'
          : video.description,
      lines: const [
        CmsLine(
          name: '4K极速线路',
          episodes: [
            CmsEpisode(name: '第01集', url: 'https://media.example/1.m3u8'),
            CmsEpisode(name: '第02集', url: 'https://media.example/2.m3u8'),
            CmsEpisode(name: '第03集', url: 'https://media.example/3.m3u8'),
            CmsEpisode(name: '第04集', url: 'https://media.example/4.m3u8'),
          ],
        ),
      ],
    );
  }

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [
        CmsCategory(id: '1', name: '电影'),
        CmsCategory(id: '2', name: '剧集'),
        CmsCategory(id: '3', name: '动漫'),
      ],
      const CmsListing(
        videos: [
          CmsVideo(
            id: 'duo-1',
            title: '双屏漫游指南',
            year: '2026',
            area: '中国大陆',
            remarks: '4K HDR',
            description: '在折叠与展开之间丝滑切换的沉浸式影院体验。',
          ),
          CmsVideo(
            id: 'duo-2',
            title: '光影折痕',
            year: '2026',
            area: '美国',
            remarks: '更新至第10集',
          ),
          CmsVideo(
            id: 'duo-3',
            title: '海风与星空',
            year: '2026',
            area: '日本',
            remarks: 'HD',
          ),
          CmsVideo(
            id: 'duo-4',
            title: '极夜航线',
            year: '2026',
            area: '英国',
            remarks: '杜比视界',
          ),
        ],
      ),
    );
  }

  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async {
    return const [
      LiveGroup(
        name: '央视',
        channels: [
          LiveChannel(
            name: 'CCTV1',
            group: '央视',
            urls: ['https://live.example/cctv1.m3u8'],
          ),
          LiveChannel(
            name: 'CCTV5',
            group: '央视',
            urls: ['https://live.example/cctv5.m3u8'],
          ),
          LiveChannel(
            name: 'CCTV6',
            group: '央视',
            urls: ['https://live.example/cctv6.m3u8'],
          ),
        ],
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const duoOuterPortrait = Size(466, 678);
  const duoOuterLandscape = Size(678, 466);
  const duoInnerPortrait = Size(669, 951);
  const duoInnerLandscape = Size(951, 669);
  const duoSplitNarrow = Size(320, 951);
  const standardPhone = Size(390, 844);

  const allDuoViewports = <(String, Size)>[
    ('iPhone Duo 5.4" Outer Portrait (466x678)', duoOuterPortrait),
    ('iPhone Duo 5.4" Outer Landscape (678x466)', duoOuterLandscape),
    ('iPhone Duo 7.6" Inner Portrait (669x951)', duoInnerPortrait),
    ('iPhone Duo 7.6" Inner Landscape (951x669)', duoInnerLandscape),
    ('iPhone Duo Split View Narrow (320x951)', duoSplitNarrow),
  ];

  group('AppleViewportLayout geometry classification', () {
    test('classifies standard iPhone, iPhone Duo outer/inner, and Split View',
        () {
      const std = AppleViewportLayout(standardPhone);
      expect(std.isShortPortrait, isFalse);
      expect(std.isExpandedPortrait, isFalse);
      expect(std.isCompactSplit, isFalse);
      expect(std.prefersWideDetail, isFalse);
      expect(std.iosHomeHeroHeight(844), inInclusiveRange(500.0, 620.0));
      expect(std.posterGridExtent(useSidebar: false), 132.0);

      const outerP = AppleViewportLayout(duoOuterPortrait);
      expect(outerP.isShortPortrait, isTrue);
      expect(outerP.isExpandedPortrait, isFalse);
      expect(outerP.prefersWideDetail, isFalse);
      expect(outerP.iosHomeHeroHeight(678), inInclusiveRange(360.0, 470.0));
      expect(outerP.posterGridExtent(useSidebar: false), 144.0);

      const outerL = AppleViewportLayout(duoOuterLandscape);
      expect(outerL.isShortLandscape, isTrue);
      expect(outerL.isWideLandscape, isTrue);
      expect(outerL.prefersWideDetail, isTrue);

      const innerP = AppleViewportLayout(duoInnerPortrait);
      expect(innerP.isExpandedPortrait, isTrue);
      expect(innerP.isShortPortrait, isFalse);
      expect(innerP.prefersWideDetail, isFalse);
      expect(innerP.horizontalPadding(useSidebar: false), 24.0);
      expect(innerP.posterGridExtent(useSidebar: false), 162.0);
      expect(innerP.iosHomeHeroHeight(951), inInclusiveRange(500.0, 600.0));

      const innerL = AppleViewportLayout(duoInnerLandscape);
      expect(innerL.isWideLandscape, isTrue);
      expect(innerL.prefersWideDetail, isTrue);

      const split = AppleViewportLayout(duoSplitNarrow);
      expect(split.isCompactSplit, isTrue);
      expect(split.horizontalPadding(useSidebar: false), 12.0);
      expect(split.posterGridExtent(useSidebar: false), 148.0);
    });
  });

  group('iPhone Duo full widget matrix (Light + Dark)', () {
    setUp(() {
      IosLiquidGlassBridge.setAvailableForTest(false);
    });

    tearDown(() {
      IosLiquidGlassBridge.setAvailableForTest(false);
    });

    testWidgets(
      'AppleLiquidGlassDock renders with zero overflow across all iPhone Duo sizes and live fold/unfold in Light & Dark',
      (tester) async {
        const dockItems = <(IconData, IconData, String)>[
          (
            CupertinoIcons.play_rectangle,
            CupertinoIcons.play_rectangle_fill,
            '主页',
          ),
          (
            CupertinoIcons.dot_radiowaves_left_right,
            CupertinoIcons.dot_radiowaves_left_right,
            '直播',
          ),
          (
            CupertinoIcons.square_stack_3d_up,
            CupertinoIcons.square_stack_3d_up_fill,
            '片库',
          ),
          (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
        ];
        final sizeNotifier = ValueNotifier<Size>(duoOuterPortrait);
        final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.light);
        final collapsedNotifier = ValueNotifier<bool>(false);
        addTearDown(() {
          sizeNotifier.dispose();
          themeNotifier.dispose();
          collapsedNotifier.dispose();
          tester.view.reset();
        });

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: ValueListenableBuilder<Size>(
                valueListenable: sizeNotifier,
                builder: (_, size, __) {
                  final isLandscape = size.width > size.height;
                  return MediaQuery(
                    data: MediaQueryData(
                      size: size,
                      padding: const EdgeInsets.only(top: 34, bottom: 21),
                    ),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: collapsedNotifier,
                      builder: (_, collapsed, __) => Scaffold(
                        extendBody: true,
                        bottomNavigationBar: isLandscape
                            ? null
                            : Center(
                                heightFactor: 1,
                                child: AppleLiquidGlassDock(
                                  selectedIndex: 0,
                                  onSelect: (_) {},
                                  isLandscape: false,
                                  items: dockItems,
                                  onSearch: () {},
                                  onScrollToTop: () {},
                                  collapsed: collapsed,
                                ),
                              ),
                        body: Stack(
                          fit: StackFit.expand,
                          children: [
                            const SizedBox.expand(),
                            if (isLandscape)
                              Positioned(
                                top: 0,
                                bottom: 0,
                                right: 0,
                                child: Center(
                                  child: AppleLiquidGlassDock(
                                    selectedIndex: 0,
                                    onSelect: (_) {},
                                    isLandscape: true,
                                    items: dockItems,
                                    onSearch: () {},
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeNotifier.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            sizeNotifier.value = size;
            collapsedNotifier.value = false;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            if (size.width <= size.height) {
              final expandedRect = tester.getRect(
                find.byType(AppleLiquidGlassDock),
              );
              collapsedNotifier.value = true;
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final collapsedRect = tester.getRect(
                find.byType(AppleLiquidGlassDock),
              );
              expect(
                collapsedRect.height,
                closeTo(expandedRect.height, 1.0),
              );
              expect(
                collapsedRect.bottom,
                closeTo(expandedRect.bottom, 1.0),
              );
            }
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'DetailScreen adapts cleanly across outer cover, unfolded inner, landscape, and Split View in Light & Dark',
      (tester) async {
        final storage = await initTestStorage();
        final client = _DuoTestCmsClient();
        const site = CmsSite(
          key: 'duo_site',
          name: '双屏测试超长片源名称',
          type: 1,
          api: 'https://source.example/api',
        );
        const video = CmsVideo(
          id: 'duo-1',
          title: '双屏漫游指南：折叠屏全适配',
          year: '2026',
          area: '中国大陆',
          remarks: '4K HDR',
        );

        final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
        addTearDown(() {
          themeMode.dispose();
          tester.view.reset();
        });

        tester.view.physicalSize = duoOuterPortrait;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: DetailScreen(
                client: client,
                storage: storage,
                site: site,
                initialVideo: video,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('双屏漫游指南：折叠屏全适配'), findsOneWidget);
        expect(tester.takeException(), isNull);

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(find.text('双屏漫游指南：折叠屏全适配'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosGlobalSearchPage and IosSettingsPage adapt cleanly across all iPhone Duo sizes in Light & Dark',
      (tester) async {
        final storage = await initTestStorage();
        final client = _DuoTestCmsClient();
        const site = CmsSite(
          key: 'duo_site',
          name: '双屏测试源',
          type: 1,
          api: 'https://source.example/api',
        );
        const videos = [
          CmsVideo(id: '1', title: '影片一', year: '2026'),
          CmsVideo(id: '2', title: '影片二', year: '2026'),
          CmsVideo(id: '3', title: '影片三', year: '2026'),
          CmsVideo(id: '4', title: '影片四', year: '2026'),
        ];
        final queryCtrl = TextEditingController();
        final revision = ValueNotifier<int>(0);
        final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
        addTearDown(() {
          queryCtrl.dispose();
          revision.dispose();
          themeMode.dispose();
          tester.view.reset();
        });

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: IosGlobalSearchPage(
                controller: queryCtrl,
                storage: storage,
                client: client,
                stateRevision: revision,
                readSnapshot: () => GlobalSearchSnapshot(
                  isPrivate: false,
                  searching: false,
                  searchPerformed: false,
                  searchKeyword: '',
                  siteFilterKey: '',
                  searchEpoch: 0,
                  results: const [],
                  notices: const {},
                  verificationSites: const {},
                  visibleSupportedSites: const [site],
                  activeSite: site,
                  homeHotVideos: videos,
                ),
                sourceLabelOf: (s) => s.name,
                onSearch: (_) {},
                onResetSearch: () {},
                onSiteFilterChanged: (_) {},
                onRetryVerifiedSearch: (_) async {},
                onOpenVideoDetail: (_, __) {},
                buildVideoCard: (s, v, {badge, onTap}) => ColoredBox(
                  color: Colors.blueGrey,
                  child: Center(child: Text(v.title)),
                ),
              ),
            ),
          ),
        );

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }

        // Now verify IosSettingsPage across all iPhone Duo sizes in Light & Dark.
        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: Scaffold(
                body: IosSettingsPage(
                  onChanged: () {},
                  pages: (_) => const [
                    SettingsPane(
                      'appearance',
                      '外观与显示',
                      '主题、外屏与内屏布局',
                      CupertinoIcons.paintbrush_fill,
                      AppleColors.systemBlue,
                      trailingText: '跟随系统',
                      sectionGroup: 'appearance',
                      content: SizedBox.shrink(),
                    ),
                    SettingsPane(
                      'playback',
                      '播放与渲染',
                      '硬解、代理与折叠连续播放',
                      CupertinoIcons.play_circle_fill,
                      AppleColors.systemGreen,
                      trailingText: '自动',
                      sectionGroup: 'playback',
                      content: SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'AdaptiveShell preserves tab state with zero overflow across live iPhone Duo fold/unfold/split transitions in Light & Dark',
      (tester) async {
        final storage = await initTestStorage();
        final client = _DuoTestCmsClient();
        await storage.saveConfig(
          '{"sites":[{"key":"duo_site","name":"双屏影院源","type":1,"api":"https://source.example/api"}],'
          '"lives":[{"name":"央视测试","url":"https://live.example/live.m3u"}]}',
        );

        final themeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
        addTearDown(() {
          themeMode.dispose();
          tester.view.reset();
        });

        tester.view.physicalSize = duoOuterPortrait;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (_, mode, __) => MaterialApp(
              themeMode: mode,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: AdaptiveShell(client: client, storage: storage),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Verify Home tab hero height respects compact 5.4" outer cover (`<= 470pt`).
        final heroFinder = find.byKey(const ValueKey('ios-home-immersive-hero'));
        expect(heroFinder, findsOneWidget);
        expect(
          tester.getSize(heroFinder).height,
          lessThanOrEqualTo(470.0),
        );

        // Verify Rex-style Hero bottom transition in BOTH Light & Dark Mode:
        // - ZERO rounded sheet cap (`ios-hero-light-sheet-cap` removed).
        // - `ios-hero-top-ambient-aura` lives strictly in Layer 0 BEHIND
        //   CustomScrollView (NOT inside `ios-home-immersive-hero` / Sliver 0,
        //   eliminating Sliver paint-order fog over the first shelf header!).
        // - `ios-hero-bottom-ambient-gradient` uses an 8-stop single-color
        //   smoothstep dissolve whose solid end color matches Layer 0's solid
        //   color pixel-for-pixel, and Layer 0 dissolves cleanly to alpha 0.0.
        void expectSeamlessHeroBottomMelt({
          required bool dark,
          bool allowLightMidScroll = false,
        }) {
          expect(
            find.byKey(const ValueKey('ios-hero-light-sheet-cap')),
            findsNothing,
          );
          final auraFinder =
              find.byKey(const ValueKey('ios-hero-top-ambient-aura'));
          expect(auraFinder, findsOneWidget);
          expect(
            find.descendant(of: heroFinder, matching: auraFinder),
            findsNothing,
          );

          final auraBox = tester.widget<DecoratedBox>(auraFinder);
          final auraGrad =
              (auraBox.decoration as BoxDecoration).gradient! as LinearGradient;
          final auraSolidColor = auraGrad.colors.first;
          expect(auraGrad.colors[1], equals(auraSolidColor));
          expect(auraSolidColor.a, closeTo(1.0, 0.001));
          expect(auraGrad.colors.last.a, closeTo(0.0, 0.001));

          final bottomBox = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('ios-hero-bottom-ambient-gradient')),
          );
          final bottomGrad =
              (bottomBox.decoration as BoxDecoration).gradient!
                  as LinearGradient;
          expect(bottomGrad.colors.length, greaterThanOrEqualTo(8));
          expect(bottomGrad.colors.first.a, closeTo(0.0, 0.001));
          expect(bottomGrad.colors.last, equals(auraSolidColor));
          expect(bottomGrad.colors.last.a, closeTo(1.0, 0.001));
          if (dark) {
            expect(auraSolidColor.computeLuminance(), lessThanOrEqualTo(0.15));
          } else {
            expect(
              auraSolidColor.computeLuminance(),
              inInclusiveRange(0.04, allowLightMidScroll ? 0.90 : 0.72),
            );
          }
        }

        final homeScrollCtrl = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .controller!;

        expectSeamlessHeroBottomMelt(dark: false);
        homeScrollCtrl.jumpTo(180.0);
        await tester.pump();
        expectSeamlessHeroBottomMelt(dark: false, allowLightMidScroll: true);
        homeScrollCtrl.jumpTo(0.0);
        await tester.pump();

        themeMode.value = ThemeMode.dark;
        await tester.pumpAndSettle();
        expectSeamlessHeroBottomMelt(dark: true);
        homeScrollCtrl.jumpTo(180.0);
        await tester.pump();
        expectSeamlessHeroBottomMelt(dark: true);
        homeScrollCtrl.jumpTo(0.0);
        await tester.pump();

        themeMode.value = ThemeMode.light;
        await tester.pumpAndSettle();

        // Live unfold to 7.6" inner portrait -> landscape -> Split View -> fold back!
        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          themeMode.value = mode;
          for (final (_, size) in allDuoViewports) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }

        // Switch to Live tab and verify fold/unfold/Split View with zero overflow.
        tester.view.physicalSize = duoOuterPortrait;
        await tester.pumpAndSettle();
        await tester.tap(find.text('直播').last);
        await tester.pumpAndSettle();
        for (final (_, size) in allDuoViewports) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpAndSettle();
          expect(find.text('电视直播'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        // Switch to Library tab and verify Split View + Unfolded portrait.
        tester.view.physicalSize = duoInnerPortrait;
        await tester.pumpAndSettle();
        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        for (final size in const [
          duoSplitNarrow,
          duoOuterPortrait,
          duoInnerPortrait,
          duoInnerLandscape,
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpAndSettle();
          expect(find.text('我的片库'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('iOS 0.7.5 Home shelf contrast & hero bottom seam pixel verification',
      () {
    setUp(() {
      IosLiquidGlassBridge.setAvailableForTest(false);
    });

    tearDown(() {
      IosLiquidGlassBridge.setAvailableForTest(false);
    });

    double contrastRatio(Color fg, Color bg) {
      final effectiveFg = fg.a < 0.999 ? Color.alphaBlend(fg, bg) : fg;
      final l1 = effectiveFg.computeLuminance();
      final l2 = bg.computeLuminance();
      return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
    }

    Color samplePixel(ByteData rgba, int width, int height, int x, int y) {
      final cx = x.clamp(0, width - 1);
      final cy = y.clamp(0, height - 1);
      final idx = (cy * width + cx) * 4;
      return Color.fromARGB(
        rgba.getUint8(idx + 3),
        rgba.getUint8(idx),
        rgba.getUint8(idx + 1),
        rgba.getUint8(idx + 2),
      );
    }

    int maxChannelDiff(Color a, Color b) {
      final dr = ((a.r - b.r) * 255).round().abs();
      final dg = ((a.g - b.g) * 255).round().abs();
      final db = ((a.b - b.b) * 255).round().abs();
      return math.max(dr, math.max(dg, db));
    }

    Future<Uint8List> encodeSolidPosterPng(
      Color color, {
      int width = 64,
      int height = 96,
    }) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = color,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(width, height);
      picture.dispose();
      try {
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        return byteData!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }

    Future<({ui.Image image, ByteData rgba})> captureBoundary(
      WidgetTester tester,
      GlobalKey boundaryKey,
    ) async {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1.0));
      final rgba = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      return (image: image!, rgba: rgba!);
    }

    testWidgets(
      'Item 4: Home shelf title, card title & translucent subtitle maintain WCAG contrast across Light/Dark, scroll offsets, colored poster, and iPad without flickering',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        addTearDown(() => tester.view.reset());

        Future<void> verifyContrastScenario({
          required String label,
          required Size size,
          required ThemeMode mode,
          required CmsClient client,
          required List<double> offsets,
          bool checkSingleInkTransition = false,
        }) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          final storage = await initTestStorage();
          await storage.saveConfig(
            '{"sites":[{"key":"contrast_site","name":"对比度源","type":1,"api":"https://source.example/api"}]}',
          );
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                themeMode: mode,
                theme: ThemeData.light(useMaterial3: true),
                darkTheme: ThemeData.dark(useMaterial3: true),
                home: AdaptiveShell(client: client, storage: storage),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();

          final scrollCtrl = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).first)
              .controller!;

          bool? lastIsLightHeader;
          var polarityTransitions = 0;

          for (final off in offsets) {
            scrollCtrl.jumpTo(off.clamp(0.0, scrollCtrl.position.maxScrollExtent));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));

            final snap = await captureBoundary(tester, boundaryKey);
            final w = snap.image.width;
            final h = snap.image.height;

            try {
              final headerFinder = find.text('光影风向标');
              expect(
                headerFinder,
                findsOneWidget,
                reason: '$label @ offset=$off must show 光影风向标',
              );
              final headerRect = tester.getRect(headerFinder);
              if (headerRect.top >= 0 && headerRect.bottom <= h) {
                final headerWidget = tester.widget<Text>(headerFinder);
                final fg = headerWidget.style!.color!;
                final bgY = headerRect.center.dy.round();
                final bgX = math.min(w - 60, (headerRect.right + 40).round());
                final bg = samplePixel(snap.rgba, w, h, bgX, bgY);
                final cr = contrastRatio(fg, bg);
                expect(
                  cr,
                  greaterThanOrEqualTo(3.0),
                  reason:
                      '$label @ offset=$off header contrast ${cr.toStringAsFixed(2)}:1 < 3.0',
                );
                expect(
                  cr,
                  greaterThanOrEqualTo(4.3),
                  reason:
                      '$label @ offset=$off header contrast ${cr.toStringAsFixed(2)}:1 < 4.3',
                );

                final isLight = fg.computeLuminance() > 0.5;
                if (lastIsLightHeader != null && lastIsLightHeader != isLight) {
                  polarityTransitions++;
                }
                lastIsLightHeader = isLight;
              }

              final shelfFinder =
                  find.byKey(const Key('curated-module-weekly_trending'));
              expect(shelfFinder, findsOneWidget);
              final shelfTexts = tester
                  .widgetList<Text>(
                    find.descendant(
                      of: shelfFinder,
                      matching: find.byType(Text),
                    ),
                  )
                  .toList();

              var checkedCardTitle = false;
              var checkedCardSubtitle = false;
              for (final textWidget in shelfTexts) {
                final fontSize = textWidget.style?.fontSize;
                if (fontSize != 13.5 && fontSize != 11.0) continue;
                final rect = tester.getRect(find.byWidget(textWidget));
                if (rect.top < 0 || rect.bottom > h) continue;
                final bgY = rect.center.dy.round();
                final bgX = math.min(w - 10, (rect.right + 8).round());
                final bg = samplePixel(snap.rgba, w, h, bgX, bgY);
                final fg = textWidget.style!.color!;
                final cr = contrastRatio(fg, bg);
                if (fontSize == 13.5 && !checkedCardTitle) {
                  checkedCardTitle = true;
                  expect(
                    cr,
                    greaterThanOrEqualTo(4.5),
                    reason:
                        '$label @ offset=$off card title "${textWidget.data}" contrast ${cr.toStringAsFixed(2)}:1 < 4.5',
                  );
                } else if (fontSize == 11.0 && !checkedCardSubtitle) {
                  checkedCardSubtitle = true;
                  expect(
                    cr,
                    greaterThanOrEqualTo(4.5),
                    reason:
                        '$label @ offset=$off card subtitle "${textWidget.data}" (a=${fg.a.toStringAsFixed(2)}) contrast ${cr.toStringAsFixed(2)}:1 < 4.5',
                  );
                }
                if (checkedCardTitle && checkedCardSubtitle) break;
              }
              expect(
                checkedCardTitle,
                isTrue,
                reason: '$label @ offset=$off must check a visible card title',
              );
              expect(
                checkedCardSubtitle,
                isTrue,
                reason:
                    '$label @ offset=$off must check a visible card subtitle',
              );
            } finally {
              snap.image.dispose();
            }
          }

          if (checkSingleInkTransition) {
            expect(
              polarityTransitions,
              lessThanOrEqualTo(1),
              reason:
                  '$label must not flicker ink polarity repeatedly during continuous scroll (got $polarityTransitions transitions)',
            );
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }

        // 1) Light 390x844 default poster across rest, mid-scroll (incl. 239pt and neighbors), and post-hero.
        await verifyContrastScenario(
          label: 'Light 390x844 default poster',
          size: standardPhone,
          mode: ThemeMode.light,
          client: _DuoTestCmsClient(),
          offsets: const [0, 60, 120, 150, 165, 175, 185, 200, 220, 239, 260, 280, 350, 500],
          checkSingleInkTransition: true,
        );

        // 2) Dark 390x844 default poster.
        await verifyContrastScenario(
          label: 'Dark 390x844 default poster',
          size: standardPhone,
          mode: ThemeMode.dark,
          client: _DuoTestCmsClient(),
          offsets: const [0, 150, 239, 500],
          checkSingleInkTransition: true,
        );

        // 3) Light 390x844 vivid warm-orange poster.
        final warmPosterBytes = await tester.runAsync(
          () => encodeSolidPosterPng(const Color(0xFFD96B27)),
        );
        PosterLoader.seedMemoryForTest(
          'https://poster.example/ios075-warm-orange.png',
          warmPosterBytes!,
          title: '暖色海报影片',
          year: '2026',
          asHd: true,
        );
        final coloredClient = _SingleHeroPosterClient(
          const CmsVideo(
            id: 'warm-hero-1',
            title: '暖色海报影片',
            poster: 'https://poster.example/ios075-warm-orange.png',
            year: '2026',
            area: '中国大陆',
            remarks: '4K',
          ),
        );
        await verifyContrastScenario(
          label: 'Light 390x844 warm-orange poster',
          size: standardPhone,
          mode: ThemeMode.light,
          client: coloredClient,
          offsets: const [0, 150, 239, 500],
          checkSingleInkTransition: true,
        );

        // 4) Light iPad portrait (820x1180) default poster.
        await verifyContrastScenario(
          label: 'Light iPad 820x1180 default poster',
          size: const Size(820, 1180),
          mode: ThemeMode.light,
          client: _DuoTestCmsClient(),
          offsets: const [0, 150, 239, 520],
          checkSingleInkTransition: true,
        );
      },
    );

    testWidgets(
      'Item 5: Hero bottom edge renders seamlessly with zero cross-screen pixel seam at 239pt mid-scroll in Light, Dark, colored poster & iPad',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        addTearDown(() => tester.view.reset());

        Future<void> verifyNoHeroSeam({
          required String label,
          required Size size,
          required ThemeMode mode,
          required CmsClient client,
          required List<double> offsets,
        }) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          final storage = await initTestStorage();
          await storage.saveConfig(
            '{"sites":[{"key":"seam_site","name":"接缝测试源","type":1,"api":"https://source.example/api"}]}',
          );
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                themeMode: mode,
                theme: ThemeData.light(useMaterial3: true),
                darkTheme: ThemeData.dark(useMaterial3: true),
                home: AdaptiveShell(client: client, storage: storage),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();

          final scrollCtrl = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).first)
              .controller!;

          for (final off in offsets) {
            scrollCtrl.jumpTo(off.clamp(0.0, scrollCtrl.position.maxScrollExtent));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));

            final heroRect = tester.getRect(
              find.byKey(const ValueKey('ios-home-immersive-hero')),
            );
            final seamY = heroRect.bottom.round();
            final snap = await captureBoundary(tester, boundaryKey);
            final w = snap.image.width;
            final h = snap.image.height;

            try {
              // Sample left, center, right unobstructed columns across the Hero bottom boundary.
              final columns = <int>[40, math.min(180, w ~/ 2), w - 40];
              for (final x in columns) {
                final pM2 = samplePixel(snap.rgba, w, h, x, seamY - 2);
                final pM1 = samplePixel(snap.rgba, w, h, x, seamY - 1);
                final p0 = samplePixel(snap.rgba, w, h, x, seamY);
                final pP1 = samplePixel(snap.rgba, w, h, x, seamY + 1);
                final pP2 = samplePixel(snap.rgba, w, h, x, seamY + 2);

                final naturalDelta = math.max(
                  maxChannelDiff(pM2, pM1),
                  maxChannelDiff(pP1, pP2),
                );
                final boundaryDelta = math.max(
                  maxChannelDiff(pM1, p0),
                  maxChannelDiff(p0, pP1),
                );
                expect(
                  boundaryDelta,
                  lessThanOrEqualTo(math.max(naturalDelta + 2, 3)),
                  reason:
                      '$label @ off=$off x=$x seamY=$seamY had seam jump $boundaryDelta (natural=$naturalDelta; y-1=$pM1 y0=$p0 y+1=$pP1)',
                );
              }
            } finally {
              snap.image.dispose();
            }
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }

        await verifyNoHeroSeam(
          label: 'Light 390x844 default poster',
          size: standardPhone,
          mode: ThemeMode.light,
          client: _DuoTestCmsClient(),
          offsets: const [0, 150, 239],
        );

        await verifyNoHeroSeam(
          label: 'Dark 390x844 default poster',
          size: standardPhone,
          mode: ThemeMode.dark,
          client: _DuoTestCmsClient(),
          offsets: const [0, 150, 239],
        );

        final warmPosterBytes = await tester.runAsync(
          () => encodeSolidPosterPng(const Color(0xFFD96B27)),
        );
        PosterLoader.seedMemoryForTest(
          'https://poster.example/ios075-seam-warm.png',
          warmPosterBytes!,
          title: '接缝暖色海报',
          year: '2026',
          asHd: true,
        );
        await verifyNoHeroSeam(
          label: 'Light 390x844 warm-orange poster',
          size: standardPhone,
          mode: ThemeMode.light,
          client: _SingleHeroPosterClient(
            const CmsVideo(
              id: 'seam-warm-1',
              title: '接缝暖色海报',
              poster: 'https://poster.example/ios075-seam-warm.png',
              year: '2026',
            ),
          ),
          offsets: const [0, 239],
        );

        await verifyNoHeroSeam(
          label: 'Light iPad 820x1180 default poster',
          size: const Size(820, 1180),
          mode: ThemeMode.light,
          client: _DuoTestCmsClient(),
          offsets: const [0, 239],
        );
      },
    );

    testWidgets(
      'Review Item 3: Source-updates catalog cards maintain >= 4.5:1 title & subtitle contrast when moved to first Home section (iPad 820x1180 & iPhone 390x844) while default order stays intact',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        addTearDown(() => tester.view.reset());

        Future<void> verifyCustomSourceUpdatesFirst({
          required String label,
          required Size size,
          required List<double> offsets,
        }) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          final storage = await initTestStorage();
          await storage.saveConfig(
            '{"sites":[{"key":"duo_site","name":"双屏影院源","type":1,"api":"https://source.example/api"}]}',
          );
          await storage.setHomeSectionOrder(const [
            StorageService.homeSectionSourceUpdates,
            StorageService.homeSectionWidescreenRadar,
            StorageService.homeSectionEditorialPicks,
            StorageService.homeSectionHotStream,
          ]);
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                themeMode: ThemeMode.light,
                theme: ThemeData.light(useMaterial3: true),
                darkTheme: ThemeData.dark(useMaterial3: true),
                home: AdaptiveShell(
                  client: _DuoTestCmsClient(),
                  storage: storage,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final scrollCtrl = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).first)
              .controller!;

          for (final off in offsets) {
            scrollCtrl.jumpTo(off.clamp(0.0, scrollCtrl.position.maxScrollExtent));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));

            final snap = await captureBoundary(tester, boundaryKey);
            final w = snap.image.width;
            final h = snap.image.height;

            try {
              // Find visible source-catalog video card title ('光影折痕', fontSize 13.0)
              // and its subtitle ('更新至第10集', fontSize 11.0).
              final titleFinder = find.text('光影折痕');
              final subFinder = find.text('更新至第10集');
              expect(
                titleFinder,
                findsWidgets,
                reason: '$label @ off=$off must render catalog card title',
              );
              expect(
                subFinder,
                findsWidgets,
                reason: '$label @ off=$off must render catalog card subtitle',
              );

              // Pick the card Text widgets (fontSize 13.0 and 11.0, excluding poster remarks overlay fontSize 10.0).
              Text? cardTitleWidget;
              Rect? cardTitleRect;
              for (final el in titleFinder.evaluate()) {
                final t = el.widget as Text;
                if (t.style?.fontSize == 13.0) {
                  final r = tester.getRect(find.byWidget(t));
                  if (r.top >= 0 && r.bottom <= h) {
                    cardTitleWidget = t;
                    cardTitleRect = r;
                    break;
                  }
                }
              }
              Text? cardSubWidget;
              Rect? cardSubRect;
              for (final el in subFinder.evaluate()) {
                final t = el.widget as Text;
                if (t.style?.fontSize == 11.0) {
                  final r = tester.getRect(find.byWidget(t));
                  if (r.top >= 0 && r.bottom <= h) {
                    cardSubWidget = t;
                    cardSubRect = r;
                    break;
                  }
                }
              }
              expect(
                cardTitleWidget,
                isNotNull,
                reason: '$label @ off=$off visible catalog card title not found',
              );
              expect(
                cardSubWidget,
                isNotNull,
                reason: '$label @ off=$off visible catalog card subtitle not found',
              );

              // Sample clean backdrop pixel in the horizontal margin at the exact text y-band.
              final titleBg = samplePixel(
                snap.rgba,
                w,
                h,
                6,
                cardTitleRect!.center.dy.round(),
              );
              final subBg = samplePixel(
                snap.rgba,
                w,
                h,
                6,
                cardSubRect!.center.dy.round(),
              );
              final titleCr = contrastRatio(
                cardTitleWidget!.style!.color!,
                titleBg,
              );
              final subCr = contrastRatio(
                cardSubWidget!.style!.color!,
                subBg,
              );
              expect(
                titleCr,
                greaterThanOrEqualTo(4.5),
                reason:
                    '$label @ off=$off catalog card title contrast ${titleCr.toStringAsFixed(2)}:1 < 4.5 (fg=${cardTitleWidget.style!.color} bg=$titleBg)',
              );
              expect(
                subCr,
                greaterThanOrEqualTo(4.5),
                reason:
                    '$label @ off=$off catalog card subtitle contrast ${subCr.toStringAsFixed(2)}:1 < 4.5 (fg=${cardSubWidget.style!.color} bg=$subBg)',
              );
            } finally {
              snap.image.dispose();
            }
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }

        // Codex repro 1: Light iPad 820x1180 at rest (0pt) + mid-scroll + post-hero.
        await verifyCustomSourceUpdatesFirst(
          label: 'Custom source-updates first Light iPad 820x1180',
          size: const Size(820, 1180),
          offsets: const [0, 150, 239, 520],
        );

        // Codex repro 2: Light iPhone 390x844 at 100pt + 180pt + 239pt + 500pt.
        await verifyCustomSourceUpdatesFirst(
          label: 'Custom source-updates first Light iPhone 390x844',
          size: standardPhone,
          offsets: const [100, 180, 239, 500],
        );
      },
    );

    testWidgets(
      'Review Item 4: Hero featured title keeps >= 3.0:1 contrast against actual background at rest, 320pt mid-scroll and nearby offsets (missing poster & loaded dark/warm posters)',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        addTearDown(() => tester.view.reset());

        Future<void> verifyHeroTitleContrast({
          required String label,
          required CmsClient client,
          required String heroTitle,
          required List<double> offsets,
        }) async {
          tester.view.physicalSize = standardPhone;
          tester.view.devicePixelRatio = 1.0;
          final storage = await initTestStorage();
          await storage.saveConfig(
            '{"sites":[{"key":"hero_title_site","name":"首推源","type":1,"api":"https://source.example/api"}]}',
          );
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                themeMode: ThemeMode.light,
                theme: ThemeData.light(useMaterial3: true),
                darkTheme: ThemeData.dark(useMaterial3: true),
                home: AdaptiveShell(client: client, storage: storage),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();

          final scrollCtrl = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).first)
              .controller!;

          for (final off in offsets) {
            scrollCtrl.jumpTo(off.clamp(0.0, scrollCtrl.position.maxScrollExtent));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));

            final snap = await captureBoundary(tester, boundaryKey);
            final w = snap.image.width;
            final h = snap.image.height;

            try {
              final titleFinder = find.text(heroTitle);
              Text? heroTitleWidget;
              Rect? heroTitleRect;
              for (final el in titleFinder.evaluate()) {
                final t = el.widget as Text;
                if ((t.style?.fontSize ?? 0) >= 22.0) {
                  final r = tester.getRect(find.byWidget(t));
                  if (r.bottom > 8 && r.top < h) {
                    heroTitleWidget = t;
                    heroTitleRect = r;
                    break;
                  }
                }
              }
              expect(
                heroTitleWidget,
                isNotNull,
                reason: '$label @ off=$off must keep hero title visible on screen',
              );

              // Sample clean background pixels right beside the title glyphs at the title's y-center.
              final y = heroTitleRect!.center.dy.round().clamp(1, h - 2);
              final leftX = math.max(8, (heroTitleRect.left - 18).round());
              final rightX = math.min(w - 8, (heroTitleRect.right + 18).round());
              final bgLeft = samplePixel(snap.rgba, w, h, leftX, y);
              final bgRight = samplePixel(snap.rgba, w, h, rightX, y);
              final fg = heroTitleWidget!.style!.color!;
              final cr = math.min(
                contrastRatio(fg, bgLeft),
                contrastRatio(fg, bgRight),
              );
              expect(
                cr,
                greaterThanOrEqualTo(3.0),
                reason:
                    '$label @ off=$off (y=$y) hero title contrast ${cr.toStringAsFixed(2)}:1 < 3.0 (fg=$fg bgLeft=$bgLeft bgRight=$bgRight)',
              );
            } finally {
              snap.image.dispose();
            }
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }

        // 1) Missing poster (default #48647B backdrop) — Codex exact 320pt repro + rest + neighbors.
        await verifyHeroTitleContrast(
          label: 'Light 390x844 missing-poster hero title',
          client: _DuoTestCmsClient(),
          heroTitle: '双屏漫游指南',
          offsets: const [0, 150, 200, 239, 300, 320, 340, 360],
        );

        // 2) Loaded dark poster (#121A24).
        final darkPosterBytes = await tester.runAsync(
          () => encodeSolidPosterPng(const Color(0xFF121A24)),
        );
        PosterLoader.seedMemoryForTest(
          'https://poster.example/ios075-hero-dark.png',
          darkPosterBytes!,
          title: '暗夜首推影片',
          year: '2026',
          asHd: true,
        );
        await verifyHeroTitleContrast(
          label: 'Light 390x844 loaded dark-poster hero title',
          client: _SingleHeroPosterClient(
            const CmsVideo(
              id: 'hero-dark-1',
              title: '暗夜首推影片',
              poster: 'https://poster.example/ios075-hero-dark.png',
              year: '2026',
            ),
          ),
          heroTitle: '暗夜首推影片',
          offsets: const [0, 150, 239, 300, 320, 340],
        );

        // 3) Loaded warm-orange poster (#D96B27).
        final warmPosterBytes = await tester.runAsync(
          () => encodeSolidPosterPng(const Color(0xFFD96B27)),
        );
        PosterLoader.seedMemoryForTest(
          'https://poster.example/ios075-hero-warm.png',
          warmPosterBytes!,
          title: '暖阳首推影片',
          year: '2026',
          asHd: true,
        );
        await verifyHeroTitleContrast(
          label: 'Light 390x844 loaded warm-poster hero title',
          client: _SingleHeroPosterClient(
            const CmsVideo(
              id: 'hero-warm-1',
              title: '暖阳首推影片',
              poster: 'https://poster.example/ios075-hero-warm.png',
              year: '2026',
            ),
          ),
          heroTitle: '暖阳首推影片',
          offsets: const [0, 150, 239, 320, 340],
        );
      },
    );

    testWidgets(
      'Round2 Item 5: Split dark-overall / bright-title-band poster preserves >= 3.0:1 contrast for 2-line Hero title at 228pt scroll & rest on Light 390x844 without introducing a Hero bottom seam',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        addTearDown(() => tester.view.reset());
        tester.view.physicalSize = standardPhone;
        tester.view.devicePixelRatio = 1.0;

        Future<Uint8List> encodeSplitBrightnessPosterPng() async {
          const width = 195;
          const height = 274;
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          // Overall dark poster (including lower 25% edge weighted heavily by
          // extractVibrantAmbientColor) so whole-poster ambient color stays dark
          // and Hero selects white ink even at 228pt scroll in Light mode.
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 195, 274),
            Paint()..color = const Color(0xFF0A1018),
          );
          // Pure white (#FFFFFF) local highlight spanning 100% of BOTH lines
          // of the 2-line Hero title (y in [0.68, 0.82] of heroHeight) while
          // top, sides, and bottom remain dark so overall ambient stays dark!
          canvas.drawRect(
            Rect.fromLTWH(
              width * 0.08,
              height * 0.68,
              width * 0.84,
              height * 0.14,
            ),
            Paint()..color = const Color(0xFFFFFFFF),
          );
          final picture = recorder.endRecording();
          final image = picture.toImageSync(width, height);
          picture.dispose();
          try {
            final byteData =
                await image.toByteData(format: ui.ImageByteFormat.png);
            return byteData!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        }

        const twoLineTitle = '星际迷航终章：暗夜光年跨越深空双行标题测试';
        final splitPosterBytes = await tester.runAsync(
          encodeSplitBrightnessPosterPng,
        );
        PosterLoader.seedMemoryForTest(
          'https://poster.example/ios075-split-bright-title.png',
          splitPosterBytes!,
          title: twoLineTitle,
          year: '2026',
          asHd: true,
        );

        final storage = await initTestStorage();
        await storage.saveConfig(
          '{"sites":[{"key":"split_hero_site","name":"分区海报源","type":1,"api":"https://source.example/api"}]}',
        );
        final client = _SingleHeroPosterClient(
          const CmsVideo(
            id: 'hero-split-1',
            title: twoLineTitle,
            poster: 'https://poster.example/ios075-split-bright-title.png',
            year: '2026',
            area: '美国',
            remarks: '4K HDR',
            description: '局部亮区复杂海报标题可读性回归测试',
          ),
        );

        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              themeMode: ThemeMode.light,
              theme: ThemeData.light(useMaterial3: true),
              darkTheme: ThemeData.dark(useMaterial3: true),
              home: AdaptiveShell(client: client, storage: storage),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final scrollCtrl = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .controller!;

        double? contrastAt228;
        for (final off in const [0.0, 120.0, 228.0, 260.0, 320.0]) {
          scrollCtrl.jumpTo(off.clamp(0.0, scrollCtrl.position.maxScrollExtent));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));

          final snap = await captureBoundary(tester, boundaryKey);
          final w = snap.image.width;
          final h = snap.image.height;
          try {
            final heroFinder = find.byKey(const ValueKey('ios-home-immersive-hero'));
            expect(heroFinder, findsOneWidget);
            final heroRect = tester.getRect(heroFinder);

            // Confirm Hero title renders as 2 lines and stays visible at each offset.
            final titleFinder = find.descendant(
              of: heroFinder,
              matching: find.text(twoLineTitle),
            );
            expect(titleFinder, findsOneWidget);
            final titleWidget = tester.widget<Text>(titleFinder);
            final titleRect = tester.getRect(titleFinder);
            expect(
              titleRect.height,
              greaterThanOrEqualTo(44.0),
              reason: 'Hero title must wrap to 2 lines (height=${titleRect.height})',
            );
            final fg = titleWidget.style!.color!;

            // Sample actual backdrop pixels right inside & around the bright patch behind BOTH lines of the 2-line title.
            final yLine1 = (titleRect.top + titleRect.height * 0.25)
                .round()
                .clamp(1, h - 2);
            final yMid = titleRect.center.dy.round().clamp(1, h - 2);
            final yLine2 = (titleRect.top + titleRect.height * 0.75)
                .round()
                .clamp(1, h - 2);
            final yAbove = (titleRect.top - 3).round().clamp(1, h - 2);
            final yBelow = (titleRect.bottom + 2).round().clamp(1, h - 2);
            final leftX = math.max(8, (titleRect.left - 8).round());
            final rightX = math.min(w - 8, (titleRect.right + 8).round());
            final innerLeftX = (titleRect.left + 2).round().clamp(8, w - 8);
            final innerRightX = (titleRect.right - 2).round().clamp(8, w - 8);
            final centerX = titleRect.center.dx.round().clamp(8, w - 8);

            final samplePoints = <(int, int)>[
              (leftX, yLine1),
              (rightX, yLine1),
              (innerLeftX, yMid),
              (innerRightX, yMid),
              (leftX, yLine2),
              (rightX, yLine2),
              (centerX, yAbove),
              (centerX, yBelow),
            ];
            var minCr = double.infinity;
            Color? worstBg;
            for (final (sx, sy) in samplePoints) {
              if (sy <= 0 || sy >= h - 1) continue;
              final bg = samplePixel(snap.rgba, w, h, sx, sy);
              final cr = contrastRatio(fg, bg);
              if (cr < minCr) {
                minCr = cr;
                worstBg = bg;
              }
            }
            if (off == 228.0) {
              contrastAt228 = minCr;
              // Confirm this scenario really exercises white ink over a dark-overall
              // poster with a bright region directly behind the 2-line Hero title.
              expect(
                fg.computeLuminance(),
                greaterThan(0.8),
                reason: 'Expected white hero title ink at 228pt (got $fg)',
              );
            }
            expect(
              minCr,
              greaterThanOrEqualTo(3.0),
              reason:
                  'Split-poster 2-line Hero title @ offset=$off min contrast ${minCr.toStringAsFixed(2)}:1 < 3.0 (fg=$fg worstBg=$worstBg)',
            );

            // Also verify Hero bottom seam remains seamless (<= 1 channel diff) when bottom is on screen.
            final heroBottomY = heroRect.bottom.round();
            if (heroBottomY >= 4 && heroBottomY <= h - 4) {
              for (final frac in const [0.15, 0.50, 0.85]) {
                final x = (w * frac).round();
                final above = samplePixel(snap.rgba, w, h, x, heroBottomY - 2);
                final below = samplePixel(snap.rgba, w, h, x, heroBottomY + 2);
                final diff = maxChannelDiff(above, below);
                expect(
                  diff,
                  lessThanOrEqualTo(1),
                  reason:
                      'Split-poster Hero bottom seam @ offset=$off x=$x diff=$diff > 1 (above=$above below=$below)',
                );
              }
            }
          } finally {
            snap.image.dispose();
          }
        }
        expect(contrastAt228, isNotNull);
        expect(contrastAt228!, greaterThanOrEqualTo(3.0));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

class _SingleHeroPosterClient extends CmsClient {
  final CmsVideo heroVideo;
  _SingleHeroPosterClient(this.heroVideo);

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const [CmsCategory(id: '1', name: '电影')],
      CmsListing(videos: [heroVideo]),
    );
  }

  @override
  Future<CmsVideo> fetchDetail(
    CmsSite site,
    CmsVideo video, {
    bool forceRefresh = false,
  }) async =>
      video;
}

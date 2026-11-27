// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/motion/player_enter_transition.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/windows_appearance.dart';

import 'test_storage_helper.dart';

class _InstantDetailClient extends CmsClient {
  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates,
  ) async =>
      (source, item);

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async =>
      const CmsListing();
}

class _RouteRecorder extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

/// Generates a real PNG byte payload for a 2:3 vertical striped poster:
/// top 1/3 red (#E02020), middle 1/3 green (#20D050), bottom 1/3 red (#E02020).
Future<Uint8List> _encodeStripedPosterPng({
  int width = 120,
  int height = 180,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final third = height / 3.0;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), third),
    Paint()..color = const Color(0xFFE02020),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, third, width.toDouble(), third),
    Paint()..color = const Color(0xFF20D050),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, third * 2, width.toDouble(), height - third * 2),
    Paint()..color = const Color(0xFFE02020),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Builds a distinctive bright detail-page backdrop texture so any opaque
/// `#121216` (`RGB(18, 18, 22)`) occlusion over titles/buttons/cards stands out.
ui.Image _createDetailBackdropImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // Vivid sky-blue base (#2A8AE0 -> RGB 42, 138, 224)
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF2A8AE0),
  );
  // Top Liquid Glass nav button zone (#F0D040 -> RGB 240, 208, 64)
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height * 0.14),
    Paint()..color = const Color(0xFFF0D040),
  );
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(width, height);
  } finally {
    picture.dispose();
  }
}

Future<ByteData> _renderShaderFrameRgba({
  required ui.FragmentProgram program,
  required PlayerTransitionSnapshot snapshot,
  required Size size,
  required double progress,
}) async {
  final shader = program.fragmentShader();
  try {
    final painter = PlayerEnterShaderPainter(
      shader: shader,
      progress: progress,
      snapshot: snapshot,
      safePaddingLogical: EdgeInsets.zero,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, size);
    final picture = recorder.endRecording();
    final rendered = picture.toImageSync(size.width.round(), size.height.round());
    picture.dispose();
    try {
      return (await rendered.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    } finally {
      rendered.dispose();
    }
  } finally {
    shader.dispose();
  }
}

(int r, int g, int b, int a) _pixelAt(ByteData rgba, int width, int x, int y) {
  final idx = (y * width + x) * 4;
  return (
    rgba.getUint8(idx),
    rgba.getUint8(idx + 1),
    rgba.getUint8(idx + 2),
    rgba.getUint8(idx + 3),
  );
}

bool _looksLikeDarkGraySlab((int r, int g, int b, int a) px) =>
    px.$1 < 35 && px.$2 < 35 && px.$3 < 40;

void main() {
  setUp(() async {
    OhosRuntime.resetForTesting();
    PlayerEnterTransition.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    await PosterLoader.clearCache();
  });

  tearDown(() async {
    OhosRuntime.resetForTesting();
    PlayerEnterTransition.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    await PosterLoader.clearCache();
  });

  const privateSite = CmsSite(
    key: 'r4_detail_site',
    name: 'R4 详情转场测试源',
    type: 1,
    api: 'https://detail.example/api',
    isPrivate: true,
  );

  CmsVideo buildVideo({required String posterUrl}) => CmsVideo(
        id: 'r4_vid_1',
        title: '影院视窗测试片',
        poster: posterUrl,
        year: '2026',
        remarks: '4K HDR10',
        description: '用于验证真实详情页点击播放后的视窗转场与纹理释放。',
        lines: const [
          CmsLine(
            name: '主线路',
            episodes: [
              CmsEpisode(name: '第01集', url: 'https://detail.example/ep1.mp4'),
            ],
          ),
        ],
      );

  group('S-01 real DetailScreen click-play transition integration tests', () {
    testWidgets(
      'Case 1 (Portrait width < 720, iPhone): clicking play passes Rect.zero portal, does NOT occlude frame 0 title/buttons, runs depth-recession only',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final program = await PlayerEnterTransition.prewarmShader();
        expect(program, isNotNull);

        // Even WITH poster bytes loaded on the full-bleed background, portrait layout
        // has NO independent 2:3 card and MUST NOT bind full-bleed hero as portal!
        const posterUrl = 'https://poster.example/portrait_hero.png';
        late Uint8List posterPng;
        await tester.runAsync(() async {
          posterPng = await _encodeStripedPosterPng(width: 120, height: 180);
        });
        PosterLoader.seedMemoryForTest(posterUrl, posterPng, asHd: true);

        ui.Image? capturedBackdrop;
        PlayerTransitionMode? resolvedMode;
        final observer = _RouteRecorder();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: DetailScreen(
              site: privateSite,
              initialVideo: buildVideo(posterUrl: posterUrl),
              client: _InstantDetailClient(),
              storage: storage,
              debugTransitionShaderProgram: program,
              debugTransitionCapturer: (_) async {
                capturedBackdrop = _createDetailBackdropImage(390, 844);
                return capturedBackdrop;
              },
              debugOnTransitionModeResolved: (m) => resolvedMode = m,
              debugPlayerBuilder: (_, __, ___, ____, _____, ______) =>
                  const Scaffold(body: Text('portrait-player-mounted')),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Click the real DetailScreen primary play button.
        final playFinder = find.text('播放 · 第01集');
        expect(playFinder, findsOneWidget);
        await tester.tap(playFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final pushedRoute = observer.pushed.whereType<PlayerEnterPageRoute<void>>().last;
        expect(pushedRoute.resolvedMode, PlayerTransitionMode.shaderPortal);
        expect(resolvedMode, PlayerTransitionMode.shaderPortal);
        final snapshot = pushedRoute.snapshot!;
        expect(snapshot.hasBackdrop, isTrue);
        // Portrait immersive layout MUST emit zero/empty portal rect & no foreground poster.
        expect(snapshot.posterOriginLogical, Rect.zero);
        expect(snapshot.hasPoster, isFalse);
        expect(snapshot.posterImage, isNull);

        // Verify real compiled player_enter.frag output at frame 0 & mid-recession:
        late ByteData frame0Rgba;
        late ByteData midRgba;
        await tester.runAsync(() async {
          frame0Rgba = await _renderShaderFrameRgba(
            program: program!,
            snapshot: snapshot,
            size: const Size(390, 844),
            progress: 0.0,
          );
          midRgba = await _renderShaderFrameRgba(
            program: program,
            snapshot: snapshot,
            size: const Size(390, 844),
            progress: 0.45,
          );
        });

        // Frame 0: top Liquid Glass buttons (40, 40), hero center (195, 220),
        // and title/action area (195, 520) are 100% unoccluded (NOT #121216!).
        final topNavPx = _pixelAt(frame0Rgba, 390, 40, 40);
        final upperHeroPx = _pixelAt(frame0Rgba, 390, 195, 220);
        final titleZonePx = _pixelAt(frame0Rgba, 390, 195, 520);
        expect(_looksLikeDarkGraySlab(topNavPx), isFalse);
        expect(_looksLikeDarkGraySlab(upperHeroPx), isFalse);
        expect(_looksLikeDarkGraySlab(titleZonePx), isFalse);
        expect(topNavPx.$1, greaterThan(220)); // yellow top bar preserved
        expect(topNavPx.$2, greaterThan(190));
        expect(upperHeroPx.$3, greaterThan(200)); // blue backdrop preserved
        expect(titleZonePx.$3, greaterThan(200));

        // Mid-transition (0.45): depth recession + darkening runs cleanly (darker than frame 0,
        // still blue-tinted backdrop with zero green/red poster portal overlay).
        final midCenterPx = _pixelAt(midRgba, 390, 195, 422);
        expect(midCenterPx.$3, greaterThan(midCenterPx.$1));
        expect(midCenterPx.$3, lessThan(upperHeroPx.$3));

        // Complete transition -> backdrop texture disposed cleanly.
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('portrait-player-mounted'), findsOneWidget);
        expect(snapshot.isDisposed, isTrue);
        expect(capturedBackdrop?.debugDisposed, isTrue);
      },
    );

    testWidgets(
      'Case 2 (Wide width >= 720, iPad/macOS, poster READY): clicking play passes real decoded ui.Image + local 2:3 card rect, expands via BoxFit.cover, and disposes ui.Image on complete & cancel',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1024, 768);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final program = await PlayerEnterTransition.prewarmShader();
        expect(program, isNotNull);

        const posterUrl = 'https://poster.example/wide_card_2x3.png';
        late Uint8List posterPng;
        await tester.runAsync(() async {
          posterPng = await _encodeStripedPosterPng(width: 120, height: 180);
        });
        PosterLoader.seedMemoryForTest(posterUrl, posterPng, asHd: true);

        final capturedBackdrops = <ui.Image>[];
        PlayerTransitionMode? resolvedMode;
        final observer = _RouteRecorder();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: DetailScreen(
              site: privateSite,
              initialVideo: buildVideo(posterUrl: posterUrl),
              client: _InstantDetailClient(),
              storage: storage,
              debugTransitionShaderProgram: program,
              debugTransitionCapturer: (_) async {
                final img = _createDetailBackdropImage(1024, 768);
                capturedBackdrops.add(img);
                return img;
              },
              debugOnTransitionModeResolved: (m) => resolvedMode = m,
              debugPlayerBuilder: (_, __, ___, ____, _____, ______) =>
                  const Scaffold(body: Text('wide-ready-player')),
            ),
          ),
        );
        // Allow MemoryImage inside _buildPosterCard to finish decoding in runAsync.
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // 2a) First play click -> full completion path.
        final playFinder = find.text('播放 · 第01集');
        expect(playFinder, findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(playFinder);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final route1 =
            observer.pushed.whereType<PlayerEnterPageRoute<void>>().last;
        expect(route1.resolvedMode, PlayerTransitionMode.shaderPortal);
        expect(resolvedMode, PlayerTransitionMode.shaderPortal);

        final snap1 = route1.snapshot!;
        final poster1 = snap1.posterImage;
        expect(snap1.hasBackdrop, isTrue);
        expect(snap1.hasPoster, isTrue);
        expect(snap1.ownsPoster, isTrue);
        expect(poster1, isNotNull);
        expect(poster1!.width, 120);
        expect(poster1.height, 180);
        expect(snap1.posterAspect, closeTo(2.0 / 3.0, 0.02));

        // Must be the local independent 2:3 poster card rect (NOT full-screen 1024x768 backdrop!).
        final origin = snap1.posterOriginLogical;
        expect(origin.width, inInclusiveRange(160.0, 230.0));
        expect(origin.height, inInclusiveRange(240.0, 345.0));
        expect(origin.width / origin.height, closeTo(2.0 / 3.0, 0.05));
        expect(origin.width, lessThan(1024.0 * 0.35));
        expect(origin.height, lessThan(768.0 * 0.55));

        // Verify real compiled shader renders poster inside card rect at frame 0,
        // leaves right-side title/buttons unoccluded, and expands with BoxFit.cover at progress 0.45.
        late ByteData frame0Rgba;
        late ByteData midRgba;
        await tester.runAsync(() async {
          frame0Rgba = await _renderShaderFrameRgba(
            program: program!,
            snapshot: snap1,
            size: const Size(1024, 768),
            progress: 0.0,
          );
          midRgba = await _renderShaderFrameRgba(
            program: program,
            snapshot: snap1,
            size: const Size(1024, 768),
            progress: 0.45,
          );
        });

        final cardCenterX = origin.center.dx.round();
        final cardCenterY = origin.center.dy.round();
        final cardTopY = (origin.top + origin.height * 0.16).round();
        final f0CardCenter = _pixelAt(frame0Rgba, 1024, cardCenterX, cardCenterY);
        final f0CardTop = _pixelAt(frame0Rgba, 1024, cardCenterX, cardTopY);
        final f0TitleSide = _pixelAt(frame0Rgba, 1024, 650, 260);
        // Inside 2:3 card: green middle stripe & red top stripe
        expect(f0CardCenter.$2, greaterThan(f0CardCenter.$1 + 100));
        expect(f0CardCenter.$2, greaterThan(f0CardCenter.$3 + 80));
        expect(f0CardTop.$1, greaterThan(f0CardTop.$2 + 100));
        // Right side over title/buttons: unoccluded vivid blue backdrop!
        expect(f0TitleSide.$3, greaterThan(200));

        // At progress = 0.45, portal expands toward centered 16:9 viewport (512, 384):
        // BoxFit.cover preserves aspect ratio by vertically cropping into green center band.
        final midViewportCenter = _pixelAt(midRgba, 1024, 512, 384);
        expect(midViewportCenter.$2, greaterThan(midViewportCenter.$1 + 50));
        expect(midViewportCenter.$2, greaterThan(midViewportCenter.$3 + 30));

        // Complete 420ms transition -> BOTH backdrop and poster ui.Images MUST be disposed!
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('wide-ready-player'), findsOneWidget);
        expect(snap1.isDisposed, isTrue);
        expect(poster1.debugDisposed, isTrue);
        expect(capturedBackdrops.last.debugDisposed, isTrue);

        // 2b) Pop back, click play again, and cancel/pop MID-FLIGHT (at 120ms) ->
        // poster & backdrop ui.Images MUST be cleanly disposed with zero double-dispose!
        Navigator.of(tester.element(find.text('wide-ready-player'))).pop();
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          await tester.tap(find.text('播放 · 第01集'));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));

        final route2 =
            observer.pushed.whereType<PlayerEnterPageRoute<void>>().last;
        final snap2 = route2.snapshot!;
        final poster2 = snap2.posterImage;
        expect(poster2, isNotNull);
        expect(poster2!.debugDisposed, isFalse);

        // Cancel mid-transition!
        route2.navigator!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(snap2.isDisposed, isTrue);
        expect(poster2.debugDisposed, isTrue);
        expect(capturedBackdrops.last.debugDisposed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Case 3 (Wide width >= 720, poster NOT ready): clicking play does NOT draw #121216 slab over uBackdropTex, leaves frame 0 unoccluded, runs depth-recession only',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1024, 768);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final program = await PlayerEnterTransition.prewarmShader();
        expect(program, isNotNull);

        ui.Image? capturedBackdrop;
        PlayerTransitionMode? resolvedMode;
        final observer = _RouteRecorder();

        // Empty poster URL + private site -> poster texture is NOT ready (posterAvailable == false).
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: DetailScreen(
              site: privateSite,
              initialVideo: buildVideo(posterUrl: ''),
              client: _InstantDetailClient(),
              storage: storage,
              debugTransitionShaderProgram: program,
              debugTransitionCapturer: (_) async {
                capturedBackdrop = _createDetailBackdropImage(1024, 768);
                return capturedBackdrop;
              },
              debugOnTransitionModeResolved: (m) => resolvedMode = m,
              debugPlayerBuilder: (_, __, ___, ____, _____, ______) =>
                  const Scaffold(body: Text('wide-notready-player')),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        final playFinder = find.text('播放 · 第01集');
        expect(playFinder, findsOneWidget);
        await tester.tap(playFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final route =
            observer.pushed.whereType<PlayerEnterPageRoute<void>>().last;
        expect(route.resolvedMode, PlayerTransitionMode.shaderPortal);
        expect(resolvedMode, PlayerTransitionMode.shaderPortal);

        final snapshot = route.snapshot!;
        expect(snapshot.hasBackdrop, isTrue);
        expect(snapshot.hasPoster, isFalse);
        expect(snapshot.posterImage, isNull);

        late ByteData frame0Rgba;
        late ByteData midRgba;
        await tester.runAsync(() async {
          frame0Rgba = await _renderShaderFrameRgba(
            program: program!,
            snapshot: snapshot,
            size: const Size(1024, 768),
            progress: 0.0,
          );
          midRgba = await _renderShaderFrameRgba(
            program: program,
            snapshot: snapshot,
            size: const Size(1024, 768),
            progress: 0.45,
          );
        });

        // Frame 0: both the poster-card region (140, 320) AND title/buttons (650, 260) &
        // top nav (80, 40) match unoccluded backdrop — ZERO #121216 dark-gray slab!
        final cardAreaPx = _pixelAt(frame0Rgba, 1024, 140, 320);
        final titleAreaPx = _pixelAt(frame0Rgba, 1024, 650, 260);
        final topNavPx = _pixelAt(frame0Rgba, 1024, 80, 40);
        expect(_looksLikeDarkGraySlab(cardAreaPx), isFalse);
        expect(_looksLikeDarkGraySlab(titleAreaPx), isFalse);
        expect(_looksLikeDarkGraySlab(topNavPx), isFalse);
        expect(cardAreaPx.$3, greaterThan(200));
        expect(titleAreaPx.$3, greaterThan(200));
        expect(topNavPx.$1, greaterThan(220));

        // Mid-transition runs pure depth-recession darkening on uBackdropTex.
        final midCenterPx = _pixelAt(midRgba, 1024, 512, 384);
        expect(midCenterPx.$3, greaterThan(midCenterPx.$1));
        expect(midCenterPx.$3, lessThan(cardAreaPx.$3));

        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('wide-notready-player'), findsOneWidget);
        expect(snapshot.isDisposed, isTrue);
        expect(capturedBackdrop?.debugDisposed, isTrue);
      },
    );

    testWidgets(
      'Windows 185ms fast route & OHOS guard stay intact when clicking play from real DetailScreen',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final storage = await initTestStorage();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        var captureCalled = false;
        PlayerTransitionMode? resolvedMode;
        final observer = _RouteRecorder();

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: DetailScreen(
              site: privateSite,
              initialVideo: buildVideo(posterUrl: ''),
              client: _InstantDetailClient(),
              storage: storage,
              debugTransitionCapturer: (_) async {
                captureCalled = true;
                return _createDetailBackdropImage(1280, 720);
              },
              debugOnTransitionModeResolved: (m) => resolvedMode = m,
              debugPlayerBuilder: (_, __, ___, ____, _____, ______) =>
                  const Scaffold(body: Text('win-fast-player')),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await tester.tap(find.text('立即播放'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));

        final winRoute =
            observer.pushed.whereType<PlayerEnterPageRoute<void>>().last;
        expect(captureCalled, isFalse);
        expect(resolvedMode, PlayerTransitionMode.scaleFadeFallback);
        expect(winRoute.transitionDuration, const Duration(milliseconds: 185));
        expect(find.text('win-fast-player'), findsOneWidget);

        // OHOS guard: DetailScreen bypasses pushPlayerRoute altogether.
        Navigator.of(tester.element(find.text('win-fast-player'))).pop();
        await tester.pumpAndSettle();
        observer.pushed.clear();
        OhosRuntime.debugIsOhosOverride = true;

        await tester.tap(find.text('立即播放'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(observer.pushed.whereType<PlayerEnterPageRoute<void>>(), isEmpty);
        expect(find.text('win-fast-player'), findsOneWidget);
      },
    );
  });
}

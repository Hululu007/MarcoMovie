import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/main.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/desktop_horizontal_scroller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'mouse drag changes offset on DesktopHorizontalScroller with AppScrollBehavior',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: Scaffold(
            body: SizedBox(
              height: 100,
              width: 400,
              child: DesktopHorizontalScroller(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: 30,
                  itemBuilder: (_, i) =>
                      SizedBox(width: 80, child: Text('Item $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.offset, 0.0);

      // Mouse drag from (300, 50) towards left (-100 px)
      final gesture = await tester.startGesture(const Offset(300, 50),
          kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(0.0));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'PointerScrollEvent with vertical delta scrolls horizontally when not at boundary',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: Scaffold(
            body: SizedBox(
              height: 100,
              width: 400,
              child: DesktopHorizontalScroller(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: 30,
                  itemBuilder: (_, i) =>
                      SizedBox(width: 80, child: Text('Item $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.offset, 0.0);

      // Send a vertical scroll event (wheel down)
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 50),
          scrollDelta: Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.offset, 120.0);

      // Send another vertical scroll event
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 50),
          scrollDelta: Offset(0, 80),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.offset, 200.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'vertical wheel passes through to outer vertical ListView when horizontal list is at boundary',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final outerController = ScrollController();
      final horizontalController = ScrollController();
      addTearDown(outerController.dispose);
      addTearDown(horizontalController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: Scaffold(
            body: SizedBox(
              height: 500,
              width: 400,
              child: ListView(
                controller: outerController,
                children: [
                  const SizedBox(height: 50, child: Text('Header')),
                  SizedBox(
                    height: 100,
                    child: DesktopHorizontalScroller(
                      controller: horizontalController,
                      child: ListView.builder(
                        controller: horizontalController,
                        scrollDirection: Axis.horizontal,
                        itemCount: 10,
                        itemBuilder: (_, i) =>
                            SizedBox(width: 80, child: Text('Item $i')),
                      ),
                    ),
                  ),
                  for (int i = 0; i < 20; i++)
                    SizedBox(height: 100, child: Text('Vertical Item $i')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(outerController.offset, 0.0);
      expect(horizontalController.offset, 0.0);

      // First jump horizontal list to its maximum right boundary
      horizontalController
          .jumpTo(horizontalController.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(horizontalController.offset,
          horizontalController.position.maxScrollExtent);

      // Send a downward wheel event over the horizontal list (position (200, 100))
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 100),
          scrollDelta: Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();

      // Since horizontal list is at max boundary, it did not intercept the vertical wheel,
      // so the outer vertical list received the scroll!
      expect(outerController.offset, greaterThan(0.0));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'vertical wheel upward at minScrollExtent passes through to outer vertical ListView',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final outerController = ScrollController();
      final horizontalController = ScrollController();
      addTearDown(outerController.dispose);
      addTearDown(horizontalController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: Scaffold(
            body: SizedBox(
              height: 500,
              width: 400,
              child: ListView(
                controller: outerController,
                children: [
                  for (int i = 0; i < 5; i++)
                    SizedBox(height: 100, child: Text('Top Item $i')),
                  SizedBox(
                    height: 100,
                    child: DesktopHorizontalScroller(
                      controller: horizontalController,
                      child: ListView.builder(
                        controller: horizontalController,
                        scrollDirection: Axis.horizontal,
                        itemCount: 10,
                        itemBuilder: (_, i) =>
                            SizedBox(width: 80, child: Text('Item $i')),
                      ),
                    ),
                  ),
                  for (int i = 0; i < 20; i++)
                    SizedBox(height: 100, child: Text('Bottom Item $i')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll outer list down a bit so it can scroll up
      outerController.jumpTo(200.0);
      await tester.pumpAndSettle();
      expect(outerController.offset, 200.0);
      expect(horizontalController.offset, 0.0); // at min boundary

      // Send upward scroll event (scrollDelta.dy = -100) over horizontal list
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 100),
          scrollDelta: Offset(0, -100),
        ),
      );
      await tester.pumpAndSettle();

      // Since horizontal list is at min boundary, vertical wheel passed to outer list
      expect(outerController.offset, lessThan(200.0));
      expect(horizontalController.offset, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('clicking hover arrow scrolls by step', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          home: Scaffold(
            body: SizedBox(
              height: 100,
              width: 400,
              child: DesktopHorizontalScroller(
                controller: controller,
                arrowStep: 160.0,
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: 30,
                  itemBuilder: (_, i) =>
                      SizedBox(width: 80, child: Text('Item $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially at offset 0, hover over scroller
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(const Offset(200, 50));
      await tester.pumpAndSettle();

      // Right arrow should be visible; left arrow not visible (at start boundary)
      final rightArrowFinder =
          find.byKey(const ValueKey('desktop_scroll_right_arrow'));
      final leftArrowFinder =
          find.byKey(const ValueKey('desktop_scroll_left_arrow'));
      expect(rightArrowFinder, findsOneWidget);
      expect(leftArrowFinder, findsNothing);

      // Click right arrow
      await tester.tap(rightArrowFinder);
      await tester.pumpAndSettle();

      expect(controller.offset, 160.0);

      // Move mouse slightly to refresh hover state metrics
      await gesture.moveTo(const Offset(201, 50));
      await tester.pumpAndSettle();

      // Now left arrow should also be visible
      expect(find.byKey(const ValueKey('desktop_scroll_left_arrow')),
          findsOneWidget);

      // Click left arrow
      await tester.tap(find.byKey(const ValueKey('desktop_scroll_left_arrow')));
      await tester.pumpAndSettle();

      expect(controller.offset, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'responsive layout uses sidebar at 960x1030 (vertical split) and 1280x720 on desktop',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.saveConfig(
        '{"sites":[{"key":"demo","name":"演示源","type":1,"api":"https://source.example/api"}]}',
      );
      final client = CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

      // Set size to 960 x 1030 (half-screen snap on Windows, width < height but width >= 700)
      tester.view.physicalSize = const Size(960, 1030);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: client),
        ),
      );
      await tester.pumpAndSettle();

      // With responsive logic: width >= 700 on desktop uses sidebar layout (AppleLiquidGlassDock with isLandscape == true)
      final desktopSidebarDock = find.byWidgetPredicate(
        (w) => w is AppleLiquidGlassDock && w.isLandscape == true,
      );
      final mobileBottomDock = find.byWidgetPredicate(
        (w) => w is AppleLiquidGlassDock && w.isLandscape == false,
      );

      expect(desktopSidebarDock, findsOneWidget,
          reason: '960x1030 split should render sidebar dock');
      expect(mobileBottomDock, findsNothing,
          reason: '960x1030 split should not render bottom dock');

      // Resize to 1280 x 720 (standard landscape desktop)
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpAndSettle();

      expect(
          find.byWidgetPredicate(
              (w) => w is AppleLiquidGlassDock && w.isLandscape == true),
          findsOneWidget);
      expect(
          find.byWidgetPredicate(
              (w) => w is AppleLiquidGlassDock && w.isLandscape == false),
          findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'non-desktop platform returns child directly with no hover arrows or listener',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 100,
              width: 400,
              child: DesktopHorizontalScroller(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  itemCount: 30,
                  itemBuilder: (_, i) =>
                      SizedBox(width: 80, child: Text('Item $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // On iOS / non-desktop, DesktopHorizontalScroller directly returns child without wrapping
      expect(
          find.descendant(
              of: find.byType(DesktopHorizontalScroller),
              matching: find.byType(MouseRegion)),
          findsNothing);
      expect(find.byKey(const ValueKey('desktop_scroll_right_arrow')),
          findsNothing);
      expect(find.byKey(const ValueKey('desktop_scroll_left_arrow')),
          findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

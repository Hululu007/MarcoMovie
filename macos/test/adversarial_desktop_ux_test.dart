import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/main.dart';
import 'package:marco_movie/ui/desktop_horizontal_scroller.dart';

void main() {
  group('Adversarial Verification Suite - Desktop UX (Feature B1 & B2)', () {
    // -------------------------------------------------------------
    // Objective 1: Pointer signal resolver behavior
    // -------------------------------------------------------------
    testWidgets(
        '1.1: Vertical wheel (Offset(0, 100)) translates to horizontal scroll in both directions',
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
                height: 120,
                width: 400,
                child: DesktopHorizontalScroller(
                  controller: controller,
                  child: ListView.builder(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, i) =>
                        SizedBox(width: 100, child: Text('Item $i')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.offset, 0.0);

        // Downward wheel event (Offset(0, 100))
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 60),
            scrollDelta: Offset(0, 100),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, 100.0);

        // Additional downward wheel event (Offset(0, 50))
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 60),
            scrollDelta: Offset(0, 50),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, 150.0);

        // Upward wheel event (Offset(0, -60))
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 60),
            scrollDelta: Offset(0, -60),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, 90.0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        '1.2: Downward wheel at maxScrollExtent bypasses registration and passes through to ancestor vertical scrollable',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final verticalController = ScrollController();
        final horizontalController = ScrollController();
        addTearDown(verticalController.dispose);
        addTearDown(horizontalController.dispose);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Scaffold(
              body: SizedBox(
                height: 600,
                width: 400,
                child: ListView(
                  controller: verticalController,
                  children: [
                    Container(height: 50, color: Colors.blue),
                    SizedBox(
                      height: 120,
                      child: DesktopHorizontalScroller(
                        controller: horizontalController,
                        child: ListView.builder(
                          controller: horizontalController,
                          scrollDirection: Axis.horizontal,
                          itemCount: 10,
                          itemBuilder: (_, i) =>
                              SizedBox(width: 80, child: Text('H-Item $i')),
                        ),
                      ),
                    ),
                    for (int i = 0; i < 25; i++)
                      SizedBox(height: 80, child: Text('V-Item $i')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(verticalController.offset, 0.0);
        expect(horizontalController.offset, 0.0);

        // Jump horizontal list directly to maximum extent
        horizontalController
            .jumpTo(horizontalController.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final maxH = horizontalController.position.maxScrollExtent;
        expect(horizontalController.offset, maxH);

        // Downward wheel event over the horizontal scroller (y: 100)
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 100),
            scrollDelta: Offset(0, 120),
          ),
        );
        await tester.pumpAndSettle();

        // Horizontal list remains at maxExtent
        expect(horizontalController.offset, maxH);
        // Ancestor vertical list receives the scroll
        expect(verticalController.offset, greaterThan(0.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        '1.3: Upward wheel at offset 0 bypasses registration and passes through to ancestor vertical scrollable',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final verticalController = ScrollController();
        final horizontalController = ScrollController();
        addTearDown(verticalController.dispose);
        addTearDown(horizontalController.dispose);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Scaffold(
              body: SizedBox(
                height: 600,
                width: 400,
                child: ListView(
                  controller: verticalController,
                  children: [
                    for (int i = 0; i < 10; i++)
                      SizedBox(height: 80, child: Text('V-Top-Item $i')),
                    SizedBox(
                      height: 120,
                      child: DesktopHorizontalScroller(
                        controller: horizontalController,
                        child: ListView.builder(
                          controller: horizontalController,
                          scrollDirection: Axis.horizontal,
                          itemCount: 10,
                          itemBuilder: (_, i) =>
                              SizedBox(width: 80, child: Text('H-Item $i')),
                        ),
                      ),
                    ),
                    for (int i = 0; i < 20; i++)
                      SizedBox(height: 80, child: Text('V-Bottom-Item $i')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Pre-scroll vertical list down
        verticalController.jumpTo(300.0);
        await tester.pumpAndSettle();
        expect(verticalController.offset, 300.0);
        expect(horizontalController.offset, 0.0);

        // Upward wheel event over the horizontal scroller
        final scrollerCenter = tester.getCenter(find.byType(DesktopHorizontalScroller));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: scrollerCenter,
            scrollDelta: const Offset(0, -100),
          ),
        );
        await tester.pumpAndSettle();

        // Horizontal list remains at 0.0
        expect(horizontalController.offset, 0.0);
        // Vertical list scrolled up
        expect(verticalController.offset, lessThan(300.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        '1.4: Non-scrollable horizontal content (maxScrollExtent == 0) passes all wheel events to ancestor',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final verticalController = ScrollController();
        final horizontalController = ScrollController();
        addTearDown(verticalController.dispose);
        addTearDown(horizontalController.dispose);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Scaffold(
              body: SizedBox(
                height: 600,
                width: 500,
                child: ListView(
                  controller: verticalController,
                  children: [
                    SizedBox(
                      height: 80,
                      child: DesktopHorizontalScroller(
                        controller: horizontalController,
                        child: ListView(
                          controller: horizontalController,
                          scrollDirection: Axis.horizontal,
                          children: const [
                            SizedBox(width: 100, child: Text('Short')),
                          ],
                        ),
                      ),
                    ),
                    for (int i = 0; i < 20; i++)
                      SizedBox(height: 80, child: Text('Item $i')),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(horizontalController.position.maxScrollExtent, 0.0);

        // Send downward scroll over short horizontal list
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(100, 40),
            scrollDelta: Offset(0, 100),
          ),
        );
        await tester.pumpAndSettle();

        // Vertical controller should receive scroll because horizontal list cannot scroll
        expect(verticalController.offset, greaterThan(0.0));
        expect(horizontalController.offset, 0.0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        '1.5: Delta larger than remaining distance clamps to maxExtent cleanly',
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
                    itemCount: 10,
                    itemBuilder: (_, i) =>
                        SizedBox(width: 80, child: Text('Item $i')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final maxExtent = controller.position.maxScrollExtent; // 800 - 400 = 400
        controller.jumpTo(350.0);
        await tester.pumpAndSettle();

        // Delta is 100, but only 50 left
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 50),
            scrollDelta: Offset(0, 100),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.offset, maxExtent);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // -------------------------------------------------------------
    // Objective 2: Hover navigation buttons
    // -------------------------------------------------------------
    testWidgets('2.1: Navigation buttons hidden on non-hover and when showArrows is false',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
                  showArrows: false,
                  child: ListView.builder(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, i) =>
                        SizedBox(width: 80, child: Text('Item $i')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Initial non-hover state
        expect(find.byKey(const ValueKey('desktop_scroll_left_arrow')), findsNothing);
        expect(find.byKey(const ValueKey('desktop_scroll_right_arrow')), findsNothing);

        // 2. Hover with showArrows: false
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(const Offset(200, 50));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('desktop_scroll_left_arrow')), findsNothing);
        expect(find.byKey(const ValueKey('desktop_scroll_right_arrow')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('2.2: Button visibility at offset 0, intermediate offset, and max extent',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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
                  showArrows: true,
                  child: ListView.builder(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, i) =>
                        SizedBox(width: 80, child: Text('Item $i')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(const Offset(200, 50));
        await tester.pumpAndSettle();

        final leftArrow = find.byKey(const ValueKey('desktop_scroll_left_arrow'));
        final rightArrow = find.byKey(const ValueKey('desktop_scroll_right_arrow'));

        // At offset 0: left hidden, right shown
        expect(leftArrow, findsNothing);
        expect(rightArrow, findsOneWidget);

        // Scroll to intermediate offset (e.g. 200)
        controller.jumpTo(200.0);
        await mouse.moveTo(const Offset(201, 50)); // trigger hover metrics update
        await tester.pumpAndSettle();

        // Both arrows shown
        expect(leftArrow, findsOneWidget);
        expect(rightArrow, findsOneWidget);

        // Jump to maxScrollExtent
        controller.jumpTo(controller.position.maxScrollExtent);
        await mouse.moveTo(const Offset(202, 50));
        await tester.pumpAndSettle();

        // At maxExtent: left shown, right hidden
        expect(leftArrow, findsOneWidget);
        expect(rightArrow, findsNothing);

        // Move mouse outside (exit hover)
        await mouse.moveTo(const Offset(500, 500));
        await tester.pumpAndSettle();

        // Neither arrow shown on exit
        expect(leftArrow, findsNothing);
        expect(rightArrow, findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('2.3: Button click animates by 80% viewport dimension when arrowStep is null',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final controller = ScrollController();
        addTearDown(controller.dispose);

        // Viewport width is 500 => 80% is 400.0
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 100,
                width: 500,
                child: DesktopHorizontalScroller(
                  controller: controller,
                  arrowStep: null, // default 80%
                  child: ListView.builder(
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 30,
                    itemBuilder: (_, i) =>
                        SizedBox(width: 100, child: Text('Item $i')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(const Offset(250, 50));
        await tester.pumpAndSettle();

        final rightArrow = find.byKey(const ValueKey('desktop_scroll_right_arrow'));
        expect(rightArrow, findsOneWidget);

        // Click right arrow
        await tester.tap(rightArrow);
        await tester.pump(); // Register animation ticker
        // Step halfway through animation
        await tester.pump(const Duration(milliseconds: 125));
        expect(controller.offset, greaterThan(0.0));
        expect(controller.offset, lessThan(400.0));

        // Complete animation
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(400.0, 0.001));

        // Now hover to refresh and click left arrow
        await mouse.moveTo(const Offset(251, 50));
        await tester.pumpAndSettle();

        final leftArrow = find.byKey(const ValueKey('desktop_scroll_left_arrow'));
        expect(leftArrow, findsOneWidget);

        await tester.tap(leftArrow);
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(0.0, 0.001));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // -------------------------------------------------------------
    // Objective 3: Mouse drag scrolling & ReorderableListView safety
    // -------------------------------------------------------------
    testWidgets('3.1: Mouse drag scrolling works on horizontal and vertical lists with AppScrollBehavior',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final hController = ScrollController();
        final vController = ScrollController();
        addTearDown(hController.dispose);
        addTearDown(vController.dispose);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    height: 100,
                    width: 400,
                    child: ListView.builder(
                      controller: hController,
                      scrollDirection: Axis.horizontal,
                      itemCount: 30,
                      itemBuilder: (_, i) =>
                          SizedBox(width: 80, child: Text('H-Item $i')),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: vController,
                      itemCount: 50,
                      itemBuilder: (_, i) =>
                          SizedBox(height: 50, child: Text('V-Item $i')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Mouse drag horizontal list
        final hGesture = await tester.startGesture(const Offset(300, 50),
            kind: PointerDeviceKind.mouse);
        await hGesture.moveBy(const Offset(-120, 0));
        await tester.pump();
        await hGesture.up();
        await tester.pumpAndSettle();

        expect(hController.offset, greaterThan(0.0));

        // 2. Mouse drag vertical list
        final vGesture = await tester.startGesture(const Offset(200, 300),
            kind: PointerDeviceKind.mouse);
        await vGesture.moveBy(const Offset(0, -150));
        await tester.pump();
        await vGesture.up();
        await tester.pumpAndSettle();

        expect(vController.offset, greaterThan(0.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        '3.2: ReorderableListView with dragDevices {touch, trackpad} ignores mouse drag on body and handles drag handle reordering cleanly',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final list = ['Site A', 'Site B', 'Site C', 'Site D', 'Site E'];
        final controller = ScrollController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const AppScrollBehavior(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: const {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.trackpad,
                      },
                    ),
                    child: SizedBox(
                      height: 400,
                      child: ReorderableListView.builder(
                        scrollController: controller,
                        buildDefaultDragHandles: false,
                        itemCount: list.length,
                        // ignore: deprecated_member_use
                        onReorder: (oldIdx, newIdx) {
                          setState(() {
                            if (newIdx > oldIdx) newIdx--;
                            final item = list.removeAt(oldIdx);
                            list.insert(newIdx, item);
                          });
                        },
                        itemBuilder: (ctx, idx) => ListTile(
                          key: ValueKey(list[idx]),
                          title: Text(list[idx]),
                          leading: ReorderableDragStartListener(
                            index: idx,
                            child: const Icon(Icons.drag_handle,
                                key: ValueKey('handle')),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Mouse drag across the list body should NOT scroll the list because mouse is excluded from dragDevices
        final bodyGesture = await tester.startGesture(const Offset(200, 200),
            kind: PointerDeviceKind.mouse);
        await bodyGesture.moveBy(const Offset(0, -80));
        await tester.pump();
        await bodyGesture.up();
        await tester.pumpAndSettle();

        expect(controller.offset, 0.0);

        // 2. Dragging the ReorderableDragStartListener handle with mouse DOES reorder
        final firstHandle = find.byKey(const ValueKey('handle')).first;
        final handleCenter = tester.getCenter(firstHandle);

        final dragGesture = await tester.startGesture(handleCenter,
            kind: PointerDeviceKind.mouse);
        await tester.pump();
        // Drag item 0 downwards by 120 pixels (past item 1)
        await dragGesture.moveBy(const Offset(0, 120));
        await tester.pumpAndSettle();
        await dragGesture.up();
        await tester.pumpAndSettle();

        // Item 0 should have been reordered
        expect(list[0], isNot('Site A'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        '3.3: Dynamic controller replacement updates metrics and attaches listener without error',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final ctrl1 = ScrollController();
        final ctrl2 = ScrollController();
        addTearDown(ctrl1.dispose);
        addTearDown(ctrl2.dispose);

        Widget buildApp(ScrollController ctrl) {
          return MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 100,
                width: 400,
                child: DesktopHorizontalScroller(
                  controller: ctrl,
                  child: ListView.builder(
                    controller: ctrl,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, i) =>
                        SizedBox(width: 80, child: Text('Item $i')),
                  ),
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(buildApp(ctrl1));
        await tester.pumpAndSettle();

        // Pump with ctrl2
        await tester.pumpWidget(buildApp(ctrl2));
        await tester.pumpAndSettle();

        // Wheel event should update ctrl2
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 50),
            scrollDelta: Offset(0, 100),
          ),
        );
        await tester.pumpAndSettle();

        expect(ctrl2.hasClients, isTrue);
        expect(ctrl2.offset, 100.0);
        expect(ctrl1.hasClients, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

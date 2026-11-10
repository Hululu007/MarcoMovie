import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/player_interaction_layers.dart';

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
        '$kind rapid seek taps never pause or toggle desktop fullscreen',
        (tester) async {
      var seeks = 0, pauses = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: PlayerInteractionLayers(
        surface: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => pauses++,
          child: const SizedBox.expand(),
        ),
        controls: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
          CupertinoButton(
              key: const Key('rewind'),
              onPressed: () => seeks -= 15,
              child: const Icon(Icons.replay_10)),
          CupertinoButton(
              key: const Key('forward'),
              onPressed: () => seeks += 15,
              child: const Icon(Icons.forward_10)),
        ])),
      ))));
      for (final key in ['forward', 'rewind']) {
        final before = seeks;
        await tester.tap(find.byKey(Key(key)), kind: kind);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.byKey(Key(key)), kind: kind);
        await tester.pump(const Duration(milliseconds: 400));
        expect(seeks - before, key == 'forward' ? 30 : -30);
        expect(pauses, 0);
      }
      await tester.tapAt(const Offset(20, 20), kind: kind);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(20, 20), kind: kind);
      await tester.pump(const Duration(milliseconds: 400));
      expect(pauses, 1,
          reason: 'Video background double tap remains available.');
    });
  }
}

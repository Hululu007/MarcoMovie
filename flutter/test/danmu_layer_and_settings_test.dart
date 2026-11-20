import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/danmu/danmu_layer.dart';
import 'package:marco_movie/ui/danmu/danmu_settings_sheet.dart';

void main() {
  tearDown(() {
    OhosRuntime.resetForTesting();
  });

  group('Collision-Free Linear Kinematics Layout Engine', () {
    test('fast long danmu never overtakes slow short danmu on the same lane', () {
      final engine = DanmuLayoutEngine();
      final laneSlow = engine.allocateScrollLane(
        startMs: 0,
        viewWidth: 1920,
        textWidth: 80,
        durationMs: 7600,
        maxRows: 6,
      );
      final laneFast = engine.allocateScrollLane(
        startMs: 500,
        viewWidth: 1920,
        textWidth: 700,
        durationMs: 7600,
        maxRows: 6,
      );
      expect(laneSlow, 0);
      expect(laneFast, 1);
    });

    test('80-item mixed-width burst maintains >= 24px gap at every timestamp', () {
      final engine = DanmuLayoutEngine();
      final burst = List<DanmuItem>.generate(
        80,
        (i) => DanmuItem(
          id: 'b_$i',
          timeMs: i * 180,
          mode: 1,
          rgbColor: 0xFFFFFF,
          text: '弹' * (2 + (i % 18)),
        ),
      );
      var peakActive = 0;
      for (var t = 0; t <= 16000; t += 100) {
        engine.step(
          effectiveMs: t,
          candidates: burst,
          viewWidth: 1920,
          viewHeight: 1080,
          fontSize: 24,
          topInset: 0,
          bottomSafeInset: 44,
          area: 0.50,
          rowCap: 6,
          maxOnScreenItems: 120,
          scrollDurationMs: 7600,
          showScroll: true,
          showTop: true,
          showBottom: true,
          measureWidth: (item) => item.text.length * 28.0,
        );
        final active = engine.activeEntries;
        if (active.length > peakActive) peakActive = active.length;
        for (var i = 0; i < active.length; i++) {
          final a = active[i];
          if (a.item.mode != 1) continue;
          for (var j = i + 1; j < active.length; j++) {
            final b = active[j];
            if (b.item.mode != 1 || a.lane != b.lane) continue;
            final left = a.x <= b.x ? a : b;
            final right = a.x <= b.x ? b : a;
            final gap = right.x - (left.x + left.width);
            expect(
              gap,
              greaterThanOrEqualTo(23.5),
              reason: 'Collision on lane ${a.lane} at t=$t: gap=${gap}px',
            );
          }
        }
      }
      expect(peakActive, greaterThan(0));
    });

    test('pinned top/bottom tracks respect 4000ms exclusivity & bottomSafeInset',
        () {
      final engine = DanmuLayoutEngine();
      const pinned = <DanmuItem>[
        DanmuItem(id: 't1', timeMs: 1000, mode: 5, rgbColor: 0xFFFFFF, text: '顶1'),
        DanmuItem(id: 't2', timeMs: 2000, mode: 5, rgbColor: 0xFFFFFF, text: '顶2'),
        DanmuItem(id: 'bot1', timeMs: 1000, mode: 4, rgbColor: 0xFFFFFF, text: '底1'),
      ];
      engine.step(
        effectiveMs: 2500,
        candidates: pinned,
        viewWidth: 1920,
        viewHeight: 1080,
        fontSize: 24,
        topInset: 0,
        bottomSafeInset: 80,
        area: 0.50,
        rowCap: 6,
        maxOnScreenItems: 120,
        scrollDurationMs: 7600,
        showScroll: true,
        showTop: true,
        showBottom: true,
        measureWidth: (_) => 100,
      );
      final byId = {for (final e in engine.activeEntries) e.item.id: e};
      expect(byId['t1']?.lane, 0);
      expect(byId['t2']?.lane, 1);
      expect(byId['bot1']!.y, lessThanOrEqualTo(1080 - 80));
    });
  });

  group('Bounded TextPainter Pool & 4K 300-Item Performance Benchmark', () {
    test('pool bounds size, evicts LRU and reuses TextPainters', () {
      final pool = DanmuTextPainterPool(maxEntries: 8);
      addTearDown(pool.dispose);
      for (var i = 0; i < 12; i++) {
        pool.acquire(
          text: 'item-$i',
          rgbColor: 0xFFFFFF,
          fontSize: 20,
          opacity: 0.85,
        );
      }
      expect(pool.length, 8);
      expect(pool.evictionCount, 4);
      final prevHits = pool.hitCount;
      pool.acquire(
        text: 'item-11',
        rgbColor: 0xFFFFFF,
        fontSize: 20,
        opacity: 0.85,
      );
      expect(pool.hitCount, prevHits + 1);
    });

    test('4K (3840x2160) 300-item steady-state paint frame completes < 8ms', () {
      final pool = DanmuTextPainterPool(maxEntries: 384);
      addTearDown(pool.dispose);
      final engine = DanmuLayoutEngine();

      // 300 distinct items distributed across 14 rows at 4K (3840px wide):
      // ~100px width + 24px clearance -> >= 28 non-overlapping items per row,
      // so all 300 items are simultaneously active with zero collisions.
      final items = List<DanmuItem>.generate(
        300,
        (i) => DanmuItem(
          id: 'p_$i',
          timeMs: (i ~/ 14) * 320,
          mode: 1,
          rgbColor: i.isEven ? 0xFFFFFF : 0x64D2FF,
          text: '弹#$i',
        ),
      );
      const settings = DanmuSettings(
        enabled: true,
        opacity: 0.85,
        displayArea: 1.00,
        fontSize: 18.0,
        maxRows: 14,
      );

      var currentPos = 7200;
      final painter = DanmuLayerPainter(
        layoutEngine: engine,
        painterPool: pool,
        settings: settings,
        effectiveFontSize: 18.0,
        bottomSafeInset: 44.0,
        topInset: 8.0,
        maxOnScreenItems: 300,
        resolveRawPositionMs: () => currentPos,
        resolveCandidates: (_) => items,
      );

      // Warm-up frame populates TextPainter pool
      {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        painter.paint(canvas, const Size(3840, 2160));
        rec.endRecording().dispose();
      }
      expect(engine.activeCount, 300);

      // Measure 20 steady-state frames at 60fps progression
      final missesBefore = pool.missCount;
      final sw = Stopwatch()..start();
      const frames = 20;
      for (var f = 0; f < frames; f++) {
        currentPos += 16;
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        painter.paint(canvas, const Size(3840, 2160));
        rec.endRecording().dispose();
      }
      sw.stop();
      final avgFrameMs = sw.elapsedMicroseconds / 1000.0 / frames;
      expect(
        pool.missCount,
        missesBefore,
        reason: 'Steady-state frames should reuse pool with 0 new layouts',
      );
      expect(
        avgFrameMs,
        lessThan(8.0),
        reason:
            '4K 300-item steady-state paint took ${avgFrameMs.toStringAsFixed(2)}ms/frame (>= 8ms budget)',
      );
    });
  });

  group('DanmuLayer & DanmuSettingsSheet Widget Guards', () {
    testWidgets('DanmuLayer paints when enabled and hides under OhosRuntime.isOhos',
        (tester) async {
      const items = <DanmuItem>[
        DanmuItem(id: 'w1', timeMs: 1000, mode: 1, rgbColor: 0xFFFFFF, text: '你好弹幕'),
      ];
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: DanmuLayer(
                settings: DanmuSettings(enabled: true),
                positionMs: 1500,
                playing: false,
                items: items,
              ),
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(DanmuLayer),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      OhosRuntime.debugIsOhosOverride = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: DanmuLayer(
                settings: DanmuSettings(enabled: true),
                positionMs: 1500,
                playing: false,
                items: items,
              ),
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(DanmuLayer),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'DanmuSettingsSheet blocks ReDoS pattern re:(a|aa)+\$ and saves safe rules',
        (tester) async {
      DanmuSettings latest = const DanmuSettings();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmuSettingsSheet(
              initialSettings: latest,
              persistAutomatically: false,
              onChanged: (s) => latest = s,
            ),
          ),
        ),
      );

      final ruleField = find.widgetWithText(TextField, '输入关键词或 re:剧透|打卡');
      final addBtn = find.widgetWithText(FilledButton, '添加');
      expect(ruleField, findsOneWidget);

      await tester.ensureVisible(ruleField);
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();

      // Attempt to add catastrophic ReDoS pattern -> must be rejected with error
      await tester.enterText(ruleField, r're:(a|aa)+$');
      await tester.tap(addBtn);
      await tester.pump();
      expect(latest.blockRules, isEmpty);
      expect(find.textContaining('禁止闭合括号后紧跟量词'), findsOneWidget);

      // Add safe regex -> accepted
      await tester.enterText(ruleField, 're:剧透|打卡');
      await tester.tap(addBtn);
      await tester.pump();
      expect(latest.blockRules, <String>['re:剧透|打卡']);

      // Under OhosRuntime.isOhos == true -> sheet collapses to SizedBox.shrink
      OhosRuntime.debugIsOhosOverride = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmuSettingsSheet(
              initialSettings: latest,
              persistAutomatically: false,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('弹幕设置'), findsNothing);
    });
  });
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/danmu/block_filter.dart';
import 'package:marco_movie/core/danmu/dandanplay_provider.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/danmu/segment_cache.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/danmu/danmu_layer.dart';
import 'package:marco_movie/ui/danmu/danmu_settings_sheet.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';

void main() {
  tearDown(() {
    OhosRuntime.resetForTesting();
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 0.68;
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

    test('DanmuClockInterpolator re-anchors monotonically on 2.0x -> 1.0x release without wiping active danmu',
        () {
      final clock = DanmuClockInterpolator(initialPosMs: 10000, playSpeed: 2.0);
      clock.onTickerStarted(10000);
      clock.onTick(const Duration(milliseconds: 180));
      final t180 = clock.currentPositionMs(playing: true);
      expect(t180, 10360);

      final engine = DanmuLayoutEngine();
      const items = <DanmuItem>[
        DanmuItem(id: 's1', timeMs: 9000, mode: 1, rgbColor: 0xFFFFFF, text: '普通'),
        DanmuItem(id: 's2', timeMs: 9100, mode: 1, rgbColor: 0xFFFFFF, text: '剧透警告'),
        DanmuItem(id: 'top1', timeMs: 9200, mode: 5, rgbColor: 0xFFFFFF, text: '顶部'),
      ];
      engine.step(
        effectiveMs: t180,
        candidates: items,
        viewWidth: 1920,
        viewHeight: 1080,
        fontSize: 20,
        topInset: 0,
        bottomSafeInset: 44,
        area: 0.50,
        rowCap: 6,
        maxOnScreenItems: 120,
        scrollDurationMs: 7600,
        showScroll: true,
        showTop: true,
        showBottom: true,
        measureWidth: (_) => 160,
      );
      expect(engine.activeCount, 3);
      final s1LaneBefore =
          engine.activeEntries.firstWhere((e) => e.item.id == 's1').lane;

      // Release 2.0x boost back to 1.0x mid-tick -> must NOT regress clock or reset engine
      clock.setPlaySpeed(1.0, playing: true);
      clock.onTick(const Duration(milliseconds: 196));
      final t196 = clock.currentPositionMs(playing: true);
      expect(t196, 10376);
      expect(t196, greaterThanOrEqualTo(t180));

      // Even if player clock tick arrives slightly behind estimate (10350), stays monotonic
      clock.onTick(const Duration(milliseconds: 200));
      clock.onExternalPosition(10350, playing: true);
      expect(clock.currentPositionMs(playing: true), greaterThanOrEqualTo(t196));

      engine.step(
        effectiveMs: t196,
        candidates: const <DanmuItem>[],
        viewWidth: 1920,
        viewHeight: 1080,
        fontSize: 20,
        topInset: 0,
        bottomSafeInset: 44,
        area: 0.50,
        rowCap: 6,
        maxOnScreenItems: 120,
        scrollDurationMs: 7600,
        showScroll: true,
        showTop: true,
        showBottom: true,
        measureWidth: (_) => 160,
      );
      expect(engine.activeCount, 3);
      expect(
        engine.activeEntries.firstWhere((e) => e.item.id == 's1').lane,
        s1LaneBefore,
      );

      // Disabling showTop immediately removes active top danmu while preserving scroll danmu
      engine.step(
        effectiveMs: t196 + 16,
        candidates: const <DanmuItem>[],
        viewWidth: 1920,
        viewHeight: 1080,
        fontSize: 20,
        topInset: 0,
        bottomSafeInset: 44,
        area: 0.50,
        rowCap: 6,
        maxOnScreenItems: 120,
        scrollDurationMs: 7600,
        showScroll: true,
        showTop: false,
        showBottom: true,
        measureWidth: (_) => 160,
      );
      expect(engine.activeCount, 2);

      // purgeBlocked removes newly blocked active danmu while keeping safe active danmu
      engine.purgeBlocked(DanmuBlockFilter.compile(const <String>['剧透']));
      expect(engine.activeCount, 1);
      expect(engine.activeEntries.single.item.id, 's1');
    });

    test('DanmuLayoutEngine preserves in-flight lanes across rowCap 6 -> 4 -> 5 changes',
        () {
      final engine = DanmuLayoutEngine();
      final wave1 = List<DanmuItem>.generate(
        6,
        (i) => DanmuItem(
          id: 'lane_$i',
          timeMs: 1000,
          mode: 1,
          rgbColor: 0xFFFFFF,
          text: '弹幕$i',
        ),
      );
      engine.step(
        effectiveMs: 1200,
        candidates: wave1,
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
        measureWidth: (_) => 200,
      );
      final lane4Before =
          engine.activeEntries.firstWhere((e) => e.item.id == 'lane_4');
      expect(lane4Before.lane, 4);
      final x4Before = lane4Before.x;

      final wave2 = <DanmuItem>[
        ...wave1,
        const DanmuItem(
          id: 'new_after_drop',
          timeMs: 2600,
          mode: 1,
          rgbColor: 0xFFFFFF,
          text: '新弹幕',
        ),
      ];
      engine.step(
        effectiveMs: 2700,
        candidates: wave2,
        viewWidth: 1920,
        viewHeight: 1080,
        fontSize: 24,
        topInset: 0,
        bottomSafeInset: 44,
        area: 0.50,
        rowCap: 4,
        maxOnScreenItems: 120,
        scrollDurationMs: 7600,
        showScroll: true,
        showTop: true,
        showBottom: true,
        measureWidth: (_) => 200,
      );
      final lane4After =
          engine.activeEntries.firstWhere((e) => e.item.id == 'lane_4');
      final newEntry =
          engine.activeEntries.firstWhere((e) => e.item.id == 'new_after_drop');
      expect(lane4After.lane, 4);
      expect(lane4After.x, lessThan(x4Before));
      expect(newEntry.lane, inInclusiveRange(0, 3));
    });

    testWidgets(
        'DanmuLayer syncs initial/swapped segmentCache offset & filter, fetches while paused, and uses listEquals for blockRules',
        (tester) async {
      final fetchedWindows = <int>[];
      final mockClient = MockClient((req) async {
        if (req.url.path == '/api/v2/comment/ep1') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'segments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'startMs': 0,
                  'endMs': 30000,
                  'segmentUrl': '/seg/0',
                },
                <String, dynamic>{
                  'startMs': 30000,
                  'endMs': 60000,
                  'segmentUrl': '/seg/1',
                },
              ],
            }),
            200,
          );
        }
        if (req.url.path.startsWith('/seg/')) {
          final w = int.parse(req.url.path.substring('/seg/'.length));
          fetchedWindows.add(w);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{
                  'cid': 'w${w}_safe',
                  'p': '${w * 30 + 18}.0,1,16777215',
                  'm': '正常内容$w',
                },
                <String, dynamic>{
                  'cid': 'w${w}_spoiler',
                  'p': '${w * 30 + 19}.0,1,16777215',
                  'm': '剧透内容$w',
                },
              ],
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('not found', 404);
      });

      final provider = DandanplayProvider(
        multilineServerUrls: 'https://node-a.danmu.test',
        minRequestIntervalMs: 0,
        client: mockClient,
      );
      final cache = DanmuSegmentCache(provider: provider);
      addTearDown(cache.dispose);
      final boundId = DandanplayProvider.encodeBoundEpisodeId(
        'https://node-a.danmu.test',
        'ep1',
      );
      await cache.bindSession(boundId);

      // Mount paused DanmuLayer with initial +15000ms offset and saved block rule '剧透'
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: DanmuLayer(
                settings: const DanmuSettings(
                  enabled: true,
                  timeOffsetMs: 15000,
                  blockRules: <String>['剧透'],
                ),
                positionMs: 5000,
                playing: false,
                segmentCache: cache,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => cache.waitUntilIdle());

      expect(cache.timeOffsetMs, 15000);
      expect(cache.isWindowCached(0), isTrue);
      // Effective time = 5000 + 15000 = 20000ms; '剧透内容0' must be filtered by synced blockFilter
      final snap0 = cache.snapshotForPosition(5000);
      expect(snap0.map((e) => e.text).toList(), <String>['正常内容0']);

      // While still paused, shift timeOffsetMs to +30000ms (effectiveMs = 35000 -> window 1)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: DanmuLayer(
                settings: const DanmuSettings(
                  enabled: true,
                  timeOffsetMs: 30000,
                  blockRules: <String>['剧透', '正常内容1'],
                ),
                positionMs: 5000,
                playing: false,
                segmentCache: cache,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => cache.waitUntilIdle());

      expect(cache.timeOffsetMs, 30000);
      expect(fetchedWindows, contains(1));
      expect(cache.isWindowCached(1), isTrue);
      // Both items in window 1 are now blocked via updated blockRules
      expect(cache.snapshotForPosition(20000), isEmpty);
    });

    testWidgets(
        'DanmuSettingsSheet uses IosNativeSwitch, opaque reduceTransparency surface, and throttles slider save to onChangeEnd',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      GlassworkBackdrop.reduceTransparency.value = true;
      DanmuSettings latest = const DanmuSettings(opacity: 0.85);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmuSettingsSheet(
              initialSettings: latest,
              persistAutomatically: true,
              onChanged: (s) => latest = s,
            ),
          ),
        ),
      );

      expect(find.byType(IosNativeSwitch), findsOneWidget);
      final colored = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(DanmuSettingsSheet),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(colored.color, DanmuSettingsSheet.reducedTransparencySurface);

      // Simulate slider drag: onChanged previews live without saving until onChangeEnd
      final opacitySlider = tester.widget<Slider>(find.byType(Slider).first);
      opacitySlider.onChanged!(0.50);
      await tester.pump();
      expect(latest.opacity, 0.50);
      final spBeforeEnd = await SharedPreferences.getInstance();
      expect(spBeforeEnd.getDouble(DanmuPrefs.keyOpacity), isNull);

      opacitySlider.onChangeEnd!(0.50);
      await tester.pump();
      final spAfterEnd = await SharedPreferences.getInstance();
      expect(spAfterEnd.getDouble(DanmuPrefs.keyOpacity), 0.50);
    });
  });
}

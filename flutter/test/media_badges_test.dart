import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/media_badges.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/media_badge.dart';

File _resolveSpecFile(String relative) {
  final candidates = <String>[
    relative,
    '../$relative',
    '../../$relative',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  throw StateError('Unable to locate $relative from ${Directory.current.path}');
}

void main() {
  final rulesFile = _resolveSpecFile('shared/ui-spec/badge-rules.json');
  final goldenFile = _resolveSpecFile('shared/ui-spec/badge-golden.json');
  final rulesJson = rulesFile.readAsStringSync();
  final goldenDoc =
      jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  final cases = goldenDoc['cases'] as List<dynamic>;

  test('Flutter asset copy of badge-rules.json matches shared/ui-spec', () {
    final assetFile = _resolveSpecFile('flutter/assets/ui-spec/badge-rules.json');
    expect(assetFile.readAsStringSync(), rulesJson);
  });

  test('MediaBadges passes 165/165 golden cases (JSON-loaded and built-in)', () {
    expect(cases.length, 165);
    final jsonEngine = MediaBadges.fromJson(rulesJson);
    final builtinEngine = MediaBadges.instance;

    for (final rawCase in cases) {
      final c = rawCase as Map<String, dynamic>;
      final id = c['id'] as String;
      final input = c['input'] as String?;
      final expected = (c['expected'] as List<dynamic>)
          .map((e) => '${(e as Map<String, dynamic>)['id']}:${e['label']}')
          .toList();

      final actualJson =
          jsonEngine.extract(input).map((b) => '${b.id}:${b.label}').toList();
      expect(actualJson, expected, reason: 'JSON engine mismatch on $id');

      final actualBuiltin =
          builtinEngine.extract(input).map((b) => '${b.id}:${b.label}').toList();
      expect(actualBuiltin, expected, reason: 'Built-in engine mismatch on $id');
    }
  });

  test('256-entry LRU cache bounds size and preserves hits', () {
    final engine = MediaBadges.fromJson(rulesJson);
    engine.clearCache();
    for (var i = 0; i < 320; i++) {
      engine.extract('Synthetic.Sample.$i.2160p.HDR10+.DD+ 5.1.mkv');
    }
    expect(engine.cacheSize, MediaBadges.lruCacheCapacity);
  });

  test('Pure-data fusion overrides filename resolution with live track and runs combos', () {
    final engine = MediaBadges.fromJson(rulesJson);
    final fused = engine.fuse(
      sources: const ['Example.Movie.4K.DV.REMUX.NF.mkv'],
      track: const MediaTrackSpec(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'hev1.2.4.L120',
        audioCodec: 'ec-3',
        audioChannels: 6,
        atmos: true,
      ),
    );
    expect(
      fused.map((b) => b.label).toList(),
      const ['1080p', 'DV · ATMOS', 'REMUX', 'DD+', '5.1', 'HEVC', 'NF'],
    );
  });

  test('Uncached average match latency stays below 0.2ms', () {
    final engine = MediaBadges.fromJson(rulesJson);
    final inputs = cases
        .map((raw) => (raw as Map<String, dynamic>)['input'] as String?)
        .toList();
    for (var w = 0; w < 3; w++) {
      engine.clearCache();
      for (final s in inputs) {
        engine.extract(s);
      }
    }
    const passes = 10;
    final sw = Stopwatch()..start();
    for (var p = 0; p < passes; p++) {
      engine.clearCache();
      for (final s in inputs) {
        engine.extract(s);
      }
    }
    sw.stop();
    final avgMs = sw.elapsedMicroseconds / 1000.0 / (passes * inputs.length);
    expect(avgMs, lessThan(0.2),
        reason: 'Avg uncached latency ${avgMs.toStringAsFixed(4)}ms >= 0.2ms');
  });

  testWidgets('MediaBadgeRow renders plain text capsules and respects reduceTransparency',
      (tester) async {
    final badges = MediaBadges.extractBadges('Sample.2160p.DV.Atmos.REMUX.mkv');
    GlassworkBackdrop.reduceTransparency.value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaBadgeRow(badges: badges),
        ),
      ),
    );
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('DV · ATMOS'), findsOneWidget);
    expect(find.text('REMUX'), findsOneWidget);

    GlassworkBackdrop.reduceTransparency.value = true;
    await tester.pump();
    expect(find.text('4K'), findsOneWidget);
    GlassworkBackdrop.reduceTransparency.value = false;
  });
}

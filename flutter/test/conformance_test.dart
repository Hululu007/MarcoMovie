// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/models.dart';

Directory _resolveConformanceDir() {
  final current = Directory.current;
  final sep = Platform.pathSeparator;
  final candidates = [
    Directory([current.path, 'shared', 'conformance'].join(sep)),
    Directory([current.path, '..', 'shared', 'conformance'].join(sep)),
    Directory([current.path, '..', '..', 'shared', 'conformance'].join(sep)),
    Directory('shared/conformance'),
    Directory('../shared/conformance'),
  ];
  for (final dir in candidates) {
    if (dir.existsSync()) return dir;
  }
  throw StateError('Cannot locate shared/conformance/ directory from ${current.path}');
}

Map<String, dynamic> _applyPlatformOverrides(
  Map<String, dynamic> expected,
  String platform,
) {
  final copy = jsonDecode(jsonEncode(expected)) as Map<String, dynamic>;
  final overrides = copy['platformOverrides'];
  if (overrides is Map && overrides[platform] is Map) {
    final platformMap = overrides[platform] as Map<String, dynamic>;
    if (platformMap['sites'] is List && copy['sites'] is List) {
      final expectedSites = copy['sites'] as List;
      for (final overrideSite in platformMap['sites'] as List) {
        if (overrideSite is! Map) continue;
        final key = overrideSite['key'];
        for (int i = 0; i < expectedSites.length; i++) {
          if (expectedSites[i] is Map && expectedSites[i]['key'] == key) {
            expectedSites[i] = {...expectedSites[i] as Map, ...overrideSite};
          }
        }
      }
    }
    platformMap.forEach((k, v) {
      if (k != 'sites') copy[k] = v;
    });
  }
  return copy;
}

Map<String, dynamic> _normalizeConfig(CmsConfig config) {
  return {
    'sites': config.sites.map((s) {
      dynamic extVal;
      if (s.ext.isNotEmpty) {
        if (s.ext.trim().startsWith('{')) {
          try {
            extVal = jsonDecode(s.ext);
          } catch (_) {
            extVal = s.ext;
          }
        } else {
          extVal = s.ext;
        }
      } else {
        extVal = '';
      }
      return {
        'key': s.key,
        'name': s.name,
        'type': s.type,
        'api': s.api,
        'jar': s.jar,
        'playUrl': s.playUrl,
        'searchable': s.searchable,
        'ext': extVal,
        'extTooLarge': s.isExtTooLarge,
        'capabilityStatus': s.capabilityStatus,
        'headers': s.headers,
      };
    }).toList(),
    if (config.depots.isNotEmpty)
      'depots': config.depots.map((d) => {
        'name': d.name,
        'url': d.url,
      }).toList(),
    if (config.parses.isNotEmpty)
      'parses': config.parses.map((p) => {
        'name': p.name,
        'url': p.url,
        'type': p.type,
        'headers': p.headers,
      }).toList(),
    if (config.spider.isNotEmpty)
      'spider': config.spider,
  };
}

Map<String, dynamic> _normalizeListing(CmsListing listing) {
  return {
    'page': listing.page,
    'pageCount': listing.pageCount,
    'videos': listing.videos.map((v) => {
      'id': v.id,
      'title': v.title,
      'lines': v.lines.map((l) => {
        'name': l.name,
        'episodes': l.episodes.map((e) => {
          'name': e.name,
          'url': e.url,
        }).toList(),
      }).toList(),
    }).toList(),
  };
}

void main() {
  group('Tri-Platform Conformance Test Suite (Flutter Runner)', () {
    final conformanceDir = _resolveConformanceDir();
    final caseDirs = conformanceDir
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split(RegExp(r'[\\/]')).last.startsWith('case_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    test('verifies conformance suite discovery', () {
      expect(caseDirs.length, greaterThanOrEqualTo(20),
          reason: 'Expected at least 20 canonical conformance test cases');
    });

    for (final dir in caseDirs) {
      final caseId = dir.path.split(RegExp(r'[\\/]')).last;
      test(caseId, () {
        final sep = Platform.pathSeparator;
        final inputFile = File([dir.path, 'input.bin'].join(sep));
        final metaFile = File([dir.path, 'meta.json'].join(sep));
        final expectedFile = File([dir.path, 'expected.json'].join(sep));

        expect(inputFile.existsSync(), isTrue, reason: '$caseId missing input.bin');
        expect(metaFile.existsSync(), isTrue, reason: '$caseId missing meta.json');
        expect(expectedFile.existsSync(), isTrue, reason: '$caseId missing expected.json');

        final inputBytes = inputFile.readAsBytesSync();
        final meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
        final rawExpected = jsonDecode(expectedFile.readAsStringSync()) as Map<String, dynamic>;
        final expected = _applyPlatformOverrides(rawExpected, 'flutter');

        final entrypoint = (meta['entrypoint'] ?? meta['type'] ?? 'config').toString().toLowerCase();
        final origin = (meta['origin'] ?? '').toString();

        if (entrypoint == 'listing' || entrypoint == 'lines') {
          final text = CmsParser.decodeTextDocument(inputBytes);
          final listing = CmsParser.parseListing(text);
          final actual = _normalizeListing(listing);
          _assertListingMatches(actual, expected, caseId);
        } else {
          final unpacked = CmsParser.decodeConfigDocument(inputBytes);
          final config = CmsParser.parseConfig(unpacked, origin: origin);
          final actual = _normalizeConfig(config);
          _assertConfigMatches(actual, expected, caseId);
        }
      });
    }
  });
}

void _assertConfigMatches(
  Map<String, dynamic> actual,
  Map<String, dynamic> expected,
  String caseId,
) {
  if (expected.containsKey('sites')) {
    final expSites = expected['sites'] as List;
    final actSites = (actual['sites'] as List?) ?? [];
    expect(actSites.length, expSites.length,
        reason: '[$caseId] sites count mismatch');
    for (int i = 0; i < expSites.length; i++) {
      final exp = expSites[i] as Map;
      final act = actSites[i] as Map;
      exp.forEach((key, val) {
        if (key == 'headers' && val is Map) {
          final actHeaders = (act['headers'] as Map?) ?? {};
          val.forEach((hKey, hVal) {
            expect(actHeaders[hKey], hVal,
                reason: '[$caseId] site $i header mismatch for $hKey');
          });
        } else if (key == 'ext' && val is Map) {
          final actExt = act['ext'];
          expect(actExt, isA<Map>(),
              reason: '[$caseId] site $i ext must be Map');
          val.forEach((eKey, eVal) {
            expect((actExt as Map)[eKey], eVal,
                reason: '[$caseId] site $i ext.$eKey mismatch');
          });
        } else if (key != 'platformOverrides') {
          expect(act[key], val,
              reason: '[$caseId] site $i property mismatch for "$key": expected $val, got ${act[key]}');
        }
      });
    }
  }
  if (expected.containsKey('depots')) {
    final expDepots = expected['depots'] as List;
    final actDepots = (actual['depots'] as List?) ?? [];
    expect(actDepots.length, expDepots.length,
        reason: '[$caseId] depots count mismatch');
    for (int i = 0; i < expDepots.length; i++) {
      final expD = expDepots[i] as Map;
      final actD = actDepots[i] as Map;
      expect(actD['name'], expD['name'], reason: '[$caseId] depot $i name mismatch');
      expect(actD['url'], expD['url'], reason: '[$caseId] depot $i url mismatch');
    }
  }
  if (expected.containsKey('parses')) {
    final expParses = expected['parses'] as List;
    final actParses = (actual['parses'] as List?) ?? [];
    expect(actParses.length, expParses.length,
        reason: '[$caseId] parses count mismatch');
    for (int i = 0; i < expParses.length; i++) {
      final expP = expParses[i] as Map;
      final actP = actParses[i] as Map;
      expect(actP['name'], expP['name'], reason: '[$caseId] parse $i name mismatch');
      expect(actP['url'], expP['url'], reason: '[$caseId] parse $i url mismatch');
      expect(actP['type'], expP['type'], reason: '[$caseId] parse $i type mismatch');
    }
  }
  if (expected.containsKey('spider')) {
    expect(actual['spider'], expected['spider'],
        reason: '[$caseId] spider declaration mismatch');
  }
}

void _assertListingMatches(
  Map<String, dynamic> actual,
  Map<String, dynamic> expected,
  String caseId,
) {
  if (expected.containsKey('page')) expect(actual['page'], expected['page']);
  if (expected.containsKey('pageCount')) expect(actual['pageCount'], expected['pageCount']);
  if (expected.containsKey('videos')) {
    final expVideos = expected['videos'] as List;
    final actVideos = (actual['videos'] as List?) ?? [];
    expect(actVideos.length, expVideos.length,
        reason: '[$caseId] videos count mismatch');
    for (int i = 0; i < expVideos.length; i++) {
      final expV = expVideos[i] as Map;
      final actV = actVideos[i] as Map;
      expect(actV['id'], expV['id'], reason: '[$caseId] video $i id mismatch');
      if (expV.containsKey('title')) {
        expect(actV['title'], expV['title'], reason: '[$caseId] video $i title mismatch');
      }
      if (expV.containsKey('lines')) {
        final expLines = expV['lines'] as List;
        final actLines = (actV['lines'] as List?) ?? [];
        expect(actLines.length, expLines.length,
            reason: '[$caseId] video $i lines count mismatch');
        for (int j = 0; j < expLines.length; j++) {
          final expL = expLines[j] as Map;
          final actL = actLines[j] as Map;
          expect(actL['name'], expL['name'],
              reason: '[$caseId] video $i line $j name mismatch');
          if (expL.containsKey('episodes')) {
            final expEps = expL['episodes'] as List;
            final actEps = (actL['episodes'] as List?) ?? [];
            expect(actEps.length, expEps.length,
                reason: '[$caseId] video $i line $j episodes count mismatch');
            for (int k = 0; k < expEps.length; k++) {
              final expEp = expEps[k] as Map;
              final actEp = actEps[k] as Map;
              expect(actEp['name'], expEp['name'],
                  reason: '[$caseId] video $i line $j episode $k name mismatch');
              expect(actEp['url'], expEp['url'],
                  reason: '[$caseId] video $i line $j episode $k url mismatch');
            }
          }
        }
      }
    }
  }
}

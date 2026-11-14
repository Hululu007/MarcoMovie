import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/resilient_http_client.dart';
import 'package:marco_movie/core/source_playback.dart';
import 'package:marco_movie/core/wogg_source.dart';

const catalogue = '''<html><title>玩偶共享站</title><body>
<div class="module-item"><div class="module-item-pic">
<a href="/voddetail/42.html" title="原站片名"></a>
<img data-src="/poster.jpg"></div><div class="module-item-text">4K</div>
<div class="module-item-caption"><span>2026</span></div></div>
<div class="page"><a href="/vodshow/3--------8---.html">8</a></div>
</body></html>''';

CmsSite site(
        {String origin = 'https://catalogue.invalid/', String key = 'wogg'}) =>
    CmsSite(
        key: key,
        name: '原始玩偶',
        type: 3,
        api: 'csp_WoGGGuard',
        subscriptionId: 'subscription-one',
        headers: const {
          'Cookie': 'subscription-only',
          'Authorization': 'secret'
        },
        ext: jsonEncode({'siteUrl': origin}));

WoggSource adapter(Future<String> Function(String, Map<String, String>) read,
        {Future<List<CmsEpisode>> Function(String)? listShare}) =>
    WoggSource(
      read: read,
      readBytes: (_, __) async =>
          throw StateError('Explicit origin must not fetch plugin'),
      listShare: listShare ?? (_) async => const [],
    );

void main() {
  String shareDetail(List<String> shares) => '''<title>玩偶共享站</title>
    <div class="video-info"></div>
    ${[
        for (var i = 0; i < shares.length; i++)
          '<div class="module-tab-item downtab-item">原线${String.fromCharCode(65 + i)}<span>1</span></div>'
      ].join()}
    ${[
        for (final share in shares)
          '<div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="$share"></a></div></div>'
      ].join()}
    ''';

  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(ready(), isTrue);
  }

  String groupedDetail(List<String> tabs, List<List<String>> panels) =>
      '''<title>玩偶共享站</title><div class="video-info"></div>
      ${tabs.map((tab) => '<div class="module-tab-item downtab-item">$tab<span>1</span></div>').join()}
      ${panels.map((shares) => '<div class="module-downlist">${shares.map((share) => '<div class="module-row-info"><a data-clipboard-text="$share"></a></div>').join()}</div>').join()}
      ''';

  Future<Map<String, dynamic>> groupedVideo(
      List<String> tabs, List<List<String>> panels, List<String> seen) async {
    final source = adapter((_, __) async => groupedDetail(tabs, panels),
        listShare: (url) async {
      seen.add(url);
      final host = Uri.parse(url).host;
      final provider = host == 'pan.baidu.com'
          ? 'baidu'
          : host == 'pan.quark.cn'
              ? 'quark'
              : host.endsWith('uc.cn')
                  ? 'uc'
                  : 'ali';
      return [
        CmsEpisode(
            name: 'original-${seen.length}.mkv',
            url:
                '${provider == 'quark' ? 'mmwogg' : 'mmcloud'}://$provider?fid=${seen.length}')
      ];
    });
    return jsonDecode(await source.invoke(site(), 'detail', ['42']))['list'][0];
  }

  test('one downlist with four share tabs preserves the actual providers',
      () async {
    final shares = [
      'https://pan.quark.cn/s/fixtureA',
      'https://pan.quark.cn/s/fixtureB',
      'https://pan.baidu.com/s/1fixtureC',
      'https://pan.baidu.com/s/1fixtureD',
    ];
    final seen = <String>[];
    final video = await groupedVideo(
        ['夸克网盘 ', '夸克网盘 ', '百度网盘 ', '百度网盘 '], [shares], seen);
    expect(seen, shares);
    expect(video['lines'].map((line) => line['name']),
        ['夸克网盘 1', '夸克网盘 2', '百度网盘 3', '百度网盘 4']);
    expect(video['lines'].map((line) => line['episodes'][0]['url']), [
      'mmwogg://quark?fid=1',
      'mmwogg://quark?fid=2',
      'mmcloud://baidu?fid=3',
      'mmcloud://baidu?fid=4',
    ]);
  });

  test('one-to-one panels retain matching original provider aliases', () async {
    final video = await groupedVideo([
      '优汐',
      '嘟嘟'
    ], [
      ['https://drive.uc.cn/s/fixtureA', 'https://fast.uc.cn/s/fixtureB'],
      ['https://pan.baidu.com/s/1fixtureC'],
    ], []);
    expect(
        video['lines'].map((line) => line['name']), ['优汐 1', '优汐 2', '嘟嘟 3']);
  });

  test(
      'conflicting or mixed provider tabs cannot rename the actual share owner',
      () async {
    final video = await groupedVideo([
      '夸克网盘',
      '嘟嘟',
      '优汐 / 百度',
      '阿里云盘'
    ], [
      ['https://pan.baidu.com/s/1fixtureA', 'https://pan.quark.cn/s/fixtureB'],
      ['https://drive.uc.cn/s/fixtureC', 'https://www.alipan.com/s/fixtureD'],
    ], []);
    expect(video['lines'].map((line) => line['name']),
        ['百度网盘 1', '夸克网盘 2', 'UC网盘 3', '阿里云盘 4']);
  });

  test('missing or unmatched tabs fall back to supported provider hosts',
      () async {
    final shares = [
      'https://fast.uc.cn/s/fixtureA',
      'https://alipan.com/s/fixtureB',
      'https://aliyundrive.com/s/fixtureC',
      'https://www.aliyundrive.com/s/fixtureD',
    ];
    for (final tabs in <List<String>>[
      [],
      ['夸克网盘', '嘟嘟']
    ]) {
      final video = await groupedVideo(tabs, [shares], []);
      expect(video['lines'].map((line) => line['name']),
          ['UC网盘 1', '阿里云盘 2', '阿里云盘 3', '阿里云盘 4']);
    }
  });

  test('duplicate shares do not shift following tab associations', () async {
    final video = await groupedVideo([
      '第一份',
      '重复份',
      '嘟嘟'
    ], [
      [
        'https://pan.quark.cn/s/fixtureA',
        'https://pan.quark.cn/s/fixtureA',
        'https://pan.baidu.com/s/1fixtureB',
      ]
    ], []);
    expect(video['lines'].map((line) => line['name']), ['第一份 1', '嘟嘟 2']);
    expect(video['lines'][1]['episodes'][0]['url'], 'mmcloud://baidu?fid=2');
  });

  test('cached WoGG labels are corrected without changing files or metadata',
      () {
    const files = [
      CmsEpisode(
          name: 'original.mkv',
          url: 'mmcloud://baidu?fid=3',
          headers: {'Referer': 'https://provider.invalid'},
          playbackSession: {'temporary': 'retained'})
    ];
    const original = CmsVideo(
        id: '42',
        title: 'fixture',
        poster: '/poster',
        remarks: 'remark',
        year: '2026',
        area: 'area',
        actor: 'actor',
        description: 'description',
        tag: 'tag',
        sourceWarnings: ['warning'],
        lines: [CmsLine(name: '夸克网盘 3', episodes: files)]);
    final corrected = WoggSource.normalizeCachedVideoLabels(site(), original);
    expect(corrected.lines.single.name, '百度网盘 3');
    expect(identical(corrected.lines.single.episodes, files), isTrue);
    expect(identical(corrected.lines.single.episodes.single, files.single),
        isTrue);
    expect([
      corrected.id,
      corrected.title,
      corrected.poster,
      corrected.remarks,
      corrected.year,
      corrected.area,
      corrected.actor,
      corrected.description,
      corrected.tag
    ], [
      '42',
      'fixture',
      '/poster',
      'remark',
      '2026',
      'area',
      'actor',
      'description',
      'tag'
    ]);
    expect(
        identical(corrected.sourceWarnings, original.sourceWarnings), isTrue);
    expect(
        identical(WoggSource.normalizeCachedVideoLabels(site(), corrected),
            corrected),
        isTrue);
    expect(original.lines.single.name, '夸克网盘 3');
  });

  test(
      'cache correction does not guess unknown, mixed, neutral or other-source ownership',
      () {
    const original = CmsVideo(id: '42', title: 'fixture', lines: [
      CmsLine(name: '夸克网盘 1', episodes: [
        CmsEpisode(name: 'a', url: 'mmcloud://baidu?fid=1'),
        CmsEpisode(name: 'b', url: 'mmwogg://quark?fid=2')
      ]),
      CmsLine(name: '夸克网盘 2', episodes: [
        CmsEpisode(name: 'a', url: 'mmcloud://baidu?fid=1'),
        CmsEpisode(name: 'b', url: 'https://media.invalid/file.mkv')
      ]),
      CmsLine(
          name: '嘟嘟 3',
          episodes: [CmsEpisode(name: 'a', url: 'mmcloud://baidu?fid=3')]),
      CmsLine(
          name: '原线 4',
          episodes: [CmsEpisode(name: 'a', url: 'mmcloud://baidu?fid=4')]),
      CmsLine(name: '夸克网盘 5', episodes: []),
    ]);
    expect(
        identical(
            WoggSource.normalizeCachedVideoLabels(site(), original), original),
        isTrue);
    const conflict = CmsVideo(id: '42', title: 'fixture', lines: [
      CmsLine(
          name: '夸克网盘 1',
          episodes: [CmsEpisode(name: 'a', url: 'mmcloud://baidu?fid=1')]),
    ]);
    expect(
        identical(
            WoggSource.normalizeCachedVideoLabels(
                site().copyWith(api: 'csp_Other'), conflict),
            conflict),
        isTrue);
  });

  group('known 0.5.15 bookmark label recovery', () {
    const baidu =
        CmsEpisode(name: 'original.mkv', url: 'mmcloud://baidu?fid=3');
    const quark = CmsEpisode(name: 'other.mkv', url: 'mmwogg://quark?fid=4');
    const corrected = CmsVideo(id: '42', title: 'fixture', lines: [
      CmsLine(name: '百度网盘 3', episodes: [baidu]),
      CmsLine(name: '夸克网盘 4', episodes: [quark]),
    ]);
    WatchHistoryEntry bookmark(
            {String siteKey = 'wogg',
            String id = '42',
            String line = '夸克网盘 3',
            String episode = 'original.mkv'}) =>
        WatchHistoryEntry(
            site: siteKey,
            id: id,
            title: 'saved title',
            poster: 'saved poster',
            line: line,
            episode: episode,
            index: 17,
            position: 12345,
            duration: 67890,
            updated: 123456);

    test(
        'uses original share ordinal across missing lines and keeps every other field',
        () {
      final original = bookmark();
      final result =
          WoggSource.normalizeCachedBookmark(site(), corrected, original);
      expect(result.line, '百度网盘 3');
      final expected = original.toJson()..['line'] = '百度网盘 3';
      expect(result.toJson(), expected);
      expect(original.line, '夸克网盘 3');
      expect(
          identical(
              WoggSource.normalizeCachedBookmark(site(), corrected, result),
              result),
          isTrue);
    });

    test(
        'bookmark target follows exact migrated file and ignores stale indices',
        () {
      const reordered = CmsVideo(id: '42', title: 'fixture', lines: [
        CmsLine(name: '夸克网盘 4', episodes: [quark]),
        CmsLine(name: '百度网盘 3', episodes: [
          CmsEpisode(name: 'another.mkv', url: 'mmcloud://baidu?fid=another'),
          baidu
        ]),
      ]);
      final saved = bookmark();
      expect(saved.index, 17);
      expect(WoggSource.resolveCachedBookmarkTarget(site(), reordered, saved),
          (1, 1));
      expect(
          WoggSource.resolveCachedBookmarkTarget(
              site(), reordered, bookmark(line: '百度网盘 3')),
          (1, 1));
      expect(saved.line, '夸克网盘 3');
      expect(saved.index, 17);
    });

    test('unresolved or ambiguous bookmark target has no resumable progress',
        () {
      for (final saved in [
        bookmark(siteKey: 'other'),
        bookmark(id: 'other'),
        bookmark(line: '原线 3'),
        bookmark(line: '夸克网盘 99'),
        bookmark(episode: ''),
        bookmark(episode: 'missing.mkv'),
        bookmark(episode: 'other.mkv'),
      ]) {
        expect(WoggSource.resolveCachedBookmarkTarget(site(), corrected, saved),
            isNull);
      }
      expect(
          WoggSource.resolveCachedBookmarkTarget(
              site().copyWith(api: 'csp_Other'), corrected, bookmark()),
          isNull);
      for (final lines in <List<CmsLine>>[
        [
          const CmsLine(name: '百度网盘 3', episodes: [baidu]),
          const CmsLine(name: '百度网盘 3', episodes: [baidu])
        ],
        [
          const CmsLine(name: '百度网盘 3', episodes: [baidu, baidu])
        ],
        [const CmsLine(name: '百度网盘 3', episodes: [])],
        [
          const CmsLine(name: '百度网盘 4', episodes: [baidu])
        ],
      ]) {
        final video = CmsVideo(id: '42', title: 'fixture', lines: lines);
        expect(
            WoggSource.resolveCachedBookmarkTarget(site(), video, bookmark()),
            isNull);
        expect(
            WoggSource.resolveCachedBookmarkTarget(
                site(), video, bookmark(line: '百度网盘 3')),
            isNull);
      }
    });

    test(
        'requires the same source and video, exact generated label, and saved file',
        () {
      for (final original in [
        bookmark(siteKey: 'other'),
        bookmark(id: 'other'),
        bookmark(line: '夸克网盘 4', episode: 'other.mkv'),
        bookmark(line: '夸克网盘'),
        bookmark(line: '夸克网盘 03'),
        bookmark(line: '夸克网盘 0'),
        bookmark(line: '某合集夸克网盘 3'),
        bookmark(line: '夸克/百度 3'),
        bookmark(line: '原线 3'),
        bookmark(episode: ''),
        bookmark(episode: '   '),
        bookmark(episode: 'missing.mkv'),
        bookmark(episode: 'other.mkv'),
      ]) {
        expect(
            identical(
                WoggSource.normalizeCachedBookmark(site(), corrected, original),
                original),
            isTrue,
            reason: 'A partial match must not move the saved file');
      }
      final original = bookmark();
      expect(
          identical(
              WoggSource.normalizeCachedBookmark(
                  site().copyWith(api: 'csp_Other'), corrected, original),
              original),
          isTrue);
    });

    test(
        'ambiguous ordinal, unknown or mixed files, and uncorrected labels stay untouched',
        () {
      final original = bookmark();
      for (final lines in <List<CmsLine>>[
        [
          const CmsLine(name: '百度网盘 3', episodes: [baidu]),
          const CmsLine(name: '嘟嘟 3', episodes: [baidu])
        ],
        [
          const CmsLine(name: '百度网盘 2', episodes: [baidu])
        ],
        [const CmsLine(name: '百度网盘 3', episodes: [])],
        [
          const CmsLine(name: '百度网盘 3', episodes: [baidu, quark])
        ],
        [
          const CmsLine(name: '百度网盘 3', episodes: [
            baidu,
            CmsEpisode(
                name: 'unknown.mkv', url: 'https://media.invalid/file.mkv')
          ])
        ],
        [
          const CmsLine(name: '百度网盘 3', episodes: [
            CmsEpisode(
                name: 'original.mkv', url: 'https://media.invalid/file.mkv')
          ])
        ],
        [
          const CmsLine(name: '百度网盘 3', episodes: [baidu, baidu])
        ],
        [
          const CmsLine(name: 'UC网盘 3', episodes: [baidu])
        ],
        [
          const CmsLine(name: '夸克网盘 3', episodes: [baidu])
        ],
        [
          const CmsLine(name: 'Quark 3', episodes: [
            CmsEpisode(name: 'original.mkv', url: 'mmwogg://quark?fid=3')
          ])
        ],
      ]) {
        final video = CmsVideo(id: '42', title: 'fixture', lines: lines);
        expect(
            identical(
                WoggSource.normalizeCachedBookmark(site(), video, original),
                original),
            isTrue);
      }
    });
  });

  test(
      'partial directory keeps its original line and warns once without persisting metadata',
      () async {
    final source = adapter(
        (_, __) async => shareDetail(['https://pan.quark.cn/s/original']),
        listShare: (_) async => [
              for (var i = 0; i < 2; i++)
                CmsEpisode(
                  name: 'returned-$i',
                  url: 'mmwogg://quark?fid=$i',
                  playbackSession: const {
                    'listingWarning': 'provider-specific temporary metadata'
                  },
                )
            ]);
    final result =
        jsonDecode(await source.invoke(site(), 'detail', ['42']))['list'][0];
    expect(result['lines'].single['name'], '原线A 1');
    expect(result['lines'].single['episodes'].length, 2);
    expect(result['wogg_share_errors'].length, 1);
    expect(result['wogg_share_errors'].single['line'], '原线A 1');
    expect(result['wogg_share_errors'].single['message'], contains('目录返回不完整'));
    expect(jsonEncode(result), isNot(contains('provider-specific')));
    expect(jsonEncode(result['lines']), isNot(contains('listingWarning')));
  });

  test('detail runs at most three shares concurrently and keeps original order',
      () async {
    final gates = [for (var i = 0; i < 5; i++) Completer<List<CmsEpisode>>()];
    final started = <int>[];
    var active = 0;
    var peak = 0;
    final source = adapter(
        (_, __) async => shareDetail([
              for (var i = 0; i < 5; i++) 'https://pan.quark.cn/s/share$i',
            ]), listShare: (url) async {
      final id = int.parse(url.substring(url.length - 1));
      started.add(id);
      active++;
      if (active > peak) peak = active;
      try {
        return await gates[id].future;
      } finally {
        active--;
      }
    });
    final future = source.invoke(site(), 'detail', ['42']);
    await until(() => started.length == 3);
    expect(started, [0, 1, 2]);
    List<CmsEpisode> result(int id) =>
        [CmsEpisode(name: 'file-$id', url: 'mmcloud://uc?fid=$id')];
    gates[2].complete(result(2));
    await until(() => started.length == 4);
    gates[1].completeError(const FormatException('expired share'));
    await until(() => started.length == 5);
    gates[4].complete(result(4));
    gates[3].complete(result(3));
    gates[0].complete(result(0));
    final video = jsonDecode(await future)['list'][0];
    expect(peak, 3);
    expect(video['lines'].map((line) => line['name']),
        ['原线A 1', '原线C 3', '原线D 4', '原线E 5']);
    expect(video['wogg_share_errors'][0]['line'], '原线B 2');
  });

  test('share timeout signals its own cancellation and preserves other lines',
      () async {
    final timeoutSignal = Completer<void>();
    final source = WoggSource(
      read: (_, __) async => shareDetail(
          ['https://pan.quark.cn/s/slow', 'https://pan.quark.cn/s/fast']),
      readBytes: (_, __) async => Uint8List(0),
      listShare: (_) async => throw StateError('Must use cancellable callback'),
      shareTimeout: const Duration(milliseconds: 20),
      listShareWithCancellation: (url, cancel) async {
        if (url.endsWith('/fast')) {
          return const [CmsEpisode(name: 'file', url: 'mmcloud://uc?fid=1')];
        }
        await cancel.future;
        timeoutSignal.complete();
        throw const FormatException('cancelled');
      },
    );
    final result =
        jsonDecode(await source.invoke(site(), 'detail', ['42']))['list'][0];
    await timeoutSignal.future;
    expect(result['lines'].single['name'], '原线B 2');
    expect(result['wogg_share_errors'].single['line'], '原线A 1');
  });

  test(
      'detail cancellation cancels active shares and never starts queued shares',
      () async {
    final cancelled = Completer<void>();
    var started = 0;
    var signalled = 0;
    final source = WoggSource(
      read: (_, __) async => shareDetail(
          [for (var i = 0; i < 6; i++) 'https://pan.quark.cn/s/share$i']),
      readBytes: (_, __) async => Uint8List(0),
      listShare: (_) async => throw StateError('Must use cancellable callback'),
      listShareWithCancellation: (_, cancel) async {
        started++;
        await cancel.future;
        signalled++;
        throw const FormatException('cancelled');
      },
    );
    final pending =
        source.invoke(site(), 'detail', ['42'], cancellation: cancelled);
    final rejected = expectLater(pending, throwsFormatException);
    await until(() => started == 3);
    cancelled.complete();
    await rejected;
    expect(started, 3);
    expect(signalled, 3);
  });

  test('Baidu clipboard extraction code is preserved on its original URL',
      () async {
    final seen = <String>[];
    final source = adapter(
        (_, __) async => shareDetail([
              '链接：https://pan.baidu.com/s/1original 提取码：a1B2',
              'https://pan.baidu.com/s/1existing?pwd=z9Y8 提取码:z9Y8',
              'https://pan.baidu.com/s/1conflict?pwd=old1 提取码:new2',
              'https://pan.baidu.com/s/1first https://pan.baidu.com/s/1second 提取码:abcd',
            ]), listShare: (url) async {
      seen.add(url);
      return const [CmsEpisode(name: 'file', url: 'mmcloud://baidu?fid=1')];
    });
    final result =
        jsonDecode(await source.invoke(site(), 'detail', ['42']))['list'][0];
    expect(seen, [
      'https://pan.baidu.com/s/1original?pwd=a1B2',
      'https://pan.baidu.com/s/1existing?pwd=z9Y8'
    ]);
    expect(result['lines'].length, 2);
    expect(result['wogg_share_errors'].map((item) => item['line']),
        ['原线C 3', '原线D 4']);
  });

  test('requires exact WoGG API and original configuration', () {
    expect(WoggSource.supports(site()), isTrue);
    expect(WoggSource.supports(site().copyWith(api: 'csp_WoGG')), isTrue);
    expect(
        WoggSource.supports(site().copyWith(api: 'csp_NotWoGGGuard')), isFalse);
    expect(WoggSource.supports(site().copyWith(ext: '')), isFalse);
    expect(
        WoggSource.supports(site()
            .copyWith(ext: '', spider: 'https://plugin.invalid/source.jar')),
        isTrue);
  });

  test(
      'home keeps original ids and resolves posters without leaking subscription headers',
      () async {
    final requests = <String>[];
    final source = adapter((url, headers) async {
      requests.add(url);
      expect(headers.keys, ['User-Agent']);
      return catalogue;
    });
    final result =
        jsonDecode(await source.invoke(site(), 'home', [false])) as Map;
    expect(requests, ['https://catalogue.invalid/']);
    expect((result['class'] as List).map((x) => x['type_id']),
        ['1', '2', '44', '6', '3', '4', '46', '5']);
    expect(result['list'][0]['vod_id'], '42');
    expect(result['list'][0]['vod_name'], '原站片名');
    expect(
        result['list'][0]['vod_pic'], 'https://catalogue.invalid/poster.jpg');
    expect(result['filters']['1'][0]['key'], '3');
  });

  test('category uses original 12-slot path with encoded filter values',
      () async {
    String? requested;
    final source = adapter((url, _) async {
      requested = url;
      return catalogue;
    });
    final result = jsonDecode(await source.invoke(site(), 'category', [
      '3',
      2,
      true,
      {'1': '中国大陆', '3': '科幻', '11': '2026'},
    ]));
    final rawPath = Uri.parse(requested!).pathSegments.last;
    final slots = rawPath.replaceFirst('.html', '').split('-');
    expect(slots.length, 12);
    expect(slots[0], '3');
    expect(slots[1], '中国大陆');
    expect(slots[3], '科幻');
    expect(slots[8], '2');
    expect(slots[11], '2026');
    expect(result['page'], 2);
    expect(result['pagecount'], 8);
    await expectLater(
        source.invoke(site(), 'category', [
          '3',
          1,
          true,
          {'12': 'x'}
        ]),
        throwsFormatException);
  });

  test('search encodes keyword and does not duplicate unsupported later pages',
      () async {
    final requests = <String>[];
    final source = adapter((url, _) async {
      requests.add(url);
      return '''<html><title>玩偶共享站</title><div class="module-search-item">
      <div class="video-info-header"><h3><a href="/voddetail/8.html">准确标题</a></h3>
      <a class="video-serial">4K</a></div><div class="module-item-pic">
      <img data-src="/8.jpg"></div></div></html>''';
    });
    final result =
        jsonDecode(await source.invoke(site(), 'search', ['剧 & 集', false, 1]));
    expect(Uri.parse(requests.single).queryParameters['wd'], '剧 & 集');
    expect(result['list'][0]['vod_name'], '准确标题');
    final next =
        jsonDecode(await source.invoke(site(), 'search', ['剧 & 集', false, 2]));
    expect(next['list'], isEmpty);
    expect(requests.length, 1);
  });

  test(
      'detail keeps real share lines, episode headers and safe partial warnings',
      () async {
    const detail = '''<html><title>玩偶共享站</title>
    <div class="video-cover"><div class="module-item-pic"><img alt="原片" data-src="/p.jpg"></div></div>
    <div class="video-info-items"><span class="video-info-itemtitle">年代：</span><div class="video-info-item">2026</div></div>
    <div class="module-tab-item downtab-item">优汐<span>1</span></div>
    <div class="module-tab-item downtab-item">嘟嘟<span>1</span></div>
    <div class="module-tab-item downtab-item">夸克<span>1</span></div>
    <div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/first"></a></div></div>
    <div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://pan.baidu.com/s/second?pwd=abc"></a></div></div>
    <div class="module-downlist"><div class="module-row-info"><a data-clipboard-text="https://pan.quark.cn/s/third"></a></div></div>
    </html>''';
    final shares = <String>[];
    final source = adapter((_, __) async => detail, listShare: (url) async {
      shares.add(url);
      if (url.contains('quark')) throw StateError('secret_cookie raw_url');
      return [
        CmsEpisode(
            name: '第1集 4K',
            url: 'mmcloud://uc?id=${shares.length}',
            headers: const {'Referer': 'https://provider.invalid/'})
      ];
    });
    final result = jsonDecode(await source.invoke(site(), 'detail', ['42']));
    final video = result['list'][0];
    expect(video['vod_name'], '原片');
    expect(video['vod_year'], '2026');
    expect(video['lines'].length, 2);
    expect(video['lines'][0]['name'], '优汐 1');
    expect(video['lines'][1]['name'], '嘟嘟 2');
    expect(video['lines'][0]['episodes'][0]['url'], startsWith('mmcloud://'));
    expect(video['lines'][0]['episodes'][0]['headers']['Referer'],
        'https://provider.invalid/');
    expect(video['wogg_share_errors'][0]['line'], '夸克 3');
    expect(jsonEncode(video['wogg_share_errors']),
        isNot(contains('secret_cookie')));
    expect(shares.length, 3);
  });

  test('unavailable original shares never become replacement streams',
      () async {
    final source = adapter(
        (_, __) async => '''<title>玩偶共享站</title><div class="video-info"></div>
    <div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/first"></a></div>''');
    await expectLater(
        source.invoke(site(), 'detail', ['42']), throwsFormatException);
  });

  test(
      'explicit source origins remain isolated and never fail over to another site',
      () async {
    final requests = <String>[];
    final source = adapter((url, _) async {
      requests.add(url);
      return catalogue;
    });
    await source.invoke(site(), 'home', []);
    await source.invoke(site(origin: 'https://another.invalid/'), 'home', []);
    expect(
        requests, ['https://catalogue.invalid/', 'https://another.invalid/']);
    final failed = <String>[];
    final unavailable = adapter((url, _) async {
      failed.add(url);
      return '<title>Unrelated CMS</title>';
    });
    await expectLater(
        unavailable.invoke(site(), 'home', []), throwsFormatException);
    expect(failed, ['https://catalogue.invalid/']);
  });

  test('cancellation after network prevents further parsing or share requests',
      () async {
    final cancel = Completer<void>();
    final source = adapter((_, __) async {
      cancel.complete();
      return catalogue;
    });
    await expectLater(source.invoke(site(), 'home', [], cancellation: cancel),
        throwsFormatException);
  });

  test('unknown plugin bytes fail closed before archive parsing', () {
    expect(() => WoggPluginConfiguration.extract(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });

  test('malformed explicit origin is rejected before a request', () async {
    final source = adapter((_, __) async => throw StateError('Must not fetch'));
    await expectLater(
        source.invoke(site(origin: 'https://user:password@catalogue.invalid/'),
            'home', []),
        throwsFormatException);
  });

  test('Quark, UC, Ali and Baidu share clipboard passcodes normalize cleanly',
      () async {
    final seen = <String>[];
    final source = adapter(
        (_, __) async => shareDetail([
              '链接：https://pan.quark.cn/s/qShare1 提取码：q1W2',
              '链接：https://drive.uc.cn/s/uShare2?public=1 提取码: u3R4',
              'https://www.alipan.com/s/aShare3 提取码=a5B6',
              'https://pan.baidu.com/share/init?surl=bShare4&pwd=c7D8',
            ]), listShare: (url) async {
      seen.add(url);
      return const [CmsEpisode(name: 'ep1.mkv', url: 'mmwogg://quark?fid=1')];
    });
    final result =
        jsonDecode(await source.invoke(site(), 'detail', ['42']))['list'][0];
    expect(seen, [
      'https://pan.quark.cn/s/qShare1?pwd=q1W2',
      'https://drive.uc.cn/s/uShare2?public=1&pwd=u3R4',
      'https://www.alipan.com/s/aShare3?pwd=a5B6',
      'https://pan.baidu.com/s/1bShare4?pwd=c7D8',
    ]);
    expect(result['lines'].length, 4);
    expect(
      ResilientHttpClient.normalizeCloudShareUrl(
          'push://https%3A%2F%2Fpan.quark.cn%2Fs%2FqShare1%3Fpwd%3Dq1W2'),
      'https://pan.quark.cn/s/qShare1?pwd=q1W2',
    );
  });

  test('upcoming title without valid share reports upcoming message clearly',
      () async {
    const upcomingHtml = '''<html><title>玩偶共享站</title>
    <div class="video-info"></div>
    <div class="video-info-items"><span class="video-info-itemtitle">备注：</span><div class="video-info-item">敬请期待</div></div>
    </html>''';
    final source = adapter((_, __) async => upcomingHtml);
    await expectLater(
      source.invoke(site(), 'detail', ['42']),
      throwsA(isA<FormatException>()
          .having((e) => e.message, 'message', contains('敬请期待'))),
    );
  });

  test('SourcePlayback.decode accepts boolean false and empty parse flags',
      () async {
    final ep = await SourcePlayback.decode(
      {
        'parse': false,
        'jx': '',
        'url': ['原画', 'https://catalogue.invalid/a.m3u8', '高清', 'https://catalogue.invalid/b.m3u8'],
      },
      const CmsEpisode(name: '第1集', url: 'mmjs://play?id=1'),
      localUrl: (u) async => Uri.parse(u),
    );
    expect(ep.url, 'https://catalogue.invalid/a.m3u8');
    expect(ep.variants.map((v) => v.name), ['原画', '高清']);
  });

  test('WoggPluginConfiguration.extractFromDex decodes synthetic rotated DEX',
      () {
    final ua =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'
            .padRight(111, '0');
    expect(ua.length, 111);
    const origins = [
      'https://one.invalid/',
      'https://two.invalid/',
      'http://three.invalid/',
      'https://four.invalid/',
      'https://five.invalid/',
    ];
    const uaMask = 0x9b2d;
    const originMasks = [0x3a1f, 0x7c21, 0x8d45, 0x5512, 0xe103];

    final dex = _buildSyntheticWoggDex(
      ua: ua,
      uaMask: uaMask,
      origins: origins,
      originMasks: originMasks,
    );
    final config = WoggPluginConfiguration.extractFromDex(dex);
    expect(config.origins, origins);
    expect(config.userAgent, ua);

    final badOriginDex = _buildSyntheticWoggDex(
      ua: ua,
      uaMask: uaMask,
      origins: const [
        'https://one.invalid/bad-path',
        'https://two.invalid/',
        'http://three.invalid/',
        'https://four.invalid/',
        'https://five.invalid/',
      ],
      originMasks: originMasks,
    );
    expect(
      () => WoggPluginConfiguration.extractFromDex(badOriginDex),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => WoggPluginConfiguration.extractFromDex(
          Uint8List.fromList(List<int>.filled(128, 0))),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => WoggPluginConfiguration.extract(_minimalStoredZip(const {
        'classes.dex': [1, 2, 3],
        'assets/ftyguard_v8.so': [4, 5, 6],
      })),
      throwsA(isA<FormatException>()
          .having((e) => e.message, 'message', contains('尚未完成适配'))),
    );
  });
}

Uint8List _minimalStoredZip(Map<String, List<int>> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = entry.value;
    final localOff = out.length;
    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint32(14, _crc32(data), Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out.add(lh.buffer.asUint8List());
    out.add(name);
    out.add(data);

    final ch = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint32(16, _crc32(data), Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, localOff, Endian.little);
    central.add(ch.buffer.asUint8List());
    central.add(name);
  }
  final cdOff = out.length;
  final cdBytes = central.toBytes();
  out.add(cdBytes);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOff, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.toBytes();
}

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final b in data) {
    crc ^= b & 0xff;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

Uint8List _buildSyntheticWoggDex({
  required String ua,
  required int uaMask,
  required List<String> origins,
  required List<int> originMasks,
}) {
  final shorts = List<int>.filled(43, 0, growable: true);
  for (final cu in ua.codeUnits) {
    shorts.add((cu ^ uaMask) & 0xffff);
  }
  final originSlices = <(int, int)>[];
  for (var i = 0; i < origins.length; i++) {
    final st = shorts.length;
    final mask = originMasks[i];
    for (final cu in origins[i].codeUnits) {
      shorts.add((cu ^ mask) & 0xffff);
    }
    originSlices.add((st, origins[i].length));
  }
  final count = shorts.length;

  final strings = <String>[
    '<clinit>',
    '<init>',
    'I',
    'LLIII',
    'Lcom/github/catvod/spider/WoGG;',
    'Lfixture/Dec;',
    'Ljava/lang/Object;',
    'Ljava/lang/String;',
    'V',
    '[S',
    'c',
    'd',
    'getKey',
  ]..sort();
  final sIdx = {for (var i = 0; i < strings.length; i++) strings[i]: i};

  final types = <String>[
    'I',
    'Lcom/github/catvod/spider/WoGG;',
    'Lfixture/Dec;',
    'Ljava/lang/Object;',
    'Ljava/lang/String;',
    'V',
    '[S',
  ]..sort((a, b) => sIdx[a]!.compareTo(sIdx[b]!));
  final tIdx = {for (var i = 0; i < types.length; i++) types[i]: i};

  final protos = <(int, int, List<int>)>[
    (
      sIdx['LLIII']!,
      tIdx['Ljava/lang/String;']!,
      [tIdx['[S']!, tIdx['I']!, tIdx['I']!, tIdx['I']!],
    ),
    (sIdx['V']!, tIdx['V']!, <int>[]),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  final pDec = protos.indexWhere((p) => p.$3.isNotEmpty);
  final pVoid = protos.indexWhere((p) => p.$3.isEmpty);

  final fields = <(int, int, int)>[
    (tIdx['Lcom/github/catvod/spider/WoGG;']!, tIdx['[S']!, sIdx['c']!),
  ];

  final methods = <(int, int, int)>[
    (tIdx['Lfixture/Dec;']!, pDec, sIdx['d']!),
    (tIdx['Lcom/github/catvod/spider/WoGG;']!, pVoid, sIdx['<clinit>']!),
    (tIdx['Lcom/github/catvod/spider/WoGG;']!, pVoid, sIdx['<init>']!),
    (tIdx['Lcom/github/catvod/spider/WoGG;']!, pVoid, sIdx['getKey']!),
  ]..sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      final n = a.$3.compareTo(b.$3);
      return n != 0 ? n : a.$2.compareTo(b.$2);
    });
  int findMethod(String cls, String name) =>
      methods.indexWhere((m) => m.$1 == tIdx[cls] && m.$3 == sIdx[name]);
  final mDec = findMethod('Lfixture/Dec;', 'd');
  final mClinit = findMethod('Lcom/github/catvod/spider/WoGG;', '<clinit>');
  final mInit = findMethod('Lcom/github/catvod/spider/WoGG;', '<init>');
  final mGetKey = findMethod('Lcom/github/catvod/spider/WoGG;', 'getKey');

  final clinitUnits = <int>[
    0x0013, count,
    0x0023, tIdx['[S']!,
    0x0026, 6, 0,
    0x0069, 0,
    0x000e,
    0x0300, 2, count & 0xffff, (count >> 16) & 0xffff,
    ...shorts,
  ];
  if (clinitUnits.length.isOdd) clinitUnits.add(0);
  final initUnits = <int>[
    0x0012,
    0x0113, 43,
    0x0213, 111,
    0x0313, uaMask & 0xffff,
    0x4071, mDec, 0x3210,
    0x000e,
  ];
  final getKeyUnits = <int>[
    0x0012,
    0x0313, originMasks[4] & 0xffff,
    0x0412,
    0x042c, 0, 0, // sparse-switch at unit 4, patched below
  ];
  for (var i = 0; i < 4; i++) {
    getKeyUnits.addAll([
      0x0113, originSlices[i].$1,
      0x0213, originSlices[i].$2,
      0x0313, originMasks[i] & 0xffff,
      0x4071, mDec, 0x3210,
    ]);
  }
  getKeyUnits.addAll([0x0029, 2]); // goto/16 -> restores headerRegs mask[4]
  final case4Start = getKeyUnits.length;
  getKeyUnits.addAll([
    0x0113, originSlices[4].$1,
    0x0213, originSlices[4].$2,
    0x4071, mDec, 0x3210,
    0x000e,
  ]);
  if (getKeyUnits.length.isOdd) getKeyUnits.add(0x0000);
  final swOff = getKeyUnits.length - 4;
  getKeyUnits[5] = swOff & 0xffff;
  getKeyUnits[6] = (swOff >> 16) & 0xffff;
  getKeyUnits.addAll([0x0200, 1, 1, 0, (case4Start - 4) & 0xffff, 0]);

  List<int> encodeCode(int regs, int outs, List<int> units) {
    final bd = ByteData(16 + units.length * 2)
      ..setUint16(0, regs, Endian.little)
      ..setUint16(4, outs, Endian.little)
      ..setUint32(12, units.length, Endian.little);
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(16 + i * 2, units[i] & 0xffff, Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  void addUleb(BytesBuilder b, int v) {
    var x = v;
    do {
      var byte = x & 0x7f;
      x >>= 7;
      if (x != 0) byte |= 0x80;
      b.addByte(byte);
    } while (x != 0);
  }

  const strIdsOff = 0x70;
  final typeIdsOff = strIdsOff + strings.length * 4;
  final protoIdsOff = typeIdsOff + types.length * 4;
  final fieldIdsOff = protoIdsOff + protos.length * 12;
  final methodIdsOff = fieldIdsOff + fields.length * 8;
  final classDefsOff = methodIdsOff + methods.length * 8;
  final dataOff = classDefsOff + 32;

  final data = BytesBuilder();
  void pad4() {
    while ((dataOff + data.length) % 4 != 0) {
      data.addByte(0);
    }
  }

  final strDataOffs = <int>[];
  for (final s in strings) {
    strDataOffs.add(dataOff + data.length);
    addUleb(data, s.length);
    data.add(utf8.encode(s));
    data.addByte(0);
  }
  final protoParamOffs = <int, int>{};
  for (var i = 0; i < protos.length; i++) {
    final params = protos[i].$3;
    if (params.isNotEmpty) {
      pad4();
      protoParamOffs[i] = dataOff + data.length;
      final tl = ByteData(4 + params.length * 2)
        ..setUint32(0, params.length, Endian.little);
      for (var j = 0; j < params.length; j++) {
        tl.setUint16(4 + j * 2, params[j], Endian.little);
      }
      data.add(tl.buffer.asUint8List());
    }
  }
  pad4();
  final clinitOff = dataOff + data.length;
  data.add(encodeCode(1, 0, clinitUnits));
  pad4();
  final initOff = dataOff + data.length;
  data.add(encodeCode(4, 4, initUnits));
  pad4();
  final getKeyOff = dataOff + data.length;
  data.add(encodeCode(5, 4, getKeyUnits));

  final classDataOff = dataOff + data.length;
  addUleb(data, 1);
  addUleb(data, 0);
  addUleb(data, 3);
  addUleb(data, 0);
  addUleb(data, 0);
  addUleb(data, 0x0008);
  final direct = [
    (mClinit, 0x10008, clinitOff),
    (mInit, 0x10001, initOff),
    (mGetKey, 0x0009, getKeyOff),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  var prevM = 0;
  for (final m in direct) {
    addUleb(data, m.$1 - prevM);
    addUleb(data, m.$2);
    addUleb(data, m.$3);
    prevM = m.$1;
  }

  final dataBytes = data.toBytes();
  final totalLen = dataOff + dataBytes.length;
  final dex = Uint8List(totalLen);
  dex.setRange(0, 8, utf8.encode('dex\n035\x00'));
  final hdr = ByteData.sublistView(dex);
  hdr
    ..setUint32(0x20, totalLen, Endian.little)
    ..setUint32(0x24, 0x70, Endian.little)
    ..setUint32(0x28, 0x12345678, Endian.little)
    ..setUint32(0x38, strings.length, Endian.little)
    ..setUint32(0x3c, strIdsOff, Endian.little)
    ..setUint32(0x40, types.length, Endian.little)
    ..setUint32(0x44, typeIdsOff, Endian.little)
    ..setUint32(0x48, protos.length, Endian.little)
    ..setUint32(0x4c, protoIdsOff, Endian.little)
    ..setUint32(0x50, fields.length, Endian.little)
    ..setUint32(0x54, fieldIdsOff, Endian.little)
    ..setUint32(0x58, methods.length, Endian.little)
    ..setUint32(0x5c, methodIdsOff, Endian.little)
    ..setUint32(0x60, 1, Endian.little)
    ..setUint32(0x64, classDefsOff, Endian.little)
    ..setUint32(0x68, dataBytes.length, Endian.little)
    ..setUint32(0x6c, dataOff, Endian.little);
  for (var i = 0; i < strDataOffs.length; i++) {
    hdr.setUint32(strIdsOff + i * 4, strDataOffs[i], Endian.little);
  }
  for (var i = 0; i < types.length; i++) {
    hdr.setUint32(typeIdsOff + i * 4, sIdx[types[i]]!, Endian.little);
  }
  for (var i = 0; i < protos.length; i++) {
    hdr
      ..setUint32(protoIdsOff + i * 12, protos[i].$1, Endian.little)
      ..setUint32(protoIdsOff + i * 12 + 4, protos[i].$2, Endian.little)
      ..setUint32(
          protoIdsOff + i * 12 + 8, protoParamOffs[i] ?? 0, Endian.little);
  }
  for (var i = 0; i < fields.length; i++) {
    hdr
      ..setUint16(fieldIdsOff + i * 8, fields[i].$1, Endian.little)
      ..setUint16(fieldIdsOff + i * 8 + 2, fields[i].$2, Endian.little)
      ..setUint32(fieldIdsOff + i * 8 + 4, fields[i].$3, Endian.little);
  }
  for (var i = 0; i < methods.length; i++) {
    hdr
      ..setUint16(methodIdsOff + i * 8, methods[i].$1, Endian.little)
      ..setUint16(methodIdsOff + i * 8 + 2, methods[i].$2, Endian.little)
      ..setUint32(methodIdsOff + i * 8 + 4, methods[i].$3, Endian.little);
  }
  hdr
    ..setUint32(classDefsOff, tIdx['Lcom/github/catvod/spider/WoGG;']!,
        Endian.little)
    ..setUint32(classDefsOff + 4, 1, Endian.little)
    ..setUint32(classDefsOff + 8, tIdx['Ljava/lang/Object;']!, Endian.little)
    ..setUint32(classDefsOff + 16, 0xffffffff, Endian.little)
    ..setUint32(classDefsOff + 24, classDataOff, Endian.little);
  dex.setRange(dataOff, totalLen, dataBytes);
  return dex;
}

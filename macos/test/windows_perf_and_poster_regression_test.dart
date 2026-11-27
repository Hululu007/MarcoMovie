import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/core/local_media_proxy.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/poster_image.dart';

class _StreamingMockClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
      _handler;

  _StreamingMockClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

void main() {
  group('Poster accuracy & celebrity/avatar rejection regressions', () {
    test('rejects Douban personage/celebrity and streamer avatar image URLs',
        () {
      expect(
        PosterLoader.isPersonOrAvatarImageUrl(
          'https://img2.doubanio.com/view/personage/m/public/10b21dff10ff2abb5ed10e3a8009ef6e.jpg',
        ),
        isTrue,
      );
      expect(
        PosterLoader.isPersonOrAvatarImageUrl(
          'https://img1.doubanio.com/view/celebrity/s_ratio_celebrity/public/p12345.jpg',
        ),
        isTrue,
      );
      expect(
        PosterLoader.isPersonOrAvatarImageUrl(
          'https://lain.bgm.tv/pic/crt/l/12/34/5678_crt_abcd.jpg',
        ),
        isTrue,
      );
      expect(
        PosterLoader.isPersonOrAvatarImageUrl(
          'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2912345678.jpg',
        ),
        isFalse,
      );
      expect(
        PosterLoader.isPersonOrAvatarImageUrl(
          'https://media.example/posters/guyu-2026-official.jpg',
        ),
        isFalse,
      );
    });

    test(
        'Douban subject_suggest drops celebrity personage and stale-year items for 谷雨 (2026)',
        () {
      final suggestPayload = <Map<String, Object?>>[
        {
          'type': 'celebrity',
          'title': '谷雨',
          'sub_title': 'Gu Yu',
          'img':
              'https://img2.doubanio.com/view/personage/m/public/10b21dff10ff2abb5ed10e3a8009ef6e.jpg',
          'url': 'https://movie.douban.com/celebrity/1500000/',
        },
        {
          'type': 'movie',
          'title': '谷雨',
          'year': '2010',
          'img':
              'https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2010000001.jpg',
          'url': 'https://movie.douban.com/subject/4000001/',
        },
        {
          'type': 'tv',
          'title': '谷雨',
          'year': '2026',
          'img':
              'https://img1.doubanio.com/view/photo/s_ratio_poster/public/p2926000016.jpg',
          'url': 'https://movie.douban.com/subject/36800016/',
        },
      ];

      final urls = PosterLoader.parseDoubanSuggestCoverUrls(
        suggestPayload,
        '谷雨',
        year: '2026',
      );

      expect(urls, [
        'https://img1.doubanio.com/view/photo/l_ratio_poster/public/p2926000016.jpg',
      ]);
    });

    test(
        'encyclopedia filter rejects people/solar-terms and preserves period-setting dramas',
        () {
      expect(
        PosterLoader.isFilmOrTvEncyclopediaEntry(
          abstractText: '谷雨，游戏主播、赛事解说，活跃于各大直播平台。',
          descText: '电竞主播',
          targetYear: 2026,
        ),
        isFalse,
      );
      expect(
        PosterLoader.isFilmOrTvEncyclopediaEntry(
          abstractText: '谷雨是二十四节气的第六个节气，春季最后一个节气。',
          descText: '二十四节气之一',
          targetYear: 2026,
        ),
        isFalse,
      );
      expect(
        PosterLoader.isFilmOrTvEncyclopediaEntry(
          abstractText: '《谷雨》是由导演执导，于2018年首播的都市情感电视剧。',
          descText: '2018年电视剧',
          targetYear: 2026,
        ),
        isFalse,
      );
      // 2026 drama《谷雨》plot starts with historical setting year "1994年"
      expect(
        PosterLoader.isFilmOrTvEncyclopediaEntry(
          abstractText:
              '《谷雨》是由井柏然、孙艺洲、张颂文领衔主演的电视剧。1994年，香江市税务局稽查员欧阳旭与刑警严平安因一起假发票案识于微时。',
          descText: '2026年中国内地电视剧',
          targetYear: 2026,
        ),
        isTrue,
      );
    });

    test('peekMemory never shadows a live CMS poster URL with title-only cache',
        () {
      const liveCmsUrl = 'https://media.example/cms/guyu-2026-cover.jpg';
      // Even when a title lookup has not cached liveCmsUrl yet, peekMemory must
      // return null so PosterImage fetches liveCmsUrl first.
      expect(
        PosterLoader.peekMemory(liveCmsUrl, title: '谷雨', year: '2026'),
        isNull,
      );
    });
  });

  group('Zero-pause 4K binary streaming in LocalMediaLease & CloudMediaLease',
      () {
    HttpOverrides? savedOverrides;

    setUp(() {
      savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
    });

    tearDown(() {
      HttpOverrides.global = savedOverrides;
    });

    test(
        'LocalMediaLease streams multi-megabyte chunked MKV payload without dropping bytes',
        () async {
      const chunkSize = 64 * 1024;
      const chunkCount = 80; // 5 MiB (> 4 MiB flush threshold)
      final expected = Uint8List(chunkSize * chunkCount);
      // Valid Matroska EBML header signature (0x1A 0x45 0xDF 0xA3)
      expected[0] = 0x1A;
      expected[1] = 0x45;
      expected[2] = 0xDF;
      expected[3] = 0xA3;
      for (var i = 4; i < expected.length; i++) {
        expected[i] = (i * 31 + 7) & 0xFF;
      }

      String? capturedRange;
      final upstreamClient = _StreamingMockClient((request) async {
        capturedRange = request.headers['range'] ?? request.headers['Range'];
        Stream<List<int>> bodyStream() async* {
          for (var c = 0; c < chunkCount; c++) {
            final start = c * chunkSize;
            yield Uint8List.sublistView(expected, start, start + chunkSize);
            if (c % 16 == 0) {
              await Future<void>.delayed(Duration.zero);
            }
          }
        }

        return http.StreamedResponse(
          bodyStream(),
          206,
          contentLength: expected.length,
          headers: <String, String>{
            'content-type': 'video/x-matroska',
            'accept-ranges': 'bytes',
            'content-range':
                'bytes 0-${expected.length - 1}/${expected.length}',
          },
        );
      });

      final lease = await LocalMediaLease.open(
        target: Uri.parse('https://media.example/4k/guyu_ep16_hevc.mkv'),
        headers: const {'Referer': 'https://media.example/'},
        isCancelled: () => false,
        client: upstreamClient,
      );
      addTearDown(lease.close);

      final req = http.Request('GET', lease.url)
        ..headers['Range'] = 'bytes=0-${expected.length - 1}';
      final downstreamClient = http.Client();
      addTearDown(downstreamClient.close);

      final res = await downstreamClient.send(req);
      expect(res.statusCode, 206);
      expect(res.headers['accept-ranges'], 'bytes');
      final received = await res.stream.toBytes();
      expect(capturedRange, 'bytes=0-${expected.length - 1}');
      expect(received.length, expected.length);
      expect(received.sublist(0, 64), expected.sublist(0, 64));
      expect(
        received.sublist(received.length - 64),
        expected.sublist(expected.length - 64),
      );
    });

    test('LocalMediaLease still rewrites HLS #EXTM3U playlists cleanly',
        () async {
      const m3u8 = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXTINF:6.0,\n'
          'seg_0001.ts\n'
          '#EXT-X-ENDLIST\n';

      final upstreamClient = _StreamingMockClient((request) async {
        final bytes = utf8.encode(m3u8);
        return http.StreamedResponse(
          Stream<List<int>>.value(bytes),
          200,
          contentLength: bytes.length,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
        );
      });

      final lease = await LocalMediaLease.open(
        target: Uri.parse('https://media.example/live/index.m3u8'),
        headers: const {},
        isCancelled: () => false,
        client: upstreamClient,
      );
      addTearDown(lease.close);

      final response = await http.get(lease.url);
      expect(response.statusCode, 200);
      expect(response.body, contains('#EXTM3U'));
      expect(response.body, contains('http://127.0.0.1:'));
      expect(response.body, isNot(contains('\nseg_0001.ts')));
    });

    test(
        'CloudMediaLease streams 5 MiB 206 range slices end-to-end without stalls',
        () async {
      const totalBytes = 5 * 1024 * 1024;
      final payload = Uint8List(totalBytes);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i * 17 + 3) & 0xFF;
      }

      final upstreamClient = _StreamingMockClient((request) async {
        Stream<List<int>> chunked() async* {
          const step = 128 * 1024;
          for (var offset = 0; offset < payload.length; offset += step) {
            final end = (offset + step < payload.length)
                ? offset + step
                : payload.length;
            yield Uint8List.sublistView(payload, offset, end);
          }
        }

        return http.StreamedResponse(
          chunked(),
          206,
          contentLength: payload.length,
          headers: <String, String>{
            'content-type': 'video/mp4',
            'accept-ranges': 'bytes',
            'content-range': 'bytes 0-${payload.length - 1}/${payload.length}',
          },
        );
      });

      final lease = await CloudMediaLease.open(
        target: Uri.parse('https://drive-pc.quark.cn/stream/4k.mp4'),
        provider: CloudMediaProvider.quark,
        headers: const {'Cookie': 'k=v'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: upstreamClient,
      );
      addTearDown(lease.close);

      final req = http.Request('GET', lease.url)
        ..headers['Range'] = 'bytes=0-${payload.length - 1}';
      final client = CloudMediaLease.createDefaultMediaClient();
      addTearDown(client.close);

      final resp = await client.send(req);
      expect(resp.statusCode, 206);
      final body = await resp.stream.toBytes();
      expect(body.length, payload.length);
      expect(body.sublist(0, 32), payload.sublist(0, 32));
      expect(
        body.sublist(body.length - 32),
        payload.sublist(payload.length - 32),
      );
    });
  });

  group('Windows desktop UI animation & BackdropFilter fast-path', () {
    testWidgets(
        'disables expensive per-surface BackdropFilter and uses lightweight route transition on Windows',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(isWindowsDesktopUi, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.windows: WindowsSmoothPageTransitionsBuilder(),
                },
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const LiquidGlass(
                      borderRadius: 20,
                      child: SizedBox(
                        width: 120,
                        height: 48,
                        child: Center(child: Text('Glass Pill')),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          buildApplePageRoute<void>(
                            builder: (_) => const Scaffold(
                              body: Center(child: Text('Second Screen')),
                            ),
                          ),
                        );
                      },
                      child: const Text('Push Detail'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final backdropFilters =
            tester.widgetList<BackdropFilter>(find.byType(BackdropFilter));
        expect(backdropFilters, isNotEmpty);
        for (final bf in backdropFilters) {
          expect(bf.enabled, isFalse);
        }

        await tester.tap(find.text('Push Detail'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(find.byType(CupertinoPageTransition), findsNothing);
        await tester.pumpAndSettle();
        expect(find.text('Second Screen'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('preserves CupertinoPageRoute and BackdropFilter on iOS',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(isWindowsDesktopUi, isFalse);

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const LiquidGlass(
                      borderRadius: 20,
                      child: SizedBox(width: 100, height: 40),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          buildApplePageRoute<void>(
                            builder: (_) => const Scaffold(
                              body: Center(child: Text('iOS Screen')),
                            ),
                          ),
                        );
                      },
                      child: const Text('Go iOS'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final backdropFilters =
            tester.widgetList<BackdropFilter>(find.byType(BackdropFilter));
        expect(backdropFilters.any((bf) => bf.enabled), isTrue);

        await tester.tap(find.text('Go iOS'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(CupertinoPageTransition), findsWidgets);
        await tester.pumpAndSettle();
        expect(find.text('iOS Screen'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

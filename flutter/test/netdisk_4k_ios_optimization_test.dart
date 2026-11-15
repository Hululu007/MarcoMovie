import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/core/cloud_share.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/netdisk_range_proxy.dart';
import 'package:marco_movie/core/quark_drive.dart';
import 'package:marco_movie/core/wogg_netdisk_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('CmsDohResolver DNS resilience & TLS SNI', () {
    test('uses system DNS first and falls back to DoH with CNAME resolution',
        () async {
      var dohCalls = 0;
      final systemFirst = CmsDohResolver(
        systemLookup: (host) async => [InternetAddress('203.0.113.10')],
        client: MockClient((_) async {
          dohCalls++;
          return http.Response('{}', 500);
        }),
      );
      final direct = await systemFirst.resolve('vod.provider-node.net');
      expect(direct.single.address, '203.0.113.10');
      expect(dohCalls, 0);

      final dohQueries = <Uri>[];
      final fallback = CmsDohResolver(
        systemLookup: (_) async =>
            throw const SocketException('DNS poisoned'),
        client: MockClient((request) async {
          dohQueries.add(request.url);
          final type = request.url.queryParameters['type'];
          if (type == 'A') {
            return http.Response(
              jsonEncode({
                'Status': 0,
                'TC': false,
                'Answer': [
                  {
                    'name': 'vod.provider-node.net.',
                    'type': 5,
                    'TTL': 120,
                    'data': 'cdn.provider-node.net.',
                  },
                  {
                    'name': 'cdn.provider-node.net.',
                    'type': 1,
                    'TTL': 90,
                    'data': '198.51.100.42',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({'Status': 0, 'TC': false, 'Answer': []}),
            200,
          );
        }),
      );
      final resolved = await fallback.resolve('vod.provider-node.net');
      expect(resolved.map((a) => a.address), ['198.51.100.42']);
      expect(dohQueries, isNotEmpty);

      dohQueries.clear();
      await expectLater(
        fallback.resolve('nas.local'),
        throwsA(isA<SocketException>()),
      );
      expect(dohQueries, isEmpty,
          reason: 'Private .local names must never leak to public DoH');
    });

    test('connect upgrades https:// sockets via TLS with original SNI host',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final clientHelloFuture = Completer<Uint8List>();
      server.listen((socket) {
        final collected = BytesBuilder(copy: false);
        socket.listen(
          (chunk) {
            collected.add(chunk);
            if (!clientHelloFuture.isCompleted && collected.length >= 64) {
              clientHelloFuture.complete(collected.takeBytes());
              socket.destroy();
            }
          },
          onDone: () {
            if (!clientHelloFuture.isCompleted) {
              clientHelloFuture.complete(collected.takeBytes());
            }
          },
          onError: (_) {},
        );
      });

      final resolver = CmsDohResolver(
        systemLookup: (_) async => [InternetAddress.loopbackIPv4],
      );
      final ioHttp = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = resolver.connect;
      final ioClient = IOClient(ioHttp);
      addTearDown(ioClient.close);

      await expectLater(
        ioClient.get(
          Uri.parse('https://sni-check.invalid:${server.port}/api'),
        ),
        throwsA(anything),
      );

      final hello =
          await clientHelloFuture.future.timeout(const Duration(seconds: 5));
      expect(hello, isNotEmpty);
      expect(hello[0], 0x16, reason: 'First byte must be TLS Handshake (0x16)');
      final asciiHello = latin1.decode(hello, allowInvalid: true);
      expect(asciiHello, contains('sni-check.invalid'));
    });
  });

  group('CloudMediaLease 6-worker concurrent Range & 40 GiB MKV seek preemption',
      () {
    test(
        'reassembles out-of-order 6-worker chunks byte-for-byte and strips Ali credentials',
        () async {
      const chunkSize = 64 * 1024;
      const totalSize = chunkSize * 8 + 12345;
      final sourceBytes = Uint8List.fromList(
        List<int>.generate(totalSize, (i) => (i * 31 + 17) & 0xff),
      );
      final expectedSha = sha256.convert(sourceBytes).toString();
      var maxInFlight = 0;
      var currentInFlight = 0;
      final seenRanges = <String>[];

      final lease = await CloudMediaLease.open(
        target: Uri.parse('https://cdn.aliyundrive.net/4k/remux.mkv'),
        provider: CloudMediaProvider.ali,
        headers: const {
          'Referer': 'https://www.aliyundrive.com/',
          'User-Agent': 'Mozilla/5.0',
          'Authorization': 'Bearer must-not-leak',
          'Cookie': 'secret=must-not-leak',
        },
        isCancelled: () => false,
        isCurrent: () async => true,
        chunkWorkers: 6,
        chunkSize: chunkSize,
        client: MockClient((request) async {
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(request.headers.containsKey('cookie'), isFalse);
          expect(request.headers['referer'], 'https://www.aliyundrive.com/');
          final range = request.headers['range']!;
          seenRanges.add(range);
          final m = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
          final start = int.parse(m.group(1)!);
          final end = min(int.parse(m.group(2)!), totalSize - 1);
          currentInFlight++;
          maxInFlight = max(maxInFlight, currentInFlight);
          // Reverse completion order so chunk 6 finishes before chunk 1.
          final chunkIdx = start ~/ chunkSize;
          final delayMs = (8 - (chunkIdx % 8)) * 8;
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          currentInFlight--;
          return http.Response.bytes(
            Uint8List.sublistView(sourceBytes, start, end + 1),
            206,
            headers: {
              'content-type': 'video/x-matroska',
              'accept-ranges': 'bytes',
              'content-range': 'bytes $start-$end/$totalSize',
            },
          );
        }),
      );

      try {
        final response =
            await http.get(lease.url, headers: const {'Range': 'bytes=0-'});
        expect(response.statusCode, 206);
        expect(
          response.headers['content-range'],
          'bytes 0-${totalSize - 1}/$totalSize',
        );
        expect(response.bodyBytes.length, totalSize);
        expect(sha256.convert(response.bodyBytes).toString(), expectedSha);
        expect(maxInFlight, greaterThan(1),
            reason: 'Multiple Range workers must run concurrently');
        expect(seenRanges.length, 9);
        expect(lease.peakBufferedBytes,
            lessThanOrEqualTo(CloudMediaLease.maxBufferedBytes));
        expect(lease.bufferedBytes, 0);
      } finally {
        await lease.close();
      }
    });

    test(
        '40 GiB MKV head probe -> tail Cues seek cancels stale workers and stays under 24 MiB',
        () async {
      const virtual40GiB = 40 * 1024 * 1024 * 1024;
      const chunkSize = 256 * 1024;
      var cancelledStreams = 0;

      final client = _Virtual40GiBClient(
        totalSize: virtual40GiB,
        onCancel: () => cancelledStreams++,
      );
      final lease = await CloudMediaLease.open(
        target: Uri.parse('https://dl.quark.cn/remux/40gb.mkv'),
        provider: CloudMediaProvider.quark,
        headers: const {'Cookie': '__puus=ok'},
        isCancelled: () => false,
        isCurrent: () async => true,
        chunkWorkers: 6,
        chunkSize: chunkSize,
        client: client,
      );

      try {
        // 1. Head EBML/SeekHead probe at offset 0, reading 32 KiB then aborting.
        final io1 = HttpClient()..findProxy = (_) => 'DIRECT';
        final req1 = await io1.getUrl(lease.url);
        req1.headers.set('Range', 'bytes=0-');
        final res1 = await req1.close();
        expect(res1.statusCode, 206);
        expect(
          res1.headers.value('content-range'),
          'bytes 0-${virtual40GiB - 1}/$virtual40GiB',
        );
        final headChunk = await res1.first;
        expect(headChunk, isNotEmpty);
        io1.close(force: true);

        // 2. Immediate tail Cues seek near 40 GiB EOF.
        const tailOffset = virtual40GiB - 131072;
        final tailRes = await http.get(
          lease.url,
          headers: const {'Range': 'bytes=$tailOffset-'},
        );
        expect(tailRes.statusCode, 206);
        expect(tailRes.bodyBytes.length, 131072);
        expect(tailRes.bodyBytes.first, tailOffset & 0xff);

        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(cancelledStreams, greaterThanOrEqualTo(1));
        expect(lease.bufferedBytes, 0);
        expect(
          lease.peakBufferedBytes,
          lessThanOrEqualTo(CloudMediaLease.maxBufferedBytes),
        );
      } finally {
        await lease.close();
      }
    });
  });

  group('NetdiskRangeProxy standalone 6-worker loopback server', () {
    test('preempts old window on 40 GiB tail seek and enforces 24 MiB cap',
        () async {
      const virtualSize = 40 * 1024 * 1024 * 1024;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((req) async {
        final m = RegExp(r'^bytes=(\d+)-(\d+)$')
            .firstMatch(req.headers.value('range') ?? '');
        if (m == null) {
          req.response.statusCode = 416;
          await req.response.close();
          return;
        }
        final start = int.parse(m.group(1)!);
        final end = min(int.parse(m.group(2)!), virtualSize - 1);
        final len = end - start + 1;
        req.response.statusCode = 206;
        req.response.headers
          ..set('Content-Type', 'video/x-matroska')
          ..set('Accept-Ranges', 'bytes')
          ..set('Content-Range', 'bytes $start-$end/$virtualSize');
        req.response.contentLength = len;
        if (start < virtualSize - 1024 * 1024 && start > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        req.response.add(
          Uint8List.fromList(
            List<int>.generate(len, (i) => (start + i) & 0xff),
          ),
        );
        try {
          await req.response.close();
        } catch (_) {}
      });

      final proxy = NetdiskRangeProxy(workers: 6, chunkSize: 128 * 1024);
      addTearDown(proxy.close);
      final localUri = await proxy.register(
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}/4k.mkv'),
        policy: NetdiskHeaderPolicy(),
        length: virtualSize,
        contentType: 'video/x-matroska',
      );

      final io = HttpClient()..findProxy = (_) => 'DIRECT';
      final r1 = await io.getUrl(localUri);
      r1.headers.set('Range', 'bytes=0-');
      final res1 = await r1.close();
      expect(res1.statusCode, 206);
      await res1.first;
      io.close(force: true);

      const tailStart = virtualSize - 65536;
      final io2 = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => io2.close(force: true));
      final r2 = await io2.getUrl(localUri);
      r2.headers.set('Range', 'bytes=$tailStart-');
      final res2 = await r2.close();
      expect(res2.statusCode, 206);
      final tailBytes =
          await res2.fold<List<int>>(<int>[], (acc, part) => acc..addAll(part));
      expect(tailBytes.length, 65536);
      expect(tailBytes.first, tailStart & 0xff);
      expect(proxy.cancelledWindows, greaterThanOrEqualTo(1));
      expect(proxy.peakBufferedBytes,
          lessThanOrEqualTo(NetdiskRangeProxy.memoryLimit));
    });
  });

  group('CmsClient raw netdisk share expansion & smart episode matching', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
        'expands raw https://drive.uc.cn/s/... links in type-1 CMS detail and matches episode number on playback',
        () async {
      const cmsSite = CmsSite(
        key: 'raw_pan_cms',
        name: '4K网盘资源站',
        type: 1,
        api: 'https://cms-pan.invalid/api.php/provide/vod/',
      );
      final transport = MockClient((request) async {
        if (request.url.host == 'cms-pan.invalid') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'list': [
                {
                  'vod_id': '9001',
                  'vod_name': '测试4K剧集',
                  'vod_play_from': 'UC4K原盘',
                  'vod_play_url': '正片\$https://drive.uc.cn/s/ucraw4k',
                },
              ],
            })),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'pc-api.uc.cn') {
          if (request.url.path.endsWith('/token')) {
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'data': {'stoken': 'st-uc-1'},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/detail')) {
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'metadata': {'_total': 2},
                'data': {
                  'list': [
                    {
                      'fid': 'fid-ep1',
                      'file_name': 'Show.S01E01.2160p.HDR.mkv',
                      'size': 6442450944,
                      'file_type': 1,
                      'category': 1,
                      'share_fid_token': 'tok-ep1',
                    },
                    {
                      'fid': 'fid-ep2',
                      'file_name': 'Show.S01E02.2160p.HDR.mkv',
                      'size': 6442450944,
                      'file_type': 1,
                      'category': 1,
                      'share_fid_token': 'tok-ep2',
                    },
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          final body = jsonDecode(request.body) as Map;
          final fids = (body['fids'] as List).cast<String>();
          return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'data': [
                {
                  'download_url':
                      'https://media.invalid/${fids.single}.2160p.mkv',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });

      final client = CmsClient(client: transport);
      final detail = await client.fetchDetail(
        cmsSite,
        const CmsVideo(id: '9001', title: '测试4K剧集'),
      );
      expect(detail.lines, hasLength(1));
      expect(detail.lines.single.episodes, hasLength(2));
      expect(
        detail.lines.single.episodes.map((e) => e.name),
        ['Show.S01E01.2160p.HDR.mkv', 'Show.S01E02.2160p.HDR.mkv'],
      );

      // Direct playback on an unexpanded raw share URL with episode label 第02集
      // must pick S01E02 rather than defaulting to S01E01.
      final resolvedEp2 = await client.resolveEpisodeForPlayback(
        cmsSite,
        const CmsEpisode(
          name: '第02集',
          url: 'https://drive.uc.cn/s/ucraw4k',
        ),
      );
      expect(resolvedEp2.url, 'https://media.invalid/fid-ep2.2160p.mkv');
    });
  });

  group('WoggNetdiskAdapter configured WoGG-family spider support', () {
    test('fails over across configured mirrors and extracts multi-drive shares',
        () async {
      const zhizhenSite = CmsSite(
        key: 'zhizhen',
        name: '至臻4K',
        type: 3,
        api: 'csp_ZhiZhen',
        ext: '{"domains":["https://dead-mirror.invalid","https://live-mirror.invalid"]}',
      );
      expect(CspBridge.usesWoggNetdiskAdapter(zhizhenSite), isTrue);
      expect(zhizhenSite.canBrowse, isTrue);

      const detailHtml = '''
      <html><body>
        <h1>沙丘2 4K杜比视界</h1>
        <div class="module-play-list" data-title="第一季">
          <a href="https://pan.quark.cn/s/qk4kshare?pwd=abcd" title="4K REMUX"></a>
          <a data-clipboard-text="链接：https://www.alipan.com/s/ali4kshare 提取码：wxyz">原盘</a>
        </div>
      </body></html>
      ''';

      final detail = await CspBridge.fetchDetail(
        zhizhenSite,
        const CmsVideo(id: '108', title: '沙丘2'),
        (url, {headers = const {}, requestTimeout}) async {
          final uri = Uri.parse(url);
          if (uri.host == 'dead-mirror.invalid') {
            throw const SocketException('mirror down');
          }
          expect(uri.host, 'live-mirror.invalid');
          return detailHtml;
        },
      );

      expect(detail.lines.map((l) => l.name), ['4K 网盘 · 夸克', '4K 网盘 · 阿里云盘']);
      expect(
        detail.lines[0].episodes.single.url,
        'mmshare://https://pan.quark.cn/s/qk4kshare?pwd=abcd',
      );
      expect(
        detail.lines[1].episodes.single.url,
        'mmshare://https://www.alipan.com/s/ali4kshare?pwd=wxyz',
      );
    });
  });

  group('0.5.29 MacCMS 4K search card & share diagnostics regressions', () {
    test(
      'Quark public share classifies HTTP 404 41011/41012 as expired and .zip-only share as archive_only',
      () async {
        for (final entry in const [
          (41011, '分享地址已失效'),
          (41012, '好友已取消了分享'),
        ]) {
          final deadClient = MockClient(
            (_) async => http.Response(
              jsonEncode({
                'status': 404,
                'code': entry.$1,
                'message': entry.$2,
              }),
              404,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          );
          await expectLater(
            QuarkDriveClient.listPublicShareEpisodes(
              'https://pan.quark.cn/s/dead4kshare',
              httpClient: deadClient,
            ),
            throwsA(
              isA<QuarkDriveException>()
                  .having((e) => e.code, 'code', 'share_expired')
                  .having(
                    (e) => e.message,
                    'message',
                    '原夸克分享链接已取消或已失效',
                  ),
            ),
          );
        }

        final archiveClient = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'data': {'stoken': 'temp-stoken'},
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'metadata': {'_total': 2},
              'data': {
                'list': [
                  {
                    'fid': 'zip1',
                    'file_name': 'S01E01.2160p.HDR.zip',
                    'file_type': 1,
                    'category': 4,
                  },
                  {
                    'fid': 'zip2',
                    'file_name': 'S01E02.2160p.HDR.7z',
                    'file_type': 1,
                    'category': 4,
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });

        await expectLater(
          QuarkDriveClient.listPublicShareEpisodes(
            'https://pan.quark.cn/s/archive4k',
            httpClient: archiveClient,
          ),
          throwsA(
            isA<QuarkDriveException>()
                .having((e) => e.code, 'code', 'archive_only')
                .having((e) => e.message, 'message', contains('仅含压缩包')),
          ),
        );
      },
    );

    test(
      'UC share token HTTP 404 reports expired share instead of raw 404 status',
      () async {
        final cloud = CloudShareClient(
          credentialReader: (_) async => '',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'status': 404,
                'code': 41011,
                'message': '好友已取消了分享',
              }),
              404,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
        addTearDown(cloud.close);

        await expectLater(
          cloud.listShare('https://drive.uc.cn/s/deaducshare'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              '原 UC 分享链接已取消或已失效',
            ),
          ),
        );
      },
    );

    test(
      'CmsClient expands live Baidu 4K share while surfacing accurate dead/empty warnings on sibling shares',
      () async {
        final transport = MockClient((request) async {
          if (request.url.host == 'cms.example') {
            return http.Response(
              jsonEncode({
                'list': [
                  {
                    'vod_id': '501167',
                    'vod_name': '古装4K测试剧',
                    'vod_play_from': '百度网盘\$\$\$夸克网盘\$\$\$UC网盘',
                    'vod_play_url':
                        '分享1\$mmshare://https://pan.baidu.com/s/1livebaidu4k?pwd=8888\$\$\$'
                        '分享1\$mmshare://https://pan.quark.cn/s/deadquark4k\$\$\$'
                        '分享1\$mmshare://https://drive.uc.cn/s/emptyuc4k',
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.host == 'pan.baidu.com') {
            if (request.url.path.startsWith('/s/')) {
              return http.Response('ok', 200);
            }
            if (request.url.path == '/share/verify') {
              return http.Response(
                jsonEncode({'errno': 0, 'randsk': 'bd-randsk'}),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            final dir = request.url.queryParameters['dir'];
            return http.Response(
              jsonEncode({
                'errno': 0,
                'uk': '10001',
                'share_id': '20002',
                'list': dir == null
                    ? [
                        {
                          'fs_id': 'season1',
                          'isdir': 1,
                          'server_filename': '第 1 季',
                          'path': '/剧集/TEST4K/第 1 季',
                        },
                      ]
                    : [
                        for (var ep = 1; ep <= 3; ep++)
                          {
                            'fs_id': 'ep-$ep',
                            'isdir': 0,
                            'category': 1,
                            'server_filename':
                                'TEST4K.S01E0$ep.2160p.HDR.mkv',
                            'size': 5368709120,
                            'path':
                                '/剧集/TEST4K/第 1 季/TEST4K.S01E0$ep.2160p.HDR.mkv',
                          },
                      ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.host == 'drive-pc.quark.cn') {
            return http.Response(
              jsonEncode({
                'status': 404,
                'code': 41011,
                'message': '分享地址已失效',
              }),
              404,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.host == 'pc-api.uc.cn') {
            if (request.url.path.endsWith('/token')) {
              return http.Response(
                jsonEncode({
                  'status': 200,
                  'code': 0,
                  'data': {'stoken': 'uc-stoken'},
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'metadata': {'_total': 0},
                'data': {'list': const <Object>[]},
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          throw StateError('Unexpected host: ${request.url}');
        });

        final cms = CmsClient(client: transport);
        final detail = await cms.fetchDetail(
          const CmsSite(
            key: 'huban_json_fixture',
            name: '4K测试站',
            type: 1,
            api: 'https://cms.example/api.php/provide/vod/',
          ),
          const CmsVideo(id: '501167', title: '古装4K测试剧'),
        );

        expect(detail.lines, hasLength(1));
        expect(detail.lines.single.name, '百度网盘');
        expect(detail.lines.single.episodes, hasLength(3));
        expect(
          detail.lines.single.episodes.first.url,
          startsWith('mmcloud://baidu?'),
        );
        expect(
          detail.sourceWarnings,
          containsAll(<String>[
            '夸克网盘：原夸克分享链接已取消或已失效',
            'UC网盘：该网盘分享目录为空，暂无可播放视频',
          ]),
        );
      },
    );

    test(
      'WoggSource classifies dead Quark 404 and archive-only shares as source share expired instead of blaming user login',
      () async {
        const woggHtml = '''
        <title>玩偶共享站</title>
        <div class="video-info"><div class="video-info-header"><h1>臻彩测试剧</h1></div></div>
        <div class="video-cover"><div class="module-item-pic"><img alt="臻彩测试剧" data-src="/poster.jpg"></div></div>
        <div class="module-tab-item downtab-item">夸克</div>
        <div class="module-downlist"><div class="module-row-info">
          <a data-clipboard-text="https://pan.quark.cn/s/deadqk1"></a>
          <a data-clipboard-text="https://pan.quark.cn/s/ziponly1"></a>
        </div></div>
        ''';
        final transport = MockClient((request) async {
          if (request.url.host == 'wogg.example') {
            return http.Response.bytes(utf8.encode(woggHtml), 200);
          }
          if (request.url.host == 'drive-pc.quark.cn') {
            if (request.url.path.endsWith('/token')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              if (body['pwd_id'] == 'deadqk1') {
                return http.Response(
                  jsonEncode({
                    'status': 404,
                    'code': 41011,
                    'message': '分享地址已失效',
                  }),
                  404,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }
              return http.Response(
                jsonEncode({
                  'status': 200,
                  'code': 0,
                  'data': {'stoken': 'zip-token'},
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'metadata': {'_total': 1},
                'data': {
                  'list': [
                    {
                      'fid': 'z1',
                      'file_name': 'anti_dmca_pack.zip',
                      'file_type': 1,
                      'category': 4,
                    },
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          throw StateError('Unexpected host: ${request.url}');
        });

        final cms = CmsClient(client: transport);
        await expectLater(
          cms.fetchDetail(
            const CmsSite(
              key: 'wogg_test',
              name: '玩偶测试',
              type: 3,
              api: 'csp_WoGGGuard',
              ext: '{"siteUrl":"https://wogg.example"}',
            ),
            const CmsVideo(id: '131202', title: '臻彩测试剧'),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              '原站网盘分享链接已失效或目录为空，请尝试搜索其他片源',
            ),
          ),
        );
      },
    );

    test(
      'WoggNetdiskAdapter and DRPY MacCMS pan adapters extract detail href and clean title from .module-search-item',
      () async {
        const searchHtml = '''
        <!DOCTYPE html><html lang="zh-CN"><head><title>搜索结果测试剧</title></head>
        <body>
          <div class="module-search-item">
            <div class="video-cover">
              <div class="module-item-pic">
                <a href="/index.php/vod/play/id/501167/sid/1/nid/1.html" title="立刻播放">立刻播放</a>
                <img data-src="/upload/vod/poster501167.jpg" alt="剧集测试名">
              </div>
            </div>
            <div class="video-info">
              <div class="video-info-header">
                <a class="video-serial" href="/index.php/vod/play/id/501167/sid/1/nid/1.html">全47集</a>
                <h3><a href="/index.php/vod/detail/id/501167.html" title="剧集测试名">剧集测试名</a></h3>
              </div>
            </div>
          </div>
        </body></html>
        ''';

        final dartListing = WoggNetdiskAdapter.parseListing(
          searchHtml,
          Uri.parse('https://pan-cms.example/index.php/vod/search.html'),
        );
        expect(dartListing.videos, hasLength(1));
        expect(
          dartListing.videos.single.id,
          'https://pan-cms.example/index.php/vod/detail/id/501167.html',
        );
        expect(dartListing.videos.single.title, '剧集测试名');
        expect(dartListing.videos.single.remarks, '全47集');

        // Also verify shared/catpaw/drpy-wex-pan-adapter.cjs in Node VM when available.
        ProcessResult? nodeProbe;
        try {
          nodeProbe = await Process.run('node', ['--version']);
        } catch (_) {
          nodeProbe = null;
        }
        if (nodeProbe != null && nodeProbe.exitCode == 0) {
          final script = r'''
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const catpaw = path.resolve(process.cwd(), '..', 'shared', 'catpaw');
const deps = fs.readFileSync(path.join(catpaw, 'drpy-dependencies.js'), 'utf8');
const wexPan = require(path.join(catpaw, 'drpy-wex-pan-adapter.cjs'));
const ruleSrc = wexPan({ adapter: 'wexhuban-v1', origin: 'https://pan-cms.example', defaultHost: 'https://pan-cms.example', siteKey: '' });

const searchHtml = process.env.SEARCH_HTML;
const emptySearchHtml = '<!DOCTYPE html><html><head><title>搜索结果无匹配-站点</title></head><body><a href="/index.php/vod/type/id/1.html">电影</a><input id="verify" name="verify"></body></html>';
const detailHtml = '<html><body><h1 class="page-title">剧集测试名</h1><div class="module-row-one"><a data-clipboard-text="https://pan.baidu.com/s/1livebaidu4k?pwd=8888"><h4>百度4K</h4></a></div></body></html>';

const selectors = `
function selectHtml(html, parts) {
  const $ = DRPYDeps.cheerio.load(String(html || ''));
  let selected = $.root();
  for (const step of parts) {
    if (!step) continue;
    const cuts = step.split('--'), selector = cuts.shift().trim();
    if (selector && selector !== '*') selected = selected.find(selector);
    if (cuts.length) { selected = selected.clone(); for (const cut of cuts) selected.find(cut).remove(); }
  }
  return { $, selected };
}
globalThis.pdfa = (html, expression) => { const { $, selected } = selectHtml(html, String(expression).split('&&')); return selected.toArray().map(node => $.html(node)); };
globalThis.pdfh = (html, expression) => { const parts = String(expression).split('&&'); const field = parts.pop(); const { selected } = selectHtml(html, parts); const first = selected.first(); if (field === 'Text') return first.text().trim(); if (field === 'Html') return first.html() || ''; return first.attr(field) || ''; };
`;

const ctx = vm.createContext({
  console, setTimeout, clearTimeout, URL, Buffer, TextEncoder, TextDecoder,
  crypto: require('crypto').webcrypto,
  joinUrl: (base, rel) => new URL(rel, base).href,
  unsupportedFeature: (code) => { throw new Error(code); },
  local: { get: () => null, set: () => {} },
  nodeCipher: () => ({ data: '' }),
  req: (url) => {
    if (url.includes('/vod/detail/id/501167.html')) return { code: 200, content: detailHtml, headers: {} };
    if (url.includes('emptykw')) {
      if (url.includes('/vodsearch/')) return { code: 404, content: '404 Not Found', headers: {} };
      return { code: 200, content: emptySearchHtml, headers: {} };
    }
    return { code: 200, content: searchHtml, headers: {} };
  },
});
ctx.globalThis = ctx;
vm.runInContext(deps, ctx);
vm.runInContext(selectors, ctx);
ctx.__drpy = {};
vm.runInContext(ruleSrc + '\nrule._install();', ctx);

const s1 = ctx.__drpy.search('剧集测试名', false, 1);
const sEmpty = ctx.__drpy.search('emptykw', false, 1);
const dHeal = ctx.__drpy.detail('/index.php/vod/play/id/501167/sid/1/nid/1.html');
console.log(JSON.stringify({ s1, sEmpty, dHeal }));
''';
          final run = await Process.run(
            'node',
            ['-e', script],
            workingDirectory: Directory.current.path,
            environment: {'SEARCH_HTML': searchHtml},
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(run.exitCode, 0, reason: '${run.stderr}');
          final out =
              jsonDecode((run.stdout as String).trim()) as Map<String, dynamic>;
          final cards = (out['s1'] as Map)['list'] as List;
          expect(cards, hasLength(1));
          expect(cards.single['vod_id'], '/index.php/vod/detail/id/501167.html');
          expect(cards.single['vod_name'], '剧集测试名');
          expect(cards.single['vod_remarks'], '全47集');
          expect(((out['sEmpty'] as Map)['list'] as List), isEmpty);
          final healed = ((out['dHeal'] as Map)['list'] as List).single as Map;
          expect(healed['vod_play_from'], '百度网盘');
          expect(
            healed['vod_play_url'],
            contains('mmshare://https://pan.baidu.com/s/1livebaidu4k?pwd=8888'),
          );
        }
      },
    );
  });
}

class _Virtual40GiBClient extends http.BaseClient {
  _Virtual40GiBClient({required this.totalSize, required this.onCancel});

  final int totalSize;
  final void Function() onCancel;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final range = request.headers['range'] ?? '';
    final m = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    if (m == null) {
      return http.StreamedResponse(const Stream.empty(), 416);
    }
    final start = int.parse(m.group(1)!);
    final end = min(int.parse(m.group(2)!), totalSize - 1);
    final length = end - start + 1;
    final isTail = start >= totalSize - 1024 * 1024;
    late final StreamController<List<int>> controller;
    Timer? timer;
    var sent = 0;
    controller = StreamController<List<int>>(
      onListen: () {
        if (isTail) {
          controller.add(
            Uint8List.fromList(
              List<int>.generate(length, (i) => (start + i) & 0xff),
            ),
          );
          controller.close();
          return;
        }
        // Stream slowly in 16 KiB slices so aborting head probe cancels workers.
        void pushSlice() {
          if (controller.isClosed || controller.isPaused) return;
          final step = min(16384, length - sent);
          if (step <= 0) {
            timer?.cancel();
            controller.close();
            return;
          }
          controller.add(
            Uint8List.fromList(
              List<int>.generate(step, (i) => (start + sent + i) & 0xff),
            ),
          );
          sent += step;
          if (sent >= length) {
            timer?.cancel();
            controller.close();
          }
        }

        pushSlice();
        timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          pushSlice();
        });
      },
      onCancel: () {
        timer?.cancel();
        if (sent < length) {
          onCancel();
        }
      },
    );
    return http.StreamedResponse(
      controller.stream,
      206,
      contentLength: length,
      headers: {
        'content-type': 'video/x-matroska',
        'accept-ranges': 'bytes',
        'content-range': 'bytes $start-$end/$totalSize',
      },
    );
  }
}

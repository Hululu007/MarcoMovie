import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/netdisk_session.dart';
import 'package:marco_movie/core/wogg_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('desktop Baidu accepts official response cookies after QR confirmation',
      () async {
    final client =
        MockClient((request) async => request.url.host == 'pan.baidu.com'
            ? http.Response('{"errno":0,"user_info":{"uk":123}}', 200)
            : http.Response('{}', 200, headers: {
                'set-cookie':
                    'BDUSS=account-bduss; Domain=.baidu.com; Path=/; Secure, '
                        'STOKEN=account-stoken; Domain=.baidu.com; Path=/; Secure',
              }));
    expect(await NetdiskSession.exchangeBaidu(client, 'one-use-ticket'),
        'BDUSS=account-bduss; STOKEN=account-stoken');
  });

  test('desktop Baidu string status does not stay waiting after confirmation',
      () async {
    final service = NetdiskService(httpClient: MockClient((request) async {
      if (request.url.host == 'pan.baidu.com') {
        return http.Response('{"errno":0,"user_info":{"uk":123}}', 200);
      }
      if (request.url.path == '/channel/unicast') {
        return http.Response(
            jsonEncode({
              'errno': '0',
              'channel_v': {'status': '0', 'v': 'one-use-ticket'}
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'data': {
              'session': {'bduss': 'account-bduss', 'stoken': 'account-stoken'}
            }
          }),
          200);
    }));
    addTearDown(service.close);
    final result = await service.pollQrSession(NetdiskQrSession(
        driveKey: 'baidu',
        token: 'qr-ticket',
        qrContentUrl: '',
        qrImageUrl: ''));
    expect(result.state, NetdiskPollState.confirmed);
    expect(result.accountVerified, isTrue);
  });

  test('desktop original share tabs retain each cloud provider', () async {
    final source = WoggSource(
      read: (_, __) async => '''<html><title>玩偶共享站</title>
        <div class="video-info"><h1>Original file</h1></div>
        <div class="module-tab-item downtab-item">优汐1</div>
        <div class="module-tab-item downtab-item">夸克1</div>
        <div class="module-downlist">
          <div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/uc-share"></a></div>
          <div class="module-row-info"><a data-clipboard-text="https://pan.quark.cn/s/quark-share"></a></div>
        </div></html>''',
      readBytes: (_, __) async => throw StateError('No plugin needed'),
      listShare: (url) async => [
        CmsEpisode(
            name: 'Original.2160p.mkv',
            url: url.contains('quark')
                ? 'mmquark://share?share_id=quark-share&fid=original'
                : 'mmcloud://uc?share=uc-share&fid=original')
      ],
    );
    final result = jsonDecode(await source.invoke(
        CmsSite(
            key: 'wogg',
            name: 'WoGG',
            type: 3,
            api: 'csp_WoGG',
            ext: '{"siteUrl":"https://catalogue.invalid/"}'),
        'detail',
        ['42']));
    final lines = result['list'][0]['lines'] as List;
    expect(lines.map((line) => line['name']), ['优汐 1', '夸克 2']);
  });

  for (final validAccount in [true, false]) {
    test(
        'desktop Baidu completes BDUSS-only login only after account verification: $validAccount',
        () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.host == 'passport.baidu.com') {
          expect(request.url.queryParameters['u'],
              'https://pan.baidu.com/disk/home');
          return http.Response('{}', 200, headers: {
            'set-cookie':
                'BDUSS=account-bduss; Domain=.baidu.com; Path=/; Secure',
          });
        }
        expect(request.url.host, 'pan.baidu.com');
        expect(request.headers['Cookie'], contains('BDUSS=account-bduss'));
        if (request.url.path == '/disk/home') {
          return http.Response('', 302, headers: {
            'location': '/disk/main',
            'set-cookie': 'PANPSC=drive-only; Path=/; Secure'
          });
        }
        expect(request.headers['Cookie'], contains('PANPSC=drive-only'));
        if (request.url.path == '/rest/2.0/membership/user/info') {
          return http.Response(
              jsonEncode({
                'errno': validAccount ? 0 : -6,
                'user_info': {'uk': validAccount ? 123 : 0}
              }),
              200);
        }
        return http.Response('{}', 200);
      });
      final future = NetdiskSession.exchangeBaidu(client, 'one-use-ticket');
      if (validAccount) {
        expect(await future, 'BDUSS=account-bduss; PANPSC=drive-only');
      } else {
        await expectLater(future, throwsFormatException);
      }
      expect(paths, [
        '/v3/login/main/qrbdusslogin',
        '/disk/home',
        '/disk/main',
        '/api/loginStatus',
        '/rest/2.0/membership/user/info'
      ]);
    });
  }

  for (final matchCount in [0, 1, 2]) {
    test(
        'desktop legacy history resolves only a unique original catalogue match: $matchCount',
        () async {
      final requests = <Uri>[];
      const original = CmsSite(
          key: 'wogg',
          name: 'Original',
          api: 'csp_WoGG',
          type: 3,
          ext: '{"siteUrl":"https://catalogue.invalid/"}');
      final client = CmsClient(client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.host == 'catalogue.invalid') {
          final String html;
          if (request.url.path.contains('/vodsearch/')) {
            html = '<title>玩偶共享站</title><form id="search"></form>' +
                [
                  for (var i = 0; i < matchCount; i++)
                    '''
                  <div class="module-search-item"><div class="video-info-header">
                    <h3><a href="/voddetail/${42 + i}.html">Original file</a></h3>
                  </div></div>'''
                ].join();
          } else if (request.url.path == '/voddetail/42.html') {
            html =
                '''<title>玩偶共享站</title><div class="video-info"><h1>Original file</h1></div>
              <div class="module-row-info"><a data-clipboard-text="https://drive.uc.cn/s/original"></a></div>''';
          } else {
            html =
                '<title>玩偶共享站</title><div class="video-info"><h1>Different file</h1></div>';
          }
          return http.Response.bytes(utf8.encode(html), 200);
        }
        expect(request.url.host, 'pc-api.uc.cn');
        final data = request.url.path.endsWith('/token')
            ? {'stoken': 'fresh-token'}
            : {
                'list': [
                  {
                    'fid': 'original-file',
                    'file_name': 'Original.2160p.mkv',
                    'file_type': 1,
                    'category': 1,
                    'size': 8589934592,
                    'share_fid_token': 'fresh-file'
                  }
                ]
              };
        return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'metadata': {'_total': 1},
              'data': data
            }),
            200);
      }));
      final future = client.playableDetail(
          original, const CmsVideo(id: '999999', title: 'Original file'), []);
      if (matchCount == 1) {
        final (owner, video) = await future;
        expect(owner.key, original.key);
        expect(video.id, '42');
        expect(video.lines.single.episodes.single.cloudProvider, 'uc');
        expect(video.lines.single.episodes.single.name,
            contains('Original.2160p.mkv'));
      } else {
        await expectLater(future, throwsFormatException);
        expect(
            requests.every((uri) => uri.host == 'catalogue.invalid'), isTrue);
      }
      expect(requests.where((uri) => uri.path.contains('/vodsearch/')),
          hasLength(1));
    });
  }
}

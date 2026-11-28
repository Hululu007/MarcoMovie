import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/emby_library.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/poster_image.dart';

void main() {
  test(
    'Emby under a reverse proxy signs in and plays a series without exporting its token',
    () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final root = 'http://127.0.0.1:${server.port}/media';
      final reports = <Map<String, dynamic>>[];
      server.listen((r) async {
        final path = r.uri.path;
        final out = r.response;
        Object body = {};
        if (path == '/media/emby/Users/AuthenticateByName') {
          final input = jsonDecode(await utf8.decoder.bind(r).join());
          expect(input['Pw'], 'test-only-password');
          body = {
            'AccessToken': 'test-only-token',
            'User': {'Id': 'u1'},
          };
        } else if (path == '/public.png') {
          out.add(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWZkAAAAASUVORK5CYII=',
            ),
          );
          await out.close();
          return;
        } else if (r.headers.value('X-Emby-Token') != 'test-only-token') {
          out.statusCode = 401;
        } else if (path.endsWith('/PlaybackInfo')) {
          final input = jsonDecode(await utf8.decoder.bind(r).join());
          expect(r.method, 'POST');
          expect(input['UserId'], 'u1');
          expect(
            input['DeviceProfile']['TranscodingProfiles'].single['Protocol'],
            'hls',
          );
          final source = input['MediaSourceId'] ?? 'media1';
          body = source == 'denied'
              ? {'ErrorCode': 'NotAllowed'}
              : {
                  'PlaySessionId': 'session-$source',
                  'MediaSources': [
                    {
                      'Id': source == 'missing' ? 'another-version' : source,
                      'SupportsDirectStream': source == 'media1',
                      'SupportsTranscoding': true,
                      'RequiresOpening': source == 'opening',
                      'TranscodingUrl': source == 'foreign'
                          ? 'https://elsewhere.example/Videos/e1/master.m3u8'
                          : 'Videos/e1/master.m3u8?api_key=obsolete&VideoCodec=h264',
                    },
                  ],
                };
        } else if (path.contains('/Sessions/Playing')) {
          final input =
              jsonDecode(await utf8.decoder.bind(r).join())
                  as Map<String, dynamic>;
          reports.add({...input, 'path': path});
          out.statusCode = 204;
          await out.close();
          return;
        } else if (path.endsWith('/Images/Primary')) {
          out.headers.contentType = ContentType('image', 'png');
          out.add(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWZkAAAAASUVORK5CYII=',
            ),
          );
          await out.close();
          return;
        } else if (path.endsWith('/Views')) {
          body = {
            'Items': [
              {'Name': '剧集', 'Id': 'v1'},
            ],
          };
        } else if (path.endsWith('/Items')) {
          body = {
            'Items': [
              {'Name': '样片', 'Type': 'Series', 'Id': 's1'},
            ],
            'TotalRecordCount': 1,
          };
        } else if (path.endsWith('/Items/s1')) {
          body = {'Name': '样片', 'Type': 'Series', 'Id': 's1'};
        } else if (path.endsWith('/Episodes')) {
          body = {
            'Items': [
              {
                'Name': '第一集',
                'Id': 'e1',
                'ParentIndexNumber': 1,
                'IndexNumber': 1,
                'MediaSources': [
                  {'Id': 'media1'},
                ],
              },
            ],
            'TotalRecordCount': 1,
          };
        } else if (path.endsWith('/Videos/e1/stream')) {
          expect(r.uri.queryParameters['MediaSourceId'], 'media1');
          expect(r.uri.queryParameters['PlaySessionId'], isNotEmpty);
          body = {'stream': true};
        } else {
          out.statusCode = 404;
        }
        out.write(jsonEncode(body));
        await out.close();
      });
      final entry = await EmbyLibrary.login(
        root,
        'user',
        'test-only-password',
        group: '默认分组',
        isPrivate: false,
      );
      final store = await StorageService.init();
      await store.upsertSubscriptions([entry]);
      final site = store.loadSavedConfig()!.supportedSites.single;
      final cms = CmsClient();
      final home = await cms.fetchHome(site);
      expect(home.$1.single.id, 'v1');
      final item = (await cms.fetchSearch(site, '样片')).videos.single;
      expect(await PosterLoader.load(item.poster), isNotEmpty);
      final publicImage = 'http://127.0.0.1:${server.port}/public.png';
      expect(
        await PosterLoader.load(
          publicImage,
        ).timeout(const Duration(seconds: 3)),
        isNotEmpty,
      );
      final hostile = Uri.parse(
        item.poster,
      ).replace(host: 'elsewhere.example').toString();
      await expectLater(
        EmbyLibrary.imageHeaders(hostile),
        throwsFormatException,
      );
      final ep = (await cms.fetchDetail(
        site,
        item,
      )).lines.single.episodes.single;
      final stream = await cms.resolveEpisodeForPlayback(site, ep);
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final req = await http.getUrl(Uri.parse(stream.url));
      stream.headers.forEach(req.headers.set);
      expect((await req.close()).statusCode, 200);
      expect(store.exportBackupJson(), isNot(contains('test-only-')));
      expect(stream.url, isNot(contains('test-only-')));
      expect(stream.playbackSession['PlaySessionId'], 'session-media1');
      final library = await EmbyLibrary.open(site);
      final session = library.track(stream);
      await session.update(0, false);
      await session.update(12500, true);
      await session.stop(13000);
      await session.update(99999, false);
      expect(reports.map((r) => r['path']), [
        '/media/emby/Sessions/Playing',
        '/media/emby/Sessions/Playing/Progress',
        '/media/emby/Sessions/Playing/Stopped',
      ]);
      expect(reports[1]['PositionTicks'], 125000000);
      expect(reports[1]['IsPaused'], true);
      expect(reports.last['PositionTicks'], 130000000);
      CmsEpisode version(String source) => CmsEpisode(
        name: 'version',
        url: 'mmemby://play?id=e1&source=$source',
      );
      final transcoded = await library.resolve(version('transcode'));
      expect(transcoded.url, contains('/media/emby/Videos/e1/master.m3u8'));
      expect(transcoded.url, isNot(contains('api_key')));
      expect(transcoded.url, isNot(contains('obsolete')));
      expect(Uri.parse(transcoded.url).queryParameters['VideoCodec'], 'h264');
      expect(transcoded.playbackSession['PlayMethod'], 'Transcode');
      await expectLater(
        library.resolve(version('foreign')),
        throwsFormatException,
      );
      for (final invalid in ['denied', 'missing', 'opening']) {
        await expectLater(library.resolve(version(invalid)), throwsStateError);
      }
      final reporter = library.track(transcoded);
      final pending = reporter.update(0, false);
      for (var i = 0; i < 200; i++) {
        reporter.update(i * 100, i.isEven);
      }
      await reporter.stop(20000);
      await pending;
      await reporter.update(99999, false);
      expect(reports.last['path'], endsWith('/Stopped'));
      expect(reports.last['PositionTicks'], 200000000);
      expect(
        reports.where((r) => r['PlaySessionId'] == 'session-transcode').length,
        lessThanOrEqualTo(2),
      );
    },
  );

  test(
    'Emby supports composed HTTP 8096 address, bare-root fallback without /emby, and 4K DirectPlay',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        EmbyLibrary.composeServerAddress(
          useHttps: false,
          hostOrUrl: 'emby.example',
          port: '8096',
        ),
        'http://emby.example:8096',
      );
      expect(
        EmbyLibrary.composeServerAddress(
          useHttps: true,
          hostOrUrl: 'https://emby.example:8920/sub/',
        ),
        'https://emby.example:8920/sub',
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final sawHeaders = <String>[];
      var sawHevcDirectPlay = false;
      server.listen((r) async {
        final path = r.uri.path;
        final out = r.response;
        if (path == '/emby/Users/AuthenticateByName') {
          out.statusCode = 404;
          await out.close();
          return;
        }
        if (path == '/Users/AuthenticateByName') {
          sawHeaders.add(r.headers.value('x-emby-authorization') ?? '');
          out.write(
            jsonEncode({
              'AccessToken': 'root-token',
              'User': {'Id': 'u2'},
            }),
          );
          await out.close();
          return;
        }
        if (r.headers.value('X-Emby-Token') != 'root-token') {
          out.statusCode = 401;
          await out.close();
          return;
        }
        if (path == '/Users/u2/Views') {
          out.write(
            jsonEncode({
              'Items': [
                {'Name': '4K 电影', 'Id': 'v4k'},
              ],
            }),
          );
        } else if (path == '/System/Info/Public') {
          out.write(jsonEncode({'ServerName': 'Home4K', 'Id': 'srv1'}));
        } else if (path == '/Users/u2/Items/m4k') {
          out.write(
            jsonEncode({
              'Name': '4K 样片',
              'Type': 'Movie',
              'Id': 'm4k',
              'MediaSources': [
                {'Id': 'ms4k'},
              ],
            }),
          );
        } else if (path == '/Items/m4k/PlaybackInfo') {
          final input = jsonDecode(await utf8.decoder.bind(r).join());
          final codecs =
              input['DeviceProfile']?['DirectPlayProfiles']?[0]?['VideoCodec']
                  ?.toString() ??
              '';
          sawHevcDirectPlay =
              input['EnableDirectPlay'] == true && codecs.contains('hevc');
          out.write(
            jsonEncode({
              'PlaySessionId': 'ps4k',
              'MediaSources': [
                {
                  'Id': 'ms4k',
                  'SupportsDirectPlay': true,
                  'SupportsDirectStream': true,
                },
              ],
            }),
          );
        } else {
          out.statusCode = 404;
        }
        await out.close();
      });

      final composed = EmbyLibrary.composeServerAddress(
        useHttps: false,
        hostOrUrl: '127.0.0.1',
        port: '${server.port}',
      );
      final entry = await EmbyLibrary.login(
        composed,
        'tester',
        'secret',
        group: '默认分组',
        isPrivate: false,
      );
      expect(entry.name, 'Emby · Home4K');
      expect(sawHeaders.single, contains('MediaBrowser Client='));

      final store = await StorageService.init();
      await store.upsertSubscriptions([entry]);
      final site = store.loadSavedConfig()!.supportedSites.single;
      final lib = await EmbyLibrary.open(site);
      expect(lib.base.path, '');
      final ep = (await lib.detail('m4k')).lines.single.episodes.single;
      final resolved = await lib.resolve(ep);
      expect(sawHevcDirectPlay, isTrue);
      expect(resolved.url, contains('http://127.0.0.1:${server.port}/Videos/m4k/stream'));
    },
  );
}

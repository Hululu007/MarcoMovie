import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/emby_library.dart';
import 'package:marco_movie/core/media_library_connectors.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/personal_netdisk_library.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/smb2_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/personal_netdisk_picker_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'test_storage_helper.dart';

/// Minimal real SMB2 protocol TCP server on loopback (`127.0.0.1`) supporting
/// NEGOTIATE, SESSION_SETUP (NTLMSSP challenge/auth + wrong-password rejection),
/// TREE_CONNECT, CREATE, QUERY_DIRECTORY (nested dirs + videos), READ, CLOSE.
class _LoopbackSmb2Server {
  _LoopbackSmb2Server(this.server);

  final ServerSocket server;
  int get port => server.port;

  static Future<_LoopbackSmb2Server> start({
    required String expectedUser,
    required String expectedShare,
    required Map<String, List<({String name, bool isDir, Uint8List? content})>>
        tree,
  }) async {
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _LoopbackSmb2Server(sock);
    sock.listen((client) {
      unawaited(
        instance._serveClient(
          client,
          expectedUser: expectedUser,
          expectedShare: expectedShare,
          tree: tree,
        ),
      );
    });
    return instance;
  }

  Future<void> close() => server.close();

  Future<void> _serveClient(
    Socket socket, {
    required String expectedUser,
    required String expectedShare,
    required Map<String, List<({String name, bool isDir, Uint8List? content})>>
        tree,
  }) async {
    final buf = BytesBuilder(copy: false);
    final openPaths = <int, String>{};
    final enumerated = <int, bool>{};
    var nextHandle = 1;
    var authed = false;

    final completer = Completer<void>();
    socket.listen(
      (chunk) {
        buf.add(chunk);
        while (true) {
          final all = buf.toBytes();
          if (all.length < 4) break;
          final frameLen = (all[1] << 16) | (all[2] << 8) | all[3];
          if (all.length < 4 + frameLen) break;
          final pkt = Uint8List.sublistView(all, 4, 4 + frameLen);
          buf.clear();
          if (all.length > 4 + frameLen) {
            buf.add(Uint8List.sublistView(all, 4 + frameLen));
          }
          if (pkt.length < 64) continue;
          final hd = ByteData.sublistView(pkt, 0, 64);
          final cmd = hd.getUint16(12, Endian.little);
          final msgId = hd.getUint64(24, Endian.little);
          final treeId = hd.getUint32(36, Endian.little);
          final sessionId = hd.getUint64(40, Endian.little);
          final body = Uint8List.sublistView(pkt, 64);

          Uint8List buildResp(
            int status,
            Uint8List payload, {
            int respTreeId = 0,
            int respSessionId = 0,
          }) {
            final total = 64 + payload.length;
            final out = Uint8List(4 + total);
            out[0] = 0;
            out[1] = (total >> 16) & 0xFF;
            out[2] = (total >> 8) & 0xFF;
            out[3] = total & 0xFF;
            out[4] = 0xFE;
            out[5] = 0x53;
            out[6] = 0x4D;
            out[7] = 0x42;
            final rhd = ByteData.sublistView(out, 4, 68);
            rhd.setUint16(4, 64, Endian.little);
            rhd.setUint16(6, 1, Endian.little);
            rhd.setUint32(8, status, Endian.little);
            rhd.setUint16(12, cmd, Endian.little);
            rhd.setUint16(14, 64, Endian.little);
            rhd.setUint32(16, 1, Endian.little); // SERVER_TO_REDIR
            rhd.setUint64(24, msgId, Endian.little);
            rhd.setUint32(36, respTreeId, Endian.little);
            rhd.setUint64(40, respSessionId, Endian.little);
            out.setRange(68, 68 + payload.length, payload);
            return out;
          }

          if (cmd == 0x0000) {
            // NEGOTIATE
            final p = Uint8List(65);
            final bd = ByteData.sublistView(p);
            bd.setUint16(0, 65, Endian.little);
            bd.setUint16(4, 0x0210, Endian.little);
            bd.setUint32(32, 65536, Endian.little);
            socket.add(buildResp(0x00000000, p));
          } else if (cmd == 0x0001) {
            // SESSION_SETUP
            final bbd = ByteData.sublistView(body);
            final secOff = bbd.getUint16(12, Endian.little) - 64;
            final secLen = bbd.getUint16(14, Endian.little);
            final sec = Uint8List.sublistView(body, secOff, secOff + secLen);
            final msgType =
                sec.length >= 12 ? ByteData.sublistView(sec).getUint32(8, Endian.little) : 0;
            if (msgType == 1) {
              // Reply Type 2 Challenge
              final type2 = Uint8List(56);
              type2.setRange(0, 8, ascii.encode('NTLMSSP\x00'));
              final t2 = ByteData.sublistView(type2);
              t2.setUint32(8, 2, Endian.little);
              for (var i = 0; i < 8; i++) {
                type2[24 + i] = i + 1;
              }
              final p = Uint8List(8 + type2.length);
              final pbd = ByteData.sublistView(p);
              pbd.setUint16(0, 9, Endian.little);
              pbd.setUint16(4, 64 + 8, Endian.little);
              pbd.setUint16(6, type2.length, Endian.little);
              p.setRange(8, 8 + type2.length, type2);
              socket.add(buildResp(0xC0000016, p, respSessionId: 0x1234));
            } else {
              // Verify Type 3 username (reject wrong user / bad password check)
              final t3 = ByteData.sublistView(sec);
              final userLen = t3.getUint16(36, Endian.little);
              final userOff = t3.getUint32(40, Endian.little);
              final ntLen = t3.getUint16(20, Endian.little);
              final userStr = userLen > 0
                  ? _decodeUtf16(Uint8List.sublistView(sec, userOff, userOff + userLen))
                  : '';
              if (expectedUser.isNotEmpty &&
                  (userStr != expectedUser || ntLen < 16)) {
                socket.add(
                  buildResp(0xC000006D, Uint8List(9), respSessionId: sessionId),
                );
              } else {
                authed = true;
                final p = Uint8List(9);
                ByteData.sublistView(p).setUint16(0, 9, Endian.little);
                socket.add(
                  buildResp(0x00000000, p, respSessionId: 0x1234),
                );
              }
            }
          } else if (cmd == 0x0003) {
            // TREE_CONNECT
            final bbd = ByteData.sublistView(body);
            final pathOff = bbd.getUint16(4, Endian.little) - 64;
            final pathLen = bbd.getUint16(6, Endian.little);
            final unc = _decodeUtf16(
              Uint8List.sublistView(body, pathOff, pathOff + pathLen),
            );
            if (!authed || !unc.toLowerCase().endsWith('\\${expectedShare.toLowerCase()}')) {
              socket.add(
                buildResp(0xC00000CC, Uint8List(9), respSessionId: sessionId),
              );
            } else {
              final p = Uint8List(16);
              ByteData.sublistView(p).setUint16(0, 16, Endian.little);
              socket.add(
                buildResp(0x00000000, p, respTreeId: 7, respSessionId: sessionId),
              );
            }
          } else if (cmd == 0x0005) {
            // CREATE
            final bbd = ByteData.sublistView(body);
            final nameOff = bbd.getUint16(44, Endian.little) - 64;
            final nameLen = bbd.getUint16(46, Endian.little);
            final rel = nameLen > 0
                ? _decodeUtf16(Uint8List.sublistView(body, nameOff, nameOff + nameLen))
                    .replaceAll('\\', '/')
                : '';
            final fid = nextHandle++;
            openPaths[fid] = rel;
            enumerated[fid] = false;
            var fileSize = 0;
            final isDir = tree.containsKey(rel);
            if (!isDir) {
              final found = _findFile(tree, rel);
              if (found == null) {
                socket.add(
                  buildResp(0xC0000034, Uint8List(9), respTreeId: treeId, respSessionId: sessionId),
                );
                continue;
              }
              fileSize = found.length;
            }
            final p = Uint8List(89);
            final pbd = ByteData.sublistView(p);
            pbd.setUint16(0, 89, Endian.little);
            pbd.setInt64(48, fileSize, Endian.little);
            pbd.setUint64(64, fid, Endian.little);
            socket.add(
              buildResp(0x00000000, p, respTreeId: treeId, respSessionId: sessionId),
            );
          } else if (cmd == 0x000E) {
            // QUERY_DIRECTORY
            final fid = ByteData.sublistView(body).getUint64(8, Endian.little);
            if (enumerated[fid] == true) {
              socket.add(
                buildResp(0x80000006, Uint8List(9), respTreeId: treeId, respSessionId: sessionId),
              );
              continue;
            }
            enumerated[fid] = true;
            final entries = tree[openPaths[fid] ?? ''] ?? const [];
            final listing = BytesBuilder();
            for (var i = 0; i < entries.length; i++) {
              final e = entries[i];
              final nameBytes = _encodeUtf16(e.name);
              final entrySize = ((94 + nameBytes.length + 7) ~/ 8) * 8;
              final row = Uint8List(entrySize);
              final rbd = ByteData.sublistView(row);
              rbd.setUint32(0, i + 1 < entries.length ? entrySize : 0, Endian.little);
              rbd.setInt64(40, e.content?.length ?? 0, Endian.little);
              rbd.setUint32(56, e.isDir ? 0x10 : 0x80, Endian.little);
              rbd.setUint32(60, nameBytes.length, Endian.little);
              row.setRange(94, 94 + nameBytes.length, nameBytes);
              listing.add(row);
            }
            final outBytes = listing.toBytes();
            final p = Uint8List(8 + outBytes.length);
            final pbd = ByteData.sublistView(p);
            pbd.setUint16(0, 9, Endian.little);
            pbd.setUint16(2, 64 + 8, Endian.little);
            pbd.setUint32(4, outBytes.length, Endian.little);
            p.setRange(8, 8 + outBytes.length, outBytes);
            socket.add(
              buildResp(0x00000000, p, respTreeId: treeId, respSessionId: sessionId),
            );
          } else if (cmd == 0x0008) {
            // READ
            final bbd = ByteData.sublistView(body);
            final len = bbd.getUint32(4, Endian.little);
            final offset = bbd.getUint64(8, Endian.little);
            final fid = bbd.getUint64(16, Endian.little);
            final bytes = _findFile(tree, openPaths[fid] ?? '') ?? Uint8List(0);
            if (offset >= bytes.length) {
              socket.add(
                buildResp(0xC0000011, Uint8List(9), respTreeId: treeId, respSessionId: sessionId),
              );
              continue;
            }
            final end = (offset + len) > bytes.length ? bytes.length : (offset + len);
            final slice = Uint8List.sublistView(bytes, offset, end);
            final p = Uint8List(16 + slice.length);
            final pbd = ByteData.sublistView(p);
            pbd.setUint16(0, 17, Endian.little);
            pbd.setUint8(2, 64 + 16);
            pbd.setUint32(4, slice.length, Endian.little);
            p.setRange(16, 16 + slice.length, slice);
            socket.add(
              buildResp(0x00000000, p, respTreeId: treeId, respSessionId: sessionId),
            );
          } else if (cmd == 0x0006) {
            // CLOSE
            final fid = ByteData.sublistView(body).getUint64(8, Endian.little);
            openPaths.remove(fid);
            enumerated.remove(fid);
            final p = Uint8List(60);
            ByteData.sublistView(p).setUint16(0, 60, Endian.little);
            socket.add(
              buildResp(0x00000000, p, respTreeId: treeId, respSessionId: sessionId),
            );
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future;
  }

  static Uint8List? _findFile(
    Map<String, List<({String name, bool isDir, Uint8List? content})>> tree,
    String relPath,
  ) {
    final slash = relPath.lastIndexOf('/');
    final dir = slash < 0 ? '' : relPath.substring(0, slash);
    final name = slash < 0 ? relPath : relPath.substring(slash + 1);
    for (final e in tree[dir] ?? const []) {
      if (!e.isDir && e.name == name) return e.content;
    }
    return null;
  }

  static Uint8List _encodeUtf16(String s) {
    final out = Uint8List(s.codeUnits.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < s.codeUnits.length; i++) {
      bd.setUint16(i * 2, s.codeUnits[i], Endian.little);
    }
    return out;
  }

  static String _decodeUtf16(Uint8List b) {
    final bd = ByteData.sublistView(b);
    return String.fromCharCodes(
      List.generate(b.length ~/ 2, (i) => bd.getUint16(i * 2, Endian.little)),
    );
  }
}

void main() {
  setUp(() {
    // Allow real loopback HttpServer / TCP sockets even when this file also
    // contains a testWidgets() case (TestWidgetsFlutterBinding installs a mock
    // HttpOverrides that otherwise forces HTTP 400).
    HttpOverrides.global = null;
  });

  group('Req 7 — Media Servers (Emby, Jellyfin, Plex): login, real items, playback, restart & auth errors', () {
    test('Emby rejects wrong password & 403 unauthorized views without creating empty library', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final p = req.uri.path;
        if (p.endsWith('/Users/AuthenticateByName')) {
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          if (body['Pw'] == 'wrong') {
            req.response.statusCode = 401;
          } else {
            req.response.write(jsonEncode({
              'AccessToken': body['Username'] == 'noaccess' ? 'tok-noaccess' : 'tok-ok',
              'User': {'Id': body['Username']},
            }));
          }
        } else if (p.endsWith('/Views')) {
          if (req.headers.value('X-Emby-Token') == 'tok-noaccess') {
            req.response.statusCode = 403;
          } else {
            req.response.write(jsonEncode({'Items': [{'Id': 'lib1', 'Name': '电影库'}]}));
          }
        }
        await req.response.close();
      });

      final url = 'http://127.0.0.1:${server.port}';
      await expectLater(
        EmbyLibrary.login(url, 'alice', 'wrong', group: '默认分组', isPrivate: false),
        throwsStateError,
      );
      await expectLater(
        EmbyLibrary.login(url, 'noaccess', 'secret', group: '默认分组', isPrivate: false),
        throwsStateError,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('emby.account.')), isEmpty);
    });

    test('Jellyfin full lifecycle: login -> real libraries & episodes -> resolve stream -> simulated restart reopen -> wrong password & 403 rejected', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final p = req.uri.path;
        if (p == '/Users/AuthenticateByName') {
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          if (body['Pw'] != 'jf-pass') {
            req.response.statusCode = 401;
          } else {
            req.response.write(jsonEncode({
              'AccessToken': body['Username'] == 'locked' ? 'tok-locked' : 'jf-token',
              'User': {'Id': body['Username']},
            }));
          }
        } else if (req.headers.value('X-Emby-Token') == 'tok-locked') {
          req.response.statusCode = 403;
        } else if (p.endsWith('/Views')) {
          req.response.write(jsonEncode({
            'Items': [{'Id': 'jf-v1', 'Name': '4K 影院'}],
          }));
        } else if (p.endsWith('/Items')) {
          req.response.write(jsonEncode({
            'Items': [{'Id': 'm1', 'Name': '星际穿越', 'Type': 'Movie', 'ProductionYear': 2014}],
            'TotalRecordCount': 1,
          }));
        } else if (p.endsWith('/Items/m1')) {
          req.response.write(jsonEncode({
            'Id': 'm1',
            'Name': '星际穿越',
            'Type': 'Movie',
            'MediaSources': [{'Id': 'src1'}],
          }));
        } else if (p.endsWith('/PlaybackInfo')) {
          req.response.write(jsonEncode({
            'PlaySessionId': 'jf-sess-1',
            'MediaSources': [{'Id': 'src1', 'SupportsDirectStream': true}],
          }));
        } else if (p.endsWith('/Videos/m1/stream')) {
          req.response.add(utf8.encode('FAKE-MP4-HEADER-FRAME'));
        }
        await req.response.close();
      });

      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        JellyfinLibrary.login(base, 'alice', 'bad', group: '默认分组', isPrivate: false),
        throwsStateError,
      );
      await expectLater(
        JellyfinLibrary.login(base, 'locked', 'jf-pass', group: '默认分组', isPrivate: false),
        throwsStateError,
      );

      final entry = await JellyfinLibrary.login(
        base,
        'alice',
        'jf-pass',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([entry]);
      final cms = CmsClient();
      final site = storage.loadSavedConfig()!.supportedSites.single;
      final (cats, listing) = await cms.fetchHome(site);
      expect(cats.single.name, '4K 影院');
      expect(listing.videos.single.title, '星际穿越');
      final detail = await cms.fetchDetail(site, listing.videos.single);
      final resolved = await cms.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      // Verify stream responds HTTP 200 with real bytes
      final httpClient = HttpClient();
      addTearDown(() => httpClient.close(force: true));
      final streamReq = await httpClient.getUrl(Uri.parse(resolved.url));
      resolved.headers.forEach(streamReq.headers.set);
      final streamResp = await streamReq.close();
      expect(streamResp.statusCode, 200);
      expect(await utf8.decoder.bind(streamResp).join(), 'FAKE-MP4-HEADER-FRAME');

      // Simulated app restart: reload StorageService & reopen site
      final restartedStorage = await StorageService.init();
      final reopenedSite = restartedStorage.loadSavedConfig()!.supportedSites.single;
      final (_, reopenedListing) = await CmsClient().fetchHome(reopenedSite);
      expect(reopenedListing.videos.single.title, '星际穿越');
    });

    test('Plex full lifecycle: login -> sections & show leaves -> stream resolve -> restart -> invalid token & HTML rejected', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final p = req.uri.path;
        if (p.startsWith('/html')) {
          req.response.headers.contentType = ContentType.html;
          req.response.write('<html><body>Login</body></html>');
        } else if (req.headers.value('X-Plex-Token') != 'plex-ok-token') {
          req.response.statusCode = 401;
        } else if (p == '/library/sections') {
          req.response.write(jsonEncode({
            'MediaContainer': {
              'Directory': [{'key': '1', 'title': '电影', 'type': 'movie'}],
            },
          }));
        } else if (p == '/library/sections/1/all') {
          req.response.write(jsonEncode({
            'MediaContainer': {
              'totalSize': 1,
              'Metadata': [{'ratingKey': '101', 'title': '盗梦空间', 'year': 2010}],
            },
          }));
        } else if (p == '/library/metadata/101') {
          req.response.write(jsonEncode({
            'MediaContainer': {
              'Metadata': [{
                'ratingKey': '101',
                'title': '盗梦空间',
                'type': 'movie',
                'Media': [{'Part': [{'key': '/library/parts/55/file.mp4'}]}],
              }],
            },
          }));
        } else if (p == '/library/parts/55/file.mp4') {
          req.response.add(utf8.encode('PLEX-STREAM-OK'));
        }
        await req.response.close();
      });

      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        PlexLibrary.login(base, 'wrong', group: '默认分组', isPrivate: false),
        throwsStateError,
      );
      await expectLater(
        PlexLibrary.login('$base/html', 'plex-ok-token', group: '默认分组', isPrivate: false),
        throwsFormatException,
      );

      final entry = await PlexLibrary.login(
        base,
        'plex-ok-token',
        label: '家庭影院',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([entry]);
      final site = storage.loadSavedConfig()!.supportedSites.single;
      final cms = CmsClient();
      final (cats, listing) = await cms.fetchHome(site);
      expect(cats.single.name, '电影');
      expect(listing.videos.single.title, '盗梦空间');
      final detail = await cms.fetchDetail(site, listing.videos.single);
      final resolved = await cms.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(resolved.headers['X-Plex-Token'], 'plex-ok-token');
      expect(resolved.url, endsWith('/library/parts/55/file.mp4'));
    });
  });

  group('Req 7 — Network Storage (WebDAV, AList/OpenList, Pure SMB2 + Companion WebDAV)', () {
    test('WebDAV handles multi-level nested dirs, valid empty 207 dir, and REJECTS HTTP 200 HTML login page as error', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final p = req.uri.path;
        if (p.startsWith('/html-login')) {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.html;
          req.response.write('<!DOCTYPE html><html><body><form>Please Sign In</form></body></html>');
        } else if (p.startsWith('/empty')) {
          req.response.statusCode = 207;
          req.response.headers.contentType = ContentType('application', 'xml');
          req.response.write(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/empty/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '</d:multistatus>',
          );
        } else if (p == '/dav/' || p == '/dav') {
          req.response.statusCode = 207;
          req.response.write(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '<d:response><d:href>/dav/SciFi/</d:href><d:propstat><d:prop><d:displayname>科幻合集</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '</d:multistatus>',
          );
        } else if (p == '/dav/SciFi/') {
          req.response.statusCode = 207;
          req.response.write(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/dav/SciFi/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
            '<d:response><d:href>/dav/SciFi/Dune.2024.4K.mkv</d:href><d:propstat><d:prop><d:displayname>Dune.2024.4K.mkv</d:displayname></d:prop></d:propstat></d:response>'
            '</d:multistatus>',
          );
        }
        await req.response.close();
      });

      final base = 'http://127.0.0.1:${server.port}';
      // 1. HTTP 200 HTML login page MUST fail with FormatException (NOT treated as empty dir!)
      await expectLater(
        WebDavMediaLibrary.login('$base/html-login/', group: '默认分组', isPrivate: false),
        throwsFormatException,
      );

      // 2. Valid empty 207 directory succeeds cleanly as empty
      final emptyEntry = await WebDavMediaLibrary.login(
        '$base/empty/',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([emptyEntry]);
      final emptySite = storage.loadSavedConfig()!.supportedSites.single;
      final (_, emptyListing) = await CmsClient().fetchHome(emptySite);
      expect(emptyListing.videos, isEmpty);

      // 3. Nested multi-level directory: root -> 科幻合集 folder card -> Dune.2024.4K.mkv
      final nestedEntry = await WebDavMediaLibrary.login(
        '$base/dav/',
        group: '默认分组',
        isPrivate: false,
      );
      await storage.upsertSubscriptions([nestedEntry]);
      final davSite = storage
          .loadSavedConfig()!
          .supportedSites
          .firstWhere((s) => s.idOrKeyMatches(nestedEntry.id));
      final cms = CmsClient();
      final (_, rootListing) = await cms.fetchHome(davSite);
      expect(rootListing.videos.single.tag, 'media-folder');
      expect(rootListing.videos.single.title, '科幻合集');

      final subListing = await cms.fetchCategory(davSite, rootListing.videos.single.id, 1);
      expect(subListing.videos.single.title, 'Dune.2024.4K');
      final detail = await cms.fetchDetail(davSite, subListing.videos.single);
      final ep = await cms.resolveEpisodeForPlayback(
        davSite,
        detail.lines.single.episodes.single,
      );
      expect(ep.url, endsWith('/dav/SciFi/Dune.2024.4K.mkv'));
    });

    test('AList / OpenList: login -> nested subfolder -> /api/fs/get stream resolution', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final p = req.uri.path;
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        if (p == '/api/auth/login') {
          if (body['password'] != 'openlist-ok') {
            req.response.write(jsonEncode({'code': 400, 'message': 'password incorrect'}));
          } else {
            req.response.write(jsonEncode({'code': 200, 'data': {'token': 'al-tok'}}));
          }
        } else if (p == '/api/fs/list') {
          if (body['path'] == '/') {
            req.response.write(jsonEncode({
              'code': 200,
              'data': {
                'total': 1,
                'content': [{'name': '剧集目录', 'is_dir': true}],
              },
            }));
          } else {
            req.response.write(jsonEncode({
              'code': 200,
              'data': {
                'total': 1,
                'content': [{'name': 'Ep01.mp4', 'is_dir': false}],
              },
            }));
          }
        } else if (p == '/api/fs/get') {
          req.response.write(jsonEncode({
            'code': 200,
            'data': {
              'raw_url': '',
              'sign': 'sig-xyz',
            },
          }));
        }
        await req.response.close();
      });

      final base = 'http://127.0.0.1:${server.port}';
      await expectLater(
        AlistNasLibrary.login(base, username: 'admin', password: 'bad', group: '默认分组', isPrivate: false),
        throwsStateError,
      );
      final entry = await AlistNasLibrary.login(
        base,
        username: 'admin',
        password: 'openlist-ok',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([entry]);
      final site = storage.loadSavedConfig()!.supportedSites.single;
      final cms = CmsClient();
      final (_, root) = await cms.fetchHome(site);
      expect(root.videos.single.tag, 'media-folder');
      final sub = await cms.fetchCategory(site, root.videos.single.id, 1);
      expect(sub.videos.single.title, 'Ep01');
      final detail = await cms.fetchDetail(site, sub.videos.single);
      final resolved = await cms.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(resolved.url, contains('/d/'));
      expect(resolved.url, contains('sign=sig-xyz'));
    });

    test('Pure SMB2 (WITHOUT WebDAV companion): NTLMv2 auth, nested folder, video listing, HTTP 206 Range streaming & wrong-password rejection', () async {
      SharedPreferences.setMockInitialValues({});
      final sampleBytes = Uint8List.fromList(
        utf8.encode('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_SMB2_VIDEO_STREAM'),
      );
      final smbServer = await _LoopbackSmb2Server.start(
        expectedUser: 'mediauser',
        expectedShare: 'Movies',
        tree: {
          '': [
            (name: 'SciFi', isDir: true, content: null),
            (name: 'RootTrailer.mp4', isDir: false, content: sampleBytes),
          ],
          'SciFi': [
            (name: 'BladeRunner.mkv', isDir: false, content: sampleBytes),
          ],
        },
      );
      addTearDown(smbServer.close);

      // Wrong user/credentials MUST fail cleanly without creating a fake library
      await expectLater(
        SmbNasLibrary.configure(
          host: '127.0.0.1',
          port: smbServer.port,
          share: 'Movies',
          username: 'wronguser',
          password: 'bad',
          group: '默认分组',
          isPrivate: false,
        ),
        throwsA(isA<Smb2Exception>()),
      );

      // Pure SMB connect (webdavCompanionUrl intentionally empty!)
      final entry = await SmbNasLibrary.configure(
        host: '127.0.0.1',
        port: smbServer.port,
        share: 'Movies',
        username: 'mediauser',
        password: 'smb-password',
        webdavCompanionUrl: '',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([entry]);
      final site = storage.loadSavedConfig()!.supportedSites.single;
      final cms = CmsClient();

      // List root -> real folder SciFi + real video RootTrailer.mp4
      final (_, root) = await cms.fetchHome(site);
      expect(root.videos.any((v) => v.tag == 'media-folder' && v.title == 'SciFi'), isTrue);
      expect(root.videos.any((v) => v.title == 'RootTrailer'), isTrue);

      // Drill into nested SciFi subfolder -> real video BladeRunner.mkv
      final scifiFolder = root.videos.firstWhere((v) => v.title == 'SciFi');
      final sub = await cms.fetchCategory(site, scifiFolder.id, 1);
      expect(sub.videos.single.title, 'BladeRunner');

      // Resolve & stream via loopback HTTP Range 206 proxy
      final detail = await cms.fetchDetail(site, sub.videos.single);
      final ep = await cms.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      final proxy = ep.playbackSession['smbStreamProxy'] as SmbMediaStreamProxy;
      addTearDown(proxy.close);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(Uri.parse(ep.url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=10-25');
      final resp = await req.close();
      expect(resp.statusCode, 206);
      expect(resp.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-25/${sampleBytes.length}');
      final rangeData = await utf8.decoder.bind(resp).join();
      expect(rangeData, 'ABCDEFGHIJKLMNOP');
    });

    test('SMB with WebDAV companion path: lists nested folders and resolves direct media URL separately from pure SMB2', () async {
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        final p = req.uri.path;
        if (req.method == 'PROPFIND' && (p == '/smb-dav/' || p == '/smb-dav')) {
          req.response.statusCode = 207;
          req.response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          req.response.write('''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/smb-dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/smb-dav/Series/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>''');
        } else if (req.method == 'PROPFIND' && p == '/smb-dav/Series/') {
          req.response.statusCode = 207;
          req.response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          req.response.write('''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/smb-dav/Series/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/smb-dav/Series/Pilot.mp4</D:href><D:propstat><D:prop><D:getcontentlength>4096</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>''');
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final entry = await SmbNasLibrary.configure(
        host: '127.0.0.1',
        share: 'media',
        webdavCompanionUrl: 'http://127.0.0.1:${server.port}/smb-dav/',
        label: 'NAS 伴随WebDAV',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([entry]);
      final site = storage.loadSavedConfig()!.supportedSites.firstWhere((s) => s.key == entry.id);
      final cms = CmsClient();
      final (_, root) = await cms.fetchHome(site);
      expect(root.videos.single.tag, 'media-folder');
      expect(root.videos.single.title, 'Series');

      final sub = await cms.fetchCategory(site, root.videos.single.id, 1);
      expect(sub.videos.single.title, 'Pilot');
      final detail = await cms.fetchDetail(site, sub.videos.single);
      final ep = await cms.resolveEpisodeForPlayback(site, detail.lines.single.episodes.single);
      expect(ep.url, endsWith('/smb-dav/Series/Pilot.mp4'));
    });
  });

  group('Req 5 — All 4 Personal Cloud Drives (Quark, UC, Baidu, Ali)', () {
    test('Quark, UC, Baidu, and Ali personal APIs: root -> subfolder -> pagination -> save -> dedupe -> reopen -> refresh -> play -> expired auth reconnect', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      const quarkCookie = '__pus=quark_pus_1234567890; __puus=quark_puus_1234567890';
      await storage.setNetdiskCredential('quark', quarkCookie);
      await storage.setNetdiskCredential(
        'uc',
        '__pus=uc_pus_token_12345678; __puus=uc_puus_token_12345678',
      );
      await storage.setNetdiskCredential(
        'baidu',
        'BDUSS=baidu_bduss_token_12345678; STOKEN=baidu_stoken_12345678',
      );
      await storage.setNetdiskCredential('ali', 'ali_token=ali_refresh_token_12345678');

      http.Response utf8Json(
        Object body, {
        int status = 200,
        Map<String, String> headers = const {},
      }) =>
          http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            status,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              ...headers,
            },
          );

      var expiredMode = false;
      final mockHttp = MockClient((req) async {
        final host = req.url.host;
        final path = req.url.path;

        if (expiredMode) {
          if (host == 'pan.baidu.com') {
            return utf8Json({'errno': -6});
          }
          return utf8Json({'code': 'InvalidParameter.RefreshToken'}, status: 401);
        }

        // 1. Quark
        if (host == 'drive-pc.quark.cn') {
          if (path == '/1/clouddrive/file/sort') {
            final pdir = req.url.queryParameters['pdir_fid'];
            final page = int.parse(req.url.queryParameters['_page'] ?? '1');
            if (pdir == '0') {
              return utf8Json({
                'status': 200,
                'code': 0,
                'data': {
                  'list': [{'fid': 'q_sub', 'file_name': '电影收藏', 'dir': true, 'file_type': 0}],
                },
                'metadata': {'_total': 1},
              });
            }
            return utf8Json({
              'status': 200,
              'code': 0,
              'data': {
                'list': [
                  {
                    'fid': page == 1 ? 'q_vid_1' : 'q_vid_2',
                    'file_name': page == 1 ? '夸克样片1.mp4' : '夸克样片2.mp4',
                    'dir': false,
                    'file_type': 1,
                    'category': 1,
                    'size': 1024000,
                  },
                ],
              },
              'metadata': {'_total': 51},
            });
          }
          if (path == '/1/clouddrive/file/download') {
            return utf8Json({
              'status': 200,
              'code': 0,
              'data': [{'fid': 'q_vid_1', 'download_url': 'https://dl.quark.cn/q_vid_1.mp4'}],
            });
          }
          return utf8Json({'status': 200, 'code': 0, 'data': {}});
        }

        // 2. UC
        if (host == 'pc-api.uc.cn') {
          if (path == '/1/clouddrive/config') {
            return utf8Json(
              {'status': 200, 'code': 0, 'data': {}},
              headers: {'set-cookie': '__puus=refreshed_uc; Path=/'},
            );
          }
          if (path == '/1/clouddrive/file/sort') {
            final pdir = req.url.queryParameters['pdir_fid'];
            final page = int.parse(req.url.queryParameters['_page'] ?? '1');
            if (pdir == '0') {
              return utf8Json({
                'status': 200,
                'code': 0,
                'data': {
                  'list': [{'fid': 'uc_sub', 'file_name': 'UC剧集', 'dir': true, 'file_type': 0}],
                },
                'metadata': {'_total': 1},
              });
            }
            return utf8Json({
              'status': 200,
              'code': 0,
              'data': {
                'list': [
                  {
                    'fid': page == 1 ? 'uc_vid_1' : 'uc_vid_2',
                    'file_name': page == 1 ? 'UC样片1.mkv' : 'UC样片2.mkv',
                    'dir': false,
                    'file_type': 1,
                    'category': 1,
                    'size': 2048000,
                  },
                ],
              },
              'metadata': {'_total': 55},
            });
          }
          if (path == '/1/clouddrive/file/download') {
            return utf8Json({
              'status': 200,
              'code': 0,
              'data': [{'fid': 'uc_vid_1', 'download_url': 'https://dl.uc.cn/uc_vid_1.mkv'}],
            });
          }
          return utf8Json({'status': 200, 'code': 0, 'data': {}});
        }

        // 3. Baidu
        if (host == 'pan.baidu.com') {
          if (path == '/api/list') {
            final dir = req.url.queryParameters['dir'];
            final start = int.parse(req.url.queryParameters['start'] ?? '0');
            if (dir == '/') {
              return utf8Json({
                'errno': 0,
                'list': [{'fs_id': 1, 'server_filename': '百度影库', 'path': '/百度影库', 'isdir': 1}],
              });
            }
            return utf8Json({
              'errno': 0,
              'has_more': start == 0 ? 1 : 0,
              'list': [
                {
                  'fs_id': start == 0 ? 9001 : 9002,
                  'server_filename': start == 0 ? '百度样片1.mp4' : '百度样片2.mp4',
                  'path': start == 0 ? '/百度影库/百度样片1.mp4' : '/百度影库/百度样片2.mp4',
                  'isdir': 0,
                  'category': 1,
                  'size': 4096000,
                },
              ],
            });
          }
          if (path == '/api/filemetas') {
            return utf8Json({
              'errno': 0,
              'info': [{'fs_id': 9001, 'dlink': 'https://d.pcs.baidu.com/file/9001'}],
            });
          }
        }

        // 4. Ali
        if (host == 'auth.aliyundrive.com') {
          return utf8Json({
            'access_token': 'ali-access-1',
            'refresh_token': 'ali-refresh-1',
            'user_id': 'ali-u1',
            'resource_drive_id': 'ali-drive-1',
            'expires_in': 7200,
          });
        }
        if (host == 'api.aliyundrive.com' && path == '/adrive/v3/file/list') {
          final body = jsonDecode(req.body) as Map;
          if (body['parent_file_id'] == 'root') {
            return utf8Json({
              'items': [{'file_id': 'ali_sub', 'name': '阿里4K', 'type': 'folder'}],
              'next_marker': '',
            });
          }
          final marker = body['marker'] ?? '';
          return utf8Json({
            'items': [
              {
                'file_id': marker == '' ? 'ali_vid_1' : 'ali_vid_2',
                'name': marker == '' ? '阿里样片1.mp4' : '阿里样片2.mp4',
                'type': 'file',
                'category': 'video',
                'size': 8192000,
              },
            ],
            'next_marker': marker == '' ? 'cursor-page-2' : '',
          });
        }
        if (host == 'bj29.api.aliyunpds.com') {
          return utf8Json({
            'url': 'https://cdn.alipan.example/ali_vid_1.mp4',
          });
        }
        if (host == 'api.aliyundrive.com' && path.contains('get_video_preview_play_info')) {
          return utf8Json({'video_preview_play_info': {'live_transcoding_task_list': []}});
        }

        return utf8Json({}, status: 404);
      });

      final mockQuarkAccounts = _FixtureQuarkAccounts(
        session: QuarkAccountSession(
          cookie: quarkCookie,
          driveSt: '',
          accountId: 'quark-test-acc',
          validatedAt: DateTime.now().toUtc(),
        ),
        isExpired: () => expiredMode,
      );
      final cloudClient = PersonalCloudDriveClient(
        credentialReader: (p) async => storage.getNetdiskCred(p),
        credentialWriter: (p, v) => storage.setNetdiskCredential(p, v),
        quarkAccounts: mockQuarkAccounts,
        httpClient: mockHttp,
        mediaClientFactory: () => MockClient((_) async => http.Response('MEDIA-OK', 200)),
      );
      addTearDown(cloudClient.close);

      for (final provider in PersonalCloudProvider.values) {
        // 1. Read personal root
        final root = await cloudClient.listFolder(provider);
        expect(root.items.length, 1, reason: '${provider.key} root must list folder');
        expect(root.items.single.isDir, isTrue);

        // 2. Enter subfolder & verify pagination (page 1 + page 2)
        final subFolder = root.items.single;
        final p1 = await cloudClient.listFolder(
          provider,
          folderId: subFolder.id,
          page: 1,
          driveId: root.driveId,
        );
        expect(p1.items.single.isDir, isFalse);
        expect(p1.hasMore, isTrue);

        final p2 = await cloudClient.listFolder(
          provider,
          folderId: subFolder.id,
          page: 2,
          marker: p1.nextMarker,
          driveId: root.driveId,
        );
        expect(p2.items.single.name, contains('2'));

        // 3. Save chosen subfolder as resource library & verify duplicate add deduplicates
        final created1 = await PersonalCloudLibrary.create(
          client: cloudClient,
          provider: provider,
          folderId: subFolder.id,
          folderName: subFolder.name,
          driveId: root.driveId,
          group: '默认分组',
          isPrivate: false,
        );
        expect(created1.updatedExisting, isFalse);
        final created2 = await PersonalCloudLibrary.create(
          client: cloudClient,
          provider: provider,
          folderId: subFolder.id,
          folderName: subFolder.name,
          driveId: root.driveId,
          group: '默认分组',
          isPrivate: false,
        );
        expect(created2.updatedExisting, isTrue);
        expect(created2.entry.id, created1.entry.id);

        await storage.upsertSubscriptions([created1.entry]);
        final site = storage
            .loadSavedConfig()!
            .supportedSites
            .firstWhere((s) => s.key == created1.entry.id);

        // 4. Reopen saved library -> home -> detail -> resolve playback
        final lib = await PersonalCloudLibrary.open(site, client: cloudClient);
        final (_, homeListing) = await lib.home();
        expect(homeListing.videos.single.title, contains('样片1'));
        final detail = await lib.detail(homeListing.videos.single);
        final resolved = await lib.resolve(detail.lines.single.episodes.single);
        expect(resolved.url, isNotEmpty);
        final lease = resolved.playbackSession['cloudMediaLease'];
        if (lease != null) {
          await (lease as dynamic).close();
        }
      }

      // 5. Auth expiry detection -> requiresReauth == true
      expiredMode = true;
      for (final provider in PersonalCloudProvider.values) {
        await expectLater(
          cloudClient.listFolder(provider),
          throwsA(
            isA<PersonalCloudException>().having(
              (e) => e.requiresReauth,
              'requiresReauth',
              isTrue,
            ),
          ),
        );
      }
    });

    testWidgets(
      'PersonalNetdiskPickerPage: cancelled auth creates ZERO empty libraries; successful auth auto-returns and loads root',
      (tester) async {
        final storage = await initTestStorage(
          secureStore: InMemorySecureCredentialStore(),
        );
        var authGranted = false;

        final mockHttp = MockClient((req) async {
          if (req.url.host == 'pc-api.uc.cn' && req.url.path == '/1/clouddrive/config') {
            return http.Response.bytes(
              utf8.encode(jsonEncode({'status': 200, 'code': 0})),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (req.url.host == 'pc-api.uc.cn' && req.url.path == '/1/clouddrive/file/sort') {
            return http.Response.bytes(
              utf8.encode(jsonEncode({
                'status': 200,
                'code': 0,
                'data': {
                  'list': [{'fid': 'dir1', 'file_name': '我的UC电影', 'dir': true, 'file_type': 0}],
                },
                'metadata': {'_total': 1},
              })),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('{}', 404);
        });
        final cloudClient = PersonalCloudDriveClient.fromStorage(storage, httpClient: mockHttp);
        addTearDown(cloudClient.close);

        await tester.pumpWidget(
          MaterialApp(
            home: PersonalNetdiskPickerPage(
              provider: PersonalCloudProvider.uc,
              storage: storage,
              group: '默认分组',
              isPrivate: false,
              client: cloudClient,
              onAuthorizeOverride: (_) async {
                if (authGranted) {
                  await storage.setNetdiskCredential(
                    'uc',
                    '__pus=uc_pus_token_12345678; __puus=uc_puus_token_12345678',
                  );
                }
              },
              onLibrarySaved: (_) {},
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // First auto-auth cancelled -> error shown, ZERO libraries created!
        expect(find.byKey(const ValueKey('personal-netdisk-error-text')), findsOneWidget);
        expect(storage.getSubscriptions(), isEmpty);

        Future<void> drainStreams() async {
          for (var i = 0; i < 4; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        // User retries & grants authorization -> auto-returns and loads personal root!
        authGranted = true;
        await tester.tap(find.byKey(const ValueKey('personal-netdisk-reauth-btn')));
        await drainStreams();
        expect(find.text('我的UC电影'), findsOneWidget);

        // Enter subfolder & save library
        await tester.tap(find.text('我的UC电影'));
        await drainStreams();
        await tester.tap(find.byKey(const ValueKey('personal-netdisk-save-folder-btn')));
        await drainStreams();
        expect(storage.getSubscriptions().length, 1);
        expect(storage.getSubscriptions().single.name, 'UC · 我的UC电影');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });

  group('Req 7 — Current Device persistence after restart, Local Config Pack & Manual Input', () {
    test('LocalDeviceLibrary copies picked videos into permanent container so deletion of temp file + restart remains readable', () async {
      SharedPreferences.setMockInitialValues({});
      final tempRoot = await Directory.systemTemp.createTemp('marco_local_test_');
      addTearDown(() => tempRoot.delete(recursive: true));

      final docsDir = await Directory('${tempRoot.path}/Documents').create();
      final pickerTmp = File('${tempRoot.path}/tmp_picked_movie.mp4');
      await pickerTmp.writeAsBytes(utf8.encode('LOCAL-VIDEO-BYTES-OK'));
      LocalDeviceLibrary.storageRootProviderOverride = () async => docsDir;
      addTearDown(() => LocalDeviceLibrary.storageRootProviderOverride = null);

      final entry = await LocalDeviceLibrary.createFromPaths(
        [pickerTmp.path],
        label: '本机测试片库',
        group: '默认分组',
        isPrivate: false,
      );
      final storage = await StorageService.init();
      await storage.upsertSubscriptions([entry]);

      // Simulate iOS purging /tmp picker file + cold app restart
      await pickerTmp.delete();
      expect(await pickerTmp.exists(), isFalse);

      final restartedStorage = await StorageService.init();
      final site = restartedStorage.loadSavedConfig()!.supportedSites.single;
      final cms = CmsClient();
      final (_, listing) = await cms.fetchHome(site);
      expect(listing.videos.single.title, 'tmp_picked_movie');
      final detail = await cms.fetchDetail(site, listing.videos.single);
      final resolved = await cms.resolveEpisodeForPlayback(
        site,
        detail.lines.single.episodes.single,
      );
      expect(await File(resolved.url).exists(), isTrue);
      expect(await File(resolved.url).readAsString(), 'LOCAL-VIDEO-BYTES-OK');

      // Invalid non-existent file must throw without saving anything
      await expectLater(
        LocalDeviceLibrary.createFromPaths(
          ['${tempRoot.path}/does_not_exist.mp4'],
          group: '默认分组',
          isPrivate: false,
        ),
        throwsFormatException,
      );
    });

    test('Local Config Pack & Manual Input import valid samples into sites/live list and reject invalid input with zero leftover', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final cms = CmsClient();

      // 1. Valid local JSON pack
      final packBytes = Uint8List.fromList(
        utf8.encode(
          '{"sites":[{"key":"pack1","name":"配置包片源","type":1,"api":"https://pack.example/api"}],"lives":[{"name":"配置包直播","url":"https://live.example/a.m3u"}]}',
        ),
      );
      final parsedText = CmsClient.readSubscriptionFile(packBytes, 'sample.json');
      final entries = await cms.resolveBatchSubscriptions(rawTextInput: parsedText);
      await storage.upsertSubscriptions(entries);
      final cfg = storage.loadSavedConfig()!;
      expect(cfg.publicSupportedSites.any((s) => s.name == '配置包片源'), isTrue);
      expect(cfg.publicLives.any((l) => l.name == '配置包直播'), isTrue);

      // 2. Valid manual M3U input
      final m3uEntries = await cms.resolveBatchSubscriptions(
        rawTextInput: '#EXTM3U\n#EXTINF:-1,测试频道\nhttps://stream.example/live.m3u8',
      );
      await storage.upsertSubscriptions(m3uEntries);
      expect(storage.getSubscriptions().length, 2);

      // 3. Invalid manual input -> throws & leaves ZERO partial entries
      final beforeCount = storage.getSubscriptions().length;
      await expectLater(
        cms.resolveBatchSubscriptions(rawTextInput: 'not-a-valid-url-or-json'),
        throwsA(anything),
      );
      expect(storage.getSubscriptions().length, beforeCount);
    });
  });
}

extension _SiteMatch on CmsSite {
  bool idOrKeyMatches(String id) => key == id || subscriptionId == id;
}

class _FixtureQuarkAccounts extends QuarkAccountProvider {
  _FixtureQuarkAccounts({
    required this.session,
    required this.isExpired,
  }) : super(
          readCredential: () async => '',
          writeCredential: (_) async {},
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        );

  final QuarkAccountSession session;
  final bool Function() isExpired;

  @override
  Future<QuarkAccountSession> requireSession() async {
    if (isExpired()) {
      throw const QuarkAccountException('unauthenticated', '夸克登录已失效，请重新授权');
    }
    return session;
  }

  @override
  Future<void> assertCurrentSession(
    QuarkAccountSession current, {
    int? generation,
  }) async {
    if (isExpired()) {
      throw const QuarkAccountException('unauthenticated', '夸克登录已失效，请重新授权');
    }
  }
}

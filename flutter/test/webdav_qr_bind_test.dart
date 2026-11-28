import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/lan_sync_server.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/webdav_bind_crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const vectorKeyHex =
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
  const vectorNonceHex = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf';
  const vectorPlaintext =
      '{"v":1,"type":"webdav_bind","mode":"push","url":"https://dav.example/dav/","username":"alice","password":"secret"}';
  const expectedN = 'oKGio6SlpqeoqaqrrK2urw';
  const expectedC =
      'xfDx9RrOpL1khU7sInR6r_FEkaUAWr2Gb1uRwQsipYvnlQXfmuWnU5fb1UB1NCg2Qgx2MIpAZ8fkGJgZrE4XXZddPAUF7j81s4Zo6uyIPLCLJTUuJuCXD8uI9zvN0-9vg3Kk1yHHvQGjKt_1Ol9xDa6I';
  const expectedT = 'RFROaISW8WSfiPGKWfQ6WwsFqQIsJsoJ3h7w0hgUPOM';

  Uint8List hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  test('WebdavBindCrypto matches deterministic cross-platform vector and tamper rejection', () {
    final key = hexToBytes(vectorKeyHex);
    final nonce = hexToBytes(vectorNonceHex);
    final envStr = WebdavBindCrypto.sealPlaintextWithNonce(key, nonce, vectorPlaintext);
    final env = jsonDecode(envStr) as Map<String, dynamic>;
    expect(env['v'], 1);
    expect(env['alg'], WebdavBindCrypto.alg);
    expect(env['n'], expectedN);
    expect(env['c'], expectedC);
    expect(env['t'], expectedT);

    final opened = WebdavBindCrypto.openJson(key, envStr);
    expect(opened['url'], 'https://dav.example/dav/');
    expect(opened['username'], 'alice');
    expect(opened['password'], 'secret');

    env['t'] = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    expect(
      () => WebdavBindCrypto.openJson(key, jsonEncode(env)),
      throwsFormatException,
    );

    final qrUrl = WebdavBindCrypto.buildBindQrUrl('http://127.0.0.1:8080/configure/deadbeef', key);
    final parsed = WebdavBindCrypto.parseBindQrInput(qrUrl);
    expect(parsed, isNotNull);
    expect(parsed!.bindUrl, 'http://127.0.0.1:8080/configure/deadbeef/bind');
    expect(parsed.syncUrl, 'http://127.0.0.1:8080/configure/deadbeef/sync');
    expect(parsed.key, key);
  });

  test('LanSyncServer /bind push and pull WebDAV credentials end-to-end', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final receiverStorage = await StorageService.init();

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final senderStorage = await StorageService.init();
    await senderStorage.saveWebdavConfig(
      url: 'https://dav.example/dav/',
      user: 'alice',
      pass: 's3cr3t',
      auto: true,
      syncSubs: true,
      syncHistory: true,
    );

    String? boundUrlSeen;
    final server = await LanSyncServer.start(
      receiverStorage,
      bindAddress: InternetAddress.loopbackIPv4,
      onWebdavBound: (url) => boundUrlSeen = url,
    );
    try {
      final qr = server.bindQrUrlForHost('127.0.0.1');
      final pushRes = await senderStorage.bindOrSyncWithLanQr(qr);
      expect(pushRes.bindStatus, 'pushed');
      expect(boundUrlSeen, 'https://dav.example/dav/');
      expect(receiverStorage.webdavUrl, 'https://dav.example/dav/');
      expect(receiverStorage.webdavUser, 'alice');
      expect(receiverStorage.webdavPass, 's3cr3t');

      // Now empty third device pulls from receiverStorage via GET /bind
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final thirdStorage = await StorageService.init();
      final pullRes = await thirdStorage.bindOrSyncWithLanQr(qr);
      expect(pullRes.bindStatus, 'pulled');
      expect(pullRes.boundWebdav, isTrue);
      expect(thirdStorage.webdavUrl, 'https://dav.example/dav/');
      expect(thirdStorage.webdavUser, 'alice');
      expect(thirdStorage.webdavPass, 's3cr3t');
    } finally {
      await server.close(force: true);
    }
  });
}

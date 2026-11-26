import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibEncoder;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_crypto.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/ohos_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('CatPawCrypto Node.js parity', () {
    test('AES-CBC/ECB/GCM, ChaCha20-Poly1305, RSA-PKCS1, and zlib match Node crypto', () async {
      const script = r'''
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const key16 = Buffer.from('00112233445566778899aabbccddeeff', 'hex');
const key32 = Buffer.from('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'hex');
const iv16 = Buffer.from('0f0e0d0c0b0a09080706050403020100', 'hex');
const iv12 = Buffer.from('a0a1a2a3a4a5a6a7a8a9aaab', 'hex');
const plain = Buffer.from('MarcoMovie 鸿蒙与 AppleTV 本地解密测试 0123456789abcdef!', 'utf8');

function enc(algo, key, iv, opts) {
  const c = crypto.createCipheriv(algo, key, algo.endsWith('-ecb') ? null : iv, opts);
  const out = Buffer.concat([c.update(plain), c.final()]);
  return {
    data: out.toString('base64'),
    tag: (algo === 'aes-256-gcm' || algo === 'chacha20-poly1305') ? c.getAuthTag().toString('base64') : '',
  };
}

const rsa1024 = crypto.generateKeyPairSync('rsa', {
  modulusLength: 1024,
  publicKeyEncoding: { type: 'spki', format: 'der' },
  privateKeyEncoding: { type: 'pkcs8', format: 'der' },
});
const rsa1024Cipher = crypto.publicEncrypt(
  { key: crypto.createPublicKey({ key: rsa1024.publicKey, format: 'der', type: 'spki' }), padding: crypto.constants.RSA_PKCS1_PADDING },
  Buffer.from('hello-rsa-1024', 'utf8')
).toString('base64');

const rsa2048 = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const rsa2048Pkcs1Pub = crypto.createPublicKey(rsa2048.publicKey).export({ type: 'pkcs1', format: 'pem' });

console.log(JSON.stringify({
  key16: key16.toString('base64'),
  key32: key32.toString('base64'),
  iv16: iv16.toString('base64'),
  iv12: iv12.toString('base64'),
  plain: plain.toString('base64'),
  aes128Cbc: enc('aes-128-cbc', key16, iv16),
  aes256Cbc: enc('aes-256-cbc', key32, iv16),
  aes128Ecb: enc('aes-128-ecb', key16, null),
  aes256Ecb: enc('aes-256-ecb', key32, null),
  aes256Gcm12: enc('aes-256-gcm', key32, iv12),
  aes256Gcm16: enc('aes-256-gcm', key32, iv16),
  chacha: enc('chacha20-poly1305', key32, iv12, { authTagLength: 16 }),
  rsa1024Pub: rsa1024.publicKey.toString('base64'),
  rsa1024Priv: rsa1024.privateKey.toString('base64'),
  rsa1024Cipher,
  rsa2048SpkiPem: rsa2048.publicKey,
  rsa2048Pkcs1Pem: rsa2048Pkcs1Pub,
  rsa2048PrivPem: rsa2048.privateKey,
  deflate: zlib.deflateSync(plain).toString('base64'),
  deflateRaw: zlib.deflateRawSync(plain).toString('base64'),
  gzip: zlib.gzipSync(plain).toString('base64'),
}));
''';
      final proc = await Process.run('node', ['-e', script]);
      expect(proc.exitCode, 0, reason: proc.stderr.toString());
      final ref = jsonDecode(proc.stdout.toString()) as Map<String, dynamic>;

      final key16 = ref['key16'] as String;
      final key32 = ref['key32'] as String;
      final iv16 = ref['iv16'] as String;
      final iv12 = ref['iv12'] as String;
      final plain = ref['plain'] as String;

      // AES-128-CBC
      final e128Cbc = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'aes-128-cbc',
        keyB64: key16,
        ivB64: iv16,
        dataB64: plain,
      );
      expect(e128Cbc['data'], (ref['aes128Cbc'] as Map)['data']);
      expect(
        CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'aes-128-cbc',
          keyB64: key16,
          ivB64: iv16,
          dataB64: e128Cbc['data']!,
        )['data'],
        plain,
      );

      // AES-256-CBC
      final e256Cbc = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'aes-256-cbc',
        keyB64: key32,
        ivB64: iv16,
        dataB64: plain,
      );
      expect(e256Cbc['data'], (ref['aes256Cbc'] as Map)['data']);
      expect(
        CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'aes-256-cbc',
          keyB64: key32,
          ivB64: iv16,
          dataB64: e256Cbc['data']!,
        )['data'],
        plain,
      );

      // AES-128-ECB & AES-256-ECB
      final e128Ecb = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'aes-128-ecb',
        keyB64: key16,
        ivB64: '',
        dataB64: plain,
      );
      expect(e128Ecb['data'], (ref['aes128Ecb'] as Map)['data']);
      expect(
        CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'aes-128-ecb',
          keyB64: key16,
          ivB64: '',
          dataB64: e128Ecb['data']!,
        )['data'],
        plain,
      );

      final e256Ecb = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'aes-256-ecb',
        keyB64: key32,
        ivB64: '',
        dataB64: plain,
      );
      expect(e256Ecb['data'], (ref['aes256Ecb'] as Map)['data']);
      expect(
        CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'aes-256-ecb',
          keyB64: key32,
          ivB64: '',
          dataB64: e256Ecb['data']!,
        )['data'],
        plain,
      );

      // AES-256-GCM (12-byte IV & 16-byte IV)
      final eGcm12 = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'aes-256-gcm',
        keyB64: key32,
        ivB64: iv12,
        dataB64: plain,
      );
      expect(eGcm12['data'], (ref['aes256Gcm12'] as Map)['data']);
      expect(eGcm12['tag'], (ref['aes256Gcm12'] as Map)['tag']);
      expect(
        CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'aes-256-gcm',
          keyB64: key32,
          ivB64: iv12,
          dataB64: eGcm12['data']!,
          tagB64: eGcm12['tag']!,
        )['data'],
        plain,
      );
      expect(
        () => CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'aes-256-gcm',
          keyB64: key32,
          ivB64: iv12,
          dataB64: eGcm12['data']!,
          tagB64: base64Encode(Uint8List(16)),
        ),
        throwsFormatException,
      );

      final eGcm16 = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'aes-256-gcm',
        keyB64: key32,
        ivB64: iv16,
        dataB64: plain,
      );
      expect(eGcm16['data'], (ref['aes256Gcm16'] as Map)['data']);
      expect(eGcm16['tag'], (ref['aes256Gcm16'] as Map)['tag']);

      // ChaCha20-Poly1305
      final eChacha = CatPawCrypto.nodeCipher(
        op: 'encrypt',
        algo: 'chacha20-poly1305',
        keyB64: key32,
        ivB64: iv12,
        dataB64: plain,
      );
      expect(eChacha['data'], (ref['chacha'] as Map)['data']);
      expect(eChacha['tag'], (ref['chacha'] as Map)['tag']);
      expect(
        CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'chacha20-poly1305',
          keyB64: key32,
          ivB64: iv12,
          dataB64: eChacha['data']!,
          tagB64: eChacha['tag']!,
        )['data'],
        plain,
      );
      expect(
        () => CatPawCrypto.nodeCipher(
          op: 'decrypt',
          algo: 'chacha20-poly1305',
          keyB64: key32,
          ivB64: iv12,
          dataB64: eChacha['data']!,
          tagB64: base64Encode(Uint8List(16)),
        ),
        throwsFormatException,
      );

      // RSA-1024 PKCS#1 v1.5 (drpy-rsa.cjs compatibility)
      final rsa1024Pub = ref['rsa1024Pub'] as String;
      final rsa1024Priv = ref['rsa1024Priv'] as String;
      final rsa1024Dec = CatPawCrypto.rsaPkcs1(
        'decrypt',
        rsa1024Priv,
        ref['rsa1024Cipher'] as String,
      );
      expect(utf8.decode(base64Decode(rsa1024Dec)), 'hello-rsa-1024');

      final dartRsaEnc = CatPawCrypto.rsaPkcs1(
        'encrypt',
        rsa1024Pub,
        base64Encode(utf8.encode('dart-to-node')),
      );
      expect(
        utf8.decode(
          base64Decode(CatPawCrypto.rsaPkcs1('decrypt', rsa1024Priv, dartRsaEnc)),
        ),
        'dart-to-node',
      );

      // RSA-2048 PEM SPKI & PKCS#1 -> verify with Node privateDecrypt
      final encSpki = CatPawCrypto.rsaPublicEncrypt(
        ref['rsa2048SpkiPem'] as String,
        base64Encode(utf8.encode('spki-secret')),
      );
      final encPkcs1 = CatPawCrypto.rsaPublicEncrypt(
        ref['rsa2048Pkcs1Pem'] as String,
        base64Encode(utf8.encode('pkcs1-secret')),
      );
      final verifyProc = await Process.run('node', [
        '-e',
        r'''
const crypto = require('node:crypto');
const [privB64, c1, c2] = process.argv.slice(1);
const priv = Buffer.from(privB64, 'base64').toString('utf8');
const d1 = crypto.privateDecrypt({ key: priv, padding: crypto.constants.RSA_PKCS1_PADDING }, Buffer.from(c1, 'base64')).toString('utf8');
const d2 = crypto.privateDecrypt({ key: priv, padding: crypto.constants.RSA_PKCS1_PADDING }, Buffer.from(c2, 'base64')).toString('utf8');
console.log(JSON.stringify({ d1, d2 }));
''',
        base64Encode(utf8.encode(ref['rsa2048PrivPem'] as String)),
        encSpki,
        encPkcs1,
      ]);
      expect(verifyProc.exitCode, 0, reason: verifyProc.stderr.toString());
      final verified = jsonDecode(verifyProc.stdout.toString()) as Map;
      expect(verified['d1'], 'spki-secret');
      expect(verified['d2'], 'pkcs1-secret');

      // Zlib inflate / inflateRaw / gunzip
      expect(
        CatPawCrypto.zlibInflateBase64('inflate', ref['deflate'] as String),
        plain,
      );
      expect(
        CatPawCrypto.zlibInflateBase64(
          'inflateRaw',
          ref['deflateRaw'] as String,
        ),
        plain,
      );
      expect(
        CatPawCrypto.zlibInflateBase64('gunzip', ref['gzip'] as String),
        plain,
      );
      expect(
        () => CatPawCrypto.zlibInflate(
          'inflateRaw',
          base64Decode(ref['deflateRaw'] as String),
          maxOutputLength: 8,
        ),
        throwsFormatException,
      );
    });
  });

  group('HarmonyOS embedded CatPaw/DRPY/Guard engine', () {
    late Directory tempDir;
    late HttpServer mockSite;
    late CatPawHost host;

    setUp(() async {
      OhosRuntime.debugIsOhosOverride = true;
      tempDir = await Directory.systemTemp.createTemp('marco-ohos-catpaw-');
      mockSite = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mockSite.listen((HttpRequest req) async {
        final path = req.uri.path;
        if (path == '/home') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(
            '<html><body><ul class="items">'
            '<li><a href="/vod/101" title="鸿蒙测试片">鸿蒙测试片</a></li>'
            '</ul></body></html>',
          );
          await req.response.close();
          return;
        }
        if (path == '/gbk') {
          req.response.headers.set('Content-Type', 'text/html; charset=gbk');
          // GBK bytes for "中文" (0xD6 0xD0 0xCE 0xC4)
          req.response.add([0xD6, 0xD0, 0xCE, 0xC4]);
          await req.response.close();
          return;
        }
        if (path == '/redirect') {
          req.response.statusCode = 302;
          req.response.headers.set('Location', '/home');
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      host = CatPawHost(
        directory: () async => Directory('${tempDir.path}/catpaw'),
      );
    });

    tearDown(() async {
      await host.close();
      await mockSite.close(force: true);
      OhosRuntime.resetForTesting();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'runs DRPY2 home/detail/play/proxy, crypto hooks, local storage, and GBK decoding on HarmonyOS without Node',
      () async {
        final origin = 'http://127.0.0.1:${mockSite.port}';
        final rawDeflateSample = base64Encode(
          ZLibEncoder(raw: true).convert(utf8.encode('inflated-ok')),
        );
        final ruleSource = '''
var rule = {
  title: '鸿蒙测试站',
  host: ${jsonEncode(origin)},
  homeUrl: '/redirect',
  url: '/home?t=fyclass&pg=fypage',
  detailUrl: '/vod/fyid',
  class_name: '电影',
  class_url: '1',
  play_parse: true,
  预处理: 'js:rule._prep();',
  推荐: 'js:VODS=rule._list();',
  一级: 'js:VODS=rule._list();',
  二级: 'js:VOD=rule._detail();',
  搜索: 'js:VODS=rule._list();',
  lazy: 'js:input={parse:0,url:getProxy()+"&clip=101"};',
  proxy_rule: 'js:input=[200,"application/octet-stream","ABCDEFGH"];',
  _prep: function() {
    var html = request(HOST + '/redirect');
    var links = pdfa(html, '.items li');
    var firstTitle = links.length ? pdfh(links[0], 'a&&title') : '';
    var firstHref = links.length ? pd(links[0], 'a&&href', HOST) : '';
    local.set('ns', 'cachedTitle', firstTitle);
    this.class_name = firstTitle + '|' + firstHref;
    this.class_url = '1';
  },
  _list: function() {
    return [{ vod_id: '101', vod_name: local.get('ns', 'cachedTitle') || '' }];
  },
  _detail: function() {
    var cached = local.get('ns', 'cachedTitle');
    var gbkResp = req(HOST + '/gbk', {});
    var rand = new Uint8Array(16);
    crypto.getRandomValues(rand);
    var keyB64 = Buffer.from('0123456789abcdef0123456789abcdef', 'utf8').toString('base64');
    var ivB64 = Buffer.from('0123456789ab', 'utf8').toString('base64');
    var plainB64 = Buffer.from('secret-token', 'utf8').toString('base64');
    var enc = nodeCipher('encrypt', 'aes-256-gcm', keyB64, ivB64, plainB64, '');
    var dec = nodeCipher('decrypt', 'aes-256-gcm', keyB64, ivB64, enc.data, enc.tag);
    var inflated = Buffer.from(zlibInflate('inflateRaw', ${jsonEncode(rawDeflateSample)}), 'base64').toString('utf8');
    var combined = [cached, gbkResp.content, Buffer.from(dec.data, 'base64').toString('utf8'), inflated, String(rand.length)].join('|');
    return {
      vod_id: '101',
      vod_name: combined,
      vod_play_from: '测试线路',
      vod_play_url: '第1集\$101'
    };
  }
};
''';
        final manifest = <String, dynamic>{
          'version': 1,
          'kind': 'drpy',
          'runtime': CatPawHost.drpyRuntime,
          'sourceId': sha256.convert(utf8.encode('ohos-drpy-test')).toString(),
          'origin': '$origin/rule.js',
          'rule': ruleSource,
          'headers': <String, String>{},
          'requestTimeoutMs': 5000,
        };

        final address = await host.installDrpy(manifest);
        final homeRaw = await host.callDrpy(address, 'home', [true]);
        final home = jsonDecode(homeRaw) as Map<String, dynamic>;
        final classes = home['class'] as List;
        expect(classes, isNotEmpty);
        expect(
          (classes.first as Map)['type_name'],
          '鸿蒙测试片|$origin/vod/101',
        );

        final detailRaw = await host.callDrpy(address, 'detail', ['101']);
        final detail = jsonDecode(detailRaw) as Map<String, dynamic>;
        final vod = (detail['list'] as List).first as Map;
        expect(
          vod['vod_name'],
          '鸿蒙测试片|中文|secret-token|inflated-ok|16',
        );

        final playRaw = await host.callDrpy(address, 'play', [
          '测试线路',
          '101',
          <String>[],
        ]);
        final play = jsonDecode(playRaw) as Map<String, dynamic>;
        final playUrl = play['url'] as String;
        expect(playUrl, startsWith('catpaw://'));
        expect(playUrl, contains('/proxy?do=js&clip=101'));

        // Verify loopback proxy + HTTP 206 Range support
        final resolvedProxy = await host.resolve(playUrl);
        final client = HttpClient();
        try {
          final req = await client.getUrl(resolvedProxy);
          req.headers.set('Range', 'bytes=2-5');
          final resp = await req.close();
          expect(resp.statusCode, 206);
          final body = await utf8.decoder.bind(resp).join();
          expect(body, 'CDEF');
        } finally {
          client.close(force: true);
        }

        await host.releaseDrpy(address);
      },
    );

    test(
      'supports pkg:// local DRPY rule packages with sibling modules on HarmonyOS',
      () async {
        final manifest = <String, dynamic>{
          'version': 1,
          'kind': 'drpy',
          'runtime': CatPawHost.drpyRuntime,
          'sourceId': sha256.convert(utf8.encode('ohos-pkg-test')).toString(),
          'origin': 'pkg://local/rule.js',
          'modules': <String, String>{
            'pkg://local/helper.json': jsonEncode({'label': '本地模块成功'}),
          },
          'rule': r'''
var rule = {
  title: '本地规则包',
  host: 'https://pkg-fixture.invalid',
  class_name: '默认',
  class_url: '1',
  预处理: 'js:var h=JSON.parse(req("pkg://local/helper.json",{}).content);rule.class_name=h.label;',
  推荐: 'js:VODS=[];',
  一级: 'js:VODS=[];',
  二级: 'js:VOD={};',
  搜索: 'js:VODS=[];'
};
''',
          'headers': <String, String>{},
          'requestTimeoutMs': 5000,
        };

        final address = await host.installDrpy(manifest);
        final home =
            jsonDecode(await host.callDrpy(address, 'home', [true]))
                as Map<String, dynamic>;
        expect(((home['class'] as List).first as Map)['type_name'], '本地模块成功');
      },
    );

    test(
      'runs Guard bootstrap extractor inside QuickJS-NG on HarmonyOS without missing-component error',
      () async {
        // Build a minimal valid ZIP containing a dummy classes.dex so
        // drpy-guard-extractor.cjs exercises Buffer + zlib.inflateRawSync + crypto.createHash.
        final archive = Archive()
          ..addFile(
            ArchiveFile(
              'classes.dex',
              12,
              utf8.encode('dex\n035\x001234'),
            ),
          );
        final zipBytes = ZipEncoder().encode(archive);

        await expectLater(
          host.bootstrapGuard(zipBytes, adapter: 'dm84-v1'),
          throwsA(
            isA<GuardBootstrapException>().having(
              (e) => e.code,
              'code',
              anyOf('guard_artifact_invalid', 'guard_artifact_unsupported'),
            ),
          ),
        );
      },
    );

    test(
      'rejects Node.js CatPaw service bundles on HarmonyOS with an accurate message instead of missing-component error',
      () async {
        const fakeBundle =
            'module.exports = { start() { catServerFactory(); catDartServerPort(); } };';
        await expectLater(
          host.install(fakeBundle),
          throwsA(
            isA<StateError>()
                .having((e) => e.message, 'message', contains('鸿蒙端暂不支持'))
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('缺少 CatPaw 本机运行组件')),
                ),
          ),
        );
      },
    );
  });
}

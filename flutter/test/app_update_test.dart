import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/ohos_runtime.dart';

class _TestEd25519Signer {
  static final BigInt _q = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _l = (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d =
      (-BigInt.from(121665) * _inv(BigInt.from(121666))) % _q;
  static final BigInt _i =
      (BigInt.two).modPow((_q - BigInt.one) ~/ BigInt.from(4), _q);
  static final List<BigInt> _b = [
    _recoverX((BigInt.from(4) * _inv(BigInt.from(5))) % _q),
    (BigInt.from(4) * _inv(BigInt.from(5))) % _q,
  ];

  static BigInt _inv(BigInt x) => x.modPow(_q - BigInt.two, _q);

  static BigInt _recoverX(BigInt y) {
    final xx = ((y * y - BigInt.one) * _inv(_d * y * y + BigInt.one)) % _q;
    var x = xx.modPow((_q + BigInt.from(3)) ~/ BigInt.from(8), _q);
    if ((x * x - xx) % _q != BigInt.zero) x = (x * _i) % _q;
    if (x.isOdd) x = _q - x;
    return x;
  }

  static List<BigInt> _edwards(List<BigInt> p, List<BigInt> q) {
    final x1 = p[0], y1 = p[1], x2 = q[0], y2 = q[1];
    final x3 =
        ((x1 * y2 + x2 * y1) * _inv(BigInt.one + _d * x1 * x2 * y1 * y2)) % _q;
    final y3 =
        ((y1 * y2 + x1 * x2) * _inv(BigInt.one - _d * x1 * x2 * y1 * y2)) % _q;
    return [(x3 + _q) % _q, (y3 + _q) % _q];
  }

  static List<BigInt> _scalarMult(List<BigInt> p, BigInt e) {
    if (e == BigInt.zero) return [BigInt.zero, BigInt.one];
    var q = _scalarMult(p, e ~/ BigInt.two);
    q = _edwards(q, q);
    if (e.isOdd) q = _edwards(q, p);
    return q;
  }

  static Uint8List _encodePoint(List<BigInt> pt) {
    final x = pt[0], y = pt[1];
    final res = Uint8List(32);
    for (var i = 0; i < 255; i++) {
      if (((y >> i) & BigInt.one) == BigInt.one) {
        res[i ~/ 8] |= (1 << (i % 8));
      }
    }
    if (x.isOdd) res[31] |= 0x80;
    return res;
  }

  static BigInt _fromLe(List<int> bytes) {
    var r = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      r = (r << 8) | BigInt.from(bytes[i]);
    }
    return r;
  }

  static Uint8List _toLe32(BigInt v) {
    final out = Uint8List(32);
    var cur = v;
    for (var i = 0; i < 32; i++) {
      out[i] = (cur & BigInt.from(0xff)).toInt();
      cur = cur >> 8;
    }
    return out;
  }

  static Uint8List publicKeyFromSeed(Uint8List seed32) {
    final h = sha512.convert(seed32).bytes;
    var a = _fromLe(h.sublist(0, 32));
    a &= (BigInt.one << 254) - BigInt.from(8);
    a |= BigInt.one << 254;
    return _encodePoint(_scalarMult(_b, a));
  }

  static String signPayloadB64(Uint8List seed32, Map<String, dynamic> payload) {
    final canonical = AppUpdate.canonicalizeJson(payload);
    final msg = utf8.encode(canonical);
    final h = sha512.convert(seed32).bytes;
    var a = _fromLe(h.sublist(0, 32));
    a &= (BigInt.one << 254) - BigInt.from(8);
    a |= BigInt.one << 254;
    final aEnc = _encodePoint(_scalarMult(_b, a));
    final rHash = sha512.convert([...h.sublist(32, 64), ...msg]).bytes;
    final r = _fromLe(rHash) % _l;
    final rEnc = _encodePoint(_scalarMult(_b, r));
    final kHash = sha512.convert([...rEnc, ...aEnc, ...msg]).bytes;
    final k = _fromLe(kHash) % _l;
    final s = (r + k * a) % _l;
    return base64Encode([...rEnc, ..._toLe32(s)]);
  }
}

void main() {
  test('mirror error falls back to the actual GitHub asset and normalizes preview tag', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.host != 'api.github.com') return http.Response('', 500);
      return http.Response(jsonEncode({'tag_name': 'v0.4.37-preview', 'assets': [{
        'name': 'MarcoMovie-0.4.37-windows-setup.exe', 'size': 20,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.37-preview/MarcoMovie-0.4.37-windows-setup.exe',
      }]}), 200);
    });
    final release = await AppUpdate.check(client: client, platform: 'windows');
    expect(calls, 2);
    expect(release.version, '0.4.37');
    expect(release.windowsUrl!.path, isNot(contains('preview-preview')));
  });
  test('failed checks never return current version as a successful result', () async {
    await expectLater(AppUpdate.check(client: MockClient((_) async => http.Response('', 503))),
        throwsA(isA<HttpException>()));
  });
  test('missing metadata and foreign host cannot enable an installer', () {
    final release = AppUpdate.parse({'versionName': '0.4.37', 'windows': {
      'url': 'https://unknown.example/MarcoMovie-0.4.37-windows-setup.exe',
      'sha256': 'a' * 64, 'size': 20,
    }});
    expect(release.windowsUrl, isNull);
    expect(AppUpdate.parse({'versionName': '0.4.37'}).windowsUrl, isNull);
  });
  test('same-length corruption and truncated installers fail verification', () async {
    final dir = await Directory.systemTemp.createTemp('marco-update-check-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/installer.exe');
    final good = utf8.encode('verified installer fixture');
    final release = AppUpdate('0.4.37', '', Uri.parse('https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.37-preview/MarcoMovie-0.4.37-windows-setup.exe'), sha256.convert(good).toString(), good.length);
    await file.writeAsBytes(good);
    await release.verifyFile(file);
    await file.writeAsBytes(List.filled(good.length, 0));
    await expectLater(release.verifyFile(file), throwsFormatException);
    await file.writeAsBytes([1]);
    await expectLater(release.verifyFile(file), throwsFormatException);
  });

  test('platform releases do not upgrade other devices or choose a prerelease', () async {
    Map<String, dynamic> release(String platform, String version, String suffix,
        {bool prerelease = false}) => {
      'tag_name': '$platform-v$version', 'prerelease': prerelease,
      'assets': [{
        'name': 'MarcoMovie-$version-$suffix', 'size': 20,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/$platform-v$version/MarcoMovie-$version-$suffix',
      }],
    };
    final client = MockClient((request) async {
      if (request.url.host != 'api.github.com') return http.Response('', 404);
      return http.Response(jsonEncode([
        release('windows', '0.8.0', 'windows-setup.exe'),
        release('ios', '0.5.2', 'ios-unsigned.ipa', prerelease: true),
        release('ios', '0.5.1', 'ios-unsigned.ipa'),
        release('ios', '0.4.99', 'ios-unsigned.ipa'),
      ]), 200);
    });
    final ios = await AppUpdate.check(client: client, platform: 'ios');
    expect(ios.version, '0.5.1');
    expect(ios.windowsUrl, isNull);
    expect(ios.iosUrl, isNotNull);
    expect(
      ios.trollStoreInstallUrl.toString(),
      startsWith('apple-magnifier://install?url='),
    );
    final windows = await AppUpdate.check(client: client, platform: 'windows');
    expect(windows.version, '0.8.0');
    expect(windows.windowsUrl, isNotNull);
  });

  test('independent mirror feed wins without changing the legacy Android feed', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/movie/updates/ios.json');
      return http.Response(jsonEncode({
        'platform': 'ios', 'versionName': '0.5.1', 'notes': 'iPhone update',
        'package': {'url':'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.1-ios-unsigned.ipa',
          'size':100, 'sha256':'a' * 64},
      }), 200);
    });
    final release = await AppUpdate.check(client: client, platform: 'ios');
    expect(release.version, '0.5.1');
    expect(release.windowsUrl, isNull);
    expect(() => AppUpdate.parse({'platform': 'ios', 'versionName': '0.5.1'}),
        throwsFormatException);
  });

  test('unsigned mirror manifest logs notice and continues even when public key is configured', () async {
    final rng = Random(101);
    final seed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    final pubHex = _TestEd25519Signer.publicKeyFromSeed(seed)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    AppUpdate.debugPublicKeyHexOverride = pubHex;
    addTearDown(() => AppUpdate.debugPublicKeyHexOverride = null);

    final logs = <String>[];
    final prevDebugPrint = debugPrint;
    debugPrint = (String? msg, {int? wrapWidth}) {
      if (msg != null) logs.add(msg);
    };
    addTearDown(() => debugPrint = prevDebugPrint);

    expect(AppUpdate.defaultUpdatePublicKeyHex, isEmpty);

    final client = MockClient((request) async {
      expect(request.url.path, '/movie/updates/windows.json');
      return http.Response(jsonEncode({
        'platform': 'windows',
        'versionName': '0.5.30',
        'notes': 'Unsigned mirror update',
        'windows': {
          'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.30-windows-setup.exe',
          'sha256': 'b' * 64,
          'size': 2048,
        },
      }), 200);
    });

    final release = await AppUpdate.check(client: client, platform: 'windows');
    expect(release.version, '0.5.30');
    expect(
      release.windowsUrl.toString(),
      'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.30-windows-setup.exe',
    );
    expect(logs.any((l) => l.contains('signature')), isTrue);
  });

  test('invalid mirror signature skips mirror source and falls back to GitHub', () async {
    final rng = Random(202);
    final seed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    final pubHex = _TestEd25519Signer.publicKeyFromSeed(seed)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    AppUpdate.debugPublicKeyHexOverride = pubHex;
    addTearDown(() => AppUpdate.debugPublicKeyHexOverride = null);

    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.host != 'api.github.com') {
        return http.Response(jsonEncode({
          'platform': 'windows',
          'versionName': '0.9.99',
          'signature': base64Encode(List.filled(64, 0x42)),
          'windows': {
            'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.9.99-windows-setup.exe',
            'sha256': 'c' * 64,
            'size': 1024,
          },
        }), 200);
      }
      return http.Response(jsonEncode({
        'tag_name': 'v0.5.31',
        'assets': [
          {
            'name': 'MarcoMovie-0.5.31-windows-setup.exe',
            'size': 4096,
            'digest': 'sha256:${'d' * 64}',
            'browser_download_url':
                'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.5.31/MarcoMovie-0.5.31-windows-setup.exe',
          },
        ],
      }), 200);
    });

    final release = await AppUpdate.check(client: client, platform: 'windows');
    expect(calls, 2);
    expect(release.version, '0.5.31');
    expect(
      release.windowsUrl.toString(),
      'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.5.31/MarcoMovie-0.5.31-windows-setup.exe',
    );
  });

  test('validly signed payload parses only payload and rejects outer tampered windows.url', () async {
    final rng = Random(303);
    final seed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    final pubHex = _TestEd25519Signer.publicKeyFromSeed(seed)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    AppUpdate.debugPublicKeyHexOverride = pubHex;
    addTearDown(() => AppUpdate.debugPublicKeyHexOverride = null);

    final signedPayload = <String, dynamic>{
      'platform': 'windows',
      'versionName': '0.5.32',
      'notes': 'Signed payload notes',
      'windows': {
        'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.32-windows-setup.exe',
        'sha256': 'e' * 64,
        'size': 8192,
      },
    };
    final validSig = _TestEd25519Signer.signPayloadB64(seed, signedPayload);

    // 1. Clean envelope with only payload + signature succeeds and parses payload.
    final cleanClient = MockClient((request) async {
      return http.Response(jsonEncode({
        'payload': signedPayload,
        'signature': validSig,
      }), 200);
    });
    final verifiedRelease =
        await AppUpdate.check(client: cleanClient, platform: 'windows');
    expect(verifiedRelease.version, '0.5.32');
    expect(verifiedRelease.notes, 'Signed payload notes');
    expect(
      verifiedRelease.windowsUrl.toString(),
      'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.32-windows-setup.exe',
    );

    // 2. Wrapping a validly signed payload with a tampered outer windows.url MUST be rejected.
    final tamperedEnvelope = <String, dynamic>{
      'payload': signedPayload,
      'signature': validSig,
      'windows': {
        'url':
            'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.5.32/MarcoMovie-0.5.32-windows-setup.exe',
        'sha256': 'f' * 64,
        'size': 8192,
      },
    };
    expect(AppUpdate.verifyManifestSignature(tamperedEnvelope), isFalse);

    final tamperedClient = MockClient((request) async {
      if (request.url.host != 'api.github.com') {
        return http.Response(jsonEncode(tamperedEnvelope), 200);
      }
      return http.Response('', 404);
    });
    await expectLater(
      AppUpdate.check(client: tamperedClient, platform: 'windows'),
      throwsA(isA<HttpException>()),
    );
  });

  test('ReleaseNotesSummary condenses, deduplicates, categorizes and strips checksum clutter', () {
    const raw = '''
# Marco Movie Windows 0.5.18

发布日期：2026-11-12。应用版本：`0.5.18`（构建号 `68`）。本次更新升级沉浸式窗口与多线路兼容能力。

## 核心修复与优化

- **片源与网盘解析增强**：适配 32 款 WEX 插件并优化玩偶网盘分享解析（`ResilientHttpClient`）。
- **沉浸式窗口与中文安装向导**：Windows 标题栏升级沉浸式融合，安装程序全面切换简体中文。
- **修复更新后桌面重复图标**：覆盖升级不再重复创建桌面快捷方式。
- **片源与网盘解析增强**：适配 32 款 WEX 插件并优化玩偶网盘分享解析。

## 包信息与构建记录

- **安装版**：`MarcoMovie-0.5.18-windows-x64-setup.exe`，SHA-256：`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`。
- **构建提交**：`0123456789abcdef`。

## 验证范围与已知限制

- 通过公共内容守卫检查与全部自动化测试。
- 已知限制：第三方上游站点受自身网络波动影响。
''';
    final summary = ReleaseNotesSummary.parse(raw);
    expect(summary.overview, contains('本次更新升级沉浸式窗口'));
    expect(summary.overview, isNot(contains('发布日期')));
    expect(summary.totalItems, 4);
    final titles = summary.sections.map((s) => s.title).toList();
    expect(titles, containsAll(['片源与播放', '界面与交互', '问题修复与优化', '注意事项']));
    final plain = summary.toPlainText();
    expect(plain, isNot(contains('SHA-256')));
    expect(plain, isNot(contains('公共内容守卫')));
  });

  test('parseIosMajorVersion extracts major iOS version across OS strings', () {
    expect(AppUpdate.parseIosMajorVersion('Version 14.8.1 (Build 18H107)'), 14);
    expect(AppUpdate.parseIosMajorVersion('Version 15.0 (Build 19A346)'), 15);
    expect(AppUpdate.parseIosMajorVersion('Version 16.4 (Build 20E247)'), 16);
    expect(AppUpdate.parseIosMajorVersion('Version 26.5 (Build 23F10)'), 26);
    expect(AppUpdate.parseIosMajorVersion('iOS 14.4.2'), 14);
    expect(AppUpdate.parseIosMajorVersion('14.8'), 14);
    expect(AppUpdate.parseIosMajorVersion(''), isNull);
    expect(AppUpdate.parseIosMajorVersion('Windows 10 Pro'), isNull);
  });

  test('iOS 14 and iOS 15+ devices automatically pick matching IPA from mirror and GitHub', () async {
    final mainSha = '1' * 64;
    final ios14Sha = '2' * 64;
    final mirrorFeed = {
      'schema': 1,
      'platform': 'ios',
      'versionName': '0.7.5',
      'prerelease': false,
      'notes': 'iOS 0.7.5 dual package release',
      'packages': {
        'MarcoMovie-0.7.5-ios-iphone-ipad-unsigned.ipa': {
          'url':
              'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.7.5/MarcoMovie-0.7.5-ios-iphone-ipad-unsigned.ipa',
          'size': 63909667,
          'sha256': mainSha,
        },
        'MarcoMovie-0.7.5-ios14-unsigned.ipa': {
          'url':
              'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.7.5/MarcoMovie-0.7.5-ios14-unsigned.ipa',
          'size': 63911322,
          'sha256': ios14Sha,
        },
      },
    };
    final mirrorClient = MockClient((request) async {
      expect(request.url.path, '/movie/updates/ios.json');
      return http.Response(jsonEncode(mirrorFeed), 200);
    });

    // iOS 14 device picks ios14-unsigned.ipa from mirror.
    AppUpdate.debugIosMajorVersionOverride = 14;
    addTearDown(() => AppUpdate.debugIosMajorVersionOverride = null);
    final ios14Release =
        await AppUpdate.check(client: mirrorClient, platform: 'ios');
    expect(ios14Release.version, '0.7.5');
    expect(ios14Release.isIos14Compat, isTrue);
    expect(
      ios14Release.iosUrl.toString(),
      endsWith('/MarcoMovie-0.7.5-ios14-unsigned.ipa'),
    );
    expect(ios14Release.checksum, ios14Sha);
    expect(ios14Release.size, 63911322);

    // iOS 26 / iOS 15+ device picks main ios-iphone-ipad-unsigned.ipa from mirror.
    AppUpdate.debugIosMajorVersionOverride = 26;
    final ios26Release =
        await AppUpdate.check(client: mirrorClient, platform: 'ios');
    expect(ios26Release.version, '0.7.5');
    expect(ios26Release.isIos14Compat, isFalse);
    expect(
      ios26Release.iosUrl.toString(),
      endsWith('/MarcoMovie-0.7.5-ios-iphone-ipad-unsigned.ipa'),
    );
    expect(ios26Release.checksum, mainSha);
    expect(ios26Release.size, 63909667);

    // Mirror lacking ios14 package must NOT serve the iOS 15+ IPA to iOS 14;
    // it falls back to GitHub Releases and selects the newest release carrying ios14.
    var githubCalls = 0;
    final fallbackClient = MockClient((request) async {
      if (request.url.host != 'api.github.com') {
        return http.Response(
          jsonEncode({
            'schema': 1,
            'platform': 'ios',
            'versionName': '0.7.6',
            'prerelease': false,
            'packages': {
              'MarcoMovie-0.7.6-ios-iphone-ipad-unsigned.ipa': {
                'url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.7.6/MarcoMovie-0.7.6-ios-iphone-ipad-unsigned.ipa',
                'size': 64000000,
                'sha256': '3' * 64,
              },
            },
          }),
          200,
        );
      }
      githubCalls++;
      return http.Response(
        jsonEncode([
          {
            'tag_name': 'ios-v0.7.6',
            'draft': false,
            'prerelease': false,
            'assets': [
              {
                'name': 'MarcoMovie-0.7.6-ios-iphone-ipad-unsigned.ipa',
                'size': 64000000,
                'digest': 'sha256:${'3' * 64}',
                'browser_download_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.7.6/MarcoMovie-0.7.6-ios-iphone-ipad-unsigned.ipa',
              },
            ],
          },
          {
            'tag_name': 'ios-v0.7.5',
            'draft': false,
            'prerelease': false,
            'assets': [
              {
                'name': 'MarcoMovie-0.7.5-ios-iphone-ipad-unsigned.ipa',
                'size': 63909667,
                'digest': 'sha256:$mainSha',
                'browser_download_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.7.5/MarcoMovie-0.7.5-ios-iphone-ipad-unsigned.ipa',
              },
              {
                'name': 'MarcoMovie-0.7.5-ios14-unsigned.ipa',
                'size': 63911322,
                'digest': 'sha256:$ios14Sha',
                'browser_download_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/download/ios-v0.7.5/MarcoMovie-0.7.5-ios14-unsigned.ipa',
              },
            ],
          },
        ]),
        200,
      );
    });
    AppUpdate.debugIosMajorVersionOverride = 14;
    final fallbackIos14 =
        await AppUpdate.check(client: fallbackClient, platform: 'ios');
    expect(githubCalls, 1);
    expect(fallbackIos14.version, '0.7.5');
    expect(fallbackIos14.isIos14Compat, isTrue);
    expect(
      fallbackIos14.iosUrl.toString(),
      endsWith('/MarcoMovie-0.7.5-ios14-unsigned.ipa'),
    );
  });

  group('HarmonyOS NEXT independent update channel', () {
    tearDown(() {
      OhosRuntime.resetForTesting();
      AppUpdate.debugHttpClientOverride = null;
    });

    test('currentPlatform resolves harmonyos explicitly when running on OHOS', () {
      OhosRuntime.debugIsOhosOverride = true;
      expect(AppUpdate.currentPlatform, 'harmonyos');
    });

    test('reads /movie/updates/harmonyos.json packages and verifies HAP metadata & file digest', () async {
      OhosRuntime.debugIsOhosOverride = true;
      final hapBytes = utf8.encode('harmonyos-candidate-hap-fixture');
      final digest = sha256.convert(hapBytes).toString();
      final requestedPaths = <String>[];
      final client = MockClient((request) async {
        requestedPaths.add(request.url.path);
        expect(request.url.path, '/movie/updates/harmonyos.json');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'schema': 1,
              'platform': 'harmonyos',
              'versionName': '0.1.2',
              'prerelease': false,
              'notes': '# Marco Movie HarmonyOS NEXT 0.1.2\n- 修复凭据存储与独立更新',
              'packages': {
                'MarcoMovie-0.1.2-harmonyos-universal.hap': {
                  'size': hapBytes.length,
                  'sha256': digest,
                  'url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
                },
              },
              'release_url':
                  'https://github.com/Pilipala9919/MarcoMovie/releases/tag/harmonyos-v0.1.2',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final release = await AppUpdate.check(client: client);
      expect(requestedPaths, ['/movie/updates/harmonyos.json']);
      expect(release.version, '0.1.2');
      expect(release.windowsUrl, isNull);
      expect(release.iosUrl, isNull);
      expect(
        release.harmonyosUrl.toString(),
        'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
      );
      expect(release.packageFileName, 'MarcoMovie-0.1.2-harmonyos-universal.hap');
      expect(release.size, hapBytes.length);
      expect(release.checksum, digest);
      expect(
        release.releaseUrl.toString(),
        'https://github.com/Pilipala9919/MarcoMovie/releases/tag/harmonyos-v0.1.2',
      );
      expect(AppUpdate.isRemoteVersionNewer('0.1.2', '0.1.1'), isTrue);
      expect(AppUpdate.isRemoteVersionNewer('0.1.2', '0.1.2'), isFalse);

      final dir = await Directory.systemTemp.createTemp('marco-ohos-verify-');
      addTearDown(() => dir.delete(recursive: true));
      final hapFile = File('${dir.path}/MarcoMovie-0.1.2-harmonyos-universal.hap');
      await hapFile.writeAsBytes(hapBytes);
      await release.verifyFile(hapFile);
      await hapFile.writeAsBytes(utf8.encode('corrupted-candidate-hap-fixture'));
      await expectLater(release.verifyFile(hapFile), throwsFormatException);
    });

    test('falls back to GitHub harmonyos-v release and rejects APK / bad digest / offline', () async {
      OhosRuntime.debugIsOhosOverride = true;
      final goodDigest = 'b' * 64;
      // 1) Mirror returns APK -> must be rejected and fall back to GitHub harmonyos release
      final fallbackClient = MockClient((request) async {
        if (request.url.host != 'api.github.com') {
          return http.Response(
            jsonEncode({
              'platform': 'harmonyos',
              'versionName': '0.9.9',
              'packages': {
                'MarcoMovie-0.9.9-harmonyos-universal.hap': {
                  'size': 200,
                  'sha256': goodDigest,
                  'url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.9.9/MarcoMovie-0.9.9-android-mobile.apk',
                },
              },
            }),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              {
                'tag_name': 'v0.7.1',
                'prerelease': false,
                'assets': [
                  {
                    'name': 'MarcoMovie-0.7.1-mobile.apk',
                    'size': 200,
                    'digest': 'sha256:$goodDigest',
                    'browser_download_url':
                        'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.7.1/MarcoMovie-0.7.1-mobile.apk',
                  },
                ],
              },
              {
                'tag_name': 'harmonyos-v0.1.2',
                'prerelease': false,
                'body': 'GitHub 鸿蒙正式包',
                'html_url':
                    'https://github.com/Pilipala9919/MarcoMovie/releases/tag/harmonyos-v0.1.2',
                'assets': [
                  {
                    'name': 'MarcoMovie-0.1.2-harmonyos-universal.hap',
                    'size': 39500000,
                    'digest': 'sha256:$goodDigest',
                    'browser_download_url':
                        'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
                  },
                ],
              },
            ]),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final fromGithub = await AppUpdate.check(client: fallbackClient);
      expect(fromGithub.version, '0.1.2');
      expect(fromGithub.harmonyosUrl!.path, endsWith('-harmonyos-universal.hap'));

      // 2) Both endpoints return APK -> must fail
      final apkOnlyClient = MockClient((request) async {
        if (request.url.host != 'api.github.com') {
          return http.Response(
            jsonEncode({
              'platform': 'android',
              'versionName': '0.7.0',
              'packages': {
                'MarcoMovie-0.7.0-mobile.apk': {
                  'size': 100,
                  'sha256': goodDigest,
                  'url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.7.0/MarcoMovie-0.7.0-mobile.apk',
                },
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode([
            {
              'tag_name': 'harmonyos-v0.1.2',
              'assets': [
                {
                  'name': 'MarcoMovie-0.1.2-mobile.apk',
                  'size': 100,
                  'digest': 'sha256:$goodDigest',
                  'browser_download_url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-mobile.apk',
                },
              ],
            },
          ]),
          200,
        );
      });
      await expectLater(
        AppUpdate.check(client: apkOnlyClient),
        throwsA(isA<HttpException>()),
      );

      // 3) Bad SHA-256 digest -> must be rejected
      final badDigestClient = MockClient((request) async {
        if (request.url.host != 'api.github.com') {
          return http.Response(
            jsonEncode({
              'platform': 'harmonyos',
              'versionName': '0.1.2',
              'packages': {
                'MarcoMovie-0.1.2-harmonyos-universal.hap': {
                  'size': 12345,
                  'sha256': 'not-a-valid-sha256',
                  'url':
                      'https://github.com/Pilipala9919/MarcoMovie/releases/download/harmonyos-v0.1.2/MarcoMovie-0.1.2-harmonyos-universal.hap',
                },
              },
            }),
            200,
          );
        }
        return http.Response('[]', 200);
      });
      await expectLater(
        AppUpdate.check(client: badDigestClient),
        throwsA(isA<HttpException>()),
      );

      // 4) Offline -> throws HttpException
      final offlineClient = MockClient((_) async {
        throw const SocketException('Network unreachable');
      });
      await expectLater(
        AppUpdate.check(client: offlineClient),
        throwsA(isA<HttpException>()),
      );
    });

    test('compareVersions distinguishes remote newer, equal, and remote older', () {
      expect(AppUpdate.compareVersions('0.1.3', '0.1.2'), greaterThan(0));
      expect(AppUpdate.compareVersions('0.1.2', '0.1.2'), 0);
      expect(AppUpdate.compareVersions('v0.1.2', '0.1.2'), 0);
      expect(AppUpdate.compareVersions('0.1.1', '0.1.2'), lessThan(0));
      expect(AppUpdate.compareVersions('v0.1.1', '0.1.2'), lessThan(0));
      expect(AppUpdate.isRemoteVersionNewer('0.1.3', '0.1.2'), isTrue);
      expect(AppUpdate.isRemoteVersionNewer('0.1.2', '0.1.2'), isFalse);
      expect(AppUpdate.isRemoteVersionNewer('0.1.1', '0.1.2'), isFalse);
    });
  });
}

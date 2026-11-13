import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/drpy_source.dart';
import 'package:marco_movie/core/guard_source.dart';
import 'package:marco_movie/core/models.dart';

class PortHost extends CatPawHost {
  int bootstraps = 0;
  String? failure;
  Map<String, Object?>? playback;
  Map<String, dynamic>? manifest;
  final adapters = <String>[];
  final extensions = <String?>[];
  final installed = <String, Map<String, dynamic>>{};
  final invoked = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> bootstrapGuard(
    List<int> bytes, {
    String adapter = 'dm84-v1',
    String? extension,
    Completer<void>? cancellation,
  }) async {
    bootstraps++;
    adapters.add(adapter);
    extensions.add(extension);
    if (failure != null)
      throw GuardBootstrapException(failure!, 'Synthetic bootstrap failure');
    return {
      'version': 1,
      'origin': 'https://catalogue.invalid/',
      'rule':
          'var rule={title:${jsonEncode('$adapter fixture ${extension ?? ''}')},host:"https://catalogue.invalid"};',
    };
  }

  @override
  Future<String> installDrpy(Object value) async {
    manifest = Map<String, dynamic>.from(value as Map);
    final address =
        'catpaw://${sha256.convert(utf8.encode(jsonEncode(manifest)))}/api/drpy';
    installed[address] = manifest!;
    return address;
  }

  @override
  Future<String> callDrpy(
    String address,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    invoked.add(installed[address]!);
    return jsonEncode(
      method == 'play' && playback != null
          ? playback
          : {'method': method, 'list': []},
    );
  }
}

void main() {
  final bytes = Uint8List.fromList([0x50, 0x4b, 3, 4, 1, 2, 3]);
  final digest = md5.convert(bytes).toString();
  CmsSite site(String reference) => CmsSite(
    key: 'dm84',
    name: 'Imported rule',
    type: 3,
    api: 'csp_Dm84Guard',
    jar: reference,
    subscriptionId: 'one',
    headers: {
      'Authorization': 'import credential',
      'Cookie': 'import=fixture',
      'User-Agent': 'Fixture',
    },
  );

  test(
    'exact aliases select adapters and unknown Guard names never download',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      for (final api in [
        'csp_Dm84Guard',
        'csp_Dm84',
        'csp_AueteGuard',
        'csp_Auete',
        'csp_BttwooGuard',
        'csp_Bttwoo',
        'csp_AppgzGuard',
        'csp_Appgz',
        'csp_T4Guard',
        'csp_T4',
        'csp_AppTTGuard',
        'csp_AppTT',
        'csp_FyGuard',
        'csp_Fy',
      ]) {
        final source = site(
          'https://import.invalid/plugin.jar',
        ).copyWith(api: api);
        expect(GuardSource.supports(source), isTrue, reason: api);
        expect(source.canBrowse, isTrue, reason: api);
      }
      for (final api in [
        'csp_UnknownGuard',
        'csp_AueteOtherGuard',
        'csp_BttwooOtherGuard',
        'csp_Dm84Guard/extra',
        'csp_T4OtherGuard',
        'csp_AppTTOtherGuard',
        'csp_AppgzOtherGuard',
        'csp_FyOtherGuard',
      ]) {
        final source = site(
          'https://import.invalid/plugin.jar',
        ).copyWith(api: api);
        expect(GuardSource.supports(source), isFalse);
        await expectLater(
          guard.invoke(source, 'home', [false]),
          throwsFormatException,
        );
      }
      expect(
        GuardSource.supports(
          site('https://import.invalid/plugin.jar').copyWith(type: 1),
        ),
        isFalse,
      );
      expect(downloads, 0);
      expect(host.bootstraps, 0);
    },
  );

  test(
    'T4 extension is forwarded and separates cached configuration',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final first = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_T4Guard', ext: 'Zmlyc3Q=');
      final second = first.copyWith(ext: 'c2Vjb25k');
      await guard.invoke(first, 'home', [false]);
      final firstRule = host.invoked.last['rule'];
      await guard.invoke(second, 'home', [false]);
      expect(host.invoked.last['rule'], isNot(firstRule));
      await guard.invoke(first.copyWith(api: 'csp_T4'), 'home', [false]);
      expect(host.invoked.last['rule'], firstRule);
      expect(host.extensions, ['Zmlyc3Q=', 'c2Vjb25k']);
      expect(downloads, 2);
      for (final invalid in ['', '汉' * 6000]) {
        await expectLater(
          guard.invoke(first.copyWith(ext: invalid), 'home', [false]),
          throwsFormatException,
        );
      }
      expect(downloads, 2);
    },
  );

  test(
    'AppTT extension is forwarded and separates cached configuration',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final first = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_AppTTGuard', ext: 'Zmlyc3Q=');
      final second = first.copyWith(ext: 'c2Vjb25k');
      await guard.invoke(first, 'home', [false]);
      final firstRule = host.invoked.last['rule'];
      await guard.invoke(second, 'home', [false]);
      expect(host.invoked.last['rule'], isNot(firstRule));
      await guard.invoke(first.copyWith(api: 'csp_AppTT'), 'home', [false]);
      expect(host.invoked.last['rule'], firstRule);
      expect(host.adapters, ['apptt-v1', 'apptt-v1']);
      expect(host.extensions, ['Zmlyc3Q=', 'c2Vjb25k']);
      expect(downloads, 2);
      for (final invalid in ['', '汉' * 6000]) {
        await expectLater(
          guard.invoke(first.copyWith(ext: invalid), 'home', [false]),
          throwsFormatException,
        );
      }
      expect(downloads, 2);
    },
  );

  test(
    'one owner key and JAR keep adapter cache, manifest and state isolated',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final dm84 = site('https://import.invalid/plugin.jar;md5;$digest');
      final auete = dm84.copyWith(api: 'csp_AueteGuard');
      final bttwoo = dm84.copyWith(api: 'csp_BttwooGuard');
      await guard.invoke(dm84, 'home', [false]);
      final dmManifest = host.invoked.last;
      await guard.invoke(auete, 'home', [false]);
      final aueteManifest = host.invoked.last;
      await guard.invoke(bttwoo, 'home', [false]);
      final bttwooManifest = host.invoked.last;
      expect(dmManifest['rule'], contains('dm84-v1'));
      expect(aueteManifest['rule'], contains('auete-v1'));
      expect(aueteManifest['sourceId'], isNot(dmManifest['sourceId']));
      expect(bttwooManifest['rule'], contains('bttwoo-v1'));
      expect({
        dmManifest['sourceId'],
        aueteManifest['sourceId'],
        bttwooManifest['sourceId'],
      }, hasLength(3));
      await guard.invoke(dm84, 'search', ['one', false, 1]);
      expect(host.invoked.last, dmManifest);
      await guard.invoke(auete.copyWith(api: 'csp_Auete'), 'search', [
        'two',
        false,
        1,
      ]);
      expect(host.invoked.last['sourceId'], aueteManifest['sourceId']);
      await guard.invoke(bttwoo.copyWith(api: 'csp_Bttwoo'), 'search', [
        'three',
        false,
        1,
      ]);
      expect(host.invoked.last['sourceId'], bttwooManifest['sourceId']);
      expect(host.adapters, ['dm84-v1', 'auete-v1', 'bttwoo-v1']);
      expect(downloads, 3);
      expect(dm84.key, 'dm84');
      expect(auete.key, 'dm84');
      expect(dm84.subscriptionId, 'one');
      expect(auete.subscriptionId, 'one');
      expect(dm84.api, 'csp_Dm84Guard');
      expect(auete.api, 'csp_AueteGuard');
      expect(dm84.jar, auete.jar);
      expect(bttwoo.key, dm84.key);
      expect(bttwoo.subscriptionId, dm84.subscriptionId);
      expect(bttwoo.jar, dm84.jar);
      expect(bttwoo.api, 'csp_BttwooGuard');
    },
  );

  test(
    'Auete siteUrl variants fail explicitly before download or cached execution',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final source = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_AueteGuard');
      for (final override in [
        'https://custom.invalid/',
        'https://catalogue.invalid/',
      ]) {
        final configured = source.copyWith(
          ext: jsonEncode({'siteUrl': override}),
        );
        await expectLater(
          guard.invoke(configured, 'home', [false]),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('siteUrl'),
            ),
          ),
        );
      }
      expect(downloads, 0);
      expect(host.bootstraps, 0);
      await guard.invoke(source.copyWith(ext: '{"siteUrl":""}'), 'home', [
        false,
      ]);
      expect(downloads, 1);
      final calls = host.invoked.length;
      await expectLater(
        guard.invoke(
          source.copyWith(ext: '{"siteUrl":"https://custom.invalid/"}'),
          'home',
          [false],
        ),
        throwsFormatException,
      );
      expect(downloads, 1);
      expect(host.invoked.length, calls);
    },
  );

  test(
    'Bttwoo siteUrl variants fail before downloading or reusing cache',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      final source = site(
        'https://import.invalid/plugin.jar',
      ).copyWith(api: 'csp_BttwooGuard');
      final override = source.copyWith(
        ext: '{"siteUrl":"https://custom.invalid/"}',
      );
      await expectLater(
        guard.invoke(override, 'home', [false]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Bttwoo 自定义 siteUrl'),
          ),
        ),
      );
      expect(downloads, 0);
      expect(host.bootstraps, 0);
      await guard.invoke(source.copyWith(ext: '{"siteUrl":""}'), 'home', [
        false,
      ]);
      final calls = host.invoked.length;
      await expectLater(
        guard.invoke(override, 'home', [false]),
        throwsFormatException,
      );
      expect(downloads, 1);
      expect(host.invoked.length, calls);
    },
  );

  test(
    'ownerless Auete imports retain their independent origin identity',
    () async {
      final host = PortHost();
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async => bytes,
      );
      final first = site(
        'https://first.invalid/plugin.jar',
      ).copyWith(api: 'csp_AueteGuard', subscriptionId: '');
      final second = first.copyWith(jar: 'https://second.invalid/plugin.jar');
      await guard.invoke(first, 'home', [false]);
      final firstId = host.invoked.last['sourceId'];
      await guard.invoke(second, 'home', [false]);
      expect(host.invoked.last['sourceId'], isNot(firstId));
      expect(first.subscriptionId, isEmpty);
      expect(second.subscriptionId, isEmpty);
    },
  );

  test(
    'artifact integrity is verified before local bootstrap and download auth stays scoped',
    () async {
      final host = PortHost();
      var downloads = 0;
      final drpy = DrpySource(
        host: host,
        read: (_, __) async => throw StateError('rule is already local'),
      );
      final guard = GuardSource(
        host: host,
        drpy: drpy,
        read: (url, headers) async {
          downloads++;
          expect(url, 'https://import.invalid/plugin.jar');
          expect(headers['Authorization'], 'import credential');
          return bytes;
        },
      );
      final source = site('https://import.invalid/plugin.jar;md5;$digest');
      expect(GuardSource.supports(source), isTrue);
      expect(source.canBrowse, isTrue);
      expect(
        GuardSource.supports(source.copyWith(api: 'csp_UnknownGuard')),
        isFalse,
      );
      expect(GuardSource.supports(source.copyWith(jar: '')), isFalse);
      await guard.invoke(source, 'home', [false]);
      await guard.invoke(source, 'search', ['影片', false, 1]);
      expect(downloads, 1);
      expect(host.bootstraps, 1);
      expect(host.manifest!['origin'], 'https://catalogue.invalid/');
      expect(host.manifest!['headers'], {'User-Agent': 'Fixture'});
    },
  );

  test(
    'malformed and mismatched explicit MD5 never fall back to another plugin',
    () async {
      final host = PortHost();
      var downloads = 0;
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async {
          downloads++;
          return bytes;
        },
      );
      await expectLater(
        guard.invoke(
          site('https://import.invalid/plugin.jar;md5;broken'),
          'home',
          [false],
        ),
        throwsFormatException,
      );
      expect(downloads, 0);
      for (final suffix in [
        '',
        ' ',
        '$digest ',
        ' $digest',
        '$digest;md5;$digest',
      ]) {
        await expectLater(
          guard.invoke(
            site('https://import.invalid/plugin.jar;MD5;$suffix'),
            'home',
            [false],
          ),
          throwsFormatException,
        );
      }
      expect(downloads, 0);
      await expectLater(
        guard.invoke(
          site('https://import.invalid/plugin.jar;md5;${'0' * 32}'),
          'home',
          [false],
        ),
        throwsFormatException,
      );
      expect(downloads, 1);
      expect(host.bootstraps, 0);
      final cancelled = Completer<void>()..complete();
      await expectLater(
        guard.invoke(site('https://import.invalid/plugin.jar'), 'home', [
          false,
        ], cancellation: cancelled),
        throwsFormatException,
      );
      expect(downloads, 1);
    },
  );

  test('unsupported plugin version remains an explicit failure', () async {
    final host = PortHost()..failure = 'guard_artifact_unsupported';
    final guard = GuardSource(
      host: host,
      drpy: DrpySource(host: host, read: (_, __) async => ''),
      read: (_, __) async => bytes,
    );
    await expectLater(
      guard.invoke(site('https://import.invalid/plugin.jar'), 'home', [false]),
      throwsA(
        isA<GuardBootstrapException>().having(
          (e) => e.code,
          'code',
          'guard_artifact_unsupported',
        ),
      ),
    );
    expect(host.manifest, isNull);
  });

  test(
    'plugin import credentials never become implicit playback headers',
    () async {
      final host = PortHost()
        ..playback = {
          'parse': 0,
          'url': 'https://import.invalid/video.mp4',
          'header': {
            'User-Agent': 'Adapter playback',
            'X-Playback': 'explicit',
          },
        };
      final client = CmsClient(
        scriptHost: host,
        client: MockClient((request) async => http.Response.bytes(bytes, 200)),
      );
      final source = site(
        'https://import.invalid/plugin.jar;md5;$digest',
      ).copyWith(ext: 'https://import.invalid/');
      final resolved = await client.resolveEpisodeForPlayback(
        source,
        const CmsEpisode(
          name: 'Episode',
          url: 'mmjs://play?id=episode&flag=main',
        ),
      );
      expect(resolved.headers, {
        'User-Agent': 'Adapter playback',
        'X-Playback': 'explicit',
      });
    },
  );

  test(
    'concurrent search across six Guard sites sharing one JAR downloads once',
    () async {
      final host = PortHost();
      var downloads = 0;
      final gate = Completer<Uint8List>();
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) {
          downloads++;
          return gate.future;
        },
      );
      final base = site('https://import.invalid/plugin.jar;md5;$digest');
      final sites = [
        base.copyWith(key: 't4a', api: 'csp_T4Guard', ext: 'ZXh0LTE='),
        base.copyWith(key: 'auete', api: 'csp_AueteGuard'),
        base.copyWith(key: 't4b', api: 'csp_T4Guard', ext: 'ZXh0LTI='),
        base.copyWith(key: 'bttwoo', api: 'csp_BttwooGuard'),
        base.copyWith(key: 'dm84', api: 'csp_Dm84Guard'),
        base.copyWith(key: 'fy', api: 'csp_FyGuard'),
      ];
      final futures = [
        for (final s in sites) guard.invoke(s, 'search', ['斗罗大陆', false, 1]),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete(bytes);
      final results = await Future.wait(futures);
      expect(results, hasLength(6));
      expect(downloads, 1);
      expect(host.bootstraps, 6);
    },
  );

  test(
    'WEX VOD and Pan Guard adapters map cleanly with optional extensions and netdisk classification',
    () async {
      final host = PortHost();
      final guard = GuardSource(
        host: host,
        drpy: DrpySource(host: host, read: (_, __) async => ''),
        read: (_, __) async => bytes,
      );
      final base = site('https://import.invalid/plugin.jar;md5;$digest');
      const vodApis = [
        'csp_WexAppV7Guard',
        'csp_WexAiGuaziGuard',
        'csp_WexAiDuBoKuGuard',
        'csp_WexAiWenCaiGuard',
        'csp_WexFengYe4KGuard',
        'csp_WexAiFengYeGuard',
        'csp_WexAiJianPianGuard',
        'csp_WexAiJuXiaFanGuard',
        'csp_WexAiReBoGuard',
        'csp_WexAiBoBoGuard',
        'csp_WexAiIkanBotGuard',
        'csp_AiNewIkanbotGuard',
        'csp_WexAiYiYsGuard',
        'csp_AiNewYiYsGuard',
        'csp_WexAiHanXiaoQuanGuard',
      ];
      for (final api in vodApis) {
        final s = base.copyWith(api: api, name: '线路', ext: 'AppV7Dsx');
        expect(GuardSource.supports(s), isTrue, reason: api);
        expect(s.canBrowse, isTrue, reason: api);
        await guard.invoke(s, 'home', [false]);
      }
      expect(host.extensions.every((e) => e == 'AppV7Dsx'), isTrue);

      const panApis = [
        'csp_AiNewDuoduoGuard',
        'csp_AiNewHubanGuard',
        'csp_AiNewKuaiYingGuard',
        'csp_AiNewLabiGuard',
        'csp_AiNewMuouGuard',
        'csp_AiNewShanDianGuard',
        'csp_AiNewXiaoPanGuard',
        'csp_AiNewZhiZhenGuard',
        'csp_AiNewWoggGuard',
        'csp_AiNewHuajuanGuard',
        'csp_AiNewJuTouGuard',
        'csp_AiNewZhiNan4KGuard',
        'csp_AiNewWoNiu4KGuard',
        'csp_AiNewPianKuGuard',
        'csp_AiQwMkvGuard',
        'csp_AiNewYiDong4KGuard',
        'csp_SoAiAiPanSoGuard',
        'csp_SoAiHaiYinGuard',
        'csp_SoAiQuanPanGuard',
        'csp_SoKakaGuard',
      ];
      for (final api in panApis) {
        final s = base.copyWith(api: api, name: '4K线路');
        expect(GuardSource.supports(s), isTrue, reason: api);
        expect(s.canBrowse, isTrue, reason: api);
      }

      // Challenge/PoW/comment-gated spiders remain unadapted by policy.
      for (final gated in [
        'csp_AiNewGuanYingGuard',
        'csp_WexAiYueYueGuard',
        'csp_AiNewLibvioGuard',
        'csp_SoAiPanSooGuard',
        'csp_AiPan1MeGuard',
      ]) {
        final s = base.copyWith(api: gated);
        expect(GuardSource.supports(s), isFalse, reason: gated);
        if (gated == 'csp_AiPan1MeGuard') {
          expect(s.unsupportedReason, '该线路依赖论坛回复解锁，当前设备暂不支持');
        } else {
          expect(s.unsupportedReason, '该线路依赖交互式人机验证，当前设备暂不支持');
        }
      }

      // Every Guard adapter mapped by CspBridge must pass CatPawHost.bootstrapGuard allowlist validation.
      final realHost = CatPawHost(
        directory: () => Future<Directory>.error(StateError('passed_validation')),
      );
      final allApis = <String>[
        'csp_Dm84Guard',
        'csp_AueteGuard',
        'csp_BttwooGuard',
        'csp_AppgzGuard',
        'csp_T4Guard',
        'csp_AppTTGuard',
        'csp_FyGuard',
        'csp_JpysGuard',
        'csp_JpjGuard',
        'csp_NmyswvGuard',
        'csp_HmysGuard',
        'csp_App99Guard',
        'csp_AppSxGuard',
        'csp_NewCzGuard',
        'csp_LibvioGuard',
        'csp_YgpGuard',
        'csp_KanqiuGuard',
        'csp_DoubaoGuard',
        'csp_LiveGzGuard',
        'csp_AllliveGuard',
        'csp_Tingshu275Guard',
        'csp_YuetingGuard',
        'csp_SeedhubGuard',
        'csp_S_zpsGuard',
        'csp_YpanSoGuard',
        'csp_BpanSoGuard',
        'csp_KkSsGuard',
        'csp_UuSsGuard',
        ...vodApis,
        ...panApis,
      ];
      const strictRequiredExt = {'t4-v1', 'apptt-v1', 'app99-v1', 'appsx-v1'};
      const baseNoExt = {'dm84-v1', 'auete-v1', 'bttwoo-v1', 'appgz-v1', 'fy-v1'};
      for (final api in allApis) {
        final adapter = CspBridge.guardAdapterFor(base.copyWith(api: api));
        expect(adapter, isNotNull, reason: api);
        final ext = baseNoExt.contains(adapter) ? null : 'fixture';
        await expectLater(
          realHost.bootstrapGuard([1, 2, 3], adapter: adapter!, extension: ext),
          throwsA(isA<StateError>()),
          reason: '$api ($adapter, ext=$ext)',
        );
        if (!strictRequiredExt.contains(adapter) && !baseNoExt.contains(adapter)) {
          await expectLater(
            realHost.bootstrapGuard([1, 2, 3], adapter: adapter),
            throwsA(isA<StateError>()),
            reason: '$api ($adapter, ext=null)',
          );
        }
      }
    },
  );
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_features.dart';
import 'package:marco_movie/core/ai_lab_passcode.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/ed25519.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_ai_lab_sheets.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_download_groups_view.dart';
import 'package:marco_movie/ui/ios_glass_popover.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

// ============================================================================
// Pure-Dart RFC 8032 Ed25519 test signer (issues test-only passcodes)
// ============================================================================
class _TestEd25519Signer {
  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _l =
      (BigInt.one << 252) + BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d =
      BigInt.from(-121665) * _modInv(BigInt.from(121666), _p) % _p;
  static final BigInt _bx = BigInt.parse(
    '15112221349535400772501151409588531511454012693041857206046113283949847762202',
  );
  static final BigInt _by = BigInt.parse(
    '46316835694926478169428394003475163141307993866256225615783033603165251855960',
  );

  static BigInt _mod(BigInt a, BigInt m) => ((a % m) + m) % m;
  static BigInt _modInv(BigInt a, BigInt m) => _mod(a, m).modPow(m - BigInt.two, m);

  static List<BigInt> _pointAdd(List<BigInt> p1, List<BigInt> p2) {
    final x1 = p1[0], y1 = p1[1], z1 = p1[2], t1 = p1[3];
    final x2 = p2[0], y2 = p2[1], z2 = p2[2], t2 = p2[3];
    final a = _mod((y1 - x1) * (y2 - x2), _p);
    final b = _mod((y1 + x1) * (y2 + x2), _p);
    final c = _mod(t1 * BigInt.two * _d * t2, _p);
    final d = _mod(z1 * BigInt.two * z2, _p);
    final e = _mod(b - a, _p);
    final f = _mod(d - c, _p);
    final g = _mod(d + c, _p);
    final h = _mod(b + a, _p);
    return [_mod(e * f, _p), _mod(g * h, _p), _mod(f * g, _p), _mod(e * h, _p)];
  }

  static List<BigInt> _scalarMult(List<BigInt> pt, BigInt k) {
    var r = [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
    var q = pt;
    var s = k;
    while (s > BigInt.zero) {
      if (s.isOdd) r = _pointAdd(r, q);
      q = _pointAdd(q, q);
      s >>= 1;
    }
    return r;
  }

  static Uint8List _encodePoint(List<BigInt> pt) {
    final zinv = _modInv(pt[2], _p);
    final x = _mod(pt[0] * zinv, _p);
    final y = _mod(pt[1] * zinv, _p);
    final out = _encodeInt(y, 32);
    if (x.isOdd) out[31] |= 0x80;
    return out;
  }

  static Uint8List _encodeInt(BigInt v, int len) {
    final out = Uint8List(len);
    var cur = v;
    for (var i = 0; i < len; i++) {
      out[i] = (cur & BigInt.from(0xff)).toInt();
      cur >>= 8;
    }
    return out;
  }

  static BigInt _decodeInt(List<int> bytes) {
    var out = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      out = (out << 8) | BigInt.from(bytes[i] & 0xff);
    }
    return out;
  }

  static List<BigInt> get _basePoint => [_bx, _by, BigInt.one, _mod(_bx * _by, _p)];

  static Uint8List seedFor(int tag) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (i * 19 + tag) & 0xff));

  static Uint8List publicKeyBytes(Uint8List seed) {
    final h = sha512.convert(seed).bytes;
    final clamped = Uint8List.fromList(h.sublist(0, 32));
    clamped[0] &= 248;
    clamped[31] &= 63;
    clamped[31] |= 64;
    final a = _decodeInt(clamped);
    return _encodePoint(_scalarMult(_basePoint, a));
  }

  static String publicKeyHex(Uint8List seed) =>
      publicKeyBytes(seed).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List sign(Uint8List seed, Uint8List msg) {
    final h = sha512.convert(seed).bytes;
    final clamped = Uint8List.fromList(h.sublist(0, 32));
    clamped[0] &= 248;
    clamped[31] &= 63;
    clamped[31] |= 64;
    final a = _decodeInt(clamped);
    final prefix = h.sublist(32, 64);
    final pub = _encodePoint(_scalarMult(_basePoint, a));
    final rHash = sha512.convert(<int>[...prefix, ...msg]).bytes;
    final r = _mod(_decodeInt(rHash), _l);
    final rEnc = _encodePoint(_scalarMult(_basePoint, r));
    final kHash = sha512.convert(<int>[...rEnc, ...pub, ...msg]).bytes;
    final k = _mod(_decodeInt(kHash), _l);
    final s = _mod(r + k * a, _l);
    final sEnc = _encodeInt(s, 32);
    return Uint8List.fromList(<int>[...rEnc, ...sEnc]);
  }

  static String issueToken(
    Uint8List seed, {
    int expEpochSec = 0,
    bool expOAuth = false,
    String plat = 'all',
  }) {
    final payloadBytes = utf8.encode(
      jsonEncode(<String, dynamic>{
        'v': 1,
        'tag': 'r3-test',
        'iat': 1700000000,
        'exp': expEpochSec,
        'plat': plat,
        'shared': false,
        'exp_oauth': expOAuth,
        'min_vc': 0,
      }),
    );
    final msg = Uint8List.fromList(<int>[
      ...utf8.encode('marco-ai-lab-v1:'),
      ...payloadBytes,
    ]);
    final sig = sign(seed, msg);
    assert(Ed25519.verify(
      publicKey: publicKeyBytes(seed),
      message: msg,
      signature: sig,
    ));
    String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');
    return 'MMAILAB1.${b64u(payloadBytes)}.${b64u(sig)}';
  }
}

final Uint8List _valid1x1Png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Future<T> _withRealHttp<T>(Future<T> Function() fn) async {
  final prev = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await fn();
  } finally {
    HttpOverrides.global = prev;
  }
}

class _SlowKeychainBackend implements SecureStorageBackend {
  final Map<String, String> _data = <String, String>{};
  final List<String> opsLog = <String>[];
  Completer<void>? blockNextWriteForSlot;
  Completer<void>? blockedWriteStarted;
  String? blockedSlotName;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    opsLog.add('write_start:$key');
    if (blockedSlotName == key && blockNextWriteForSlot != null) {
      final gate = blockNextWriteForSlot!;
      blockNextWriteForSlot = null;
      if (blockedWriteStarted != null && !blockedWriteStarted!.isCompleted) {
        blockedWriteStarted!.complete();
      }
      await gate.future;
    }
    _data[key] = value;
    opsLog.add('write_done:$key');
  }

  @override
  Future<void> delete(String key) async {
    opsLog.add('delete:$key');
    _data.remove(key);
  }
}

class _TestDownloadPathProvider extends PathProviderPlatform {
  final Directory root;
  _TestDownloadPathProvider(this.root);

  @override
  Future<String?> getDownloadsPath() async => '${root.path}/downloads';
  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

class _FakePlayer extends Fake implements Player {
  final _FakePlayerStream _stream = _FakePlayerStream();
  PlayerState _state = const PlayerState();

  @override
  PlayerStream get stream => _stream;

  @override
  PlayerState get state => _state;

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      final pl = Playlist([playable]);
      _state = _state.copyWith(playlist: pl, playing: play);
      _stream.playlistCtl.add(pl);
      _stream.playingCtl.add(play);
    }
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    _stream.close();
  }
}

class _FakePlayerStream extends Fake implements PlayerStream {
  final playlistCtl = StreamController<Playlist>.broadcast();
  final playingCtl = StreamController<bool>.broadcast();
  final completedCtl = StreamController<bool>.broadcast();
  final positionCtl = StreamController<Duration>.broadcast();
  final durationCtl = StreamController<Duration>.broadcast();
  final bufferCtl = StreamController<Duration>.broadcast();
  final bufferingCtl = StreamController<bool>.broadcast();
  final rateCtl = StreamController<double>.broadcast();
  final volumeCtl = StreamController<double>.broadcast();
  final widthCtl = StreamController<int?>.broadcast();
  final heightCtl = StreamController<int?>.broadcast();
  final tracksCtl = StreamController<Tracks>.broadcast();
  final trackCtl = StreamController<Track>.broadcast();
  final errorCtl = StreamController<String>.broadcast();
  final subtitleCtl = StreamController<List<String>>.broadcast();
  final audioParamsCtl = StreamController<AudioParams>.broadcast();
  final videoParamsCtl = StreamController<VideoParams>.broadcast();
  final logCtl = StreamController<PlayerLog>.broadcast();

  void close() {
    for (final c in <StreamController<dynamic>>[
      playlistCtl,
      playingCtl,
      completedCtl,
      positionCtl,
      durationCtl,
      bufferCtl,
      bufferingCtl,
      rateCtl,
      volumeCtl,
      widthCtl,
      heightCtl,
      tracksCtl,
      trackCtl,
      errorCtl,
      subtitleCtl,
      audioParamsCtl,
      videoParamsCtl,
      logCtl,
    ]) {
      if (!c.isClosed) unawaited(c.close());
    }
  }

  @override
  Stream<Playlist> get playlist => playlistCtl.stream;
  @override
  Stream<bool> get playing => playingCtl.stream;
  @override
  Stream<bool> get completed => completedCtl.stream;
  @override
  Stream<Duration> get position => positionCtl.stream;
  @override
  Stream<Duration> get duration => durationCtl.stream;
  @override
  Stream<Duration> get buffer => bufferCtl.stream;
  @override
  Stream<bool> get buffering => bufferingCtl.stream;
  @override
  Stream<double> get rate => rateCtl.stream;
  @override
  Stream<double> get volume => volumeCtl.stream;
  @override
  Stream<int?> get width => widthCtl.stream;
  @override
  Stream<int?> get height => heightCtl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtl.stream;
  @override
  Stream<Track> get track => trackCtl.stream;
  @override
  Stream<String> get error => errorCtl.stream;
  @override
  Stream<List<String>> get subtitle => subtitleCtl.stream;
  @override
  Stream<AudioParams> get audioParams => audioParamsCtl.stream;
  @override
  Stream<VideoParams> get videoParams => videoParamsCtl.stream;
  @override
  Stream<PlayerLog> get log => logCtl.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AiService.instance.resetForTest();
    AiService.instance.setPrivacySessionActive(false);
    AiLabPasscodeStore.instance.resetForTest();
    CuratedDiscoveryService.resetCacheForTest();
    CuratedDiscoveryService.debugLiveUriOverride = null;
    CuratedDiscoveryService.debugLiveModuleTotalTimeout =
        const Duration(seconds: 6);
    PosterLoader.clearPrivateCache();
    PosterLoader.resetDiskCacheConfigForTest();
    IosDownloadGroupsView.resetExpandedForTest();
    debugDefaultTargetPlatformOverride = null;
  });

  // =========================================================================
  // P0-1: MarcoLiquidGlass.swift private init for nested private OptionSection
  // =========================================================================
  group('P0-1: MarcoLiquidGlass.swift Swift access-level fix', () {
    test('MarcoNativeOptionSheetController declares private init and stays brace-balanced', () {
      final swiftFile = File('ios_native/MarcoLiquidGlass.swift');
      expect(swiftFile.existsSync(), isTrue);
      final src = swiftFile.readAsStringSync();
      expect('{'.allMatches(src).length, '}'.allMatches(src).length);
      final clsStart = src.indexOf('private final class MarcoNativeOptionSheetController:');
      final clsEnd = src.indexOf('// MARK: - Native iOS 26 Liquid Glass Filter Sheet', clsStart);
      expect(clsStart, greaterThan(-1));
      expect(clsEnd, greaterThan(clsStart));
      final body = src.substring(clsStart, clsEnd);
      expect(body, contains('private struct OptionSection'));
      expect(
        body,
        contains('private init(\n    args: [String: Any],\n    parsedSections: [OptionSection]? = nil,'),
      );
      expect(
        body,
        isNot(contains('\n  init(\n    args: [String: Any],\n    parsedSections: [OptionSection]? = nil,')),
      );
    });
  });

  // =========================================================================
  // P0-2: Disable auto redirects & verify privacy/passcode/origin per hop
  // =========================================================================
  group('P0-2: AI HTTP redirect blocking and hop-by-hop authorization', () {
    test('entering privacy after first GET blocks redirect hop (0 second request)', () async {
      await _withRealHttp(() async {
        SharedPreferences.setMockInitialValues({});
        final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
        final seed = _TestEd25519Signer.seedFor(21);
        final store = AiLabPasscodeStore.instance;
        store.configureForTest(
          publicKeyHexOverride: _TestEd25519Signer.publicKeyHex(seed),
          clock: () => now,
          targetPlatform: 'ios',
          resetState: true,
        );
        await store.unlockWithPasscode(
          _TestEd25519Signer.issueToken(seed, expEpochSec: 1800003600),
        );

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async => server.close(force: true));
        final firstHit = Completer<void>();
        final releaseRedirect = Completer<void>();
        final requestedPaths = <String>[];

        server.listen((req) async {
          requestedPaths.add('${req.method} ${req.uri.path}');
          if (req.uri.path == '/v1/models') {
            if (!firstHit.isCompleted) firstHit.complete();
            await releaseRedirect.future;
            req.response.statusCode = 302;
            req.response.headers.set('location', '/v1/models-next');
            await req.response.close();
          } else {
            req.response.statusCode = 200;
            req.response.write(jsonEncode({
              'data': [
                {'id': 'should-never-be-reached'},
              ],
            }));
            await req.response.close();
          }
        });

        final secStore = InMemorySecureCredentialStore();
        AiService.instance.configureForTest(
          secureStorage: secStore,
          passcodeStore: store,
          clock: () => now,
          labUnlockedForTest: null,
          resetState: true,
        );
        await AiService.instance.saveConfig(
          AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            protocol: AiApiProtocol.openaiCompatible,
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'gpt-4.1',
          ),
        );
        await AiService.instance.setApiKey('sk-test-redirect');

        final fut = AiService.instance.fetchAvailableModelOptions();
        await firstHit.future;

        // Enter privacy AFTER first GET was sent, BEFORE 302 redirect arrives.
        AiService.instance.setPrivacySessionActive(true);
        releaseRedirect.complete();

        await expectLater(
          fut,
          throwsA(
            isA<AiServiceException>().having(
              (e) => e.code,
              'code',
              AiErrorCode.privacySpaceBlocked,
            ),
          ),
        );
        // Underlying HTTP client MUST NOT auto-follow the 302 -> strictly 1 request!
        expect(requestedPaths, equals(<String>['GET /v1/models']));
        expect(AiService.instance.discoveredModels, isEmpty);
      });
    });

    test('POST complete and cross-origin GET redirect never follow redirects', () async {
      await _withRealHttp(() async {
        SharedPreferences.setMockInitialValues({});
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async => server.close(force: true));
        final hits = <String>[];
        server.listen((req) async {
          hits.add('${req.method} ${req.uri.path}');
          if (req.uri.path == '/v1/models') {
            req.response.statusCode = 302;
            req.response.headers.set('location', 'https://other-host.example/steal');
            await req.response.close();
          } else {
            req.response.statusCode = 307;
            req.response.headers.set('location', '/v1/chat/completions-hop2');
            await req.response.close();
          }
        });

        final secStore = InMemorySecureCredentialStore();
        AiService.instance.configureForTest(
          secureStorage: secStore,
          labUnlockedForTest: true,
          resetState: true,
        );
        await AiService.instance.saveConfig(
          AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            protocol: AiApiProtocol.openaiCompatible,
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'gpt-4.1',
          ),
        );
        await AiService.instance.setApiKey('sk-no-redirect');

        await expectLater(
          AiService.instance.fetchAvailableModelOptions(),
          throwsA(isA<AiServiceException>()),
        );
        await expectLater(
          AiService.instance.complete(
            feature: 'ping',
            userPrompt: 'hi',
            useCache: false,
          ),
          throwsA(isA<AiServiceException>()),
        );
        expect(
          hits,
          equals(<String>['GET /v1/models', 'POST /v1/chat/completions']),
        );
      });
    });
  });

  // =========================================================================
  // P0-3: Case-preserving URI normalization & strict legacy type/identity check
  // =========================================================================
  group('P0-3: Offline URI case sensitivity and conservative legacy matching', () {
    test('two public subscriptions differing only in path/query case recover their own downloads; type-conflicting or insufficient legacy tasks fail closed', () {
      const subUpper = CmsSite(
        key: 'vod',
        name: '公开源A',
        type: 1,
        api: 'https://vod.example/Api/SubA?Token=AbC',
        subscriptionId: 'sub_upper',
        isPrivate: false,
      );
      const subLower = CmsSite(
        key: 'vod',
        name: '公开源B',
        type: 1,
        api: 'https://vod.example/api/subA?Token=abc',
        subscriptionId: 'sub_lower',
        isPrivate: false,
      );
      const cfgBoth = CmsConfig(sites: <CmsSite>[subUpper, subLower]);

      // Legacy tasks with matching case-sensitive path/query (and uppercase host/scheme)
      final taskUpper = DownloadTask(
        id: 't_upper',
        siteKey: 'vod',
        siteName: '公开源A',
        siteApi: 'HTTPS://VOD.EXAMPLE/Api/SubA?Token=AbC',
        siteType: 1,
        videoId: 'v1',
        title: '电影A',
        poster: '',
        lineName: '线路1',
        episodeName: '正片',
        episodeIndex: 0,
        sourceUrl: 'https://cdn.example/a.mp4',
        headers: const {},
        createdAt: 1,
        filePath: '/tmp/a.mp4',
      );
      final taskLower = DownloadTask(
        id: 't_lower',
        siteKey: 'vod',
        siteName: '公开源B',
        siteApi: 'https://vod.example/api/subA?Token=abc',
        siteType: 1,
        videoId: 'v1',
        title: '电影B',
        poster: '',
        lineName: '线路1',
        episodeName: '正片',
        episodeIndex: 0,
        sourceUrl: 'https://cdn.example/b.mp4',
        headers: const {},
        createdAt: 2,
        filePath: '/tmp/b.mp4',
      );

      final resolvedUpper = AdaptiveShell.resolveOfflinePlaybackSite(
        taskUpper,
        currentConfig: cfgBoth,
      );
      final resolvedLower = AdaptiveShell.resolveOfflinePlaybackSite(
        taskLower,
        currentConfig: cfgBoth,
      );
      expect(resolvedUpper.isEffectivelyPrivate, isFalse);
      expect(resolvedUpper.subscriptionId, 'sub_upper');
      expect(resolvedLower.isEffectivelyPrivate, isFalse);
      expect(resolvedLower.subscriptionId, 'sub_lower');

      // Type-conflicting legacy task (old type=3 vs current public type=1) MUST fail closed!
      const singlePubEmptyApi = CmsConfig(
        sites: <CmsSite>[
          CmsSite(key: 'vod', name: '新公开源', type: 1, api: '', isPrivate: false),
        ],
      );
      final typeConflictLegacy = DownloadTask(
        id: 't_type_conflict',
        siteKey: 'vod',
        siteName: '已移除爬虫源',
        siteApi: '',
        siteType: 3,
        videoId: 'v2',
        title: '旧任务',
        poster: '',
        lineName: '线路1',
        episodeName: '正片',
        episodeIndex: 0,
        sourceUrl: 'https://cdn.example/c.mp4',
        headers: const {},
        createdAt: 3,
        filePath: '/tmp/c.mp4',
      );
      expect(
        AdaptiveShell.resolveOfflinePlaybackSite(
          typeConflictLegacy,
          currentConfig: singlePubEmptyApi,
        ).isEffectivelyPrivate,
        isTrue,
      );

      // Insufficient-identity legacy task (missing API vs current public site with API) fails closed!
      const singlePubWithApi = CmsConfig(
        sites: <CmsSite>[
          CmsSite(
            key: 'vod',
            name: '新公开源',
            type: 1,
            api: 'https://new-pub.example/api',
            isPrivate: false,
          ),
        ],
      );
      final missingApiLegacy = DownloadTask(
        id: 't_missing_api',
        siteKey: 'vod',
        siteName: '旧记录',
        siteApi: '',
        siteType: 1,
        videoId: 'v3',
        title: '缺API旧任务',
        poster: '',
        lineName: '线路1',
        episodeName: '正片',
        episodeIndex: 0,
        sourceUrl: 'https://cdn.example/d.mp4',
        headers: const {},
        createdAt: 4,
        filePath: '/tmp/d.mp4',
      );
      expect(
        AdaptiveShell.resolveOfflinePlaybackSite(
          missingApiLegacy,
          currentConfig: singlePubWithApi,
        ).isEffectivelyPrivate,
        isTrue,
      );

      // Expired legacy task whose API no longer matches current public site fails closed!
      final expiredApiLegacy = DownloadTask(
        id: 't_expired_api',
        siteKey: 'vod',
        siteName: '已失效源',
        siteApi: 'https://removed.example/api',
        siteType: 1,
        videoId: 'v4',
        title: '已失效任务',
        poster: '',
        lineName: '线路1',
        episodeName: '正片',
        episodeIndex: 0,
        sourceUrl: 'https://cdn.example/e.mp4',
        headers: const {},
        createdAt: 5,
        filePath: '/tmp/e.mp4',
      );
      expect(
        AdaptiveShell.resolveOfflinePlaybackSite(
          expiredApiLegacy,
          currentConfig: singlePubWithApi,
        ).isEffectivelyPrivate,
        isTrue,
      );
    });
  });

  // =========================================================================
  // P1-4: Privacy propagation to EpisodeStillImage, portrait backdrop, download cover
  // =========================================================================
  group('P1-4: Private poster isolation for episode fallback, portrait backdrop, and download group covers', () {
    testWidgets(
      'private EpisodeStillImage and IosDownloadGroupsView keep private posters out of public disk cache and skip public metadata lookups',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final diskDir = Directory.systemTemp.createTempSync('marco_r3_p4_');
        addTearDown(() {
          PosterLoader.resetDiskCacheConfigForTest();
          try {
            if (diskDir.existsSync()) diskDir.deleteSync(recursive: true);
          } catch (_) {}
        });
        PosterLoader.debugDiskDirOverride = diskDir;
        final privateFetched = <String>[];
        PosterLoader.debugPrivateFetcherOverride = (url) async {
          privateFetched.add(url);
          return _valid1x1Png;
        };

        final privSite = const CmsSite(
          key: 'priv_s',
          name: '私密源',
          type: 1,
          api: 'https://priv.example/api',
          isPrivate: true,
        );
        final dlTasks = <DownloadTask>[
          DownloadTask(
            id: 'p_ep1',
            siteKey: 'priv_s',
            siteName: '私密源',
            siteApi: 'https://priv.example/api',
            siteType: 1,
            videoId: 'pv1',
            title: '绝密剧集',
            poster: 'https://priv.example/dl_cover.png',
            lineName: '默认',
            episodeName: '第1集',
            episodeIndex: 0,
            sourceUrl: 'https://priv.example/1.mp4',
            headers: const {},
            createdAt: 1,
            sourceSite: privSite,
          ),
          DownloadTask(
            id: 'p_ep2',
            siteKey: 'priv_s',
            siteName: '私密源',
            siteApi: 'https://priv.example/api',
            siteType: 1,
            videoId: 'pv1',
            title: '绝密剧集',
            poster: '',
            lineName: '默认',
            episodeName: '第2集',
            episodeIndex: 1,
            sourceUrl: 'https://priv.example/2.mp4',
            headers: const {},
            createdAt: 2,
            sourceSite: privSite,
          ),
          DownloadTask(
            id: 'p_notitle_ep1',
            siteKey: 'priv_s',
            siteName: '私密源',
            siteApi: 'https://priv.example/api',
            siteType: 1,
            videoId: 'pv2',
            title: '无图绝密剧集',
            poster: '',
            lineName: '默认',
            episodeName: '第1集',
            episodeIndex: 0,
            sourceUrl: 'https://priv.example/3.mp4',
            headers: const {},
            createdAt: 3,
            sourceSite: privSite,
          ),
          DownloadTask(
            id: 'p_notitle_ep2',
            siteKey: 'priv_s',
            siteName: '私密源',
            siteApi: 'https://priv.example/api',
            siteType: 1,
            videoId: 'pv2',
            title: '无图绝密剧集',
            poster: '',
            lineName: '默认',
            episodeName: '第2集',
            episodeIndex: 1,
            sourceUrl: 'https://priv.example/4.mp4',
            headers: const {},
            createdAt: 4,
            sourceSite: privSite,
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  const SizedBox(
                    width: 220,
                    height: 124,
                    child: EpisodeStillImage(
                      seriesTitle: '绝密剧集',
                      year: '2026',
                      episodeIndex: 0,
                      fallbackPosterUrl: 'https://priv.example/ep_fallback.png',
                      isPrivate: true,
                      placeholder: SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(
                    width: 220,
                    height: 124,
                    child: EpisodeStillImage(
                      seriesTitle: '仅片名无图私密剧',
                      year: '2026',
                      episodeIndex: 1,
                      fallbackPosterUrl: '',
                      isPrivate: true,
                      placeholder: SizedBox.shrink(),
                    ),
                  ),
                  IosDownloadGroupsView(
                    tasks: dlTasks,
                    isTaskPrivate: (_) => true,
                    singleRowBuilder: (_) => const SizedBox.shrink(),
                    onPlay: (_) {},
                    onPause: (_) {},
                    onResume: (_) {},
                    onDeleteTask: (_) {},
                    onPauseGroup: (_) {},
                    onResumeGroup: (_) {},
                    onDeleteGroup: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Private URLs fetched strictly via private path into memory-only bucket.
        expect(
          privateFetched,
          containsAll(<String>[
            'https://priv.example/ep_fallback.png',
            'https://priv.example/dl_cover.png',
          ]),
        );
        expect(PosterLoader.privateMemoryCount, 2);
        // Zero files written to public disk cache!
        final diskFiles = diskDir.listSync();
        expect(diskFiles, isEmpty);
        // Every PosterImage inside the multi-episode private groups carries isPrivate == true & empty title.
        final groupPosters = tester
            .widgetList<PosterImage>(
              find.descendant(
                of: find.byType(IosDownloadGroupsView),
                matching: find.byType(PosterImage),
              ),
            )
            .toList();
        expect(groupPosters, hasLength(2));
        for (final p in groupPosters) {
          expect(p.isPrivate, isTrue);
          expect(p.title, isEmpty);
        }
      },
    );

    testWidgets(
      'portrait PlayerScreen background passes isPrivate and blanks title for private site',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final storage = await initTestStorage();
        final onboardingPrefs = await OnboardingPrefs.load();
        final diskDir = Directory.systemTemp.createTempSync('marco_r3_p4b_');
        addTearDown(() {
          PosterLoader.resetDiskCacheConfigForTest();
          try {
            if (diskDir.existsSync()) diskDir.deleteSync(recursive: true);
          } catch (_) {}
        });
        PosterLoader.debugDiskDirOverride = diskDir;
        final privateFetched = <String>[];
        PosterLoader.debugPrivateFetcherOverride = (url) async {
          privateFetched.add(url);
          return _valid1x1Png;
        };

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const privSite = CmsSite(
          key: 'priv_player',
          name: '私密源',
          type: 1,
          api: 'https://priv.example/api',
          isPrivate: true,
        );
        const privVideo = CmsVideo(
          id: 'pv_bg',
          title: '私密竖屏影片',
          poster: 'https://priv.example/player_bg.png',
          lines: [
            CmsLine(
              name: '线路1',
              episodes: [
                CmsEpisode(name: '正片', url: 'https://priv.example/v.mp4'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          CupertinoApp(
            home: PlayerScreen(
              site: privSite,
              video: privVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: _FakePlayer(),
              debugVideoSurface: const SizedBox.expand(),
              debugHudPrefs: PlayerHudPrefs.inMemory(
                initial: PlayerHudPrefsData.defaultsFor(isDesktop: false),
              ),
              debugDanmuSettings: const DanmuSettings(enabled: false),
              debugOnboardingPrefs: onboardingPrefs,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final backdropPosters = tester
            .widgetList<PosterImage>(find.byType(PosterImage))
            .where((p) => p.forBackdrop)
            .toList();
        expect(backdropPosters, isNotEmpty);
        for (final bp in backdropPosters) {
          expect(bp.isPrivate, isTrue);
          expect(bp.title, isEmpty);
        }
        expect(privateFetched, contains('https://priv.example/player_bg.png'));
        expect(diskDir.listSync(), isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  // =========================================================================
  // P1-5: Visible-only pause/resume all & source/privacy-isolated group actions
  // =========================================================================
  group('P1-5: Downloads bulk toggle visible-only & multi-subscription group isolation', () {
    test('groupDownloadTasks with offlineTaskGroupDomainKey separates same siteKey+videoId across subscriptions and privacy domains', () {
      const subA = CmsSite(
        key: 'vod',
        name: '订阅A',
        type: 1,
        api: 'https://sub-a.example/api',
        subscriptionId: 'sub_a',
        isPrivate: false,
      );
      const subB = CmsSite(
        key: 'vod',
        name: '订阅B',
        type: 1,
        api: 'https://sub-b.example/api',
        subscriptionId: 'sub_b',
        isPrivate: false,
      );
      const subPriv = CmsSite(
        key: 'vod',
        name: '私密订阅',
        type: 1,
        api: 'https://sub-priv.example/api',
        subscriptionId: 'sub_priv',
        isPrivate: true,
      );
      const cfg = CmsConfig(sites: <CmsSite>[subA, subB, subPriv]);

      DownloadTask mk(String id, CmsSite site, int epIdx) => DownloadTask(
            id: id,
            siteKey: site.key,
            siteName: site.name,
            siteApi: site.api,
            siteType: site.type,
            videoId: 'same_vid_99',
            title: '同名剧集',
            poster: '',
            lineName: '默认',
            episodeName: '第${epIdx + 1}集',
            episodeIndex: epIdx,
            sourceUrl: '${site.api}/ep$epIdx.mp4',
            headers: const {},
            createdAt: epIdx + 1,
            sourceSite: site,
            status: DownloadStatus.paused,
          );

      final tasks = <DownloadTask>[
        mk('a1', subA, 0),
        mk('a2', subA, 1),
        mk('b1', subB, 0),
        mk('b2', subB, 1),
        mk('p1', subPriv, 0),
        mk('p2', subPriv, 1),
      ];

      final groups = groupDownloadTasks(
        tasks,
        groupKeyBuilder: (t) => AdaptiveShell.offlineTaskGroupDomainKey(
          t,
          currentConfig: cfg,
        ),
        isTaskPrivate: (t) => AdaptiveShell.isOfflineTaskPrivate(
          t,
          currentConfig: cfg,
          privacySessionUnlocked: false,
        ),
      );
      expect(groups, hasLength(3));
      expect(groups[0].tasks.map((t) => t.id).toList(), equals(['a1', 'a2']));
      expect(groups[0].isPrivate, isFalse);
      expect(groups[1].tasks.map((t) => t.id).toList(), equals(['b1', 'b2']));
      expect(groups[1].isPrivate, isFalse);
      expect(groups[2].tasks.map((t) => t.id).toList(), equals(['p1', 'p2']));
      expect(groups[2].isPrivate, isTrue);
    });

    testWidgets(
      'AdaptiveShell downloads bulk pause/resume only touches visible public tasks and leaves hidden private tasks untouched',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final tempRoot = Directory.systemTemp.createTempSync('marco_r3_p5_');
        final prevProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _TestDownloadPathProvider(tempRoot);
        addTearDown(() {
          PathProviderPlatform.instance = prevProvider;
          DownloadService.instance.resetForTesting();
          try {
            if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
          } catch (_) {}
        });

        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{'onboarding_done_version': 1},
        );
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 's_pub',
                'name': '公开源',
                'type': 1,
                'api': 'https://pub.example/api',
                'isPrivate': false,
              },
              {
                'key': 's_priv',
                'name': '私密源',
                'type': 1,
                'api': 'https://priv.example/api',
                'isPrivate': true,
              },
            ],
          }),
        );
        final client = CmsClient(
          client: MockClient((_) async => http.Response('{"list":[]}', 200)),
        );
        final service = DownloadService.instance;
        await tester.runAsync(() async {
          service.resetForTesting();
          final supportDir = Directory('${tempRoot.path}/support');
          await supportDir.create(recursive: true);
          final indexFile = File('${supportDir.path}/marco_downloads.json');
          await indexFile.writeAsString(
            jsonEncode([
              DownloadTask(
                id: 'pub_paused',
                siteKey: 's_pub',
                siteName: '公开源',
                siteApi: 'https://pub.example/api',
                siteType: 1,
                videoId: 'v1',
                title: '公开电影',
                poster: '',
                lineName: '主线',
                episodeName: '正片',
                episodeIndex: 0,
                sourceUrl: 'https://pub.example/v1.mp4',
                headers: const {},
                createdAt: 100,
                status: DownloadStatus.paused,
                sourceSite: const CmsSite(
                  key: 's_pub',
                  name: '公开源',
                  type: 1,
                  api: 'https://pub.example/api',
                ),
              ).toJson(),
              DownloadTask(
                id: 'priv_paused',
                siteKey: 's_priv',
                siteName: '私密源',
                siteApi: 'https://priv.example/api',
                siteType: 1,
                videoId: 'v2',
                title: '私密电影',
                poster: '',
                lineName: '主线',
                episodeName: '正片',
                episodeIndex: 0,
                sourceUrl: 'https://priv.example/v2.mp4',
                headers: const {},
                createdAt: 101,
                status: DownloadStatus.paused,
                sourceSite: const CmsSite(
                  key: 's_priv',
                  name: '私密源',
                  type: 1,
                  api: 'https://priv.example/api',
                  isPrivate: true,
                ),
              ).toJson(),
            ]),
          );
          await service.init(client);
        });

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: client),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('离线下载').first);
        await tester.pumpAndSettle();

        expect(find.text('公开电影'), findsOneWidget);
        expect(find.text('私密电影'), findsNothing);
        expect(find.text('全部继续'), findsOneWidget);

        // Tap「全部继续」-> ONLY visible public task resumes; hidden private task stays paused!
        await tester.tap(find.byKey(const ValueKey('ios-downloads-bulk-toggle')));
        await tester.pump();
        final pubAfterResume =
            service.tasks.firstWhere((t) => t.id == 'pub_paused');
        final privAfterResume =
            service.tasks.firstWhere((t) => t.id == 'priv_paused');
        expect(pubAfterResume.status, isNot(DownloadStatus.paused));
        expect(privAfterResume.status, DownloadStatus.paused);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  // =========================================================================
  // P1-6: Serialized OAuth Keychain writes/deletes & BYO test credential binding
  // =========================================================================
  group('P1-6: Serialized OAuth Keychain slot & BYO connection test generation binding', () {
    test('serialized Keychain slot guarantees logout and A->B switch win on cold start', () async {
      SharedPreferences.setMockInitialValues({});
      final backend1 = _SlowKeychainBackend();
      final svc1 = AiService(secureStorage: backend1);
      svc1.configureForTest(
        secureStorage: backend1,
        labUnlockedForTest: true,
        experimentalOAuthForTest: true,
      );
      await svc1.ensureLoaded();

      const sessionA = AiOAuthSession(
        accessToken: 'tok-a',
        refreshToken: 'ref-a',
        accountId: 'acct-a',
        expiresAtEpochMs: 1900000000000,
      );
      const sessionB = AiOAuthSession(
        accessToken: 'tok-b',
        refreshToken: 'ref-b',
        accountId: 'acct-b',
        expiresAtEpochMs: 1900000000000,
      );

      // Subcase A: A write already started -> logout -> release A write -> cold start is logged out.
      final gate1 = Completer<void>();
      final started1 = Completer<void>();
      backend1.blockedSlotName = AiService.secureOAuthSessionSlot;
      backend1.blockNextWriteForSlot = gate1;
      backend1.blockedWriteStarted = started1;

      final writeAFut = svc1.setOAuthSession(sessionA);
      await started1.future;
      final logoutFut = svc1.signOutOAuth();
      gate1.complete();
      await Future.wait([writeAFut, logoutFut]);

      final coldAfterLogout = AiService(secureStorage: backend1);
      await coldAfterLogout.ensureLoaded();
      expect(coldAfterLogout.hasOAuthSession, isFalse);
      expect(await backend1.read(AiService.secureOAuthSessionSlot), isNull);

      // Subcase B: A write already started -> switch to B -> release A write -> cold start has B.
      final gate2 = Completer<void>();
      final started2 = Completer<void>();
      backend1.blockedSlotName = AiService.secureOAuthSessionSlot;
      backend1.blockNextWriteForSlot = gate2;
      backend1.blockedWriteStarted = started2;

      final writeA2Fut = svc1.setOAuthSession(sessionA);
      await started2.future;
      final writeBFut = svc1.setOAuthSession(sessionB);
      gate2.complete();
      await Future.wait([writeA2Fut, writeBFut]);

      final coldAfterSwitchB = AiService(secureStorage: backend1);
      await coldAfterSwitchB.ensureLoaded();
      expect(coldAfterSwitchB.hasOAuthSession, isTrue);
      expect(coldAfterSwitchB.oauthSession?.accountId, 'acct-b');
      expect(coldAfterSwitchB.oauthSession?.accessToken, 'tok-b');
    });

    testWidgets(
      'BYO connection test discards A result after user changes endpoint/key to B',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final testAStarted = Completer<void>();
        final releaseTestA = Completer<void>();

        final client = MockClient((req) async {
          if (req.url.host == 'host-a.example') {
            if (!testAStarted.isCompleted) testAStarted.complete();
            await releaseTestA.future;
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'content': 'OK_FROM_A'},
                    },
                  ],
                }),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('{"error":{"message":"not called"}}', 500);
        });

        final secStore = InMemorySecureCredentialStore();
        final ai = AiService(httpClient: client, secureStorage: secStore);
        ai.configureForTest(
          httpClient: client,
          secureStorage: secStore,
          labUnlockedForTest: true,
          experimentalOAuthForTest: false,
        );
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            protocol: AiApiProtocol.openaiCompatible,
            baseUrl: 'https://host-a.example/v1',
            model: 'gpt-4.1',
          ),
        );
        await ai.setApiKey('sk-key-a');

        tester.view.physicalSize = const Size(430, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(home: IosAiSettingsPage(service: ai)),
        );
        await tester.pumpAndSettle();

        final testBtn = find.byKey(const ValueKey('ios-ai-test-btn'));
        await tester.ensureVisible(testBtn);
        await tester.pumpAndSettle();
        await tester.tap(testBtn);
        await tester.pump();
        await testAStarted.future;
        expect(testAStarted.isCompleted, isTrue);

        // While A's test is in flight, change Base URL to B!
        final baseUrlField = find.byKey(const ValueKey('ios-ai-baseurl-field'));
        await tester.ensureVisible(baseUrlField);
        await tester.enterText(baseUrlField, 'https://host-b.example/v1');
        await tester.pump();

        // Now A's delayed HTTP 200 OK completes -> MUST NOT show A's result under B!
        releaseTestA.complete();
        await tester.pumpAndSettle();

        expect(find.textContaining('OK_FROM_A'), findsNothing);
        expect(find.textContaining('连接成功'), findsNothing);
        expect(find.byKey(const ValueKey('ios-ai-test-result')), findsNothing);
      },
    );
  });

  // =========================================================================
  // P1-7: AVPlayer media handoff restores native subtitles & bitmap protection
  // =========================================================================
  group('P1-7: AVPlayer media handoff subtitle restore, bitmap track protection & PiP', () {
    test('A suppresses native subtitles -> stop -> B opens without AI and restores native subtitles; bitmap tracks stay unsuppressed', () async {
      final calls = <MethodCall>[];
      const methodCh = MethodChannel('marco_movie/ios_avplayer_r3_p7');
      const eventCh = EventChannel('marco_movie/ios_avplayer_events_r3_p7');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      messenger.setMockMethodCallHandler(methodCh, (call) async {
        calls.add(call);
        if (call.method == 'open') return true;
        return null;
      });
      messenger.setMockStreamHandler(
        eventCh,
        MockStreamHandler.inline(
          onListen: (args, events) {},
          onCancel: (args) {},
        ),
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(methodCh, null);
        messenger.setMockStreamHandler(eventCh, null);
      });

      // Film A controller
      final ctrlA = IosAvPlayerController(
        channelOverride: methodCh,
        eventChannelOverride: eventCh,
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      await ctrlA.open('https://cdn.example/filmA.m3u8');
      await ctrlA.setSuppressNativeSubtitleRendering(true);
      await ctrlA.stop();
      ctrlA.dispose();

      // Film B controller (fresh session, AI NOT enabled):
      // 1) A fresh controller syncing `false` before open MUST still invoke
      //    native `setSuppressNativeSubtitleRendering(false)` instead of
      //    short-circuiting on its initial Dart default `false`.
      // 2) Opening Film B explicitly passes `suppressNativeSubtitleRendering: false`
      //    and `force: true` also explicitly sends `false` over the channel.
      final ctrlB = IosAvPlayerController(
        channelOverride: methodCh,
        eventChannelOverride: eventCh,
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      await ctrlB.setSuppressNativeSubtitleRendering(false);
      await ctrlB.open('https://cdn.example/filmB.m3u8');
      await ctrlB.setSuppressNativeSubtitleRendering(false, force: true);
      ctrlB.dispose();

      final openCalls = calls.where((c) => c.method == 'open').toList();
      expect(openCalls, hasLength(2));
      expect(
        (openCalls[1].arguments as Map)['suppressNativeSubtitleRendering'],
        isFalse,
      );
      final suppressCalls = calls
          .where((c) => c.method == 'setSuppressNativeSubtitleRendering')
          .map((c) => c.arguments)
          .toList();
      expect(suppressCalls, equals(<Object?>[true, false, false]));

      // Track parsing preserves isBitmap / isTextExtractable flags from native Swift.
      final bitmapTrack = IosAvPlayerTrack.fromMap(const {
        'id': '0',
        'title': 'Blu-ray PGS',
        'language': 'zh',
        'selected': true,
        'isBitmap': true,
        'isTextExtractable': false,
      });
      expect(bitmapTrack.isBitmap, isTrue);
      expect(bitmapTrack.isTextExtractable, isFalse);

      // Verify Swift native engine resets suppression on open/stop and guards bitmap + PiP.
      final avSwift = File('ios_native/MarcoAvPlayerEngine.swift').readAsStringSync();
      expect(avSwift, contains('suppressNativeSubtitleRenderingRequested = suppressNativeSubtitleRendering'));
      expect(avSwift, contains('suppressNativeSubtitleRenderingRequested = false'));
      expect(avSwift, contains('&& !isPipActiveOrStarting'));
      expect(avSwift, contains('suppressNativeSubtitleAllowNonText || liveTextTrackReadyToSuppress'));
    });
  });

  // =========================================================================
  // P1-8: Studio draft vs mounted overlay & late continuation cancellation
  // =========================================================================
  group('P1-8: AI Subtitle Studio draft isolation & late continuation cancellation', () {
    testWidgets(
      'pasting a draft does not alter mounted overlay; clearing or closing during #121 continuation blocks late re-mount while preserving normal #121 continuation & offset',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        String clipboardText = '';
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': clipboardText};
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        });

        final mountCalls = <List<AiSubtitleCue>>[];
        var mountGen = 0;
        var mountedCues = <AiSubtitleCue>[
          const AiSubtitleCue(
            index: 1,
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
            text: 'Mounted Line 1',
            translatedText: '已挂载第一句',
          ),
        ];
        AiSubtitleSessionState? lastSession;

        // 1. Merely pasting a new draft must NOT alter `mountedCues`!
        clipboardText = '1\n00:00:10,000 --> 00:00:13,000\nDraft Only Line\n';
        await tester.pumpWidget(
          CupertinoApp(
            home: Builder(
              builder: (ctx) => CupertinoButton(
                onPressed: () {
                  unawaited(
                    showIosAiSubtitleStudioSheet(
                      ctx,
                      seriesTitle: '测试片',
                      episodeLabel: '第 1 集',
                      skipIntroSeconds: 0,
                      initialSession: AiSubtitleSessionState(
                        cues: mountedCues,
                        overlayActive: true,
                        draftCues: mountedCues,
                        draftMatchesOverlay: true,
                      ),
                      getOverlayMountGen: () => mountGen,
                      onSessionChanged: (s) => lastSession = s,
                      hasActiveSubtitleOverlay: true,
                      onClearSubtitleOverlay: () {
                        mountGen++;
                        mountedCues = const <AiSubtitleCue>[];
                      },
                      onApplySubtitleOverlay: (
                        cues, {
                        required bilingual,
                        required offset,
                        required label,
                      }) async {
                        mountGen++;
                        mountedCues = List<AiSubtitleCue>.of(cues);
                        mountCalls.add(mountedCues);
                      },
                    ),
                  );
                },
                child: const Text('OPEN_STUDIO'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('OPEN_STUDIO'));
        await tester.pumpAndSettle();

        final pasteBtn = find.byKey(const ValueKey('ai-sub-paste-btn'));
        await tester.ensureVisible(pasteBtn);
        await tester.tap(pasteBtn);
        await tester.pumpAndSettle();

        expect(mountCalls, isEmpty);
        expect(mountedCues.single.text, 'Mounted Line 1');
        expect(lastSession?.draftMatchesOverlay, isFalse);
        expect(lastSession?.draftCues.single.text, 'Draft Only Line');

        // Dismiss sheet.
        Navigator.of(tester.element(pasteBtn)).pop();
        await tester.pumpAndSettle();

        // 2. Late continuation response after clearing overlay MUST NOT re-mount!
        final cues130 = List<AiSubtitleCue>.generate(
          130,
          (i) => AiSubtitleCue(
            index: i + 1,
            start: Duration(seconds: i * 2),
            end: Duration(seconds: i * 2 + 1),
            text: 'Line ${i + 1}',
            translatedText: i < 120 ? '译文 ${i + 1}' : '',
          ),
        );
        final translateEntered = Completer<void>();
        final releaseTranslate = Completer<void>();
        final mockClient = MockClient((req) async {
          if (!translateEntered.isCompleted) translateEntered.complete();
          await releaseTranslate.future;
          final items = [
            for (var i = 121; i <= 130; i++)
              {'index': i, 'zh': '续译 $i'},
          ];
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode({'glossary': {}, 'cues': items}),
                    },
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        AiService.instance.configureForTest(
          httpClient: mockClient,
          secureStorage: InMemorySecureCredentialStore(),
          labUnlockedForTest: true,
          resetState: true,
        );
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            baseUrl: 'https://api.example/v1',
            model: 'gpt-4.1',
          ),
        );
        await AiService.instance.setApiKey('sk-sub-r3');

        mountedCues = List<AiSubtitleCue>.of(cues130);
        mountCalls.clear();
        await tester.pumpWidget(
          CupertinoApp(
            home: Builder(
              builder: (ctx) => CupertinoButton(
                onPressed: () {
                  unawaited(
                    showIosAiSubtitleStudioSheet(
                      ctx,
                      seriesTitle: '测试片',
                      episodeLabel: '第 1 集',
                      skipIntroSeconds: 0,
                      initialSession: AiSubtitleSessionState(
                        cues: mountedCues,
                        glossary: const {'Paul': '保罗'},
                        offset: const Duration(milliseconds: 500),
                        overlayActive: true,
                        draftCues: mountedCues,
                        draftMatchesOverlay: true,
                      ),
                      getOverlayMountGen: () => mountGen,
                      onSessionChanged: (s) => lastSession = s,
                      hasActiveSubtitleOverlay: true,
                      onClearSubtitleOverlay: () {
                        mountGen++;
                        mountedCues = const <AiSubtitleCue>[];
                      },
                      onApplySubtitleOverlay: (
                        cues, {
                        required bilingual,
                        required offset,
                        required label,
                      }) async {
                        mountGen++;
                        mountedCues = List<AiSubtitleCue>.of(cues);
                        mountCalls.add(mountedCues);
                      },
                    ),
                  );
                },
                child: const Text('OPEN_STUDIO_2'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('OPEN_STUDIO_2'));
        await tester.pumpAndSettle();

        // Tap「继续精译剩余 10 条字幕」
        final contBtn = find.byKey(const ValueKey('ai-sub-continue-translate-btn'));
        await tester.ensureVisible(contBtn);
        await tester.tap(contBtn);
        await tester.pump();
        await translateEntered.future;

        // Clear subtitle overlay while continuation is in flight!
        final clearBtn = find.byKey(const ValueKey('ai-sub-clear-overlay-btn'));
        await tester.ensureVisible(clearBtn);
        await tester.tap(clearBtn);
        await tester.pump();
        expect(mountedCues, isEmpty);

        // Release delayed continuation -> MUST NOT re-mount cleared subtitles!
        releaseTranslate.complete();
        await tester.pumpAndSettle();
        expect(mountCalls, isEmpty);
        expect(mountedCues, isEmpty);
      },
    );
  });

  // =========================================================================
  // P1-9: Recommended pick resume time only restored on matched episode
  // =========================================================================
  group('P1-9: Recommended pick switch resume episode matching', () {
    test('removed Ep 9 on old line falls back to Ep 1 at 0ms while matched episode resumes normally', () {
      const removedLineDetail = <CmsLine>[
        CmsLine(
          id: 'line_new',
          name: '新线路',
          episodes: <CmsEpisode>[
            CmsEpisode(name: '第1集', url: 'https://cdn.example/b_ep1.mp4'),
          ],
        ),
      ];
      const ep9History = WatchHistoryEntry(
        site: 'site_b',
        id: 'vid_b',
        title: '影片B',
        line: '旧线路',
        lineId: 'line_old',
        episode: '第9集',
        index: 8,
        position: 540000,
        duration: 2700000,
        updated: 1000,
      );

      final removedRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: removedLineDetail,
        recommendedLineIndex: 0,
        historyEntry: ep9History,
      );
      expect(removedRes.lineIndex, 0);
      expect(removedRes.episodeIndex, 0);
      expect(removedRes.resumeMs, 0);

      // Same index 0 renamed from Ep 9 to Ep 1 MUST ALSO reset to 0ms!
      const shiftedHistory = WatchHistoryEntry(
        site: 'site_b',
        id: 'vid_b',
        title: '影片B',
        line: '新线路',
        lineId: 'line_new',
        episode: '第9集',
        index: 0,
        position: 540000,
        duration: 2700000,
        updated: 1000,
      );
      final shiftedRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: removedLineDetail,
        recommendedLineIndex: 0,
        historyEntry: shiftedHistory,
      );
      expect(shiftedRes.resumeMs, 0);

      // Matching line & episode restores exact resume position!
      const intactLines = <CmsLine>[
        CmsLine(
          id: 'line_other',
          name: '备选线路',
          episodes: <CmsEpisode>[
            CmsEpisode(name: '第1集', url: 'https://cdn.example/o1.mp4'),
          ],
        ),
        CmsLine(
          id: 'line_old',
          name: '旧线路',
          episodes: <CmsEpisode>[
            CmsEpisode(name: '第1集', url: 'https://cdn.example/b1.mp4'),
            CmsEpisode(name: '第2集', url: 'https://cdn.example/b2.mp4'),
            CmsEpisode(name: '第9集', url: 'https://cdn.example/b9.mp4'),
          ],
        ),
      ];
      final matchedRes = PlayerScreen.resolveRecommendedSwitchTarget(
        playableLines: intactLines,
        recommendedLineIndex: 0,
        historyEntry: ep9History,
      );
      expect(matchedRes.lineIndex, 1);
      expect(matchedRes.episodeIndex, 2);
      expect(matchedRes.resumeMs, 540000);
    });
  });

  // =========================================================================
  // P1-10: New API billing_subscription unknown unit & primary catalog survival
  // =========================================================================
  group('P1-10: New API billing_subscription currency & Codex primary catalog resilience', () {
    test('New API billing_subscription + has_payment_method with 500 does not display as USD \$500', () {
      const nowMs = 1800000000000;
      final newApiSnap = AiService.parseApiBalancePayload(
        const <String, dynamic>{
          'object': 'billing_subscription',
          'has_payment_method': true,
          'soft_limit_usd': 500,
          'hard_limit_usd': 500,
          'system_hard_limit_usd': 500,
          'access_until': 0,
        },
        endpointKey: 'https://newapi-relay.example/v1',
        sourceKind: 'billing_subscription',
        nowMs: nowMs,
      );
      expect(newApiSnap, isNotNull);
      expect(newApiSnap!.currency, isEmpty);
      expect(newApiSnap.isUnitUnknown, isTrue);
      expect(newApiSnap.headlineTextZh, contains('500'));
      expect(newApiSnap.headlineTextZh, contains('单位未知'));
      expect(newApiSnap.headlineTextZh, isNot(contains(r'$')));

      // Official OpenAI host still resolves USD with host evidence.
      final openAiSnap = AiService.parseApiBalancePayload(
        const <String, dynamic>{
          'object': 'billing_subscription',
          'has_payment_method': true,
          'hard_limit_usd': 500,
        },
        endpointKey: 'https://api.openai.com/v1',
        sourceKind: 'billing_subscription',
        nowMs: nowMs,
      );
      expect(openAiSnap, isNotNull);
      expect(openAiSnap!.currency, 'USD');
      expect(openAiSnap.headlineTextZh, contains(r'$500'));
    });

    test('primary Codex catalog succeeds while secondary catalog disconnects -> preserves primary-only models; auth loss still aborts', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
      final seed = _TestEd25519Signer.seedFor(33);
      final store = AiLabPasscodeStore.instance;
      store.configureForTest(
        publicKeyHexOverride: _TestEd25519Signer.publicKeyHex(seed),
        clock: () => now,
        targetPlatform: 'ios',
        resetState: true,
      );
      await store.unlockWithPasscode(
        _TestEd25519Signer.issueToken(
          seed,
          expEpochSec: 1800003600,
          expOAuth: true,
        ),
      );

      final client = MockClient((req) async {
        if (req.url.path.endsWith('/codex/models')) {
          return http.Response(
            jsonEncode({
              'models': [
                {'slug': 'gpt-primary-exclusive', 'priority': 1},
                {'slug': 'gpt-5.4', 'priority': 2},
              ],
            }),
            200,
          );
        }
        throw const SocketException('secondary catalog offline');
      });

      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: InMemorySecureCredentialStore(),
        passcodeStore: store,
        clock: () => now,
        codexModelsEndpoint: 'https://chatgpt.example/backend-api/codex/models',
        codexWebModelsEndpoint: 'https://chatgpt.example/backend-api/models',
        labUnlockedForTest: null,
        resetState: true,
      );
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.codexOAuth,
          model: 'gpt-5.4',
        ),
      );
      await AiService.instance.setOAuthSession(
        const AiOAuthSession(
          accessToken: 'tok-ok',
          refreshToken: 'ref-ok',
          accountId: 'acct-1',
          expiresAtEpochMs: 1800099999000,
        ),
      );

      final models = await AiService.instance.fetchAvailableModelOptions();
      expect(
        models.map((m) => m.id),
        contains('gpt-primary-exclusive'),
      );

      // Now simulate auth invalidation while secondary is failing -> MUST still abort!
      final secondaryEntered = Completer<void>();
      final releaseSecondary = Completer<void>();
      final authLossClient = MockClient((req) async {
        if (req.url.path.endsWith('/codex/models')) {
          return http.Response(
            jsonEncode({
              'models': [
                {'slug': 'gpt-should-not-write', 'priority': 1},
              ],
            }),
            200,
          );
        }
        if (!secondaryEntered.isCompleted) secondaryEntered.complete();
        await releaseSecondary.future;
        throw const SocketException('secondary offline after privacy');
      });
      AiService.instance.configureForTest(httpClient: authLossClient);
      final fut = AiService.instance.fetchAvailableModelOptions();
      await secondaryEntered.future;
      AiService.instance.setPrivacySessionActive(true);
      releaseSecondary.complete();
      await expectLater(
        fut,
        throwsA(
          isA<AiServiceException>().having(
            (e) => e.code,
            'code',
            AiErrorCode.privacySpaceBlocked,
          ),
        ),
      );
      expect(
        AiService.instance.discoveredModels.map((m) => m.id),
        isNot(contains('gpt-should-not-write')),
      );
    });
  });

  // =========================================================================
  // P1-11: Curated discovery cancels body subscription / closes dedicated client
  // =========================================================================
  group('P1-11: CuratedDiscoveryService closes hanging connections on timeout', () {
    test('consecutive timed-out refreshes return old snapshot and disconnect server sockets cleanly without accumulation', () async {
      await _withRealHttp(() async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async => server.close());

        var totalAccepted = 0;
        var activeConnections = 0;
        var disconnectCount = 0;
        final openSockets = <Socket>[];
        addTearDown(() {
          for (final s in openSockets) {
            s.destroy();
          }
        });

        server.listen((socket) {
          totalAccepted++;
          activeConnections++;
          openSockets.add(socket);
          var headersReceived = false;
          var closed = false;
          void markDisconnected() {
            if (closed) return;
            closed = true;
            activeConnections--;
            disconnectCount++;
            socket.destroy();
          }

          socket.listen(
            (data) {
              if (!headersReceived) {
                headersReceived = true;
                // Send valid HTTP/1.1 200 chunked headers + partial JSON body,
                // then hang indefinitely until client disconnects!
                socket.add(
                  utf8.encode(
                    'HTTP/1.1 200 OK\r\n'
                    'Content-Type: application/json\r\n'
                    'Transfer-Encoding: chunked\r\n'
                    '\r\n'
                    '1d\r\n'
                    '{"subject_collection_items":[\r\n',
                  ),
                );
              }
            },
            onDone: markDisconnected,
            onError: (_) => markDisconnected(),
            cancelOnError: true,
          );
        });

        final spec = CuratedDiscoveryService.modules.first;
        // Seed existing good snapshot first.
        CuratedDiscoveryService.debugLiveFetcherOverride = (_) async =>
            const <CmsVideo>[
              CmsVideo(
                id: 'snap_1',
                title: '旧快照佳片',
                poster: 'https://img.example/snap1.jpg',
              ),
            ];
        final initial = await CuratedDiscoveryService.fetchModule(
          spec,
          forceRefresh: true,
        );
        expect(initial.first.title, '旧快照佳片');

        CuratedDiscoveryService.debugLiveFetcherOverride = null;
        CuratedDiscoveryService.debugLiveModuleTotalTimeout =
            const Duration(milliseconds: 220);
        CuratedDiscoveryService.debugLiveUriOverride =
            (_) => Uri.parse('http://127.0.0.1:${server.port}/slow');

        for (var round = 0; round < 3; round++) {
          final sw = Stopwatch()..start();
          final res = await CuratedDiscoveryService.fetchModule(
            spec,
            forceRefresh: true,
          );
          sw.stop();
          expect(res.first.title, '旧快照佳片');
          expect(sw.elapsedMilliseconds, lessThan(1500));
        }

        // Wait briefly for server probe tick to observe all 3 client disconnects.
        for (var i = 0; i < 20 && activeConnections > 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(totalAccepted, 3);
        expect(disconnectCount, 3);
        expect(activeConnections, 0);
      });
    });
  });

  // =========================================================================
  // P2-12: Popover -> Sheet fallback on rotation/Split View & ascending detents
  // =========================================================================
  group('P2-12: Popover rotation/Split View sheet fallback and ascending detents', () {
    testWidgets(
      'compact 375pt landscape & narrow 320pt iPad Split View expose all 4 items tappable and dismissible',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final lgSwift = File('ios_native/MarcoLiquidGlass.swift').readAsStringSync();
        expect(lgSwift, contains('sheet.detents = [.medium(), .large()]'));
        expect(lgSwift, isNot(contains('[.large(), .medium()]')));
        expect(
          lgSwift,
          contains('self.transitionPopoverToSheetFallbackIfNeeded()'),
        );

        IosLiquidGlassBridge.setAvailableForTest(false);
        for (final size in const <Size>[Size(667, 375), Size(320, 768)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          String? picked;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (ctx) => Center(
                    child: CupertinoButton(
                      onPressed: () {
                        unawaited(
                          showIosGlassPopover<void>(
                            context: ctx,
                            anchorRect: const Rect.fromLTWH(240, 200, 44, 44),
                            title: '更多设置',
                            maxWidth: 304,
                            maxHeight: 488,
                            forceDark: true,
                            builder: (popCtx) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final entry in const [
                                  ('opt1', '选项一'),
                                  ('opt2', '选项二'),
                                  ('opt3', '选项三'),
                                  ('opt4', '选项四'),
                                ])
                                  CupertinoButton(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                      horizontal: 12,
                                    ),
                                    onPressed: () {
                                      picked = entry.$1;
                                      Navigator.of(popCtx).pop();
                                    },
                                    child: Text(entry.$2),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                      child: const Text('OPEN_MENU'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('OPEN_MENU'));
          await tester.pumpAndSettle();

          for (final label in const ['选项一', '选项二', '选项三', '选项四']) {
            expect(find.text(label), findsOneWidget);
          }
          await tester.tap(find.text('选项四'));
          await tester.pumpAndSettle();
          expect(picked, 'opt4');
          expect(find.text('选项四'), findsNothing);
        }
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      },
    );
  });

  // =========================================================================
  // P2-13: PosterLoader.clearCache under FLUTTER_TEST only clears test root
  // =========================================================================
  group('P2-13: PosterLoader.clearCache test-root isolation', () {
    test('clearCache only deletes files inside active test root and preserves legacy cache dirs outside it', () async {
      final isolatedTemp =
          await Directory.systemTemp.createTemp('marco_r3_p13_');
      addTearDown(() async {
        PosterLoader.resetDiskCacheConfigForTest();
        try {
          if (await isolatedTemp.exists()) {
            await isolatedTemp.delete(recursive: true);
          }
        } catch (_) {}
      });

      final testRoot = Directory(
        '${isolatedTemp.path}${Platform.pathSeparator}active_test_cache',
      );
      await testRoot.create(recursive: true);
      final insideFile = File(
        '${testRoot.path}${Platform.pathSeparator}inside_sample.bin',
      );
      await insideFile.writeAsBytes(const <int>[1, 2, 3, 4]);

      final legacyFiles = <File>[];
      for (final folder in const <String>[
        'marco_poster_cache_v7',
        'marco_poster_cache_v6',
        'marco_poster_cache_v5',
        'marco_poster_cache_v4',
      ]) {
        final dir = Directory(
          '${isolatedTemp.path}${Platform.pathSeparator}$folder',
        );
        await dir.create(recursive: true);
        final sample = File(
          '${dir.path}${Platform.pathSeparator}keep_$folder.bin',
        );
        await sample.writeAsBytes(const <int>[9, 8, 7]);
        legacyFiles.add(sample);
      }

      PosterLoader.debugDiskDirOverride = testRoot;
      await PosterLoader.clearCache();

      // Active test root file WAS cleared.
      expect(await insideFile.exists(), isFalse);
      // Every legacy cache sample outside testRoot MUST remain intact!
      for (final f in legacyFiles) {
        expect(await f.exists(), isTrue, reason: 'Legacy sample ${f.path} must survive');
      }
    });
  });
}

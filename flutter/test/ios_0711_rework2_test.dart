// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS / iPadOS 0.7.11+104 Round-2 Rework Regression Tests
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_features.dart';
import 'package:marco_movie/core/ai_lab_gate.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/episode_scraper.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/work_aggregation.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_ai_lab_sheets.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_glass_popover.dart';
import 'package:marco_movie/ui/official_channel_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

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

  static Uint8List randomSeed() {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  }

  static String publicKeyHex(Uint8List seed32) {
    final h = sha512.convert(seed32).bytes;
    var a = _fromLe(h.sublist(0, 32));
    a &= (BigInt.one << 254) - BigInt.from(8);
    a |= BigInt.one << 254;
    final pt = _encodePoint(_scalarMult(_b, a));
    return pt.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String issueToken(
    Uint8List seed32, {
    required int expEpochSec,
    String tag = 'rework2',
    String plat = 'all',
    bool expOAuth = false,
  }) {
    final map = <String, Object>{
      'exp': expEpochSec,
      'iat': 1700000000,
      'plat': plat,
      'shared': false,
      'tag': tag,
      'v': 1,
      if (expOAuth) 'exp_oauth': true,
    };
    final payloadBytes = utf8.encode(jsonEncode(map));
    final msg = <int>[
      ...utf8.encode(AiLabGate.signDomainPrefix),
      ...payloadBytes,
    ];
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
    final sig = <int>[...rEnc, ..._toLe32(s)];
    String b64u(List<int> data) => base64UrlEncode(data).replaceAll('=', '');
    return 'MMAILAB1.${b64u(payloadBytes)}.${b64u(sig)}';
  }
}

class _FakePlayerStream extends Fake implements PlayerStream {
  final playlistCtl = StreamController<Playlist>.broadcast();
  final playingCtl = StreamController<bool>.broadcast();
  final completedCtl = StreamController<bool>.broadcast();
  final positionCtl = StreamController<Duration>.broadcast();
  final durationCtl = StreamController<Duration>.broadcast();
  final volumeCtl = StreamController<double>.broadcast();
  final rateCtl = StreamController<double>.broadcast();
  final bufferingCtl = StreamController<bool>.broadcast();
  final bufferCtl = StreamController<Duration>.broadcast();
  final errorCtl = StreamController<String>.broadcast();
  final widthCtl = StreamController<int?>.broadcast();
  final heightCtl = StreamController<int?>.broadcast();
  final trackCtl = StreamController<Track>.broadcast();
  final tracksCtl = StreamController<Tracks>.broadcast();
  final subtitleCtl = StreamController<List<String>>.broadcast();
  final audioParamsCtl = StreamController<AudioParams>.broadcast();
  final videoParamsCtl = StreamController<VideoParams>.broadcast();
  final logCtl = StreamController<PlayerLog>.broadcast();

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
  Stream<double> get volume => volumeCtl.stream;
  @override
  Stream<double> get rate => rateCtl.stream;
  @override
  Stream<bool> get buffering => bufferingCtl.stream;
  @override
  Stream<Duration> get buffer => bufferCtl.stream;
  @override
  Stream<String> get error => errorCtl.stream;
  @override
  Stream<int?> get width => widthCtl.stream;
  @override
  Stream<int?> get height => heightCtl.stream;
  @override
  Stream<Track> get track => trackCtl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtl.stream;
  @override
  Stream<List<String>> get subtitle => subtitleCtl.stream;
  @override
  Stream<AudioParams> get audioParams => audioParamsCtl.stream;
  @override
  Stream<VideoParams> get videoParams => videoParamsCtl.stream;
  @override
  Stream<PlayerLog> get log => logCtl.stream;

  void close() {
    playlistCtl.close();
    playingCtl.close();
    completedCtl.close();
    positionCtl.close();
    durationCtl.close();
    volumeCtl.close();
    rateCtl.close();
    bufferingCtl.close();
    bufferCtl.close();
    errorCtl.close();
    widthCtl.close();
    heightCtl.close();
    trackCtl.close();
    tracksCtl.close();
    subtitleCtl.close();
    audioParamsCtl.close();
    videoParamsCtl.close();
    logCtl.close();
  }
}

class _RecordingFakePlayer extends Fake implements Player {
  final _FakePlayerStream _stream = _FakePlayerStream();
  PlayerState _state = const PlayerState();
  final List<Media> openedMedias = <Media>[];
  final List<Duration> seeks = <Duration>[];

  @override
  PlayerStream get stream => _stream;
  @override
  PlayerState get state => _state;
  @override
  PlatformPlayer? get platform => null;

  void emitPosition(Duration pos) {
    _state = _state.copyWith(position: pos);
    _stream.positionCtl.add(pos);
  }

  void emitDuration(Duration dur) {
    _state = _state.copyWith(duration: dur);
    _stream.durationCtl.add(dur);
  }

  void emitPlaying(bool playing) {
    _state = _state.copyWith(playing: playing);
    _stream.playingCtl.add(playing);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedMedias.add(playable);
      final pl = Playlist([playable]);
      _state = _state.copyWith(
        playlist: pl,
        playing: play,
        position: playable.start ?? Duration.zero,
      );
      _stream.playlistCtl.add(pl);
      _stream.playingCtl.add(play);
    }
  }

  @override
  Future<void> stop() async {
    _state = _state.copyWith(playing: false);
    _stream.playingCtl.add(false);
  }

  @override
  Future<void> play() async {
    _state = _state.copyWith(playing: true);
    _stream.playingCtl.add(true);
  }

  @override
  Future<void> pause() async {
    _state = _state.copyWith(playing: false);
    _stream.playingCtl.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _state = _state.copyWith(position: position);
    _stream.positionCtl.add(position);
  }

  @override
  Future<void> setRate(double rate) async {
    _state = _state.copyWith(rate: rate);
    _stream.rateCtl.add(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    _state = _state.copyWith(volume: volume);
    _stream.volumeCtl.add(volume);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    _state = _state.copyWith(track: _state.track.copyWith(subtitle: track));
    _stream.trackCtl.add(_state.track);
  }

  @override
  Future<void> dispose() async {
    _stream.close();
  }
}

class _LeaseTrackingCmsClient extends CmsClient {
  final List<String> pinnedSites = <String>[];
  final List<String> releasedSites = <String>[];

  _LeaseTrackingCmsClient();

  @override
  VoidCallback pinPlaybackSource(CmsSite site) {
    pinnedSites.add(site.key);
    var released = false;
    return () {
      if (released) return;
      released = true;
      releasedSites.add(site.key);
    };
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AiService.instance.resetForTest();
    AiService.instance.setPrivacySessionActive(false);
    AiLabPasscodeStore.instance.resetForTest();
    CuratedDiscoveryService.resetCacheForTest();
    PosterLoader.clearPrivateCache();
    PosterLoader.resetDiskCacheConfigForTest();
    debugDefaultTargetPlatformOverride = null;
    OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = false;
  });

  // =========================================================================
  // P0-1: Follow-up AI requests & OAuth exchange re-verify auth + no writeback
  // =========================================================================
  group('P0-1: AI follow-up requests re-verify auth before every hop', () {
    test('Codex model catalog 2nd hop aborts when privacy turns on mid-flight', () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
      final seed = _TestEd25519Signer.randomSeed();
      final pubHex = _TestEd25519Signer.publicKeyHex(seed);
      final token = _TestEd25519Signer.issueToken(
        seed,
        expEpochSec: 1800003600,
        expOAuth: true,
      );
      final store = AiLabPasscodeStore.instance;
      store.configureForTest(
        publicKeyHexOverride: pubHex,
        clock: () => now,
        targetPlatform: 'ios',
        resetState: true,
      );
      await store.unlockWithPasscode(token);

      final firstHopEntered = Completer<void>();
      final firstHopRelease = Completer<void>();
      final paths = <String>[];

      final client = MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path.endsWith('/v1/models')) {
          if (!firstHopEntered.isCompleted) firstHopEntered.complete();
          await firstHopRelease.future;
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'gpt-5.4'},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'models': [
              {'slug': 'gpt-5.4-pro'},
            ],
          }),
          200,
        );
      });

      final secStore = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: secStore,
        passcodeStore: store,
        clock: () => now,
        codexModelsEndpoint: 'https://api.example/v1/models',
        codexWebModelsEndpoint: 'https://api.example/backend-api/models',
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
          accessToken: 'tok-live',
          refreshToken: 'ref-live',
          accountId: 'acct-1',
          expiresAtEpochMs: 1800099999000,
        ),
      );

      final fut = AiService.instance.fetchAvailableModelOptions();
      await firstHopEntered.future;

      // Enter privacy space between hop 1 and hop 2.
      AiService.instance.setPrivacySessionActive(true);
      firstHopRelease.complete();

      await expectLater(fut, throwsA(isA<AiServiceException>()));
      // Strictly 0 follow-up requests after state switch!
      expect(paths, equals(<String>['/v1/models']));
      expect(AiService.instance.discoveredModels, isEmpty);
    });

    test('BYO 400 parameter-adaptation retry aborts when passcode expires mid-flight', () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
      final seed = _TestEd25519Signer.randomSeed();
      final pubHex = _TestEd25519Signer.publicKeyHex(seed);
      final token = _TestEd25519Signer.issueToken(
        seed,
        expEpochSec: 1800000060,
        expOAuth: false,
      );
      final store = AiLabPasscodeStore.instance;
      store.configureForTest(
        publicKeyHexOverride: pubHex,
        clock: () => now,
        targetPlatform: 'ios',
        resetState: true,
      );
      await store.unlockWithPasscode(token);

      final firstPostEntered = Completer<void>();
      final firstPostRelease = Completer<void>();
      var postCount = 0;

      final client = MockClient((req) async {
        postCount++;
        if (postCount == 1) {
          if (!firstPostEntered.isCompleted) firstPostEntered.complete();
          await firstPostRelease.future;
          return http.Response(
            jsonEncode({
              'error': {
                'message':
                    'Unsupported parameter: max_tokens is not supported, use max_completion_tokens',
              },
            }),
            400,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'late-retry-should-never-run'},
              },
            ],
          }),
          200,
        );
      });

      final secStore = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: secStore,
        passcodeStore: store,
        clock: () => now,
        labUnlockedForTest: null,
        resetState: true,
      );
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://api.example/v1',
          model: 'o3-mini',
        ),
      );
      await AiService.instance.setApiKey('sk-test-byo-key');

      final fut = AiService.instance.complete(
        feature: 'rework2_retry_guard',
        systemPrompt: 'sys',
        userPrompt: 'hello',
      );
      await firstPostEntered.future;

      // Advance clock past passcode expiry before first response returns.
      now = DateTime.fromMillisecondsSinceEpoch(1800000120 * 1000);
      firstPostRelease.complete();

      await expectLater(fut, throwsA(isA<AiServiceException>()));
      expect(postCount, 1);
      expect(AiService.instance.monthlyUsage.requestCount, 0);
    });

    test('OAuth code exchange discards late response and loopback callback returns 403 after privacy lock', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
      final seed = _TestEd25519Signer.randomSeed();
      final pubHex = _TestEd25519Signer.publicKeyHex(seed);
      final token = _TestEd25519Signer.issueToken(
        seed,
        expEpochSec: 1800003600,
        expOAuth: true,
      );
      final store = AiLabPasscodeStore.instance;
      store.configureForTest(
        publicKeyHexOverride: pubHex,
        clock: () => now,
        targetPlatform: 'ios',
        resetState: true,
      );
      await store.unlockWithPasscode(token);

      final exchangeEntered = Completer<void>();
      final exchangeRelease = Completer<void>();
      var exchangeHits = 0;

      final client = MockClient((req) async {
        exchangeHits++;
        if (!exchangeEntered.isCompleted) exchangeEntered.complete();
        await exchangeRelease.future;
        return http.Response(
          jsonEncode({
            'access_token': 'late-access-tok',
            'refresh_token': 'late-refresh-tok',
            'expires_in': 3600,
          }),
          200,
        );
      });

      final secStore = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: secStore,
        passcodeStore: store,
        clock: () => now,
        codexTokenEndpoint: 'https://api.example/oauth/token',
        labUnlockedForTest: null,
        resetState: true,
      );

      final exFut = AiService.instance.exchangeCodexAuthorizationCode(
        code: 'code-123',
        codeVerifier: 'verifier-123',
        redirectUri: 'http://localhost:1455/auth/callback',
      );
      await exchangeEntered.future;

      // Switch to privacy while token exchange is in flight.
      AiService.instance.setPrivacySessionActive(true);
      exchangeRelease.complete();

      await expectLater(exFut, throwsA(isA<AiServiceException>()));
      expect(exchangeHits, 1);
      expect(AiService.instance.hasOAuthSession, isFalse);
      expect(await secStore.read(AiService.secureOAuthSessionSlot), isNull);

      // Re-exit privacy, start loopback login, then enter privacy before callback arrives.
      AiService.instance.setPrivacySessionActive(false);
      final pending = await AiService.instance.startInteractiveCodexLogin();
      try {
        AiService.instance.setPrivacySessionActive(true);
        final callbackUri = Uri.parse(
          'http://127.0.0.1:${AiService.codexLoopbackPort}/auth/callback'
          '?code=cb-code&state=${Uri.encodeQueryComponent(pending.request.state)}',
        );
        final statusCode = await _withRealHttp(() async {
          final httpClient = HttpClient();
          try {
            final req = await httpClient.getUrl(callbackUri);
            final resp = await req.close();
            await resp.drain<void>();
            return resp.statusCode;
          } finally {
            httpClient.close(force: true);
          }
        });
        expect(statusCode, 403);
        await expectLater(pending.future, throwsA(isA<AiServiceException>()));
        // Zero new exchange requests dispatched by the rejected callback!
        expect(exchangeHits, 1);
      } finally {
        await pending.cancel();
      }
    });
  });

  // =========================================================================
  // P0-2: Per-item offline privacy identity & queue isolation
  // =========================================================================
  group('P0-2: Per-item offline privacy identity across reused site keys', () {
    test('reused siteKey across public & private subscriptions hides private items and isolates playback queue', () {
      const pubSite = CmsSite(
        key: 'shared_key',
        name: '公开源',
        type: 1,
        api: 'https://pub.example/api.php/provide/vod',
        subscriptionId: 'sub_public',
        isPrivate: false,
      );
      const privSite = CmsSite(
        key: 'shared_key',
        name: '私密源',
        type: 1,
        api: 'https://priv.example/api.php/provide/vod',
        subscriptionId: 'sub_private',
        isPrivate: true,
      );
      const cfg = CmsConfig(sites: <CmsSite>[pubSite, privSite]);

      final pubTask = DownloadTask(
        id: 't_pub',
        siteKey: 'shared_key',
        siteName: '公开源',
        siteApi: 'https://pub.example/api.php/provide/vod',
        siteType: 1,
        videoId: 'v1',
        title: '同片名',
        poster: '',
        lineName: '默认线路',
        episodeName: '第1集',
        episodeIndex: 0,
        sourceUrl: 'https://pub.example/ep1.m3u8',
        headers: const <String, String>{},
        createdAt: 1,
        sourceSite: pubSite,
        status: DownloadStatus.completed,
        filePath: '/tmp/pub_ep1.mp4',
      );
      final privTask = DownloadTask(
        id: 't_priv',
        siteKey: 'shared_key',
        siteName: '私密源',
        siteApi: 'https://priv.example/api.php/provide/vod',
        siteType: 1,
        videoId: 'v1',
        title: '同片名',
        poster: '',
        lineName: '默认线路',
        episodeName: '第2集',
        episodeIndex: 1,
        sourceUrl: 'https://priv.example/ep2.m3u8',
        headers: const <String, String>{},
        createdAt: 2,
        sourceSite: privSite,
        status: DownloadStatus.completed,
        filePath: '/tmp/priv_ep2.mp4',
      );
      final ambiguousLegacyTask = DownloadTask(
        id: 't_legacy_ambiguous',
        siteKey: 'shared_key',
        siteName: '旧记录',
        siteApi: '',
        siteType: 1,
        videoId: 'v1',
        title: '同片名',
        poster: '',
        lineName: '默认线路',
        episodeName: '第3集',
        episodeIndex: 2,
        sourceUrl: 'https://legacy.example/ep3.m3u8',
        headers: const <String, String>{},
        createdAt: 3,
        sourceSite: null,
        status: DownloadStatus.completed,
        filePath: '/tmp/legacy_ep3.mp4',
      );

      final allTasks = <DownloadTask>[pubTask, privTask, ambiguousLegacyTask];

      expect(
        AdaptiveShell.resolveOfflinePlaybackSite(pubTask, currentConfig: cfg)
            .isEffectivelyPrivate,
        isFalse,
      );
      expect(
        AdaptiveShell.resolveOfflinePlaybackSite(privTask, currentConfig: cfg)
            .isEffectivelyPrivate,
        isTrue,
      );
      // Ambiguous legacy record sharing a key with a private site fails closed!
      expect(
        AdaptiveShell.resolveOfflinePlaybackSite(
          ambiguousLegacyTask,
          currentConfig: cfg,
        ).isEffectivelyPrivate,
        isTrue,
      );

      // Locked download list hides BOTH private and ambiguous tasks.
      final visibleLocked = AdaptiveShell.filterVisibleOfflineTasks(
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(visibleLocked.map((t) => t.id).toList(), equals(<String>['t_pub']));

      // Public playback queue built from mixed group excludes private & ambiguous items.
      final q = AdaptiveShell.buildOfflinePlaybackQueue(
        pubTask,
        allTasks,
        currentConfig: cfg,
        privacySessionUnlocked: false,
      );
      expect(q.site.isEffectivelyPrivate, isFalse);
      expect(q.queue.map((t) => t.id).toList(), equals(<String>['t_pub']));
      expect(q.startIndex, 0);
    });
  });

  // =========================================================================
  // P1-4: OAuth token refresh isolated by account & auth generation
  // =========================================================================
  group('P1-4: OAuth token refresh account & generation isolation', () {
    test('signOut during A refresh keeps logged out and discards late response', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
      final refreshEntered = Completer<void>();
      final refreshRelease = Completer<void>();

      final client = MockClient((req) async {
        if (!refreshEntered.isCompleted) refreshEntered.complete();
        await refreshRelease.future;
        return http.Response(
          jsonEncode({
            'access_token': 'refreshed-A',
            'refresh_token': 'ref-A-2',
            'expires_in': 3600,
          }),
          200,
        );
      });
      final secStore = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: secStore,
        clock: () => now,
        codexTokenEndpoint: 'https://api.example/oauth/token',
        labUnlockedForTest: true,
        experimentalOAuthForTest: true,
        resetState: true,
      );
      await AiService.instance.setOAuthSession(
        const AiOAuthSession(
          accessToken: 'expired-A',
          refreshToken: 'ref-A-1',
          accountId: 'acct-A',
          expiresAtEpochMs: 1799999000000,
        ),
      );

      final fut = AiService.instance.ensureFreshOAuthSession();
      await refreshEntered.future;

      await AiService.instance.signOutOAuth();
      refreshRelease.complete();

      await expectLater(fut, throwsA(isA<AiServiceException>()));
      expect(AiService.instance.hasOAuthSession, isFalse);
      expect(AiService.instance.oauthSession, isNull);
      expect(await secStore.read(AiService.secureOAuthSessionSlot), isNull);
    });

    test('switching from A to B during A refresh never writes A back to Keychain', () async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
      final refreshEntered = Completer<void>();
      final refreshRelease = Completer<void>();

      final client = MockClient((req) async {
        if (!refreshEntered.isCompleted) refreshEntered.complete();
        await refreshRelease.future;
        return http.Response(
          jsonEncode({
            'access_token': 'late-refreshed-A',
            'refresh_token': 'late-ref-A',
            'expires_in': 3600,
          }),
          200,
        );
      });
      final secStore = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: secStore,
        clock: () => now,
        codexTokenEndpoint: 'https://api.example/oauth/token',
        labUnlockedForTest: true,
        experimentalOAuthForTest: true,
        resetState: true,
      );
      await AiService.instance.setOAuthSession(
        const AiOAuthSession(
          accessToken: 'expired-A',
          refreshToken: 'ref-A-1',
          accountId: 'acct-A',
          expiresAtEpochMs: 1799999000000,
        ),
      );

      final fut = AiService.instance.ensureFreshOAuthSession();
      await refreshEntered.future;

      await AiService.instance.setOAuthSession(
        const AiOAuthSession(
          accessToken: 'fresh-B',
          refreshToken: 'ref-B',
          accountId: 'acct-B',
          expiresAtEpochMs: 1800099999000,
        ),
      );
      refreshRelease.complete();

      await expectLater(fut, throwsA(isA<AiServiceException>()));
      expect(AiService.instance.oauthSession?.accountId, 'acct-B');
      expect(AiService.instance.oauthSession?.accessToken, 'fresh-B');
      final persistedRaw = await secStore.read(AiService.secureOAuthSessionSlot);
      expect(persistedRaw, isNotNull);
      expect(persistedRaw, contains('acct-B'));
      expect(persistedRaw, isNot(contains('late-refreshed-A')));
    });
  });

  // =========================================================================
  // P1-5: Private detail/landscape/fallback poster isolation & late discard
  // =========================================================================
  group('P1-5: Private poster isolation and late response discard', () {
    testWidgets('private detail/landscape poster skips public disk and locking discards late fetch', (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('marco_p15_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      PosterLoader.resetDiskCacheConfigForTest();
      PosterLoader.debugDiskDirOverride = tmpDir;

      final fetchEntered = Completer<void>();
      final fetchRelease = Completer<void>();
      PosterLoader.debugPrivateFetcherOverride = (url) async {
        if (url.contains('delayed-secret')) {
          if (!fetchEntered.isCompleted) fetchEntered.complete();
          await fetchRelease.future;
        }
        return _valid1x1Png;
      };

      // 1. Start slow private load, lock privacy space (clearPrivateCache) mid-flight.
      final loadFut = PosterLoader.load(
        'https://priv.example/delayed-secret.png',
        isPrivate: true,
      );
      await fetchEntered.future;
      PosterLoader.clearPrivateCache();
      expect(PosterLoader.privateMemoryCount, 0);
      fetchRelease.complete();

      await expectLater(loadFut, throwsA(anything));
      // Cleared private cache MUST stay 0 (never bounce back to 1)!
      expect(PosterLoader.privateMemoryCount, 0);

      // 2. LandscapePosterImage with isPrivate: true must write 0 files to public disk.
      await tester.pumpWidget(
        const CupertinoApp(
          home: SizedBox(
            width: 320,
            height: 180,
            child: LandscapePosterImage(
              url: 'https://priv.example/land.png',
              placeholder: SizedBox.shrink(),
              title: '私密作品',
              isPrivate: true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final publicFiles = tmpDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.img'))
          .toList();
      expect(publicFiles, isEmpty);
    });
  });

  // =========================================================================
  // P1-6: Protocol/provider netdisk detection & independent quality sort
  // =========================================================================
  group('P1-6: Netdisk protocol/provider detection with independent quality sort', () {
    test('4K direct M3U8 vs Quark share selects correctly across all 3 modes', () async {
      final storage = await initTestStorage();
      const linesQuarkFirst = <CmsLine>[
        CmsLine(
          name: '夸克分享',
          episodes: [
            CmsEpisode(name: '正片', url: 'https://pan.quark.cn/s/abc123'),
          ],
        ),
        CmsLine(
          name: '4K直连 M3U8',
          episodes: [
            CmsEpisode(name: '正片', url: 'https://cdn.example/stream/4k.m3u8'),
          ],
        ),
      ];
      final linesDirectFirst = linesQuarkFirst.reversed.toList();

      // Mode 1: Direct priority (`1080p_direct`) MUST pick 4K direct M3U8!
      await storage.setPreferredQuality('1080p_direct');
      expect(storage.pickRecommendedLineIndex(linesQuarkFirst), 1);
      expect(storage.pickRecommendedLineIndex(linesDirectFirst), 0);

      // Mode 2: Netdisk priority (`4k_netdisk`) picks Quark share.
      await storage.setPreferredQuality('4k_netdisk');
      expect(storage.pickRecommendedLineIndex(linesQuarkFirst), 0);
      expect(storage.pickRecommendedLineIndex(linesDirectFirst), 1);

      // Mode 3: Default (`default`) preserves upstream source order.
      await storage.setPreferredQuality('default');
      expect(storage.pickRecommendedLineIndex(linesQuarkFirst), 0);
      expect(storage.pickRecommendedLineIndex(linesDirectFirst), 0);
    });
  });

  // =========================================================================
  // P1-7: Separate notice-seen vs onboarding-done in startup coordinator
  // =========================================================================
  group('P1-7: Separate notice-seen vs onboarding-done startup flows', () {
    testWidgets(
      'Windows fresh install enters Onboarding after confirming notice',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Marco Movie',
        packageName: 'com.pilipala.marcomovie',
        version: '0.7.11',
        buildNumber: '104',
        buildSignature: '',
      );
      SharedPreferences.setMockInitialValues({});
      final storage = await initTestStorage();
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(storage: storage, client: CmsClient()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey('windows-post-update-notice-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('进入应用'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(OnboardingScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets(
      'iOS interrupted first onboarding resumes without re-popping update notice, and same build completed shows 0 dialogs',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
      OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = true;
      PackageInfo.setMockInitialValues(
        appName: 'Marco Movie',
        packageName: 'com.pilipala.marcomovie',
        version: '0.7.11',
        buildNumber: '104',
        buildSignature: '',
      );
      // Interrupted onboarding: official notice already confirmed & build stamped,
      // but onboarding_done_version is still 0.
      final storage = await initTestStorage();
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(
        OnboardingPrefs.officialChannelNoticeVersionKey,
        OnboardingPrefs.currentOfficialChannelNoticeVersion,
      );
      await sp.setString(OnboardingPrefs.lastSeenAppVersionKey, '0.7.11+104');
      await sp.setInt(OnboardingPrefs.doneVersionKey, 0);
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        CupertinoApp(
          home: AdaptiveShell(storage: storage, client: CmsClient()),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
      expect(find.byType(PostUpdateWelcomeDialog), findsNothing);
      expect(find.byType(OnboardingScreen), findsOneWidget);

      // Completed install on same build 0.7.11+104 -> 0 dialogs!
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final storage2 = await initTestStorage();
      final sp2 = await SharedPreferences.getInstance();
      await sp2.setInt(
        OnboardingPrefs.officialChannelNoticeVersionKey,
        OnboardingPrefs.currentOfficialChannelNoticeVersion,
      );
      await sp2.setString(OnboardingPrefs.lastSeenAppVersionKey, '0.7.11+104');
      await sp2.setInt(
        OnboardingPrefs.doneVersionKey,
        OnboardingPrefs.currentVersion,
      );
      await tester.pumpWidget(
        CupertinoApp(
          home: AdaptiveShell(storage: storage2, client: CmsClient()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
      expect(find.byType(PostUpdateWelcomeDialog), findsNothing);
      expect(find.byType(OnboardingScreen), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  // =========================================================================
  // P1-8: Preserve matching series stem for sequel detection
  // =========================================================================
  group('P1-8: Sequel pack vs multi-version movie classification', () {
    test('沙丘 4K / 沙丘2 1080P remains 2 separate works while 沙丘 4K / 沙丘 1080P stays versions', () {
      const sequelPack = <CmsEpisode>[
        CmsEpisode(name: '沙丘 4K.mkv', url: 'https://cdn.example/dune1.mkv'),
        CmsEpisode(name: '沙丘2 1080P.mkv', url: 'https://cdn.example/dune2.mkv'),
      ];
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          sequelPack,
          videoTitle: '沙丘',
          videoTag: '电影',
        ),
        isFalse,
      );
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          sequelPack,
          videoTitle: '沙丘',
        ),
        isFalse,
      );

      const sameMovieVersions = <CmsEpisode>[
        CmsEpisode(name: '沙丘 4K.mkv', url: 'https://cdn.example/dune_4k.mkv'),
        CmsEpisode(name: '沙丘 1080P.mkv', url: 'https://cdn.example/dune_1080.mkv'),
      ];
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          sameMovieVersions,
          videoTitle: '沙丘',
          videoTag: '电影',
        ),
        isTrue,
      );
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          sameMovieVersions,
          videoTitle: '沙丘',
        ),
        isTrue,
      );
    });
  });

  // =========================================================================
  // P1-9: AVPlayer subtitle suppression coordination & immediate clear on seek/track
  // =========================================================================
  group('P1-9: AVPlayer subtitle flush & native rendering suppression', () {
    test('setSuppressNativeSubtitleRendering toggles native suppression and seek/track switch clear cues immediately', () async {
      const methodCh = MethodChannel('marco_movie/ios_avplayer_test_p19');
      const eventCh = EventChannel('marco_movie/ios_avplayer_events_test_p19');
      final recordedCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodCh, (call) async {
        recordedCalls.add(call);
        if (call.method == 'seek') {
          return <String, Object>{
            'finished': true,
            'positionMs': call.arguments as int,
          };
        }
        return true;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        eventCh,
        MockStreamHandler.inline(
          onListen: (args, events) {
            events.success(<String, Object>{
              'type': 'subtitleCue',
              'lines': <String>['Original Line One'],
              'hasNativeSamples': false,
            });
          },
        ),
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodCh, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(eventCh, null);
      });

      final ctrl = IosAvPlayerController(
        channelOverride: methodCh,
        eventChannelOverride: eventCh,
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(ctrl.dispose);

      await ctrl.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctrl.activeSubtitleLines, equals(<String>['Original Line One']));

      // Coordinate native suppression ON (inline AI overlay active) then OFF (PiP or overlay off).
      await ctrl.setSuppressNativeSubtitleRendering(true);
      expect(ctrl.suppressNativeSubtitleRendering, isTrue);
      await ctrl.setSuppressNativeSubtitleRendering(false);
      expect(ctrl.suppressNativeSubtitleRendering, isFalse);
      final suppressArgs = recordedCalls
          .where((c) => c.method == 'setSuppressNativeSubtitleRendering')
          .map((c) => c.arguments)
          .toList();
      expect(suppressArgs, equals(<Object>[true, false]));

      // Seek immediately clears stale subtitle lines.
      await ctrl.seek(const Duration(seconds: 45));
      expect(ctrl.activeSubtitleLines, isEmpty);

      // Switching subtitle track immediately clears stale subtitle lines.
      await ctrl.setSubtitleTrack('1');
      expect(ctrl.activeSubtitleLines, isEmpty);
    });
  });

  // =========================================================================
  // P1-10: Real 30-min cue timestamp + session persistence across close/reopen
  // =========================================================================
  group('P1-10: AI Subtitle Studio real timestamps & session persistence', () {
    testWidgets('at 30:00 without external file uses real timestamp so translated cue renders at 30:00', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = MockClient((req) async {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'glossary': {'Paul': '保罗'},
                      'items': [
                        {'i': 0, 'zh': '我们三十分钟时必须出发。'},
                      ],
                    }),
                  },
                },
              ],
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: InMemorySecureCredentialStore(),
        labUnlockedForTest: true,
        resetState: true,
      );
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://api.example/v1',
          model: 'gpt-4o-mini',
          subtitleTranslateEnabled: true,
        ),
      );
      await AiService.instance.setApiKey('sk-test-sub');

      List<AiSubtitleCue> appliedCues = const <AiSubtitleCue>[];
      bool liveToggled = false;
      const playPos = Duration(minutes: 30);

      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (ctx) => CupertinoButton(
              onPressed: () {
                showIosAiSubtitleStudioSheet(
                  ctx,
                  seriesTitle: '沙丘',
                  episodeLabel: '正片',
                  skipIntroSeconds: 0,
                  currentPlaybackPosition: playPos,
                  currentActiveCueLines: const <String>[
                    'Paul, we must leave now.',
                  ],
                  onToggleLiveEmbeddedTranslate: (v) => liveToggled = v,
                  onApplySubtitleOverlay: (
                    cues, {
                    required bilingual,
                    required offset,
                    required label,
                  }) async {
                    appliedCues = cues;
                  },
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('ai-sub-translate-mount-btn')));
      await tester.pumpAndSettle();

      expect(appliedCues, hasLength(1));
      expect(appliedCues.first.start <= playPos, isTrue);
      expect(appliedCues.first.end >= playPos, isTrue);
      expect(appliedCues.first.translatedText, '我们三十分钟时必须出发。');
      expect(liveToggled, isTrue);
    });

    testWidgets('reopening studio restores cues/glossary/offset, resumes from #121, and adjusts existing track offset', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final requestedLines = <String>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final userMsg = (body['messages'] as List).last['content'].toString();
        requestedLines.add(userMsg);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'glossary': {'Paul': '保罗', 'Arrakis': '厄拉科斯'},
                      'items': [
                        for (int i = 0; i < 30; i++)
                          {'i': i, 'zh': '续译第${121 + i}条'},
                      ],
                    }),
                  },
                },
              ],
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      });
      AiService.instance.configureForTest(
        httpClient: client,
        secureStorage: InMemorySecureCredentialStore(),
        labUnlockedForTest: true,
        resetState: true,
      );
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://api.example/v1',
          model: 'gpt-4o-mini',
          subtitleTranslateEnabled: true,
        ),
      );
      await AiService.instance.setApiKey('sk-test-sub2');

      // Build 150-cue session: cues 1..120 translated, 121..150 pending.
      final persistedCues = <AiSubtitleCue>[
        for (int i = 0; i < 150; i++)
          AiSubtitleCue(
            index: i + 1,
            start: Duration(seconds: i * 5),
            end: Duration(seconds: i * 5 + 4),
            text: 'Line_${i + 1}',
            translatedText: i < 120 ? '已译_${i + 1}' : '',
          ),
      ];
      AiSubtitleSessionState session = AiSubtitleSessionState(
        cues: persistedCues,
        glossary: const <String, String>{'Paul': '保罗'},
        bilingual: true,
        offset: const Duration(milliseconds: 500),
        label: 'AI 中外双语精译',
        overlayActive: true,
      );
      Duration? lastAppliedOffset;

      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (ctx) => CupertinoButton(
              onPressed: () {
                showIosAiSubtitleStudioSheet(
                  ctx,
                  seriesTitle: '沙丘',
                  episodeLabel: '正片',
                  skipIntroSeconds: 0,
                  initialSession: session,
                  onSessionChanged: (next) => session = next,
                  onApplySubtitleOverlay: (
                    cues, {
                    required bilingual,
                    required offset,
                    required label,
                  }) async {
                    lastAppliedOffset = offset;
                  },
                );
              },
              child: const Text('reopen'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('reopen'));
      await tester.pumpAndSettle();

      // Restored glossary, +0.5s offset, and "continue remaining 30" button are visible!
      expect(find.text('Paul → 保罗'), findsOneWidget);
      expect(find.text('时间轴微调：+0.5s'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-sub-continue-translate-btn')),
        findsOneWidget,
      );

      // Adjust offset on existing track -> +1.0s applied immediately.
      await tester.ensureVisible(find.text('+0.5s'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+0.5s'));
      await tester.pumpAndSettle();
      expect(lastAppliedOffset, const Duration(milliseconds: 1000));
      expect(session.offset, const Duration(milliseconds: 1000));

      // Resume translating remaining cues starting at #121!
      final continueBtn =
          find.byKey(const ValueKey('ai-sub-continue-translate-btn'));
      await tester.ensureVisible(continueBtn);
      await tester.pumpAndSettle();
      await tester.tap(continueBtn);
      await tester.pumpAndSettle();

      expect(requestedLines.join('\n'), contains('Line_121'));
      expect(requestedLines.join('\n'), isNot(contains('Line_1"')));
      expect(requestedLines.join('\n'), contains('保罗'));
      expect(session.translatedCount, 150);
      expect(session.cues[0].translatedText, '已译_1');
      expect(session.cues[120].translatedText, '续译第121条');
      expect(session.glossary['Arrakis'], '厄拉科斯');
    });
  });

  // =========================================================================
  // P1-11: _switchToRecommendedPick reuses full video switch lifecycle
  // =========================================================================
  group('P1-11: Recommended pick switch reuses complete video lifecycle', () {
    testWidgets(
      'switching A(skip 90s) -> B(skip 0s) saves A history, releases A source, updates source list to B, plays B from 0s',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
      SharedPreferences.setMockInitialValues({
        OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
      });
      final storage = await initTestStorage();
      await storage.setMediaDiskCacheLimitMb(0);
      await storage.setIosPlaybackEngineMode('mpv');
      await storage.setVideoSkipIntroSec('site_a', 'vid_a', 90);
      await storage.setVideoSkipIntroSec('site_b', 'vid_b', 0);
      final onboardingPrefs = await OnboardingPrefs.load();

      const siteA = CmsSite(
        key: 'site_a',
        name: '站点A',
        type: 1,
        api: 'https://sitea.example/api',
      );
      const siteAAlt = CmsSite(
        key: 'site_a_alt',
        name: '站点A备源',
        type: 1,
        api: 'https://sitea-alt.example/api',
      );
      const siteB = CmsSite(
        key: 'site_b',
        name: '站点B',
        type: 1,
        api: 'https://siteb.example/api',
      );
      const videoA = CmsVideo(
        id: 'vid_a',
        title: '影片A',
        lines: [
          CmsLine(
            name: '线路A',
            episodes: [
              CmsEpisode(name: '正片', url: 'https://cdn.example/a.mp4'),
            ],
          ),
        ],
      );
      const videoAAlt = CmsVideo(
        id: 'vid_a_alt',
        title: '影片A',
        lines: [
          CmsLine(
            name: '备源线路',
            episodes: [
              CmsEpisode(name: '正片', url: 'https://cdn.example/a_alt.mp4'),
            ],
          ),
        ],
      );
      const videoB = CmsVideo(
        id: 'vid_b',
        title: '影片B',
        lines: [
          CmsLine(
            name: '线路B',
            episodes: [
              CmsEpisode(name: '正片', url: 'https://cdn.example/b.mp4'),
            ],
          ),
        ],
      );

      final fakePlayer = _RecordingFakePlayer();
      final client = _LeaseTrackingCmsClient();
      Future<void> Function(AiCuratedPick)? switchPick;
      Map<String, Object?> Function()? inspectState;

      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        CupertinoApp(
          home: PlayerScreen(
            site: siteA,
            video: videoA,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            client: client,
            alternativeSources: <WorkSourceRef>[
              WorkSourceRef(
                site: siteAAlt,
                videoId: 'vid_a_alt',
                video: videoAAlt,
                sourceLabel: '站点A备源',
              ),
            ],
            debugPlayer: fakePlayer,
            debugVideoSurface: const SizedBox.expand(),
            debugHudPrefs: PlayerHudPrefs.inMemory(
              initial: PlayerHudPrefsData.defaultsFor(isDesktop: false)
                  .copyWith(skipCountdown: false),
            ),
            debugDanmuSettings: const DanmuSettings(enabled: false),
            debugOnboardingPrefs: onboardingPrefs,
            debugOnBindSwitchPickForTest: (fn) => switchPick = fn,
            debugOnBindStateInspectorForTest: (fn) => inspectState = fn,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.pinnedSites, equals(<String>['site_a']));
      expect(inspectState!()['skipIntroSec'], 90);
      expect(
        inspectState!()['crossSiteSourceIds'],
        contains('site_a_alt:vid_a_alt'),
      );

      // Simulate Film A playing past its 90s intro skip to 125s out of 3600s.
      fakePlayer.emitDuration(const Duration(seconds: 3600));
      fakePlayer.emitPlaying(true);
      await tester.pump(const Duration(milliseconds: 50));
      fakePlayer.emitPosition(const Duration(seconds: 125));
      await tester.pump(const Duration(milliseconds: 50));

      // Switch to Film B via AI recommended pick!
      await switchPick!(
        const AiCuratedPick(
          title: '影片B',
          year: '2026',
          reason: '同题材佳作',
          matchedSite: siteB,
          matchedVideo: videoB,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      // 1. Film A's exact resume progress saved to watch history.
      final history = storage.getWatchHistory();
      final histA = history
          .where((e) => e.site == 'site_a' && e.id == 'vid_a')
          .toList();
      expect(histA, hasLength(1));
      expect(histA.first.position, 125000);

      // 2. Film A's source lease was released and Film B's source was pinned.
      expect(client.releasedSites, contains('site_a'));
      expect(client.pinnedSites, equals(<String>['site_a', 'site_b']));

      // 3. State belongs strictly to Film B (skipIntroSec == 0, source list == B only).
      final snap = inspectState!();
      expect(snap['activeSiteKey'], 'site_b');
      expect(snap['activeVideoId'], 'vid_b');
      expect(snap['skipIntroSec'], 0);
      expect(snap['crossSiteSourceIds'], equals(<String>['site_b:vid_b']));

      // 4. Film B opened directly at 0s and does NOT trigger Film A's 90s intro skip!
      expect(fakePlayer.openedMedias.length, greaterThanOrEqualTo(2));
      expect(
        fakePlayer.openedMedias.last.uri,
        isNot(equals(fakePlayer.openedMedias.first.uri)),
      );
      expect(fakePlayer.openedMedias.last.start ?? Duration.zero, Duration.zero);
      final seeksBeforeBPlay = fakePlayer.seeks.length;
      fakePlayer.emitDuration(const Duration(seconds: 3600));
      fakePlayer.emitPlaying(true);
      fakePlayer.emitPosition(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      expect(fakePlayer.seeks.length, seeksBeforeBPlay);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  // =========================================================================
  // P1-12: Evidence-based billing currency/units & explicit-only unlimited
  // =========================================================================
  group('P1-12: Evidence-based billing units and explicit unlimited detection', () {
    test('covers CNY, USD, large finite token, explicit unlimited, unknown unit, and missing usage', () {
      const nowMs = 1800000000000;

      // 1. CNY (DeepSeek official host / explicit currency)
      final cny = AiService.parseApiBalancePayload(
        {
          'is_available': true,
          'balance_infos': [
            {'currency': 'CNY', 'total_balance': '38.50'},
          ],
        },
        endpointKey: 'https://api.deepseek.com/v1',
        sourceKind: 'user_balance',
        nowMs: nowMs,
      );
      expect(cny, isNotNull);
      expect(cny!.currency, 'CNY');
      expect(cny.headlineTextZh, contains('¥38.50'));

      // 2. USD (OpenAI official host + explicit USD)
      final usd = AiService.parseApiBalancePayload(
        {'total_granted': 20.0, 'total_used': 5.0, 'total_available': 15.0},
        endpointKey: 'https://api.openai.com/v1',
        sourceKind: 'credit_grants',
        nowMs: nowMs,
      );
      expect(usd, isNotNull);
      expect(usd!.currency, 'USD');
      expect(usd.headlineTextZh, contains(r'$15.00'));

      // 3. Large finite token quota (100,000,000) MUST NOT be labeled unlimited!
      final bigFinite = AiService.parseApiBalancePayload(
        {'total_tokens': 100000000, 'remaining_tokens': 85000000},
        endpointKey: 'https://relay.example/v1',
        sourceKind: 'credit_grants',
        nowMs: nowMs,
      );
      expect(bigFinite, isNotNull);
      expect(bigFinite!.isUnlimited, isFalse);
      expect(bigFinite.currency, 'TOKENS');
      expect(bigFinite.headlineTextZh, isNot(contains('无限')));
      expect(bigFinite.headlineTextZh, isNot(contains(r'$')));

      // 4. Explicit unlimited flag -> unlimited
      final explicitUnlimited = AiService.parseApiBalancePayload(
        {'unlimited_quota': true, 'total_used': 12.5},
        endpointKey: 'https://relay.example/v1',
        sourceKind: 'credit_grants',
        nowMs: nowMs,
      );
      expect(explicitUnlimited, isNotNull);
      expect(explicitUnlimited!.isUnlimited, isTrue);
      expect(explicitUnlimited.headlineTextZh, contains('无限额度'));

      // 5. Generic relay without unit evidence -> explicitly marks unknown unit, NO "$"
      final unknownUnit = AiService.parseApiBalancePayload(
        {'total_granted': 500, 'total_available': 320},
        endpointKey: 'https://relay.example/v1',
        sourceKind: 'credit_grants',
        nowMs: nowMs,
      );
      expect(unknownUnit, isNotNull);
      expect(unknownUnit!.isUnitUnknown, isTrue);
      expect(unknownUnit.headlineTextZh, contains('单位未知'));
      expect(unknownUnit.headlineTextZh, isNot(contains(r'$')));
      expect(unknownUnit.headlineTextZh, isNot(contains('¥')));

      // 6. Missing /billing/usage on subscription -> shows limit without faking usage = 0
      final subOnly = AiService.parseApiBalancePayload(
        {'object': 'billing_subscription', 'hard_limit_usd': 50.0},
        endpointKey: 'https://api.openai.com/v1',
        sourceKind: 'billing_subscription',
        nowMs: nowMs,
      );
      expect(subOnly, isNotNull);
      expect(subOnly!.totalUsed, isNull);
      expect(subOnly.remaining, isNull);
      expect(subOnly.headlineTextZh, contains('额度上限'));
    });
  });

  // =========================================================================
  // P1-13: Curated HTTP body total timeout & scoped posterless scrape deferral
  // =========================================================================
  group('P1-13: Curated body total deadline & scoped posterless scrape deferral', () {
    test('stalled HTTP response body hits total deadline and preserves old snapshot', () async {
      await _withRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async => server.close(force: true));
        final hangingSockets = <HttpResponse>[];
        server.listen((req) {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"subjects":[');
          // Intentionally flush headers and partial body without closing!
          unawaited(req.response.flush());
          hangingSockets.add(req.response);
        });

        CuratedDiscoveryService.resetCacheForTest();
        final spec = CuratedDiscoveryService.modules.first;
        // Seed an existing good snapshot first.
        CuratedDiscoveryService.debugLiveFetcherOverride = (_) async =>
            const <CmsVideo>[
              CmsVideo(
                id: 'curated:snap:1',
                title: '旧快照影片',
                poster: 'https://cdn.example/old_snap.jpg',
              ),
            ];
        final initial = await CuratedDiscoveryService.fetchModule(
          spec,
          forceRefresh: true,
        );
        expect(initial.first.title, '旧快照影片');

        // Switch to real stalled loopback HTTP server with 250ms total budget.
        CuratedDiscoveryService.debugLiveFetcherOverride = null;
        CuratedDiscoveryService.debugLiveModuleTotalTimeout =
            const Duration(milliseconds: 250);
        CuratedDiscoveryService.debugLiveUriOverride =
            (_) => Uri.http('127.0.0.1:${server.port}', '/stalled', {'p': '1'});

        final sw = Stopwatch()..start();
        final afterTimeout = await CuratedDiscoveryService.fetchModule(
          spec,
          forceRefresh: true,
        );
        sw.stop();

        // Must finish near the total deadline (never hang indefinitely) and keep old snapshot!
        expect(sw.elapsedMilliseconds, lessThan(2500));
        expect(afterTimeout.first.title, '旧快照影片');
        expect(afterTimeout.first.poster, 'https://cdn.example/old_snap.jpg');
      });
    });

    testWidgets('ordinary CMS cards do not defer posterless scrape while curated seeds do', (tester) async {
      final refreshBlocker = Completer<List<CmsVideo>?>();
      CuratedDiscoveryService.resetCacheForTest();
      CuratedDiscoveryService.debugLiveFetcherOverride =
          (_) => refreshBlocker.future;
      final refreshFut = CuratedDiscoveryService.refreshAllModules();
      await tester.pump(const Duration(milliseconds: 20));
      expect(CuratedDiscoveryService.shouldDeferPosterlessSeedScrape, isTrue);

      await tester.pumpWidget(
        const CupertinoApp(
          home: Row(
            children: [
              SizedBox(
                width: 80,
                height: 120,
                child: PosterImage(
                  key: ValueKey('cms-ordinary-card'),
                  url: '',
                  title: '普通CMS影片',
                  placeholder: SizedBox.shrink(),
                ),
              ),
              SizedBox(
                width: 80,
                height: 120,
                child: PosterImage(
                  key: ValueKey('curated-seed-card'),
                  url: '',
                  title: '精选种子影片',
                  deferTitleScrape: true,
                  placeholder: SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<PosterImage>(find.byKey(const ValueKey('cms-ordinary-card')))
            .deferTitleScrape,
        isFalse,
      );
      expect(
        tester
            .widget<PosterImage>(find.byKey(const ValueKey('curated-seed-card')))
            .deferTitleScrape,
        isTrue,
      );

      refreshBlocker.complete(null);
      await refreshFut;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  // =========================================================================
  // P2-14: Cold-start disk cache cap enforcement across short runs
  // =========================================================================
  group('P2-14: Startup 100 MiB cache cap enforcement & test dir isolation', () {
    test('repeated cold starts prune oversized cache without needing 24 writes', () async {
      await _withRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async => server.close(force: true));
        server.listen((req) {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType('image', 'png');
          req.response.add(_valid1x1Png);
          unawaited(req.response.close());
        });

        final tmpDir = Directory.systemTemp.createTempSync('marco_p214_');
        addTearDown(() async {
          PosterLoader.resetDiskCacheConfigForTest();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          try {
            if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
          } catch (_) {}
        });

        // Seed 4 files totaling 400 bytes in the cache directory BEFORE cold start.
        for (var i = 0; i < 4; i++) {
          final f = File('${tmpDir.path}${Platform.pathSeparator}old_$i.img');
          f.writeAsBytesSync(Uint8List(100), flush: true);
          f.setLastModifiedSync(
            DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
          );
        }

        // Simulate cold start with cap = 220 bytes and a single disk cache lookup.
        PosterLoader.resetDiskCacheConfigForTest();
        PosterLoader.debugDiskDirOverride = tmpDir;
        PosterLoader.debugDiskMaxBytesOverride = 220;

        // Even a single load (well under 24 writes!) triggers startup prune.
        await PosterLoader.load('http://127.0.0.1:${server.port}/startup_cap.png');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final remainingBytes = tmpDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.img'))
            .fold<int>(0, (sum, f) => sum + f.lengthSync());
        expect(remainingBytes, lessThanOrEqualTo(220));
      });
    });
  });

  // =========================================================================
  // P2-15: 375pt landscape & 320pt narrow iPad Split View 4-item tap & dismiss
  // =========================================================================
  group('P2-15: 375pt landscape and 320pt iPad Split View 4-item tap & dismiss', () {
    for (final viewport in const <({String name, Size size, Rect anchor})>[
      (
        name: '375pt tall landscape',
        size: Size(667, 375),
        anchor: Rect.fromLTWH(590, 315, 44, 44),
      ),
      (
        name: '320pt narrow iPad Split View',
        size: Size(320, 768),
        anchor: Rect.fromLTWH(264, 700, 44, 44),
      ),
    ]) {
      testWidgets('${viewport.name} renders all 4 options tappable and dismisses cleanly', (tester) async {
        tester.view.physicalSize = viewport.size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        String? tappedId;
        Future<void> openPopover(BuildContext ctx) {
          return showIosGlassPopover<void>(
            context: ctx,
            anchorRect: viewport.anchor,
            title: '播放选项',
            maxWidth: 304,
            maxHeight: 488,
            forceDark: true,
            builder: (popCtx) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final i in const [1, 2, 3, 4])
                  CupertinoButton(
                    key: ValueKey('opt-$i'),
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 12,
                    ),
                    onPressed: () {
                      tappedId = 'opt-$i';
                      Navigator.of(popCtx).pop();
                    },
                    child: Text('选项 $i'),
                  ),
              ],
            ),
          );
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: CupertinoButton(
                    key: const ValueKey('open-popover-btn'),
                    onPressed: () => unawaited(openPopover(ctx)),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        );

        // Open and verify all 4 items are visible and inside the viewport, tap item 4!
        await tester.tap(find.byKey(const ValueKey('open-popover-btn')));
        await tester.pumpAndSettle();

        for (final i in const [1, 2, 3, 4]) {
          final finder = find.byKey(ValueKey('opt-$i'));
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          expect(rect.top, greaterThanOrEqualTo(0.0));
          expect(rect.bottom, lessThanOrEqualTo(viewport.size.height));
          expect(rect.left, greaterThanOrEqualTo(0.0));
          expect(rect.right, lessThanOrEqualTo(viewport.size.width));
        }
        await tester.tap(find.byKey(const ValueKey('opt-4')));
        await tester.pumpAndSettle();
        expect(tappedId, 'opt-4');
        expect(find.byKey(const ValueKey('opt-4')), findsNothing);

        // Reopen and verify tapping outside / barrier dismisses cleanly.
        await tester.tap(find.byKey(const ValueKey('open-popover-btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('opt-1')), findsOneWidget);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('opt-1')), findsNothing);
      });
    }
  });

  // =========================================================================
  // P2-16: Offline model picker preserves offline notice & "待验证" badges
  // =========================================================================
  group('P2-16: Offline model picker preserves notice and marks fallback models 待验证', () {
    testWidgets(
      'complete offline state never displays 已获取 N 个可用模型 and marks built-in models 待验证',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
      SharedPreferences.setMockInitialValues({});
      final offlineClient = MockClient((req) async {
        throw const SocketException('Network unreachable');
      });
      final secStore = InMemorySecureCredentialStore();
      AiService.instance.configureForTest(
        httpClient: offlineClient,
        secureStorage: secStore,
        labUnlockedForTest: true,
        experimentalOAuthForTest: true,
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
          accessToken: 'tok-offline',
          refreshToken: 'ref-offline',
          accountId: 'acct-offline',
          expiresAtEpochMs: 2000000000000,
        ),
      );

      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: IosAiSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll to and tap the model fetch / refresh button.
      final fetchBtn = find.byKey(const ValueKey('ios-ai-fetch-models-btn'));
      await tester.ensureVisible(fetchBtn);
      await tester.pumpAndSettle();
      await tester.tap(fetchBtn);
      await tester.pumpAndSettle();

      expect(find.textContaining('当前离线或接口不可达，以下为内置目录（待验证）'), findsOneWidget);
      expect(find.textContaining('已获取'), findsNothing);
      expect(find.text('待验证'), findsWidgets);
    });
  });
}

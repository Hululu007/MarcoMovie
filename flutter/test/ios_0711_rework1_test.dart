// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
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
import 'package:fvp/mdk.dart' as mdk;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_features.dart';
import 'package:marco_movie/core/ai_lab_gate.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/config_center_bridge.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/episode_scraper.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/mdk_platform_player.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_ai_lab_sheets.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_glass_popover.dart';
import 'package:marco_movie/ui/ios_launch_splash.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/official_channel_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
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
    String tag = 'rework1',
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

class _ExtendedFakeMdkBackend
    implements MdkNativeBackend, MdkExtendedNativeBackend {
  final ValueNotifier<int?> _tex = ValueNotifier<int?>(null);
  final StreamController<({int oldStatus, int newStatus})> _statusCtl =
      StreamController<({int oldStatus, int newStatus})>.broadcast();
  final StreamController<mdk.PlaybackState> _stateCtl =
      StreamController<mdk.PlaybackState>.broadcast();
  final StreamController<({int error, String category, String detail})>
      _eventCtl = StreamController<
          ({int error, String category, String detail})>.broadcast();
  final StreamController<({double startSec, double endSec, List<String> lines})>
      _subtitleCtl = StreamController<
          ({double startSec, double endSec, List<String> lines})>.broadcast();

  Completer<int>? _pendingTexture;
  int cancelTextureCalls = 0;
  int disposeCalls = 0;
  int prepareCalls = 0;
  int positionMsValue = 0;
  MdkMediaSnapshot snapshot = const MdkMediaSnapshot(
    durationMs: 120000,
    videoWidth: 1920,
    videoHeight: 1080,
  );

  @override
  ValueListenable<int?> get textureIdListenable => _tex;
  @override
  Stream<({int oldStatus, int newStatus})> get onStatusChanged =>
      _statusCtl.stream;
  @override
  Stream<mdk.PlaybackState> get onStateChanged => _stateCtl.stream;
  @override
  Stream<({int error, String category, String detail})> get onEvent =>
      _eventCtl.stream;
  @override
  Stream<({double startSec, double endSec, List<String> lines})>
      get onSubtitleText => _subtitleCtl.stream;

  void emitSubtitle(double startSec, double endSec, List<String> lines) {
    _subtitleCtl.add((startSec: startSec, endSec: endSec, lines: lines));
  }

  @override
  int get positionMs => positionMsValue;
  @override
  int get bufferedMs => 5000;
  @override
  bool get isLive => false;
  @override
  MdkMediaSnapshot readMediaSnapshot() => snapshot;

  @override
  set media(String uri) {}
  @override
  set state(mdk.PlaybackState value) {}
  @override
  set playbackRate(double value) {}
  @override
  set volume(double value) {}
  @override
  set mute(bool value) {}
  @override
  set loop(int value) {}
  @override
  set videoDecoders(List<String> decoders) {}
  @override
  set activeAudioTracks(List<int> tracks) {}
  @override
  set activeSubtitleTracks(List<int> tracks) {}
  @override
  set activeVideoTracks(List<int> tracks) {}
  @override
  void setProperty(String key, String value) {}
  @override
  void setBufferRange({int min = -1, int max = -1, bool drop = false}) {}
  @override
  void setMediaForType(String uri, mdk.MediaType type) {}

  @override
  Future<int> prepare({int position = 0}) async {
    prepareCalls++;
    return 0;
  }

  @override
  Future<int> seek({required int position, required mdk.SeekFlag flags}) async {
    positionMsValue = position;
    return 0;
  }

  @override
  Future<int> updateTexture({int? width, int? height}) {
    _pendingTexture = Completer<int>();
    return _pendingTexture!.future;
  }

  @override
  void cancelPendingTextureWait() {
    cancelTextureCalls++;
    final pending = _pendingTexture;
    _pendingTexture = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(-1);
    }
  }

  @override
  Future<void> disposeAsync() async {
    disposeCalls++;
    cancelPendingTextureWait();
    await _statusCtl.close();
    await _stateCtl.close();
    await _eventCtl.close();
    await _subtitleCtl.close();
    _tex.dispose();
  }
}

class _FakePlayer extends Fake implements Player {
  final _FakePlayerStream _stream = _FakePlayerStream();
  PlayerState _state = const PlayerState();
  bool disposed = false;

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
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    _state = _state.copyWith(track: _state.track.copyWith(subtitle: track));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _stream.dispose();
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

  Future<void> dispose() async {
    await playlistCtl.close();
    await playingCtl.close();
    await completedCtl.close();
    await positionCtl.close();
    await durationCtl.close();
    await bufferCtl.close();
    await bufferingCtl.close();
    await rateCtl.close();
    await volumeCtl.close();
    await widthCtl.close();
    await heightCtl.close();
    await tracksCtl.close();
    await trackCtl.close();
    await errorCtl.close();
    await subtitleCtl.close();
    await audioParamsCtl.close();
    await videoParamsCtl.close();
    await logCtl.close();
  }
}

/// Minimal valid 1x1 PNG bytes for disk/private poster tests.
final Uint8List _validPngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiService.instance.configureForTest(
      secureStorage: InMemorySecureCredentialStore(),
      resetState: true,
    );
    AiLabGate.debugPublicKeyHexOverride = null;
    CuratedDiscoveryService.resetCacheForTest();
    PosterLoader.resetDiskCacheConfigForTest();
    PosterLoader.clearPrivateCache();
    IosLiquidGlassBridge.setAvailableForTest(false);
    IosLaunchCurtainHost.resetCurtainStateForTest(completed: true);
    OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = false;
  });

  tearDown(() {
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiLabGate.debugPublicKeyHexOverride = null;
    CuratedDiscoveryService.resetCacheForTest();
    PosterLoader.resetDiskCacheConfigForTest();
    PosterLoader.clearPrivateCache();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLaunchCurtainHost.resetCurtainStateForTest(completed: true);
    OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = false;
  });

  group('P0-1: Privacy Space Isolation & AI Passcode / exp_oauth Outbound Gate', () {
    testWidgets(
      'Private session, post-open passcode expiry, and residual OAuth on non-exp_oauth token emit ZERO outbound HTTP requests',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final seed = _TestEd25519Signer.randomSeed();
        final pubHex = _TestEd25519Signer.publicKeyHex(seed);
        var now = DateTime.utc(2026, 11, 27, 12, 0, 0);
        var outboundRequests = 0;

        final store = AiLabPasscodeStore();
        store.configureForTest(
          clock: () => now,
          publicKeyHexOverride: pubHex,
          targetPlatform: 'ios',
          resetState: true,
        );
        final mockHttp = MockClient((req) async {
          outboundRequests++;
          return http.Response('{}', 200);
        });
        final secure = InMemorySecureCredentialStore();
        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        ai.configureForTest(
          passcodeStore: store,
          clock: () => now,
          labUnlockedForTest: null,
          resetState: true,
        );

        // Unlock with regular passcode (`exp_oauth: false`), expiring in 60s
        final regularToken = _TestEd25519Signer.issueToken(
          seed,
          expEpochSec: (now.millisecondsSinceEpoch ~/ 1000) + 60,
          plat: 'ios',
          expOAuth: false,
        );
        await store.unlockWithPasscode(regularToken, nowOverride: now);
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            baseUrl: 'https://api.example/v1',
            model: 'gpt-4o-mini',
          ),
        );
        await ai.setApiKey('sk-test-regular');
        // Plant an expiring residual OAuth session that would trigger token refresh if unguarded
        await ai.setOAuthSession(
          AiOAuthSession(
            accessToken: 'expired_access_tok',
            refreshToken: 'residual_rt_tok',
            expiresAtEpochMs: now.millisecondsSinceEpoch - 1000,
            accountId: 'acct_residual',
            planType: 'plus',
          ),
        );

        // Case A: Regular passcode (`exp_oauth: false`) + residual OAuth -> 0 requests across ALL OAuth paths
        expect(ai.isLabUnlocked, isTrue);
        expect(ai.isExperimentalOAuthAllowed, isFalse);
        await expectLater(
          ai.ensureFreshOAuthSession(),
          throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.unauthorized)),
        );
        expect(await ai.refreshSubscriptionQuota(), isNull);
        await expectLater(
          ai.fetchAvailableModelOptions(
            configOverride: ai.config.copyWith(authMode: AiAuthMode.codexOAuth),
          ),
          throwsA(isA<AiServiceException>()),
        );
        await expectLater(
          ai.complete(
            feature: 'ping',
            systemPrompt: 'sys',
            userPrompt: 'hi',
            configOverride: ai.config.copyWith(authMode: AiAuthMode.codexOAuth),
          ),
          throwsA(isA<AiServiceException>()),
        );
        expect(outboundRequests, 0);

        // Case B: Privacy session active -> settings/usage pages & ALL service paths emit 0 requests
        ai.setPrivacySessionActive(true);
        expect(ai.isLabUnlocked, isFalse);
        await tester.pumpWidget(
          MaterialApp(
            home: IosAiSettingsPage(service: ai),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          MaterialApp(
            home: IosAiUsageDetailPage(service: ai),
          ),
        );
        await tester.pumpAndSettle();
        expect(await ai.refreshApiBalance(force: true), isNull);
        expect(await ai.refreshSubscriptionQuota(), isNull);
        await expectLater(
          ai.fetchAvailableModelOptions(),
          throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.privacySpaceBlocked)),
        );
        await expectLater(
          ai.complete(feature: 'ping', systemPrompt: 's', userPrompt: 'u'),
          throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.privacySpaceBlocked)),
        );
        expect(outboundRequests, 0);

        // Case C: Exit privacy, then advance clock past passcode expiry AFTER page opened -> 0 requests
        ai.setPrivacySessionActive(false);
        now = now.add(const Duration(seconds: 120));
        expect(ai.isLabUnlocked, isFalse);
        expect(await ai.refreshApiBalance(force: true), isNull);
        expect(await ai.refreshSubscriptionQuota(), isNull);
        await expectLater(
          ai.fetchAvailableModels(),
          throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.disabled)),
        );
        await expectLater(
          ai.complete(feature: 'ping', systemPrompt: 's', userPrompt: 'u'),
          throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.disabled)),
        );
        expect(outboundRequests, 0);
      },
    );
  });

  group('P0-2: Offline Download & Playback Private Identity Closed-Loop', () {
    test('DownloadService.enqueue rejects private flag and private group sites', () async {
      final privFlagSite = const CmsSite(
        key: 'priv_flag',
        name: '私密源',
        type: 1,
        api: 'https://priv.example/api',
        isPrivate: true,
      );
      final privGroupSite = const CmsSite(
        key: 'priv_grp',
        name: '分组源',
        type: 1,
        api: 'https://grp.example/api',
        group: '隐私空间',
      );
      const video = CmsVideo(id: 'v1', title: '私密影片');
      const ep = CmsEpisode(name: '正片', url: 'https://cdn.example/v1.mp4');
      const line = CmsLine(name: '默认', episodes: [ep]);

      expect(
        DownloadService.instance.enqueue(
          site: privFlagSite,
          video: video,
          line: line,
          episodeIndexes: const [0],
        ),
        0,
      );
      expect(
        DownloadService.instance.enqueue(
          site: privGroupSite,
          video: video,
          line: line,
          episodeIndexes: const [0],
        ),
        0,
      );
    });

    test('AdaptiveShell.resolveOfflinePlaybackSite preserves private flag/group and fails closed for legacy tasks', () {
      final taskWithPrivFlag = DownloadTask(
        id: 't1',
        siteKey: 's_priv',
        siteName: 'S1',
        siteApi: '',
        siteType: 1,
        videoId: 'v1',
        title: 'Secret A',
        poster: '',
        lineName: 'L1',
        episodeName: 'EP1',
        episodeIndex: 0,
        sourceUrl: 'https://x/a.mp4',
        headers: const {},
        createdAt: 1000,
        filePath: '/tmp/a.mp4',
        sourceSite: const CmsSite(
          key: 's_priv',
          name: 'S1',
          type: 1,
          api: '',
          isPrivate: true,
        ),
      );
      final resolvedFlag = AdaptiveShell.resolveOfflinePlaybackSite(taskWithPrivFlag);
      expect(resolvedFlag.isEffectivelyPrivate, isTrue);

      final taskWithPrivGroup = DownloadTask(
        id: 't2',
        siteKey: 's_grp',
        siteName: 'S2',
        siteApi: '',
        siteType: 1,
        videoId: 'v2',
        title: 'Secret B',
        poster: '',
        lineName: 'L1',
        episodeName: 'EP1',
        episodeIndex: 0,
        sourceUrl: 'https://x/b.mp4',
        headers: const {},
        createdAt: 1001,
        filePath: '/tmp/b.mp4',
        sourceSite: const CmsSite(
          key: 's_grp',
          name: 'S2',
          type: 1,
          api: '',
          group: '私密分组',
        ),
      );
      final resolvedGrp = AdaptiveShell.resolveOfflinePlaybackSite(taskWithPrivGroup);
      expect(resolvedGrp.isEffectivelyPrivate, isTrue);

      // Legacy task with sourceSite == null and no confirmed public match fails closed (private = true)!
      final legacyTask = DownloadTask(
        id: 't3',
        siteKey: 'unknown_old_site',
        siteName: 'Old',
        siteApi: '',
        siteType: 1,
        videoId: 'v3',
        title: 'Legacy',
        poster: '',
        lineName: 'L1',
        episodeName: 'EP1',
        episodeIndex: 0,
        sourceUrl: 'https://x/c.mp4',
        headers: const {},
        createdAt: 1002,
        filePath: '/tmp/c.mp4',
      );
      final resolvedLegacy = AdaptiveShell.resolveOfflinePlaybackSite(legacyTask);
      expect(resolvedLegacy.isEffectivelyPrivate, isTrue);

      // Public task matching confirmed public site in config resolves public
      final pubSite = const CmsSite(
        key: 'pub_site',
        name: 'Public',
        type: 1,
        api: 'https://pub.example',
      );
      final pubTask = DownloadTask(
        id: 't4',
        siteKey: 'pub_site',
        siteName: 'Public',
        siteApi: 'https://pub.example',
        siteType: 1,
        videoId: 'v4',
        title: 'Public Movie',
        poster: '',
        lineName: 'L1',
        episodeName: 'EP1',
        episodeIndex: 0,
        sourceUrl: 'https://x/d.mp4',
        headers: const {},
        createdAt: 1003,
        filePath: '/tmp/d.mp4',
        sourceSite: pubSite,
      );
      final resolvedPub = AdaptiveShell.resolveOfflinePlaybackSite(
        pubTask,
        currentConfig: CmsConfig(sites: [pubSite]),
      );
      expect(resolvedPub.isEffectivelyPrivate, isFalse);
    });
  });

  group('P1-3 & P1-4: MDK Cancellable First-Frame Texture & Cross-Kernel Subtitles', () {
    test('MdkPlatformPlayer unblocks pre-first-frame open on cancelPendingOpen, forwards subtitles, and disposes cleanly', () async {
      final backend = _ExtendedFakeMdkBackend();
      backend.snapshot = MdkMediaSnapshot(
        durationMs: 120000,
        videoWidth: 1920,
        videoHeight: 1080,
        subtitleTracks: [
          SubtitleTrack.auto(),
          SubtitleTrack.no(),
          const SubtitleTrack('0', 'English', 'en', codec: 'subrip'),
          const SubtitleTrack('1', 'Blu-ray PGS', 'zh', codec: 'hdmv_pgs_subtitle'),
        ],
      );
      final player = MdkPlatformPlayer(debugBackend: backend);

      // Start open -> stalls inside updateTexture() waiting for first frame
      final open1 = player.open(Media('https://cdn.example/ep1.mkv?token=aaa'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Cancel pre-first-frame (simulating episode switch or exit before first frame)
      player.cancelPendingOpen();
      await open1.timeout(const Duration(milliseconds: 500));
      expect(backend.cancelTextureCalls, greaterThanOrEqualTo(1));

      // Reopen episode 2, emit subtitle cue, then advance past cue end -> auto clears!
      final open2 = player.open(Media('https://cdn.example/ep2.mkv?token=bbb'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      backend.cancelPendingTextureWait();
      await open2.timeout(const Duration(milliseconds: 500));

      final emittedSubs = <List<String>>[];
      final sub = player.stream.subtitle.listen(emittedSubs.add);
      backend.emitSubtitle(1.0, 3.0, const ['Hello world']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emittedSubs.last, const ['Hello world']);

      // Seek clears stale cue
      await player.seek(const Duration(seconds: 10));
      expect(emittedSubs.last, isEmpty);

      // Bitmap subtitle detection
      expect(MdkPlatformPlayer.isBitmapSubtitleCodec('hdmv_pgs_subtitle'), isTrue);
      expect(MdkPlatformPlayer.isBitmapSubtitleCodec('dvd_subtitle'), isTrue);
      expect(MdkPlatformPlayer.isBitmapSubtitleCodec('subrip'), isFalse);

      await sub.cancel();
      await player.dispose();
      expect(backend.disposeCalls, 1);
    });

    test('IosAvPlayerController forwards native subtitleCue and subtitleTracksChanged events', () async {
      const methodCh = MethodChannel('marco_test/av_sub_m');
      const eventCh = EventChannel('marco_test/av_sub_e');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodCh, (call) async {
        if (call.method == 'open') return true;
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        eventCh,
        MockStreamHandler.inline(
          onListen: (args, events) {
            events.success(<String, Object>{
              'type': 'ready',
              'mediaId': 1,
              'eventSeq': 1,
              'durationMs': 60000,
              'positionMs': 0,
              'subtitleTracks': [
                {'id': '0', 'title': 'English', 'language': 'en', 'selected': true},
              ],
            });
            events.success(<String, Object>{
              'type': 'subtitleCue',
              'mediaId': 1,
              'eventSeq': 2,
              'lines': ['Good morning, Neo.'],
              'hasNativeSamples': false,
            });
            events.success(<String, Object>{
              'type': 'subtitleCue',
              'mediaId': 1,
              'eventSeq': 3,
              'lines': <String>[],
              'hasNativeSamples': true,
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
      final cues = <({List<String> lines, bool hasNativeSamples})>[];
      final sub = ctrl.onSubtitleCueChanged.listen(cues.add);
      await ctrl.open('https://cdn.example/movie.m3u8');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(ctrl.subtitleTracks.length, 1);
      expect(cues.any((c) => c.lines.contains('Good morning, Neo.')), isTrue);
      expect(ctrl.currentSubtitleHasNonTextSamples, isTrue);

      await sub.cancel();
      ctrl.dispose();
    });
  });

  group('P1-5: Full-Length Subtitles (#121 & Final Cue Preserved)', () {
    test('translateSubtitleCues preserves full 150-cue timeline including #121 and final cue, and supports continuation', () async {
      final mockHttp = MockClient((req) async {
        final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
        final msgs = body['messages'] as List;
        final userPrompt = msgs.last['content'] as String;
        final jsonStart = userPrompt.indexOf('[');
        final inputList = jsonDecode(userPrompt.substring(jsonStart)) as List;
        final items = [
          for (final item in inputList)
            {'i': item['i'], 'zh': '译:${item['t']}'},
        ];
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({'glossary': {'Neo': '尼奥'}, 'items': items}),
                },
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 10},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(
        httpClient: mockHttp,
        secureStorage: InMemorySecureCredentialStore(),
      );
      ai.configureForTest(labUnlockedForTest: true, resetState: true);
      await ai.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://api.example/v1',
          model: 'gpt-4o-mini',
          subtitleTranslateEnabled: true,
        ),
      );
      await ai.setApiKey('sk-sub-test');

      final fullCues = List<AiSubtitleCue>.generate(
        150,
        (i) => AiSubtitleCue(
          index: i + 1,
          start: Duration(seconds: i * 5),
          end: Duration(seconds: i * 5 + 3),
          text: 'Line ${i + 1}',
        ),
      );

      final lab = AiLabService(ai);
      final batch1 = await lab.translateSubtitleCues(
        seriesTitle: 'Matrix',
        cues: fullCues,
        maxCues: 120,
      );
      // Full timeline preserved (150 cues, NOT truncated to 120!)
      expect(batch1.cues.length, 150);
      expect(batch1.totalCount, 150);
      expect(batch1.translatedCount, 120);
      expect(batch1.hasUntranslatedRemainder, isTrue);
      expect(batch1.cues[0].translatedText, '译:Line 1');
      // Cue #121 (index 120) and final cue #150 (index 149) keep original text & timestamps!
      expect(batch1.cues[120].text, 'Line 121');
      expect(batch1.cues[120].translatedText, isEmpty);
      expect(batch1.cues[149].text, 'Line 150');
      expect(batch1.cues[149].start, const Duration(seconds: 149 * 5));

      // Continue remaining cues from startIndex: 120
      final batch2 = await lab.translateSubtitleCues(
        seriesTitle: 'Matrix',
        cues: batch1.cues,
        existingGlossary: batch1.glossary,
        startIndex: 120,
        maxCues: 120,
      );
      expect(batch2.cues.length, 150);
      expect(batch2.translatedCount, 150);
      expect(batch2.hasUntranslatedRemainder, isFalse);
      expect(batch2.cues[120].translatedText, '译:Line 121');
      expect(batch2.cues[149].translatedText, '译:Line 150');
    });
  });

  group('P1-6: Custom Toolbar Dual PiP Anchors (Zero Duplicate GlobalKey)', () {
    testWidgets(
      'Adding pip to bottom dock alongside top-right pip renders cleanly without Duplicate GlobalKey and both buttons are tappable',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var pipTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: IosPlayerChrome(
                title: '测试影片',
                episodeName: '第 1 集',
                lineName: '线路 1',
                isLive: false,
                playing: true,
                loading: false,
                buffering: false,
                hasError: false,
                position: const Duration(seconds: 10),
                duration: const Duration(minutes: 10),
                isScrubbing: false,
                scrubPositionMs: 10000,
                playbackSpeed: 1.0,
                skipIntroSec: 0,
                skipOutroSec: 0,
                specBadges: const [],
                fallbackSpecsLabel: '',
                specBadgesExpanded: false,
                isLandscape: true,
                danmuEnabled: false,
                sleepTimerActive: false,
                hasMultipleLines: true,
                isFavorite: false,
                isCasting: false,
                isDownloading: false,
                storageReduceTransparency: false,
                isPipSupported: true,
                onPipTap: () => pipTaps++,
                toolbarItems: const ['episodes', 'pip', 'more'],
                onBack: () {},
                onPlayPause: () {},
                onRewind15: () {},
                onForward15: () {},
                onScrubStart: (_) {},
                onScrubUpdate: (_) {},
                onScrubEnd: (_) {},
                onScrubCancel: () {},
                onEpisodesTap: () {},
                onLinesTap: () {},
                onSpeedTap: () {},
                onDanmuToggle: () {},
                onDanmuSettingsTap: () {},
                onAspectAndStrategyTap: () {},
                onAudioSubtitleTap: () {},
                onMoreTap: () {},
                onLockTap: () {},
                onFullscreenToggle: () {},
                onInteraction: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('ios-player-pip-button')), findsOneWidget);
        expect(find.byKey(const Key('ios-player-dock-pip-button')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ios-player-pip-button')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('ios-player-dock-pip-button')));
        await tester.pump();
        expect(pipTaps, 2);
      },
    );
  });

  group('P1-7: Bidirectional Movie Detection & Bare Year Rejection', () {
    test('Rejects bare years, documentaries, mini-series, sequels, and split parts; accepts true multi-version movies', () {
      // Bare years must NOT be treated as episode markers or numbers
      expect(EpisodeScraper.hasExplicitEpisodicMarker('2024.mkv'), isFalse);
      expect(EpisodeScraper.hasExplicitEpisodicMarker('1999.mp4'), isFalse);
      expect(EpisodeScraper.parseEpisode('2024.mkv', rawIndex: 0).parsedEpisodeNumber, isNull);
      expect(EpisodeScraper.hasExplicitEpisodicMarker('01.mkv'), isTrue);

      // Unnumbered documentary `森林` / `海洋` -> NOT multi-version movie!
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '森林', url: 'https://x/1.mp4'),
            CmsEpisode(name: '海洋', url: 'https://x/2.mp4'),
          ],
          videoTitle: '地球脉动',
          videoTag: '纪录片',
        ),
        isFalse,
      );

      // Unnumbered mini-series with quality tags on distinct episode titles -> NOT movie!
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '圣朱尼佩罗 1080P.mkv', url: 'https://x/1.mkv'),
            CmsEpisode(name: '急转直下 1080P.mkv', url: 'https://x/2.mkv'),
          ],
          videoTitle: '黑镜',
        ),
        isFalse,
      );

      // Sequel pack (distinct years or sequel numbers) -> NOT single multi-version movie!
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '沙丘 2021 4K.mkv', url: 'https://x/1.mkv'),
            CmsEpisode(name: '沙丘2 2024 4K.mkv', url: 'https://x/2.mkv'),
          ],
          videoTitle: '沙丘',
          videoTag: '电影',
        ),
        isFalse,
      );
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '教父1 1080P.mkv', url: 'https://x/1.mkv'),
            CmsEpisode(name: '教父2 1080P.mkv', url: 'https://x/2.mkv'),
          ],
          videoTitle: '教父',
          videoTag: '电影',
        ),
        isFalse,
      );

      // Split parts 上/下 -> NOT single version (must keep auto-next!)
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '赤壁 上 1080P.mkv', url: 'https://x/1.mkv'),
            CmsEpisode(name: '赤壁 下 1080P.mkv', url: 'https://x/2.mkv'),
          ],
          videoTitle: '赤壁',
          videoTag: '电影',
        ),
        isFalse,
      );

      // True multi-audio / multi-quality / extras of one movie -> TRUE!
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '国语中字', url: 'https://x/1.m3u8'),
            CmsEpisode(name: '粤语中字', url: 'https://x/2.m3u8'),
          ],
          videoTitle: '无间道',
        ),
        isTrue,
      );
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '沙丘2.2024.4K.DV.mkv', url: 'https://x/1.mkv'),
            CmsEpisode(name: '沙丘2.2024.1080P.mp4', url: 'https://x/2.mp4'),
          ],
          videoTitle: '沙丘2',
        ),
        isTrue,
      );
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '2024.mkv', url: 'https://x/1.mkv'),
            CmsEpisode(name: '4K杜比.mkv', url: 'https://x/2.mkv'),
          ],
          videoTitle: '沙丘2',
        ),
        isTrue,
      );

      // Manual calibration override ALWAYS wins -> returns false!
      expect(
        EpisodeScraper.isLikelyMultiVersionMovie(
          const [
            CmsEpisode(name: '国语中字', url: 'https://x/1.m3u8'),
            CmsEpisode(name: '粤语中字', url: 'https://x/2.m3u8'),
          ],
          videoTitle: '无间道',
          override: const EpisodeScrapeOverride(enabled: true, episodeOffset: 1),
        ),
        isFalse,
      );
    });
  });

  group('P1-8: Watch-Brief Feature Toggle Enforcement', () {
    testWidgets('Turning off spoilerFreeRecapEnabled blocks business methods and hides Detail AI hub entries with 0 requests', (tester) async {
      var httpCalls = 0;
      final ai = AiService(
        httpClient: MockClient((_) async {
          httpCalls++;
          return http.Response('{}', 200);
        }),
        secureStorage: InMemorySecureCredentialStore(),
      );
      ai.configureForTest(labUnlockedForTest: true, resetState: true);
      await ai.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://api.example/v1',
          model: 'gpt-4o-mini',
          spoilerFreeRecapEnabled: false,
        ),
      );
      await ai.setApiKey('sk-toggle');
      final lab = AiLabService(ai);

      await expectLater(
        lab.generateWatchBrief(title: '星际穿越'),
        throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.disabled)),
      );
      await expectLater(
        lab.checkPostCreditsGuide(title: '星际穿越'),
        throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.disabled)),
      );
      await expectLater(
        lab.askAboutWork(title: '星际穿越', question: '黑洞原理？'),
        throwsA(isA<AiServiceException>().having((e) => e.code, 'code', AiErrorCode.disabled)),
      );
      expect(httpCalls, 0);

      // Also verify Detail AI Lab sheet hides all 3 tiles when global config disables spoilerFreeRecapEnabled
      AiService.instance.configureForTest(
        secureStorage: InMemorySecureCredentialStore(),
        labUnlockedForTest: true,
        resetState: true,
      );
      await AiService.instance.saveConfig(
        const AiConfig(
          enabled: true,
          spoilerFreeRecapEnabled: false,
          customSkills: <AiCustomSkill>[],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => CupertinoButton(
                onPressed: () {
                  showIosDetailAiLabSheet(
                    ctx,
                    title: '星际穿越',
                    year: '2014',
                    overview: '...',
                    currentEpisodeNumber: 1,
                    currentLineEpisodes: const [CmsEpisode(name: '正片', url: 'https://x/1.mp4')],
                    isMultiVersionMovie: true,
                    onApplyEpisodeOverride: (_, __) async {},
                  );
                },
                child: const Text('OPEN_HUB'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN_HUB'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('零剧透看点与设定背景科普'), findsNothing);
      expect(find.text('片尾彩蛋与版本差异提示'), findsNothing);
      expect(find.text('自由观影问答（防剧透）'), findsNothing);
      expect(httpCalls, 0);
    });
  });

  group('P1-9, P1-10 & P2-15: Balance Cap Honesty, Case-Sensitive Path, Account Isolation, Rolling Usage >200 & 429 Backoff', () {
    test('billing_subscription without usage shows cap (not remaining 100), preserves path case, isolates keys & OAuth accounts', () async {
      expect(
        AiService.normalizeApiBalanceEndpointKey('https://API.Example/TenantA/v1/'),
        isNot(AiService.normalizeApiBalanceEndpointKey('https://api.example/tenanta/v1/')),
      );

      final requests = <Uri>[];
      final mockHttp = MockClient((req) async {
        requests.add(req.url);
        if (req.url.path.endsWith('/dashboard/billing/subscription')) {
          return http.Response(
            jsonEncode({'hard_limit_usd': 100.0}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (req.url.path.endsWith('/dashboard/billing/usage')) {
          return http.Response('{"error":"forbidden"}', 500);
        }
        return http.Response('not found', 404);
      });

      final ai = AiService(
        httpClient: mockHttp,
        secureStorage: InMemorySecureCredentialStore(),
      );
      ai.configureForTest(labUnlockedForTest: true, resetState: true);
      await ai.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://proxy.example/TenantA/v1',
          model: 'gpt-4o-mini',
        ),
      );
      await ai.setApiKey('sk-account-A');

      final snap = await ai.refreshApiBalance(force: true);
      expect(snap, isNotNull);
      expect(snap!.remaining, isNull);
      expect(snap.totalGranted, 100.0);
      expect(snap.headlineTextZh, contains('额度上限'));
      expect(snap.headlineTextZh, isNot(contains('剩余')));

      // Swapping API key on the SAME endpoint immediately invalidates old cached balance
      await ai.setApiKey('sk-account-B');
      expect(ai.apiBalance, isNull);

      // OAuth switch account + offline -> NEVER displays Account A's cached quota!
      await ai.setOAuthSession(
        const AiOAuthSession(
          accessToken: 'tok_A',
          refreshToken: 'rt_A',
          expiresAtEpochMs: 9999999999999,
          accountId: 'acct_A',
          planType: 'plus',
        ),
      );
      await ai.setOAuthSession(
        const AiOAuthSession(
          accessToken: 'tok_B',
          refreshToken: 'rt_B',
          expiresAtEpochMs: 9999999999999,
          accountId: 'acct_B',
          planType: 'pro',
        ),
      );
      expect(ai.subscriptionQuota, isNull);
    });

    test('Rolling usage tracks 205 calls beyond 200-item display cap and expires strictly at 5h/7d boundaries', () async {
      var now = DateTime.utc(2026, 11, 20, 10, 0, 0);
      final mockHttp = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'content': 'ok'}},
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(
        httpClient: mockHttp,
        secureStorage: InMemorySecureCredentialStore(),
      );
      ai.configureForTest(
        clock: () => now,
        labUnlockedForTest: true,
        resetState: true,
      );
      await ai.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://api.example/v1',
          model: 'gpt-4o-mini',
        ),
      );
      await ai.setApiKey('sk-rolling');

      for (var i = 0; i < 205; i++) {
        await ai.complete(
          feature: 'ping',
          systemPrompt: 's',
          userPrompt: 'msg_$i',
          useCache: false,
        );
      }

      // Display history is capped at 200, rolling ledger accurately holds all 205!
      expect(ai.usageHistory.length, AiService.maxUsageHistoryEntries);
      final w5h = ai.rollingWindowUsage(const Duration(hours: 5));
      expect(w5h.requests, 205);
      expect(w5h.totalTokens, 205 * 15);

      // Advance 5h + 1m -> 5h window = 0, 7d window still = 205!
      now = now.add(const Duration(hours: 5, minutes: 1));
      expect(ai.rollingWindowUsage(const Duration(hours: 5)).requests, 0);
      expect(ai.rollingWindowUsage(const Duration(days: 7)).requests, 205);

      // Advance past 7d -> 7d window = 0!
      now = now.add(const Duration(days: 7));
      expect(ai.rollingWindowUsage(const Duration(days: 7)).requests, 0);
    });

    test('HTTP 429 with Retry-After stops probing immediately (1 request instead of 6) and respects backoff; 401 refresh merges Codex models with fallback badge', () async {
      var now = DateTime.utc(2026, 11, 27, 12, 0, 0);
      var balanceProbeHits = 0;
      var modelAttempts = 0;
      final mockHttp = MockClient((req) async {
        if (req.url.path.contains('/billing/') || req.url.path.contains('/credits')) {
          balanceProbeHits++;
          return http.Response(
            'rate limited',
            429,
            headers: {'retry-after': '60'},
          );
        }
        if (req.url.path.endsWith('/oauth/token')) {
          return http.Response(
            jsonEncode({
              'access_token': 'refreshed_tok',
              'refresh_token': 'rt_2',
              'expires_in': 3600,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (req.url.path.endsWith('/models')) {
          modelAttempts++;
          if (modelAttempts == 1) {
            return http.Response('unauthorized', 401);
          }
          return http.Response(
            jsonEncode({
              'models': [
                {'slug': 'gpt-5.4-live', 'display_name': 'GPT-5.4 Live'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });

      final ai = AiService(
        httpClient: mockHttp,
        secureStorage: InMemorySecureCredentialStore(),
      );
      ai.configureForTest(
        clock: () => now,
        codexTokenEndpoint: 'https://auth.example/oauth/token',
        codexModelsEndpoint: 'https://chatgpt.example/backend-api/codex/models',
        labUnlockedForTest: true,
        experimentalOAuthForTest: true,
        resetState: true,
      );
      await ai.saveConfig(
        const AiConfig(
          enabled: true,
          authMode: AiAuthMode.apiKey,
          baseUrl: 'https://relay.example/v1',
          model: 'gpt-4o-mini',
        ),
      );
      await ai.setApiKey('sk-429-test');

      // Concurrent probes coalesce & stop on first 429!
      await Future.wait([
        ai.refreshApiBalance(),
        ai.refreshApiBalance(),
      ]);
      expect(balanceProbeHits, 1);

      // Second call within Retry-After backoff sends 0 requests!
      await ai.refreshApiBalance();
      expect(balanceProbeHits, 1);

      // 401 -> refresh -> 200 Codex models path returns clean live entries without mixing local fallbacks
      await ai.setOAuthSession(
        AiOAuthSession(
          accessToken: 'old_tok',
          refreshToken: 'rt_1',
          expiresAtEpochMs: now.millisecondsSinceEpoch + 3600000,
          accountId: 'acct_codex',
          planType: 'plus',
        ),
      );
      final opts = await ai.fetchAvailableModelOptions(
        configOverride: ai.config.copyWith(authMode: AiAuthMode.codexOAuth),
      );
      expect(opts.any((m) => m.id == 'gpt-5.4-live' && !m.isLocalFallback), isTrue);
      expect(opts.any((m) => m.isLocalFallback), isFalse);
    });
  });

  group('P1-11: Legacy Drive Order Migration & Multi-Quality Variant Ordering', () {
    test('Migrates legacy non-default driveOrder without flag, shields from ConfigCenterBridge, and orders multi-quality variants', () async {
      // Simulate legacy install that stored custom driveOrder without `netdisk_drive_order_customized`
      SharedPreferences.setMockInitialValues(<String, Object>{
        StorageService.keyDriveOrder: <String>['ali', 'baidu', 'quark', 'uc'],
      });
      final storage = await StorageService.init();
      expect(storage.hasCustomDriveOrder, isTrue);
      expect(storage.driveOrder, const ['ali', 'baidu', 'quark', 'uc']);

      // ConfigCenterBridge must NOT overwrite user's migrated legacy driveOrder
      await ConfigCenterBridge.syncAll(
        storage: storage,
        sites: const [
          CmsSite(
            key: 'cfg_center',
            name: '配置中心',
            type: 3,
            api: 'csp_Config',
            ext: '{"driveOrder":["quark","uc","baidu","ali"]}',
          ),
        ],
        overwriteExisting: false,
        pushToExternal: false,
      );
      expect(storage.driveOrder, const ['ali', 'baidu', 'quark', 'uc']);

      const variants = <CmsEpisode>[
        CmsEpisode(name: '夸克 4K', url: 'https://pan.quark.cn/s/1'),
        CmsEpisode(name: '直连 1080P', url: 'https://cdn.example/1080.m3u8'),
        CmsEpisode(name: '阿里 4K', url: 'https://www.alipan.com/s/1'),
        CmsEpisode(name: '百度 4K', url: 'https://pan.baidu.com/s/1'),
      ];

      // 4k_netdisk: same 4K tier ordered by user's driveOrder (`ali` -> `baidu` -> `quark`), then direct 1080P
      await storage.setPreferredQuality('4k_netdisk');
      final ordered4k = storage.orderQualityVariants(variants);
      expect(ordered4k.map((e) => e.name).toList(), [
        '阿里 4K',
        '百度 4K',
        '夸克 4K',
        '直连 1080P',
      ]);

      // 1080p_direct: direct stream wins ahead of netdisk 4K
      await storage.setPreferredQuality('1080p_direct');
      final orderedDirect = storage.orderQualityVariants(variants);
      expect(orderedDirect.first.name, '直连 1080P');

      // default: preserves exact site original order
      await storage.setPreferredQuality('default');
      final orderedDefault = storage.orderQualityVariants(variants);
      expect(orderedDefault.map((e) => e.name).toList(), [
        '夸克 4K',
        '直连 1080P',
        '阿里 4K',
        '百度 4K',
      ]);
    });
  });

  group('P1-12: Legacy Token Migration & Curtain Completion Event', () {
    test('Migrates bare semver token once so subsequent build-only bump triggers post-update notice, and awaits curtainCompleted event', () async {
      // Legacy bare token `0.7.10`
      SharedPreferences.setMockInitialValues(<String, Object>{
        OnboardingPrefs.lastSeenAppVersionKey: '0.7.10',
      });
      final prefs = await OnboardingPrefs.load();
      // Same semver with build `0.7.10+104`: migrate bare token silently -> no popup
      final migrated = await prefs.migrateLegacyBareVersionTokenIfNeeded('0.7.10+104');
      expect(migrated, isTrue);
      expect(prefs.lastSeenAppVersion, '0.7.10+104');
      expect(prefs.shouldShowPostUpdateNotice('0.7.10+104', hasExistingUserData: true), isFalse);

      // Next build-only upgrade `0.7.10+105` -> NOW reliably pops!
      expect(prefs.shouldShowPostUpdateNotice('0.7.10+105', hasExistingUserData: true), isTrue);

      // Curtain completion event coordinates asynchronously without fixed sleep
      IosLaunchCurtainHost.resetCurtainStateForTest(completed: false);
      var completed = false;
      final waitFut = IosLaunchCurtainHost.waitUntilCurtainCompleted().then((_) {
        completed = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      IosLaunchCurtainHost.curtainCompleted.value = true;
      await waitFut.timeout(const Duration(milliseconds: 200));
      expect(completed, isTrue);
    });
  });

  group('P1-13 & P2-16: Poster Caches Byte Cap, Private Isolation, Curated Snapshot Preservation & First-Frame Warmup', () {
    test('Disk poster cache evicts oldest files beyond byte cap; private posters stay memory-only and clear on exit', () async {
      final tmpDir = await Directory.systemTemp.createTemp('marco_poster_cap_test_');
      addTearDown(() async {
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      });

      PosterLoader.debugDiskDirOverride = tmpDir;
      PosterLoader.debugDiskMaxBytesOverride = 200; // strict 200-byte cap

      final chunk = Uint8List.fromList(List<int>.filled(90, 0x41));
      final t0 = DateTime(2026, 1, 1, 10, 0, 0);
      await PosterLoader.writePublicDiskEntryForTest('old_poster', chunk, modifiedAt: t0);
      await PosterLoader.writePublicDiskEntryForTest('mid_poster', chunk, modifiedAt: t0.add(const Duration(minutes: 1)));
      await PosterLoader.writePublicDiskEntryForTest('new_poster', chunk, modifiedAt: t0.add(const Duration(minutes: 2)));

      final remainingBytes = await PosterLoader.enforceDiskCacheCapNow();
      expect(remainingBytes, lessThanOrEqualTo(200));
      final files = tmpDir.listSync().whereType<File>().where((f) => f.path.endsWith('.img')).toList();
      expect(files.length, 2);

      // Private poster load NEVER writes to public disk dir or public memory!
      PosterLoader.debugPrivateFetcherOverride = (_) async => _validPngBytes;
      final beforeDiskCount = files.length;
      final privBytes = await PosterLoader.load(
        'https://private.example/secret_poster.png',
        isPrivate: true,
      );
      expect(privBytes, _validPngBytes);
      expect(PosterLoader.privateMemoryCount, 1);
      final afterDiskCount =
          tmpDir.listSync().whereType<File>().where((f) => f.path.endsWith('.img')).length;
      expect(afterDiskCount, beforeDiskCount);
      expect(
        PosterLoader.peekMemory('https://private.example/secret_poster.png', isPrivate: false),
        isNull,
      );

      PosterLoader.clearPrivateCache();
      expect(PosterLoader.privateMemoryCount, 0);
      expect(
        PosterLoader.peekMemory('https://private.example/secret_poster.png', isPrivate: true),
        isNull,
      );
    });

    test('CuratedDiscoveryService preserves valid disk snapshot when offline/partial live refresh fails', () async {
      final tmpDir = await Directory.systemTemp.createTemp('marco_curated_snap_test_');
      addTearDown(() async {
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      });

      final cnHot = CuratedDiscoveryService.modules.firstWhere((m) => m.id == 'cn_hot');
      // 1. Live fetch succeeds and saves real poster snapshot to disk
      CuratedDiscoveryService.debugLiveFetcherOverride = (spec) async {
        if (spec.id == 'cn_hot') {
          return const [
            CmsVideo(
              id: 'db_1',
              title: '快照热播剧',
              poster: 'https://img3.doubanio.com/view/photo/l_ratio_poster/public/p999.jpg',
            ),
          ];
        }
        return null;
      };
      final live = await CuratedDiscoveryService.fetchModule(cnHot, forceRefresh: true);
      expect(live.first.poster, contains('doubanio.com'));
      await CuratedDiscoveryService.saveToDiskNow(overrideDirForTest: tmpDir);

      // 2. Cold restart offline: warmFromDisk restores real poster URLs BEFORE live fetch
      CuratedDiscoveryService.resetCacheForTest();
      final warmed = await CuratedDiscoveryService.warmFromDisk(overrideDirForTest: tmpDir);
      expect(warmed, isTrue);
      expect(CuratedDiscoveryService.peekModule(cnHot).first.poster, contains('doubanio.com'));

      // 3. Live refresh fails (offline / partial failure) -> MUST preserve restored snapshot, NOT overwrite with posterless seeds!
      CuratedDiscoveryService.debugLiveFetcherOverride = (_) async => null;
      final afterOffline = await CuratedDiscoveryService.fetchModule(cnHot, forceRefresh: true);
      expect(afterOffline.first.title, '快照热播剧');
      expect(afterOffline.first.poster, contains('doubanio.com'));
    });
  });

  group('P2-14: Safe-Area Net-Clearance Popover Layout & Sheet Fallback', () {
    test('320pt narrow Split View right-edge anchor NEVER overlaps the 30x36pt button', () {
      const screen = Size(320, 680);
      const safe = EdgeInsets.only(top: 24, bottom: 20);
      const rightButtonAnchor = Rect.fromLTWH(278, 320, 30, 36);

      final layout = computeIosGlassPopoverLayout(
        screen: screen,
        safe: safe,
        anchorRect: rightButtonAnchor,
        maxWidth: 304,
        maxHeight: 420,
      );
      expect(layout.useSheetFallback, isFalse);
      final bubbleRect = layout.boundingRect(screen.height);
      expect(bubbleRect.right, lessThanOrEqualTo(rightButtonAnchor.left));
      expect(bubbleRect.overlaps(rightButtonAnchor), isFalse);
    });

    testWidgets('375pt tall landscape iPhone displays 4 tappable options cleanly without occluding anchor', (tester) async {
      tester.view.physicalSize = const Size(667, 375);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const bottomMoreAnchor = Rect.fromLTWH(560, 322, 44, 34);
      final tapped = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: CupertinoButton(
                  onPressed: () {
                    showIosGlassPopover<void>(
                      context: ctx,
                      anchorRect: bottomMoreAnchor,
                      title: '播放选项',
                      maxWidth: 304,
                      maxHeight: 360,
                      forceDark: true,
                      builder: (popCtx) => ListView(
                        shrinkWrap: true,
                        children: [
                          for (var i = 1; i <= 4; i++)
                            GestureDetector(
                              key: ValueKey('pop-item-$i'),
                              onTap: () => tapped.add(i),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                                child: Text('设置项 $i'),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                  child: const Text('OPEN_POP'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OPEN_POP'));
      await tester.pumpAndSettle();

      // All 4 items must be visible and tappable!
      for (var i = 1; i <= 4; i++) {
        expect(find.byKey(ValueKey('pop-item-$i')), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('pop-item-$i')));
        await tester.pump();
      }
      expect(tapped, [1, 2, 3, 4]);

      // Verify popover bubble does NOT overlap the bottom anchor button
      final bubbleBox = tester.getRect(find.byKey(const Key('ios-glass-popover-bubble')));
      expect(bubbleBox.overlaps(bottomMoreAnchor), isFalse);
    });
  });

  group('P1-3, P1-4, P1-8 & P1-12 End-to-End Widget Acceptance Tests', () {
    testWidgets(
      'P1-3: Manual MPV selection is NEVER overridden by Dolby Vision MKV media',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            'ios_player_engine_mode': 'mpv',
          },
        );
        final kernelUseMdkCalls = <bool>[];
        final createdPlayers = <_FakePlayer>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: const CmsSite(key: 's_dv', name: 'DVSite', type: 1, api: 'https://dv.example'),
              video: const CmsVideo(
                id: 'dv_1',
                title: '沙丘2 杜比视界',
                remarks: '4K Dolby Vision',
                lines: [
                  CmsLine(
                    name: '4K原盘',
                    episodes: [
                      CmsEpisode(name: 'Dune.2160p.DV.HEVC.mkv', url: 'https://cdn.example/dune_dv.mkv?token=1'),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugIosKernelFactory: (useIosMdk) {
                kernelUseMdkCalls.add(useIosMdk);
                final p = _FakePlayer();
                createdPlayers.add(p);
                return VideoKernel.create(
                  debugPlayer: p,
                  debugVideoSurface: const ColoredBox(color: Colors.black),
                  hwdec: 'videotoolbox',
                );
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(kernelUseMdkCalls, isNotEmpty);
        expect(kernelUseMdkCalls.every((v) => v == false), isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        for (final p in createdPlayers) {
          await p.dispose();
        }
      },
    );

    testWidgets(
      'P1-4: External AI subtitle overlay updates live across cue1 -> empty gap -> cue2 -> pause/resume -> seek while HUD is hidden and screen locked',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final fakePlayer = _FakePlayer();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(hudPrefs.dispose);
        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            'ios_player_engine_mode': 'mpv',
          },
        );
        AiService.instance.configureForTest(
          secureStorage: InMemorySecureCredentialStore(),
          labUnlockedForTest: true,
          resetState: true,
        );
        await AiService.instance.saveConfig(const AiConfig(enabled: true));

        const cues = <AiSubtitleCue>[
          AiSubtitleCue(
            index: 1,
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
            text: 'Hello world',
            translatedText: '你好，世界',
          ),
          AiSubtitleCue(
            index: 2,
            start: Duration(seconds: 8),
            end: Duration(seconds: 12),
            text: 'Second line',
            translatedText: '第二句台词',
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: const CmsSite(key: 's1', name: 'TestSite', type: 1, api: 'https://s.example'),
              video: const CmsVideo(
                id: 'v1',
                title: '测试电影',
                lines: [
                  CmsLine(
                    name: '线路1',
                    episodes: [
                      CmsEpisode(name: '正片', url: 'https://cdn.example/test.mp4'),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugDanmuSettings: const DanmuSettings(enabled: false),
              debugInitialAiOverlayCues: cues,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));

        // 1. Cue 1 active at 2s
        fakePlayer._stream.durationCtl.add(const Duration(minutes: 10));
        fakePlayer._stream.playingCtl.add(true);
        fakePlayer._stream.positionCtl.add(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('player-ai-subtitle-primary')), findsOneWidget);
        expect(find.text('你好，世界'), findsOneWidget);

        // 2. Lock screen & hide HUD controls (tap lock button if visible, then wait past auto-hide)
        final lockFinder = find.byKey(const Key('player-lock-button'));
        if (lockFinder.evaluate().isNotEmpty) {
          await tester.tap(lockFinder);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(seconds: 5));

        // 3. Advance into empty gap (6s) while hidden & locked -> MUST clear!
        fakePlayer._stream.positionCtl.add(const Duration(seconds: 6));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('player-ai-subtitle-primary')), findsNothing);

        // 4. Advance into Cue 2 (10s) while STILL hidden & locked -> MUST render Cue 2!
        fakePlayer._stream.positionCtl.add(const Duration(seconds: 10));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('第二句台词'), findsOneWidget);

        // 5. Pause -> Resume -> Seek back to Cue 1 (2.5s) -> MUST render Cue 1!
        fakePlayer._stream.playingCtl.add(false);
        await tester.pump(const Duration(milliseconds: 50));
        fakePlayer._stream.playingCtl.add(true);
        fakePlayer._stream.positionCtl.add(const Duration(milliseconds: 2500));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('你好，世界'), findsOneWidget);

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 50));
      },
    );

    testWidgets(
      'P1-8: _switchToRecommendedPick keeps Film A intact when Pick B has no playable lines and switches cleanly when verified',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final fakePlayer = _FakePlayer();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: false);
        addTearDown(hudPrefs.dispose);
        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            'ios_player_engine_mode': 'mpv',
          },
        );

        const pubSite = CmsSite(key: 'pub', name: '公共站', type: 1, api: 'https://pub.example/api');
        final mockClient = CmsClient(
          client: MockClient((req) async {
            final ids = req.url.queryParameters['ids'] ?? '';
            if (ids == 'bad_b') {
              return http.Response(
                jsonEncode({
                  'list': [
                    {'vod_id': 'bad_b', 'vod_name': '无源影片B', 'vod_play_from': '', 'vod_play_url': ''},
                  ],
                }),
                200,
              );
            }
            if (ids == 'good_c') {
              return http.Response(
                jsonEncode({
                  'list': [
                    {
                      'vod_id': 'good_c',
                      'vod_name': '可播影片C',
                      'vod_play_from': '高清线路',
                      'vod_play_url': '正片\$https://cdn.example/good_c.mp4',
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('{"list":[]}', 200);
          }),
        );

        Future<void> Function(AiCuratedPick)? boundSwitch;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: pubSite,
              video: const CmsVideo(
                id: 'film_a',
                title: '原影片A',
                lines: [
                  CmsLine(
                    name: '线路A',
                    episodes: [
                      CmsEpisode(name: '正片A', url: 'https://cdn.example/film_a.mp4'),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              client: mockClient,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: hudPrefs,
              debugDanmuSettings: const DanmuSettings(enabled: false),
              debugOnBindSwitchPickForTest: (fn) => boundSwitch = fn,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(boundSwitch, isNotNull);
        expect(find.textContaining('原影片A'), findsWidgets);

        // 1. Pick B returns zero playable lines -> Film A stays untouched!
        await boundSwitch!(
          const AiCuratedPick(
            title: '无源影片B',
            reason: '相似风格',
            matchedSite: pubSite,
            matchedVideo: CmsVideo(id: 'bad_b', title: '无源影片B'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.textContaining('原影片A'), findsWidgets);
        expect(find.text('可播影片C'), findsNothing);

        // 2. Pick C returns verified playable line -> commits clean switch!
        await boundSwitch!(
          const AiCuratedPick(
            title: '可播影片C',
            reason: '相似风格',
            matchedSite: pubSite,
            matchedVideo: CmsVideo(id: 'good_c', title: '可播影片C'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.textContaining('可播影片C'), findsWidgets);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );

    testWidgets(
      'P1-12: AdaptiveShell coordinates 4 launch scenarios cleanly (fresh install, history-only upgrade, same-version restart, build-only bump)',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        CmsClient emptyClient() => CmsClient(
              client: MockClient((_) async => http.Response('{"class":[],"list":[]}', 200)),
            );

        // Scenario 1: Fresh install -> OfficialChannelNoticeDialog only, confirming stamps `0.7.11+104`
        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcoMovie',
          version: '0.7.11',
          buildNumber: '104',
          buildSignature: '',
        );
        SharedPreferences.setMockInitialValues(<String, Object>{});
        OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = true;
        final freshStorage = await initTestStorage();
        await tester.pumpWidget(
          MaterialApp(home: AdaptiveShell(storage: freshStorage, client: emptyClient())),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(OfficialChannelNoticeDialog), findsOneWidget);
        expect(find.byType(PostUpdateWelcomeDialog), findsNothing);
        await tester.tap(find.byKey(const ValueKey('official-channel-notice-confirm')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final afterFresh = await OnboardingPrefs.load();
        expect(afterFresh.lastSeenAppVersion, '0.7.11+104');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        // Scenario 2: Upgraded user with watch history & 0 subscriptions -> PostUpdateWelcomeDialog ONLY (never hijacked by OfficialChannelNoticeDialog)
        final upgradeStorage = await initTestStorage();
        await upgradeStorage.restoreWatchHistoryEntry(
          WatchHistoryEntry(
            site: 's1',
            id: 'v1',
            title: '历史影片',
            line: 'L1',
            episode: 'EP1',
            index: 0,
            position: 12000,
            duration: 60000,
            updated: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(home: AdaptiveShell(storage: upgradeStorage, client: emptyClient())),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PostUpdateWelcomeDialog), findsOneWidget);
        expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
        await tester.tap(find.byKey(const ValueKey('post-update-confirm-btn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect((await OnboardingPrefs.load()).lastSeenAppVersion, '0.7.11+104');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        // Scenario 3: Same-version restart (`0.7.11+104`) -> ZERO dialogs!
        await tester.pumpWidget(
          MaterialApp(home: AdaptiveShell(storage: upgradeStorage, client: emptyClient())),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PostUpdateWelcomeDialog), findsNothing);
        expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        // Scenario 4: Build-only bump (`0.7.11+104` -> `0.7.11+105`) -> pops PostUpdateWelcomeDialog once!
        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcoMovie',
          version: '0.7.11',
          buildNumber: '105',
          buildSignature: '',
        );
        await tester.pumpWidget(
          MaterialApp(home: AdaptiveShell(storage: upgradeStorage, client: emptyClient())),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PostUpdateWelcomeDialog), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('post-update-confirm-btn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect((await OnboardingPrefs.load()).lastSeenAppVersion, '0.7.11+105');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_passcode.dart';
import 'package:marco_movie/core/ai_oauth_manager.dart';
import 'package:marco_movie/core/ai_provider_profiles.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/ai_title_cleaner.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

// Deterministic RFC 8032 test-only keypair (seed = 0x00..0x1f; NOT a production key).
const _testEd25519PubKeyHex =
    '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8';
const _validWinPasscode =
    'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwMDAwMCwidGFnIjoiUElMSVBBTEEtVEVTVCIsInYiOjF9.7zwTt98l9TK9bGAm64AxIxvsCpqz-QuSLyb491xozmWcxj42_TFQtrbmhjKvlQtWNwRCan2iPTJE8WH8nznQDA';
const _expiredPasscode =
    'MMAILAB1.eyJleHAiOjE3MDAwMDAwMDAsImlhdCI6MTY5OTAwMDAwMCwidGFnIjoiRVhQSVJFRC1UUklBTCIsInYiOjF9.90Do8pa5YviI2BGq6WBp7206hJh8b3A_yGG4NPltz1EyDh7VuZ4GAOfUrtq5mvMKE_zEdp9aavB87A5PIRzGBw';
const _wrongPlatformPasscode =
    'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwMDAwMCwicGxhdCI6ImlvcyIsInRhZyI6IklPUy1PTkxZIiwidiI6MX0.ODzlLVjgZPiYJaRfSgpWGCe5mN2jc9KA7nZk1xiCqi_l6bpONK3zaWMbkUPrBYidmxzNZ6qpZpLOW2cbwl_ADg';
const _wrongVersionPasscode =
    'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwMDAwMCwidGFnIjoiQkFELVZFUiIsInYiOjJ9.m0BRSjFwgD8YPAdpwyHbw7JXLqmeiAWDSL3BqJOZku46HC2TkwT-Oe215ua5DWQQ_GpBMjFsq0cXTVxNIvEzDQ';
const _iosAndroidPasscode =
    'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwMDAwMCwibiI6ImExYjJjMyIsInBsYXQiOiJpb3MsYW5kcm9pZCIsInRhZyI6Ik1PQklMRS1PTkxZIiwidiI6MX0.4YyDryyW07AbxTfjZHbissPvmpaGG0Cpww01_XvFG4vcb47_7f8X4uaCWBK25ANdPWLoJDWF7Bw7MYs0Am0aCg';
const _androidWindowsPasscode =
    'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwMDAwMCwibiI6ImQ0ZTVmNiIsInBsYXQiOiJhbmRyb2lkLHdpbmRvd3MiLCJzaGFyZWQiOnRydWUsInRhZyI6IkRVQUwtQVciLCJ2IjoxfQ.GRH6R_8DCdSNpe2csAYBfO71fo_lbJE-fsDRPl2fs-3qM9s5j2P2pPORP4GbNg8Of5ENVMHw9uMKvXz3c_vuDw';
const _semicolonExpOAuthPasscode =
    'MMAILAB1.eyJleHAiOjAsImV4cF9vYXV0aCI6dHJ1ZSwiaWF0IjoxNzk1NzAwMDAwLCJtaW5fdmMiOjgwLCJuIjoiMTEyMjMzIiwicGxhdCI6ImlwaG9uZTtwYyIsInNoYXJlZCI6dHJ1ZSwidGFnIjoiRVhQLUFETUlOIiwidiI6MX0.iJMOUXrCZaLsw3o8pzhtisBRbV0Fp_IA6AwUS0_rspsnf57L-UNFyuGdTOdXesBL3JyQraTj0PIPfMr-Mt6xBg';
// Production-signed 3-platform universal passcode (verified against built-in defaultPublicKeyHex)
const _realSignedUniversalPasscode =
    'MMAILAB1.eyJleHAiOjE3OTgzMDI5NDAsImlhdCI6MTc5NTcxMDk0MCwibiI6IjllNjAwYyIsInBsYXQiOiJhbGwiLCJzaGFyZWQiOnRydWUsInRhZyI6ImNoYW5uZWwtMDEiLCJ2IjoxfQ.i-wBNpbuTEmMaCnJYvCoeBttxHWKrM5JQCGhmxO9nsGf1KbnkrvuWvDvoY5xlAMrC7570oMIXC_IHlboqFQZBQ';

class _InMemorySecureStorage implements SecureStorageBackend {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _SearchRecordingClient extends CmsClient {
  final List<String> searchedKeywords = <String>[];

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const <CmsCategory>[CmsCategory(id: '1', name: '电影')],
        const CmsListing(
          videos: <CmsVideo>[CmsVideo(id: 'v1', title: '星际穿越')],
        ),
      );

  @override
  Future<CmsListing> fetchSearch(CmsSite site, String keyword,
      {int page = 1}) async {
    searchedKeywords.add(keyword);
    return CmsListing(
      videos: <CmsVideo>[CmsVideo(id: 'hit_$keyword', title: keyword)],
    );
  }

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates, {
    bool forceRefresh = false,
  }) async =>
      (source, item);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AiLabPasscodeVerifier.debugPublicKeyHexOverride = null;
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiTitleCleaner.instance.configureForTest(
      aiService: AiService.instance,
      clearCache: true,
    );
  });

  group('Ed25519 offline passcode verification & store', () {
    test('verifies valid signature, tolerates whitespace, rejects tamper/expiry/platform/feature',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AiLabPasscodeVerifier.debugPublicKeyHexOverride = _testEd25519PubKeyHex;

      // Valid token embedded inside chat prose & line breaks
      final ok = AiLabPasscodeVerifier.verify(
        '解锁口令：${_validWinPasscode.substring(0, 20)}\n${_validWinPasscode.substring(20)}  ',
        now: DateTime.utc(2026, 11, 26),
      );
      expect(ok.isValid, isTrue);
      expect(ok.payload?.tag, 'PILIPALA-TEST');
      expect(ok.payload?.platform, 'all');

      // 1-char tampered payload MUST fail Ed25519 verification
      final parts = _validWinPasscode.split('.');
      final flipped =
          '${parts[0]}.${parts[1][0] == "A" ? "B" : "A"}${parts[1].substring(1)}.${parts[2]}';
      final tampered = AiLabPasscodeVerifier.verify(flipped);
      expect(tampered.isValid, isFalse);
      expect(tampered.status, AiLabPasscodeStatus.invalidSignature);

      // Expired token MUST fail
      final expired = AiLabPasscodeVerifier.verify(
        _expiredPasscode,
        now: DateTime.utc(2026, 11, 26),
      );
      expect(expired.isValid, isFalse);
      expect(expired.status, AiLabPasscodeStatus.expired);

      // Wrong platform MUST fail on Windows
      final wrongPlat = AiLabPasscodeVerifier.verify(
        _wrongPlatformPasscode,
        targetPlatform: 'windows',
      );
      expect(wrongPlat.isValid, isFalse);
      expect(wrongPlat.status, AiLabPasscodeStatus.wrongPlatform);

      // Unsupported version MUST fail
      final wrongVer = AiLabPasscodeVerifier.verify(_wrongVersionPasscode);
      expect(wrongVer.isValid, isFalse);
      expect(wrongVer.status, AiLabPasscodeStatus.unsupportedVersion);

      // Store persists signed token and cryptographically re-verifies on reload
      final store = AiLabPasscodeStore(
        publicKeyHexOverride: _testEd25519PubKeyHex,
        clock: () => DateTime.utc(2026, 11, 26),
      );
      await store.ensureLoaded();
      expect(store.isUnlocked, isFalse);

      final unlockRes = await store.unlockWithPasscode(_validWinPasscode);
      expect(unlockRes.isValid, isTrue);
      expect(store.isUnlocked, isTrue);

      // Reload from SharedPreferences -> still unlocked
      final reloaded = AiLabPasscodeStore(
        publicKeyHexOverride: _testEd25519PubKeyHex,
        clock: () => DateTime.utc(2026, 11, 26),
      );
      await reloaded.ensureLoaded();
      expect(reloaded.isUnlocked, isTrue);

      // Tampering persisted token in SharedPreferences -> locked on reload!
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AiLabPasscodeStore.prefsPasscodeKey, flipped);
      final forged = AiLabPasscodeStore(
        publicKeyHexOverride: _testEd25519PubKeyHex,
        clock: () => DateTime.utc(2026, 11, 26),
      );
      await forged.ensureLoaded();
      expect(forged.isUnlocked, isFalse);
    });

    test('verifies real 3-platform signed token, multi-platform lists/aliases, exp_oauth, min_vc, and dynamic platform detection',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 1. Verify production-signed 3-platform universal token with built-in pubkey (NO override!)
      AiLabPasscodeVerifier.debugPublicKeyHexOverride = null;
      final checkTime = DateTime.utc(2026, 11, 27);
      for (final plat in <String>['windows', 'ios', 'android']) {
        final res = AiLabPasscodeVerifier.verify(
          _realSignedUniversalPasscode,
          targetPlatform: plat,
          now: checkTime,
        );
        expect(res.isValid, isTrue, reason: 'Failed on $plat: ${res.messageZh}');
        expect(res.payload?.tag, 'channel-01');
        expect(res.payload?.platform, 'all');
        expect(res.payload?.shared, isTrue);
        expect(res.payload?.experimentalOAuth, isFalse);
        expect(res.payload?.minVersionCode, 0);
        expect(res.payload?.nonce, '9e600c');
      }

      // 2. Multi-platform combos, aliases, exp_oauth, and min_vc (using test keypair)
      AiLabPasscodeVerifier.debugPublicKeyHexOverride = _testEd25519PubKeyHex;

      // plat="ios,android" MUST reject on Windows and accept on iOS/Android aliases
      final mobileOnlyOnWin = AiLabPasscodeVerifier.verify(
        _iosAndroidPasscode,
        targetPlatform: 'windows',
      );
      expect(mobileOnlyOnWin.isValid, isFalse);
      expect(mobileOnlyOnWin.status, AiLabPasscodeStatus.wrongPlatform);
      for (final p in <String>[
        'ios',
        'iphone',
        'ipad',
        'android',
        'android-mobile',
        'mobile',
      ]) {
        expect(
          AiLabPasscodeVerifier.verify(_iosAndroidPasscode, targetPlatform: p)
              .isValid,
          isTrue,
          reason: 'Expected ios,android passcode to accept $p',
        );
      }

      // plat="android,windows" MUST accept on Windows/Android aliases and reject on iOS
      for (final p in <String>['windows', 'win', 'pc', 'android', 'mobile']) {
        final r = AiLabPasscodeVerifier.verify(
          _androidWindowsPasscode,
          targetPlatform: p,
        );
        expect(r.isValid, isTrue, reason: 'Expected android,windows to accept $p');
        expect(r.payload?.shared, isTrue);
      }
      expect(
        AiLabPasscodeVerifier.verify(
          _androidWindowsPasscode,
          targetPlatform: 'ios',
        ).status,
        AiLabPasscodeStatus.wrongPlatform,
      );

      // plat="iphone;pc" + exp_oauth=true + min_vc=80
      final expOk = AiLabPasscodeVerifier.verify(
        _semicolonExpOAuthPasscode,
        targetPlatform: 'windows',
        currentVersionCode: 80,
      );
      expect(expOk.isValid, isTrue);
      expect(expOk.payload?.experimentalOAuth, isTrue);
      expect(expOk.payload?.shared, isTrue);
      expect(expOk.payload?.minVersionCode, 80);
      expect(
        AiLabPasscodeVerifier.verify(
          _semicolonExpOAuthPasscode,
          targetPlatform: 'ios',
        ).isValid,
        isTrue,
      );
      expect(
        AiLabPasscodeVerifier.verify(
          _semicolonExpOAuthPasscode,
          targetPlatform: 'android',
        ).status,
        AiLabPasscodeStatus.wrongPlatform,
      );
      expect(
        AiLabPasscodeVerifier.verify(
          _semicolonExpOAuthPasscode,
          targetPlatform: 'windows',
          currentVersionCode: 79,
        ).status,
        AiLabPasscodeStatus.versionTooOld,
      );

      // 3. AiLabPasscodeStore auto-detects runtime platform (NOT hardcoded 'windows')
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final winStore = AiLabPasscodeStore(
        publicKeyHexOverride: _testEd25519PubKeyHex,
        clock: () => checkTime,
      );
      expect(winStore.effectiveTargetPlatform, 'windows');
      expect(
        (await winStore.unlockWithPasscode(_iosAndroidPasscode)).status,
        AiLabPasscodeStatus.wrongPlatform,
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final iosStore = AiLabPasscodeStore(
        publicKeyHexOverride: _testEd25519PubKeyHex,
        clock: () => checkTime,
      );
      expect(iosStore.effectiveTargetPlatform, 'ios');
      expect(
        (await iosStore.unlockWithPasscode(_iosAndroidPasscode)).isValid,
        isTrue,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('OpenMinis-style compliant auth, discovery, catalog, and recommendations',
      () {
    test('OpenRouter PKCE loopback server exchanges code for API key cleanly',
        () async {
      late Uri capturedCallback;
      String? capturedVerifier;
      final mockClient = MockClient((request) async {
        expect(request.url.toString(), OpenRouterPkceManager.keyExchangeUrl);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['code'], 'or_code_9919');
        expect(body['code_challenge_method'], 'S256');
        capturedVerifier = body['code_verifier'] as String?;
        return http.Response(
          jsonEncode(<String, String>{'key': 'sk-or-v1-testissued123456'}),
          200,
        );
      });

      final result = await OpenRouterPkceManager.authorize(
        httpClient: mockClient,
        onAuthorizeUriReady: (authUri, callbackUri) {
          capturedCallback = callbackUri;
          expect(authUri.host, 'openrouter.ai');
          expect(authUri.queryParameters['code_challenge_method'], 'S256');
        },
        urlOpener: (_) async {
          // Simulate browser redirecting back to our ephemeral 127.0.0.1 server
          // via raw TCP socket so Flutter's TestWidgetsFlutterBinding HttpOverrides
          // does not intercept loopback HTTP with a synthetic 400.
          final cb = capturedCallback.replace(
            queryParameters: <String, String>{'code': 'or_code_9919'},
          );
          final sock = await Socket.connect(
            InternetAddress.loopbackIPv4,
            cb.port,
          );
          sock.write(
            'GET ${cb.path}?${cb.query} HTTP/1.1\r\n'
            'Host: 127.0.0.1:${cb.port}\r\n'
            'Connection: close\r\n\r\n',
          );
          await sock.flush();
          final rawResp = await utf8.decoder.bind(sock).join();
          sock.destroy();
          expect(rawResp, startsWith('HTTP/1.1 200'));
          return true;
        },
      );

      expect(result.apiKey, 'sk-or-v1-testissued123456');
      expect(capturedVerifier, isNotNull);
      expect(capturedVerifier!.length, greaterThanOrEqualTo(32));
    });

    test('GitHub Copilot RFC 8628 Device Flow polls, handles slow_down, and caches/refreshes session token',
        () async {
      var pollCount = 0;
      var sessionExchangeCount = 0;
      var currentTime = DateTime.utc(2026, 11, 26, 12, 0, 0);
      final sleepDurations = <Duration>[];

      final mockClient = MockClient((request) async {
        final url = request.url.toString();
        if (url == GitHubCopilotDeviceFlow.deviceCodeUrl) {
          return http.Response(
            jsonEncode(<String, Object>{
              'device_code': 'dev_abc',
              'user_code': 'ABCD-1234',
              'verification_uri': 'https://github.com/login/device',
              'expires_in': 900,
              'interval': 5,
            }),
            200,
          );
        }
        if (url == GitHubCopilotDeviceFlow.accessTokenUrl) {
          pollCount++;
          if (pollCount == 1) {
            return http.Response(
              jsonEncode(<String, String>{'error': 'authorization_pending'}),
              200,
            );
          }
          if (pollCount == 2) {
            return http.Response(
              jsonEncode(<String, Object>{
                'error': 'slow_down',
                'interval': 10,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, String>{'access_token': 'gho_testtoken1234'}),
            200,
          );
        }
        if (url == GitHubCopilotDeviceFlow.copilotTokenUrl) {
          sessionExchangeCount++;
          final exp = (currentTime.millisecondsSinceEpoch ~/ 1000) + 1200;
          return http.Response(
            jsonEncode(<String, Object>{
              'token': 'copilot_sess_$sessionExchangeCount',
              'expires_at': exp,
              'endpoints': <String, String>{
                'api': 'https://api.githubcopilot.com',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final flow = GitHubCopilotDeviceFlow();
      final prompt = await flow.requestDeviceCode(httpClient: mockClient);
      expect(prompt.userCode, 'ABCD-1234');

      final ghToken = await flow.pollAccessToken(
        prompt,
        httpClient: mockClient,
        clock: () => currentTime,
        sleeper: (d) async => sleepDurations.add(d),
      );
      expect(ghToken, 'gho_testtoken1234');
      expect(pollCount, 3);
      expect(sleepDurations, <Duration>[
        const Duration(seconds: 5),
        const Duration(seconds: 5),
        const Duration(seconds: 10),
      ]);

      final s1 = await flow.getOrRefreshSessionToken(
        ghToken,
        httpClient: mockClient,
        clock: () => currentTime,
      );
      final s2 = await flow.getOrRefreshSessionToken(
        ghToken,
        httpClient: mockClient,
        clock: () => currentTime.add(const Duration(minutes: 5)),
      );
      expect(s1.token, 'copilot_sess_1');
      expect(s2.token, 'copilot_sess_1');
      expect(sessionExchangeCount, 1);

      // Advance past expiry window -> refreshes automatically
      currentTime = currentTime.add(const Duration(minutes: 25));
      final s3 = await flow.getOrRefreshSessionToken(
        ghToken,
        httpClient: mockClient,
        clock: () => currentTime,
      );
      expect(s3.token, 'copilot_sess_2');
      expect(sessionExchangeCount, 2);
    });

    test('Local Ollama/LM Studio discovery, loopback zero-key completion, secret redaction, and AI picks',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final secure = _InMemorySecureStorage();

      // 1. Secret redaction
      expect(
        redactAiSecret(
          'failed Bearer sk-testsecret99999 and gho_testtoken1234',
        ),
        isNot(contains('sk-testsecret99999')),
      );
      expect(
        redactAiSecret('token=mySecretValue123'),
        isNot(contains('mySecretValue123')),
      );

      // 2. Local discovery
      final discoveryClient = MockClient((req) async {
        if (req.url.toString() == AiLocalDiscovery.ollamaTagsUrl) {
          return http.Response(
            jsonEncode(<String, Object>{
              'models': <Map<String, String>>[
                <String, String>{'name': 'qwen2.5:7b'},
                <String, String>{'name': 'llama3.2:3b'},
              ],
            }),
            200,
          );
        }
        if (req.url.toString() == AiLocalDiscovery.lmStudioModelsUrl) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <Map<String, String>>[
                <String, String>{'id': 'mistral-nemo-local'},
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final locals = await AiLocalDiscovery.discover(httpClient: discoveryClient);
      expect(locals.length, 2);
      expect(locals.first.models, contains('qwen2.5:7b'));
      expect(locals.last.models, contains('mistral-nemo-local'));

      // 3. Zero-key loopback completion + personalized picks + Privacy Space block
      var sawAuthHeader = false;
      final aiClient = MockClient((req) async {
        if (req.headers.containsKey('Authorization')) sawAuthHeader = true;
        if (req.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode(<String, Object>{
              'data': <Map<String, String>>[
                <String, String>{'id': 'qwen2.5:7b'},
              ],
            }),
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, Object>{
              'choices': <Map<String, Object>>[
                <String, Object>{
                  'message': <String, String>{
                    'content': jsonEncode(<Map<String, String>>[
                      <String, String>{
                        'title': '降临',
                        'year': '2016',
                        'reason': '与你喜欢的硬科幻语言学探索风格契合',
                      },
                      <String, String>{
                        'title': '非法带链',
                        'year': '2020',
                        'reason': 'https://evil.invalid/watch',
                      },
                    ]),
                  },
                },
              ],
              'usage': <String, int>{
                'prompt_tokens': 40,
                'completion_tokens': 30,
              },
            }),
          ),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });

      final service = AiService(httpClient: aiClient, secureStorage: secure);
      await service.saveProfile(
        const AiProviderProfile(
          id: 'local_ollama',
          name: '本地 Ollama',
          presetId: 'ollama',
          protocol: AiApiProtocol.openaiCompatible,
          authMode: AiAuthMode.localNoAuth,
          baseUrl: 'http://127.0.0.1:11434/v1',
          model: 'qwen2.5:7b',
        ),
        secret: '',
        activate: true,
        enableAiWhenActivating: true,
      );
      expect(service.isConfigured, isTrue);

      final catalog = await service.fetchAvailableModels();
      expect(catalog, contains('qwen2.5:7b'));

      // Privacy Space MUST be hard-blocked
      await expectLater(
        () => service.suggestPersonalizedRecommendations(
          recentTitles: const <String>['星际穿越'],
          favoriteTitles: const <String>['盗梦空间'],
          isPrivateSession: true,
        ),
        throwsA(
          isA<AiServiceException>().having(
            (e) => e.code,
            'code',
            AiErrorCode.privacySpaceBlocked,
          ),
        ),
      );

      // Public personalized picks succeed without auth header on loopback and strip URL items
      final picks = await service.suggestPersonalizedRecommendations(
        recentTitles: const <String>['星际穿越'],
        favoriteTitles: const <String>['盗梦空间'],
      );
      expect(sawAuthHeader, isFalse);
      expect(picks.length, 1);
      expect(picks.first.title, '降临');
    });
  });

  group('Windows 0.7.3 UI E2E: Vertical History Poster Wall & Gated AI Lab', () {
    testWidgets(
      'Continue Watching renders 2:3 vertical poster wall with delete+undo; AI Lab unlocks via Ed25519 passcode and drives Search, Picks & Detail cleanup',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        AiLabPasscodeVerifier.debugPublicKeyHexOverride = _testEd25519PubKeyHex;
        AiLabPasscodeStore.instance.configureForTest(
          publicKeyHexOverride: _testEd25519PubKeyHex,
          clock: () => DateTime.utc(2026, 11, 26),
          resetState: true,
        );

        final secure = _InMemorySecureStorage();
        final mockAiClient = MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final messages = body['messages'] as List;
          final userMsg = (messages.last as Map)['content'] as String;
          if (userMsg.contains('Reply with OK')) {
            return http.Response(
              jsonEncode(<String, Object>{
                'choices': <Map<String, Object>>[
                  <String, Object>{
                    'message': <String, String>{'content': 'OK'},
                  },
                ],
              }),
              200,
            );
          }
          if (userMsg.startsWith('[')) {
            // AiTitleCleaner batch cleanup response
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, Object>{
                  'choices': <Map<String, Object>>[
                    <String, Object>{
                      'message': <String, String>{
                        'content': jsonEncode(<Map<String, Object?>>[
                          <String, Object?>{
                            'index': 0,
                            'title': '三体',
                            'year': '2023',
                            'season': 1,
                            'episode': 1,
                          },
                        ]),
                      },
                    },
                  ],
                }),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object>{
                'choices': <Map<String, Object>>[
                  <String, Object>{
                    'message': <String, String>{
                      'content': jsonEncode(<Map<String, String>>[
                        <String, String>{
                          'title': '盗梦空间',
                          'year': '2010',
                          'reason': '高口碑多层梦境烧脑科幻经典',
                        },
                      ]),
                    },
                  },
                ],
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        });
        AiService.instance.configureForTest(
          httpClient: mockAiClient,
          secureStorage: secure,
          resetState: true,
        );
        AiTitleCleaner.instance.configureForTest(
          aiService: AiService.instance,
          clearCache: true,
        );

        const size = Size(1280, 800);
        await tester.binding.setSurfaceSize(size);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          return tester.binding.setSurfaceSize(null);
        });

        final storage = await initTestStorage(initialPrefs: <String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });
        await tester.runAsync(() async {
          await storage.saveConfig(jsonEncode({
            'sites': [
              {
                'key': 's1',
                'name': '主源',
                'type': 1,
                'api': 'https://owned.invalid/api',
              },
            ],
          }));
          await storage.upsertWatchHistory(
            const WatchHistoryEntry(
              site: 's1',
              id: 'h1',
              title: '昨日的旅途',
              poster: '',
              line: '主线路',
              episode: '第 3 集',
              index: 2,
              position: 125000,
              duration: 1800000,
              updated: 1000,
            ),
            triggerSync: false,
          );
        });

        final client = _SearchRecordingClient();
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: AdaptiveShell(
              storage: storage,
              client: client,
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Verify Windows Continue Watching 2:3 vertical poster wall + delete & undo
        await tester.tap(find.text('我的').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('继续观看').first);
        await tester.pumpAndSettle();

        final aspectFinder =
            find.byKey(const ValueKey('win-hist-poster-aspect-s1-h1'));
        expect(aspectFinder, findsOneWidget);
        final aspectWidget = tester.widget<AspectRatio>(aspectFinder);
        expect(aspectWidget.aspectRatio, closeTo(2 / 3, 0.001));
        expect(find.text('昨日的旅途'), findsOneWidget);
        expect(find.text('第 3 集 · 看到 2:05'), findsOneWidget);

        // AI Picks button MUST be hidden while AI Lab is locked!
        expect(
          find.byKey(const ValueKey('windows-ai-picks-btn')),
          findsNothing,
        );

        // Delete single history item + undo restores it
        await tester.tap(find.byKey(const ValueKey('win-hist-delete-s1-h1')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pumpAndSettle();
        expect(find.text('昨日的旅途'), findsNothing);
        expect(
          find.byKey(const ValueKey('windows-undo-history-banner')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('windows-undo-history-action')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pumpAndSettle();
        expect(find.text('昨日的旅途'), findsOneWidget);

        // 2. Search page MUST hide AI Search button while locked
        await tester.tap(find.byTooltip('搜索影片 · Ctrl+K'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-ai-search-btn')),
          findsNothing,
        );

        // 3. Settings -> AI 实验室 shows Ed25519 lock gate; bad passcode fails; valid passcode unlocks
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('AI 实验室').first);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-ai-lab-lock-card')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const ValueKey('windows-ai-lab-passcode-input')),
          'MMAILAB1.bad.token',
        );
        await tester.tap(find.byKey(const ValueKey('windows-ai-lab-unlock-btn')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-ai-lab-lock-card')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const ValueKey('windows-ai-lab-passcode-input')),
          _validWinPasscode,
        );
        await tester.tap(find.byKey(const ValueKey('windows-ai-lab-unlock-btn')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-ai-lab-unlocked-bar')),
          findsOneWidget,
        );

        // Configure local zero-key Ollama profile and enable AI Lab
        await tester.runAsync(() async {
          await AiService.instance.saveProfile(
            const AiProviderProfile(
              id: 'local_ollama',
              name: '本地 Ollama',
              presetId: 'ollama',
              protocol: AiApiProtocol.openaiCompatible,
              authMode: AiAuthMode.localNoAuth,
              baseUrl: 'http://127.0.0.1:11434/v1',
              model: 'qwen2.5:7b',
            ),
            secret: '',
            activate: true,
            enableAiWhenActivating: true,
          );
        });
        await tester.pumpAndSettle();

        // 4. Search -> 「AI 找片」 now visible -> returns candidate -> triggers _runGlobalSearch
        await tester.tap(find.byTooltip('搜索影片 · Ctrl+K'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-ai-search-btn')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('windows-ai-search-btn')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('windows-ai-search-query-input')),
          '关于多层梦境的烧脑电影',
        );
        await tester.tap(
          find.byKey(const ValueKey('windows-ai-search-submit-btn')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('盗梦空间'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('win-ai-search-pick-0')));
        await tester.pumpAndSettle();
        expect(client.searchedKeywords, contains('盗梦空间'));

        // 5. 「我的」 -> 「AI 为你挑片」 now visible -> generates picks -> triggers search
        await tester.tap(find.text('我的').first);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-ai-picks-btn')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('windows-ai-picks-btn')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('windows-ai-picks-generate-btn')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('盗梦空间'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('win-ai-picks-select-0')));
        await tester.pumpAndSettle();

        // 6. DetailScreen -> 「AI 净化选集」 cleans messy netdisk filename cleanly
        const messyVideo = CmsVideo(
          id: 'messy1',
          title: '三体',
          lines: <CmsLine>[
            CmsLine(
              name: '网盘主线',
              episodes: <CmsEpisode>[
                CmsEpisode(
                  name: '[SubGroup] Three.Body.2023.S01E01.2160p.HEVC.10bit.mkv',
                  url: 'https://owned.invalid/ep1.mkv',
                ),
              ],
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: DetailScreen(
              site: const CmsSite(
                key: 's1',
                name: '主源',
                type: 1,
                api: 'https://owned.invalid/api',
              ),
              initialVideo: messyVideo,
              client: client,
              storage: storage,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('windows-detail-episode-toggle')),
        );
        await tester.pumpAndSettle();
        final aiCleanBtn =
            find.byKey(const ValueKey('windows-detail-ai-clean-episodes'));
        expect(aiCleanBtn, findsOneWidget);
        await tester.tap(aiCleanBtn);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-detail-ai-clean-notice')),
          findsOneWidget,
        );
        expect(find.text('S01E01'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
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
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_launch_splash.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/official_channel_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _buildFakeJwt(Map<String, dynamic> claims) {
  String b64Url(Map<String, dynamic> obj) =>
      base64Url.encode(utf8.encode(jsonEncode(obj))).replaceAll('=', '');
  final header = b64Url({'alg': 'RS256', 'typ': 'JWT'});
  final payload = b64Url(claims);
  return '$header.$payload.sig_fixture';
}

/// Ephemeral RFC 8032 Ed25519 test signer (generates random seeds per test run,
/// zero static keys).
class _EphemeralEd25519Signer {
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

  static String issueLabToken(
    Uint8List seed32, {
    required int expEpochSec,
    String tag = 'PILIPALA',
    String plat = 'all',
    bool shared = false,
    bool expOAuth = false,
    int minVc = 0,
  }) {
    final map = <String, Object>{
      'exp': expEpochSec,
      'iat': 1700000000,
      'plat': plat,
      'shared': shared,
      'tag': tag,
      'v': 1,
      if (expOAuth) 'exp_oauth': true,
      if (minVc > 0) 'min_vc': minVc,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiLabGate.debugPublicKeyHexOverride = null;
    OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = false;
    IosLiquidGlassBridge.setAvailableForTest(false);
  });

  tearDown(() {
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiLabGate.debugPublicKeyHexOverride = null;
    OnboardingPrefs.debugEnablePostUpdateAutoPopInTest = false;
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  group('Item 1: AI Lab Dual-Auth (ChatGPT OAuth PKCE + API) & Live Model Picker', () {
    test(
      'PKCE request builds S256 challenge, exchanges callback code, extracts JWT plan/account, and isolates tokens in Keychain',
      () async {
        final secure = InMemorySecureCredentialStore();
        final expSeconds =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
        final openAiAuthClaimKey =
            ['https://', 'api.openai', '.com/auth'].join();
        final idToken = _buildFakeJwt({
          'email': 'pro_member@ai.example',
          'exp': expSeconds,
          openAiAuthClaimKey: {
            'chatgpt_account_id': 'acct_marco_001',
            'chatgpt_plan_type': 'plus',
          },
        });
        Map<String, dynamic>? tokenBody;
        final mockHttp = MockClient((req) async {
          if (req.url.path.endsWith('/oauth/token')) {
            tokenBody =
                jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'access_token': idToken,
                'refresh_token': 'rt_marco_secret_001',
                'id_token': idToken,
                'expires_in': 3600,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('not found', 404);
        });

        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        ai.configureForTest(
          codexTokenEndpoint: 'https://auth.ai.example/oauth/token',
          labUnlockedForTest: true,
        );
        final pkce = AiService.createCodexPkceRequest();
        expect(
          pkce.authorizeUri.queryParameters['client_id'],
          AiService.codexClientId,
        );
        expect(pkce.authorizeUri.queryParameters['code_challenge_method'], 'S256');
        expect(pkce.redirectUri, 'http://localhost:1455/auth/callback');

        final session = await ai.completeManualOAuthInput(
          'http://localhost:1455/auth/callback?code=auth_code_xyz&state=${pkce.state}',
          pendingRequest: pkce,
        );
        expect(tokenBody?['code'], 'auth_code_xyz');
        expect(tokenBody?['code_verifier'], pkce.codeVerifier);
        expect(session.accountId, 'acct_marco_001');
        expect(session.planType, 'plus');
        expect(session.email, 'pro_member@ai.example');

        // Verify refresh_token never leaks into SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final rawPrefs = prefs.getString(AiService.prefsConfigKey) ?? '';
        expect(rawPrefs.contains('rt_marco_secret_001'), isFalse);
        expect(
          (await secure.read(AiService.secureOAuthSessionSlot)) ?? '',
          contains('acct_marco_001'),
        );
      },
    );

    test(
      'Codex OAuth mode fetches /codex/models and streams SSE responses with bare application/json header',
      () async {
        final secure = InMemorySecureCredentialStore();
        final expSeconds =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
        final openAiAuthClaimKey =
            ['https://', 'api.openai', '.com/auth'].join();
        final jwt = _buildFakeJwt({
          'email': 'codex@ai.example',
          'exp': expSeconds,
          openAiAuthClaimKey: {
            'chatgpt_account_id': 'acct_codex_77',
            'chatgpt_plan_type': 'pro',
          },
        });

        String? capturedContentType;
        String? capturedAccountId;
        String? capturedOriginator;

        final mockHttp = MockClient.streaming((req, bodyStream) async {
          await bodyStream.drain<void>();
          if (req.url.path.endsWith('/codex/models')) {
            final payload = utf8.encode(
              jsonEncode({
                'models': [
                  {
                    'slug': 'gpt-5.3-codex',
                    'display_name': 'GPT-5.3 Codex',
                    'priority': 10,
                  },
                  {
                    'slug': 'gpt-5.4-mini',
                    'display_name': 'GPT-5.4 Mini',
                    'priority': 20,
                  },
                ],
              }),
            );
            return http.StreamedResponse(
              Stream.value(payload),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (req.url.path.endsWith('/codex/responses')) {
            capturedContentType =
                req.headers['Content-Type'] ?? req.headers['content-type'];
            capturedAccountId = req.headers['Chatgpt-Account-Id'] ??
                req.headers['chatgpt-account-id'];
            capturedOriginator =
                req.headers['Originator'] ?? req.headers['originator'];
            final sse = [
              'event: response.output_text.delta',
              'data: {"type":"response.output_text.delta","delta":"OK"}',
              '',
              'event: response.completed',
              'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":8}}}',
              '',
            ].join('\n');
            return http.StreamedResponse(
              Stream.value(utf8.encode(sse)),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
        });

        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        ai.configureForTest(
          codexModelsEndpoint: 'https://codex.ai.example/backend-api/codex/models',
          codexResponsesEndpoint:
              'https://codex.ai.example/backend-api/codex/responses',
          labUnlockedForTest: true,
        );
        await ai.setOAuthSession(
          AiOAuthSession(
            accessToken: jwt,
            refreshToken: 'rt_codex',
            expiresAtEpochMs: expSeconds * 1000,
            accountId: 'acct_codex_77',
            email: 'codex@ai.example',
            planType: 'pro',
          ),
        );
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'gpt-5.3-codex',
          ),
        );

        final models = await ai.fetchAvailableModelOptions();
        expect(
          models.map((m) => m.id),
          containsAll(['gpt-5.3-codex', 'gpt-5.4-mini']),
        );

        final probe = await ai.testConnection();
        expect(probe.ok, isTrue, reason: probe.messageZh);
        expect(capturedContentType, 'application/json');
        expect(capturedAccountId, 'acct_codex_77');
        expect(capturedOriginator, 'codex_cli_rs');
      },
    );

    test(
      'OpenAI reasoning model HTTP 400 on max_tokens/temperature retries cleanly with max_completion_tokens',
      () async {
        final secure = InMemorySecureCredentialStore();
        int calls = 0;
        Map<String, dynamic>? secondBody;
        final mockHttp = MockClient((req) async {
          calls++;
          final decoded =
              jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'error': {
                  'message':
                      "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
                },
              }),
              400,
              headers: {'content-type': 'application/json'},
            );
          }
          secondBody = decoded;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'OK'},
                },
              ],
              'usage': {'prompt_tokens': 8, 'completion_tokens': 4},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        ai.configureForTest(labUnlockedForTest: true);
        await ai.setApiKey('sk-test-fixture-key');
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            protocol: AiApiProtocol.openaiCompatible,
            baseUrl: 'https://api.ai-gateway.example/v1',
            model: 'GPT 5.2 Pro',
          ),
        );

        final res = await ai.testConnection();
        expect(res.ok, isTrue, reason: res.messageZh);
        expect(calls, greaterThanOrEqualTo(1));
        if (secondBody != null) {
          expect(secondBody?.containsKey('max_completion_tokens'), isTrue);
        }
      },
    );
  });

  group('Ed25519 Offline Signed Passcode Gate & 5 Core AI Lab Scenarios', () {
    test(
      'Ed25519 passcode gate locks AI Lab by default, rejects tampered/expired tokens, and unlocks offline with valid signature',
      () async {
        final seed = _EphemeralEd25519Signer.randomSeed();
        final wrongSeed = _EphemeralEd25519Signer.randomSeed();
        AiLabGate.debugPublicKeyHexOverride =
            _EphemeralEd25519Signer.publicKeyHex(seed);

        final secure = InMemorySecureCredentialStore();
        final ai = AiService(
          secureStorage: secure,
          clock: () => DateTime.fromMillisecondsSinceEpoch(1700005000 * 1000),
        );
        await ai.ensureLoaded();
        expect(ai.isLabUnlocked, isFalse);

        // 1. Wrong signing key rejected
        final wrongKeyTok = _EphemeralEd25519Signer.issueLabToken(
          wrongSeed,
          expEpochSec: 0,
        );
        await expectLater(
          ai.unlockAiLab(wrongKeyTok),
          throwsA(isA<FormatException>()),
        );
        expect(ai.isLabUnlocked, isFalse);

        // 2. Expired token rejected
        final expiredTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 1700001000,
        );
        await expectLater(
          ai.unlockAiLab(expiredTok),
          throwsA(isA<FormatException>()),
        );
        expect(ai.isLabUnlocked, isFalse);

        // 3. Valid token wrapped in announcement text unlocks & persists in Keychain
        final validTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 0,
          tag: 'PILIPALA内测',
        );
        final claims = await ai.unlockAiLab('【体验口令】复制整段解锁：$validTok 谢谢支持');
        expect(ai.isLabUnlocked, isTrue);
        expect(claims.tag, 'PILIPALA内测');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(AiLabPasscodeStore.prefsPasscodeKey), validTok);
      },
    );

    testWidgets(
      'IosAiSettingsPage displays passcode gate when locked and reveals full AI Lab + model picker after valid Ed25519 passcode',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final seed = _EphemeralEd25519Signer.randomSeed();
        AiLabGate.debugPublicKeyHexOverride =
            _EphemeralEd25519Signer.publicKeyHex(seed);
        final validTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 0,
          tag: 'VIP测试',
        );

        final secure = InMemorySecureCredentialStore(<String, String>{
          AiService.secureApiKeySlot: 'sk-model-picker-test',
        });
        final mockHttp = MockClient((req) async {
          if (req.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'gpt-4.1-mini'},
                  {'id': 'deepseek-chat'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200);
        });
        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            baseUrl: 'https://api.ai-gateway.example/v1',
          ),
        );

        await tester.pumpWidget(
          MaterialApp(home: IosAiSettingsPage(service: ai)),
        );
        await tester.pumpAndSettle();

        // Locked: shows passcode gate card, hides auth/API controls
        expect(find.byKey(const ValueKey('ios-ai-lab-gate-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-auth-mode-segment')), findsNothing);

        // Invalid input shows error
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-lab-passcode-field')),
          'invalid-passcode',
        );
        await tester.tap(find.byKey(const ValueKey('ios-ai-lab-unlock-btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-ai-lab-gate-error')), findsOneWidget);

        // Valid Ed25519 passcode unlocks immediately
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-lab-passcode-field')),
          validTok,
        );
        await tester.tap(find.byKey(const ValueKey('ios-ai-lab-unlock-btn')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ios-ai-lab-gate-card')), findsNothing);
        expect(find.byKey(const ValueKey('ios-ai-auth-mode-segment')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-subtranslate-switch')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-watchbrief-switch')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-mood-switch')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-diag-switch')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-add-skill-btn')), findsOneWidget);
      },
    );

    test(
      'All 5 Core AI Lab Scenarios execute cleanly with glossary lock, spoiler boundary, episode curating, mood picks, and desensitized diagnostics',
      () async {
        final secure = InMemorySecureCredentialStore(<String, String>{
          AiService.secureApiKeySlot: 'sk-lab-5-scenarios',
        });
        String lastPrompt = '';
        final mockHttp = MockClient((req) async {
          final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
          lastPrompt = jsonEncode(body['messages']);
          String replyJson = '{}';
          if (lastPrompt.contains('待译字幕 JSON')) {
            replyJson = jsonEncode({
              'glossary': {'Paul Atreides': '保罗·厄崔迪'},
              'items': [
                {'i': 0, 'zh': '保罗·厄崔迪必须直面沙漠。'},
              ],
            });
          } else if (lastPrompt.contains('信息边界')) {
            replyJson = jsonEncode({
              'recap': '前四集讲述了主角初入厄拉科斯星球的危机。',
              'characters': [
                {'name': '保罗', 'role': '厄崔迪家族继承人', 'summary': '随家族迁往沙丘星球'}
              ],
              'trivia': '香料是宇宙航行的核心资源。',
            });
          } else if (lastPrompt.contains('剧集条目样本')) {
            replyJson = jsonEncode({
              'canonicalTitle': '沙丘：预言',
              'seasonNumber': 1,
              'episodeOffset': -1,
              'specialIndices': [0],
              'summary': '已剔除先导预告并将正片集号减 1 对齐',
            });
          } else if (lastPrompt.contains('当前心情/需求')) {
            replyJson = jsonEncode({
              'tastePortrait': '钟爱宏大深邃的太空史诗与哲思科幻。',
              'picks': [
                {
                  'title': '银翼杀手2049',
                  'year': '2017',
                  'moodTag': '雨夜科幻',
                  'reason': '冷峻克制的未来视觉诗篇',
                }
              ],
            });
          } else if (lastPrompt.contains('脱敏异常信息')) {
            replyJson = jsonEncode({
              'rootCause': '当前 HEVC 10bit 封装在系统硬解下不兼容',
              'steps': ['切换至 MPV 软硬解内核重试'],
              'actions': ['switch_to_mpv', 'enable_vocal_loudness'],
            });
          } else {
            replyJson = '这段经典独白隐喻了人在命运洪流中的抉择。';
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': replyJson}
                  }
                ],
                'usage': {'prompt_tokens': 30, 'completion_tokens': 40},
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        ai.configureForTest(labUnlockedForTest: true);
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            baseUrl: 'https://api.ai-gateway.example/v1',
            model: 'gpt-4.1-mini',
          ),
        );
        final lab = AiLabService(ai);

        // Scenario 1: SRT parse + bilingual translate + glossary lock
        final cues = AiLabService.parseSubtitleDocument(
          '1\n00:00:02,000 --> 00:00:05,500\nPaul Atreides must face the desert.\n',
        );
        expect(cues.length, 1);
        final subRes = await lab.translateSubtitleCues(
          seriesTitle: 'Dune',
          cues: cues,
          bilingual: true,
        );
        expect(subRes.glossary['Paul Atreides'], '保罗·厄崔迪');
        expect(subRes.srtContent, contains('保罗·厄崔迪必须直面沙漠。'));
        expect(subRes.srtContent, contains('Paul Atreides must face the desert.'));

        // Scenario 2: Zero-spoiler companion (Episode 5 -> locks to Ep 1..4)
        final comp = await lab.generateEpisodeCompanion(
          title: '沙丘剧集',
          currentEpisodeNumber: 5,
        );
        expect(comp.boundaryLabel, contains('第 4 集'));
        expect(comp.characters.single.name, '保罗');

        // Scenario 3: Messy netdisk episode curating & cross-source ranking
        final plan = await lab.curateMessyEpisodes(
          rawSeriesTitle: '[4K] 沙丘：预言',
          episodes: const [
            CmsEpisode(name: '00_先导预告_SP.mp4', url: 'https://media.example/0.mp4'),
            CmsEpisode(name: 'E02_正片第一集.mkv', url: 'https://media.example/1.mp4'),
          ],
        );
        expect(plan.toScrapeOverride().episodeOffset, -1);
        expect(plan.canonicalTitle, '沙丘：预言');
        final ranked = AiLabService.rankCrossSourceMatches('沙丘', const [
          (
            CmsSite(key: 's1', name: '普通源', type: 1, api: 'https://a.example/vod'),
            CmsVideo(id: '1', title: '沙丘', remarks: '720P'),
          ),
          (
            CmsSite(key: 's2', name: '臻彩源', type: 1, api: 'https://b.example/vod'),
            CmsVideo(id: '2', title: '沙丘 4K Remux DV', remarks: '2160P 原盘'),
          ),
        ]);
        expect(ranked.first.site.key, 's2');
        expect(ranked.first.badgeLabel, contains('Remux'));

        // Scenario 4: Mood sommelier matched against local library
        const libSite = CmsSite(
          key: 'emby1',
          name: '家庭 Emby',
          type: 1,
          api: 'https://emby.example/api',
        );
        const libVid = CmsVideo(id: 'v2049', title: '银翼杀手2049', year: '2017');
        final mood = await lab.curateMoodWatchlist(
          recentHistoryTitles: const ['沙丘'],
          favoriteTitles: const ['星际穿越'],
          availableLibrarySnapshot: const [(libSite, libVid)],
          moodPrompt: '雨夜科幻',
        );
        expect(mood.picks.single.isPlayableInLibrary, isTrue);

        // Scenario 5: Desensitized diagnostics + Custom Skill execution
        final diag = await lab.diagnosePlaybackOrSourceIssue(
          rawErrorText:
              'HTTP 403 on https://nas.example/movie.mkv?token=super_secret_99 from 10.0.0.8',
          engineName: 'AVPlayer',
        );
        expect(lastPrompt.contains('super_secret_99'), isFalse);
        expect(
          diag.suggestedActions,
          contains(AiDiagnosticActionId.switchToMpv),
        );

        final skillOut = await lab.runCustomSkill(
          skill: AiCustomSkill.defaultBuiltInSkills.first,
          title: '银翼杀手2049',
          year: '2017',
        );
        expect(skillOut, contains('独白'));
      },
    );
  });

  group('Donate Card in About/Update & Post-Update First-Open Popup', () {
    testWidgets(
      'IosSupportDeveloperCard jumps to https://marcotv.wlj9919.top/movie/#donate and PostUpdateWelcomeDialog shows once per version upgrade',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // 1. Verify About/Update sponsorship card opens exact #donate anchor
        final openedUris = <Uri>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IosSupportDeveloperCard(
                urlOpener: (uri) async {
                  openedUris.add(uri);
                  return true;
                },
              ),
            ),
          ),
        );
        expect(find.byKey(const ValueKey('ios-about-donate-card')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('ios-about-donate-jump-btn')));
        await tester.pumpAndSettle();
        expect(
          openedUris.single.toString(),
          'https://marcotv.wlj9919.top/movie/#donate',
        );

        // 2. Verify PostUpdateWelcomeDialog triggers when upgrading 0.7.9 -> 0.7.10, then persists
        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
          OnboardingPrefs.lastSeenAppVersionKey: '0.7.9',
        });
        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcomovie',
          version: '0.7.10',
          buildNumber: '110',
          buildSignature: '',
        );
        final storage = await StorageService.init();
        final client = CmsClient(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

        openedUris.clear();
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: client,
              onOpenExternalUrlForTest: (uri) async {
                openedUris.add(uri);
                return true;
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(PostUpdateWelcomeDialog), findsOneWidget);
        expect(find.textContaining('谨防受骗'), findsOneWidget);
        expect(find.textContaining('唯一官方更新渠道'), findsWidgets);

        await tester.tap(find.byKey(const ValueKey('post-update-donate-btn')));
        await tester.pump();
        expect(
          openedUris.last.toString(),
          'https://marcotv.wlj9919.top/movie/#donate',
        );

        await tester.ensureVisible(
          find.byKey(const ValueKey('post-update-confirm-btn')),
        );
        await tester.tap(find.byKey(const ValueKey('post-update-confirm-btn')));
        await tester.pumpAndSettle();
        expect(find.byType(PostUpdateWelcomeDialog), findsNothing);

        final prefs = await OnboardingPrefs.load();
        expect(prefs.lastSeenAppVersion, startsWith('0.7.10'));
        expect(prefs.shouldShowPostUpdateNotice('0.7.10'), isFalse);
        expect(prefs.shouldShowPostUpdateNotice('0.7.11'), isTrue);
      },
    );
  });

  group('Items 2, 3, 5, 6 & 7: Dock, Player HUD, Launch Curtain, iPad Window & Chinese/Gitee Subscriptions', () {
    test(
      'MarcoLiquidGlass.swift anchors Dock menu above capsule & expands More popover height; prepare_platform.py uses transparent LOGO_MARK & reconciles iPad UIWindowScene',
      () {
        final swift = File('ios_native/MarcoLiquidGlass.swift').readAsStringSync();
        expect(
          swift.contains('let anchorY: CGFloat = globalOriginY < 140.0 ? (bounds.height + 8.0) : -10.0'),
          isTrue,
        );
        expect(swift.contains('preferredMenuElementOrder = .fixed'), isTrue);
        expect(swift.contains('316.0'), isTrue);
        expect(swift.contains('520.0'), isTrue);

        final py = File('prepare_platform.py').readAsStringSync();
        expect(py.contains('"import SafariServices"'), isTrue);
        expect(
          py.contains(
            'LOGO_MARK if LOGO_MARK.exists() else (IOS_ICON if IOS_ICON.exists() else OPAQUE_ICON)',
          ),
          isTrue,
        );
        expect(py.contains('("LaunchImage@3x.png", 228)'), isTrue);
        expect(py.contains('reconcileLaunchWindowAndSurface'), isTrue);
      },
    );

    testWidgets(
      'IosPlayerChrome bottom deck removes tracks/loudness/engine from primary bar',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IosPlayerChrome(
                title: '测试影片',
                episodeName: '第 01 集',
                lineName: '主力线',
                isLive: false,
                playing: true,
                loading: false,
                buffering: false,
                hasError: false,
                position: const Duration(minutes: 5),
                duration: const Duration(minutes: 45),
                isScrubbing: false,
                scrubPositionMs: 0,
                playbackSpeed: 1.0,
                skipIntroSec: 0,
                skipOutroSec: 0,
                specBadges: const [],
                fallbackSpecsLabel: '',
                specBadgesExpanded: false,
                isLandscape: true,
                portraitCompanionBox: false,
                danmuEnabled: true,
                sleepTimerActive: false,
                hasMultipleLines: true,
                isFavorite: false,
                isCasting: false,
                isDownloading: false,
                storageReduceTransparency: false,
                vocalLoudnessActive: true,
                engineLabel: 'AVPlayer',
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
        await tester.pump();

        expect(find.text('选集'), findsOneWidget);
        expect(find.text('线路'), findsOneWidget);
        expect(find.text('倍速'), findsOneWidget);
        expect(find.text('弹幕/字幕'), findsOneWidget);
        expect(find.text('画面'), findsOneWidget);
        expect(find.text('播放器'), findsOneWidget);
        expect(find.text('音轨'), findsOneWidget);
        expect(find.text('片头片尾'), findsOneWidget);
        expect(find.text('更多'), findsOneWidget);
        expect(find.text('响度'), findsNothing);
      },
    );

    testWidgets(
      'IosLaunchCurtainHost plays non-blocking specular dissolve and disposes ticker cleanly',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        IosLaunchCurtainHost.debugEnableInTest = true;
        addTearDown(() => IosLaunchCurtainHost.debugEnableInTest = false);

        int tapped = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: IosLaunchCurtainHost(
              child: Scaffold(
                body: Center(
                  child: CupertinoButton(
                    key: const ValueKey('underneath-shell-btn'),
                    onPressed: () => tapped++,
                    child: const Text('进入主页'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('marco-ios-launch-curtain')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('underneath-shell-btn')));
        expect(tapped, 1);

        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('marco-ios-launch-curtain')), findsNothing);
      },
    );

    test(
      'Chinese-path / Gitee URL normalization & Android spider.jar subscription diagnostics',
      () {
        final giteeHost = ['https://', 'gitee', '.com'].join();
        expect(
          CmsParser.extractAndNormalizeUrl(
            '$giteeHost/LG_Pro/config/raw/master/聚合/api.json，这类订阅源',
          ),
          '$giteeHost/LG_Pro/config/raw/master/%E8%81%9A%E5%90%88/api.json',
        );
        expect(
          CmsParser.normalizeUrl(
            '$giteeHost/LG_Pro/config/blob/master/聚合/api.json',
          ),
          '$giteeHost/LG_Pro/config/raw/master/%E8%81%9A%E5%90%88/api.json',
        );
        const signedRedirect =
            'https://cdn.repo.example/LG_Pro/config/raw/master/%E8%81%9A%E5%90%88/api.json?signature=abc-123_XYZ%3D%3D';
        expect(CmsParser.normalizeUrl(signedRedirect), signedRedirect);

        final rawConfig = jsonEncode({
          'spider':
              'https://repo.example/LG_Pro/config/raw/master/聚合/spider.jar;md5;0b8e2bd1926a0dcfb0257730235e8e32',
          'sites': [
            {
              'key': 'LG_douban_search',
              'name': '群123456┃豆瓣搜索',
              'type': 3,
              'api': 'csp_DoubanSearch',
            },
            {
              'key': 'LG_douban',
              'name': '豆瓣荐片',
              'type': 3,
              'api': 'csp_Douban',
            },
            {
              'key': 'LG_about',
              'name': '关于说明',
              'type': 3,
              'api': 'csp_About',
            },
            for (int i = 0; i < 12; i++)
              {
                'key': 'LG_jar_$i',
                'name': '专线$i',
                'type': 3,
                'api': 'csp_CustomJarSite$i',
              },
          ],
          'lives': [
            {
              'name': '测试直播',
              'type': 0,
              'url': 'https://live.example/iptv.m3u',
            },
          ],
        });
        final parsed = CmsParser.parseConfig(
          rawConfig,
          origin: 'https://repo.example/LG_Pro/config/raw/master/聚合/api.json',
        );
        final notice = CspBridge.buildSubscriptionRuntimeLimitationNotice([
          SubscriptionEntry(
            id: 'sub_test_lg',
            name: '聚合测试',
            url: 'https://repo.example/LG_Pro/config/raw/master/%E8%81%9A%E5%90%88/api.json',
            rawContent: rawConfig,
            siteCount: parsed.supportedSites.length,
            liveCount: parsed.lives.length,
            updatedAt: 1,
          ),
        ]);
        expect(notice, isNotNull);
        expect(notice!.message, contains('12 个点播站依赖专属加密 Android JAR 插件'));
      },
    );
  });

  group('Unified 3-Platform AI Viewing Lab Passcode Gate (iOS / Windows / Android Mobile)', () {
    const realUniversalToken =
        'MMAILAB1.eyJleHAiOjE3OTgzMDI5NDAsImlhdCI6MTc5NTcxMDk0MCwibiI6IjllNjAwYyIsInBsYXQiOiJhbGwiLCJzaGFyZWQiOnRydWUsInRhZyI6ImNoYW5uZWwtMDEiLCJ2IjoxfQ.i-wBNpbuTEmMaCnJYvCoeBttxHWKrM5JQCGhmxO9nsGf1KbnkrvuWvDvoY5xlAMrC7570oMIXC_IHlboqFQZBQ';

    test(
      'Real offline phone-keygen universal token verifies on iOS with embedded official public key and enforces auto-relock after exp',
      () async {
        // Verify with ZERO public-key override against embedded official key
        expect(
          AiLabPasscodeVerifier.defaultPublicKeyHex,
          '1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929',
        );
        var currentEpochSec = 1795720000; // within [iat=1795710940, exp=1798302940]
        AiLabPasscodeStore.instance.configureForTest(
          targetPlatform: 'ios',
          clock: () =>
              DateTime.fromMillisecondsSinceEpoch(currentEpochSec * 1000, isUtc: true),
          resetState: true,
        );
        AiService.instance.configureForTest(
          clock: () =>
              DateTime.fromMillisecondsSinceEpoch(currentEpochSec * 1000, isUtc: true),
          labUnlockedForTest: null,
          resetState: true,
        );

        final wrapped = '【Marco交流区内测口令】\n$realUniversalToken\n请复制整段粘贴开启';
        final verifyRes =
            await AiLabPasscodeStore.instance.unlockWithPasscode(wrapped);
        expect(verifyRes.isValid, isTrue, reason: verifyRes.messageZh);
        expect(verifyRes.canonicalToken, realUniversalToken);
        expect(verifyRes.payload?.tag, 'channel-01');
        expect(verifyRes.payload?.platform, 'all');
        expect(verifyRes.payload?.platformScopeLabelZh, '三端通用');
        expect(verifyRes.payload?.shared, isTrue);
        expect(verifyRes.payload?.experimentalOAuth, isFalse);
        expect(AiLabPasscodeStore.instance.isUnlocked, isTrue);
        expect(AiService.instance.isLabUnlocked, isTrue);
        expect(AiService.instance.isExperimentalOAuthAllowed, isFalse);

        // Persists signed token string, NOT a plaintext boolean switch
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(AiLabPasscodeStore.prefsPasscodeKey),
          realUniversalToken,
        );

        // Advancing time past exp (1798302940) automatically re-locks both store & AiService
        currentEpochSec = 1798302941;
        expect(AiLabPasscodeStore.instance.isUnlocked, isFalse);
        expect(AiLabPasscodeStore.instance.activePayload, isNull);
        expect(AiService.instance.isLabUnlocked, isFalse);

        // AiService blocks direct bypass calls when locked/expired
        await expectLater(
          AiService.instance.complete(
            feature: 'bypass_probe',
            userPrompt: 'hello',
            ignoreEnabledFlag: true,
          ),
          throwsA(
            isA<AiServiceException>().having(
              (e) => e.code,
              'code',
              AiErrorCode.disabled,
            ),
          ),
        );
      },
    );

    test(
      'Platform scope rejects plat="android" and plat="windows" on iOS, accepts plat="ios,android", rejects tampered signatures, and gates exp_oauth',
      () async {
        final seed = _EphemeralEd25519Signer.randomSeed();
        AiLabPasscodeVerifier.debugPublicKeyHexOverride =
            _EphemeralEd25519Signer.publicKeyHex(seed);
        final now = DateTime.fromMillisecondsSinceEpoch(1700005000 * 1000, isUtc: true);

        // 1. plat="android" rejected on iOS
        final androidOnlyTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 0,
          plat: 'android',
          tag: 'and-only',
        );
        final andRes = AiLabPasscodeVerifier.verify(
          androidOnlyTok,
          targetPlatform: 'ios',
          now: now,
        );
        expect(andRes.isValid, isFalse);
        expect(andRes.status, AiLabPasscodeStatus.wrongPlatform);
        expect(andRes.messageZh, contains('仅限 安卓'));

        // 2. plat="windows" rejected on iOS
        final winOnlyTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 0,
          plat: 'windows',
          tag: 'win-only',
        );
        final winRes = AiLabPasscodeVerifier.verify(
          winOnlyTok,
          targetPlatform: 'ios',
          now: now,
        );
        expect(winRes.isValid, isFalse);
        expect(winRes.status, AiLabPasscodeStatus.wrongPlatform);
        expect(winRes.messageZh, contains('仅限 Windows'));

        // 3. plat="ios,android" accepted on iOS and rejected on Windows
        final iosAndTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 0,
          plat: 'ios,android',
          shared: true,
          expOAuth: true,
          tag: 'mobile-dual',
        );
        final iosRes = AiLabPasscodeVerifier.verify(
          iosAndTok,
          targetPlatform: 'ios',
          now: now,
        );
        expect(iosRes.isValid, isTrue, reason: iosRes.messageZh);
        expect(iosRes.payload?.platformScopeLabelZh, '仅限 安卓/iOS');
        expect(iosRes.payload?.experimentalOAuth, isTrue);

        final winCheckDual = AiLabPasscodeVerifier.verify(
          iosAndTok,
          targetPlatform: 'windows',
          now: now,
        );
        expect(winCheckDual.status, AiLabPasscodeStatus.wrongPlatform);

        // 4. Tampered signature rejected (flip first char of signature segment so base64 padding bits stay valid)
        final segs = iosAndTok.split('.');
        final sig = segs[2];
        final flippedFirst = sig[0] == 'A' ? 'B' : 'A';
        final tampered = '${segs[0]}.${segs[1]}.$flippedFirst${sig.substring(1)}';
        final tamperedRes = AiLabPasscodeVerifier.verify(
          tampered,
          targetPlatform: 'ios',
          now: now,
        );
        expect(tamperedRes.isValid, isFalse);
        expect(tamperedRes.status, AiLabPasscodeStatus.invalidSignature);

        // 5. exp_oauth enforcement in AiService
        AiLabPasscodeStore.instance.configureForTest(
          targetPlatform: 'ios',
          clock: () => now,
          resetState: true,
        );
        AiService.instance.configureForTest(
          clock: () => now,
          labUnlockedForTest: null,
          resetState: true,
        );
        final noOAuthTok = _EphemeralEd25519Signer.issueLabToken(
          seed,
          expEpochSec: 0,
          plat: 'ios',
          expOAuth: false,
        );
        await AiService.instance.unlockAiLab(noOAuthTok);
        expect(AiService.instance.isLabUnlocked, isTrue);
        expect(AiService.instance.isExperimentalOAuthAllowed, isFalse);
        await expectLater(
          AiService.instance.completeManualOAuthInput('code=abc'),
          throwsA(
            isA<AiServiceException>().having(
              (e) => e.code,
              'code',
              AiErrorCode.unauthorized,
            ),
          ),
        );
      },
    );

    testWidgets(
      'Locked iOS shell hides AI entries, shows single-row AI 观影实验室 (内测中 · 输入口令开启), opens Marco交流区 link, extracts clipboard token, and supports replace/re-lock',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Mock clipboard holding announcement prose + real 3-platform token
        String mockClipboardText =
            '欢迎加入【Marco交流区】体验三端通用内测口令：\n$realUniversalToken\n有效期一个月';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': mockClipboardText};
          }
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>?;
            mockClipboardText = (args?['text'] ?? '').toString();
            return null;
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        final fixedNow = DateTime.fromMillisecondsSinceEpoch(
          1795720000 * 1000,
          isUtc: true,
        );
        AiLabPasscodeStore.instance.configureForTest(
          clock: () => fixedNow,
          resetState: true,
        );
        AiService.instance.configureForTest(
          secureStorage: InMemorySecureCredentialStore(),
          clock: () => fixedNow,
          labUnlockedForTest: null,
          resetState: true,
        );
        // Runtime targetPlatform on TargetPlatform.iOS must automatically resolve to 'ios'
        expect(AiLabPasscodeStore.instance.effectiveTargetPlatform, 'ios');

        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
          OnboardingPrefs.lastSeenAppVersionKey: '0.7.10',
        });
        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcomovie',
          version: '0.7.10',
          buildNumber: '110',
          buildSignature: '',
        );
        final storage = await StorageService.init();
        final client = CmsClient(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );
        final openedUrls = <Uri>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: client,
              onOpenExternalUrlForTest: (uri) async {
                openedUrls.add(uri);
                return true;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));

        // 1. Check Library tab while locked: AI sommelier button is strictly hidden
        await tester.tap(find.text('片库').last);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library-open-ai-sommelier')),
          findsNothing,
        );

        // 2. Open Settings tab -> single-row "AI 观影实验室" ("内测中 · 输入口令开启")
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        final aiCategory = find.byKey(const ValueKey('settings-category-ai'));
        await tester.ensureVisible(aiCategory);
        await tester.pumpAndSettle();
        expect(find.text('AI 观影实验室'), findsOneWidget);
        expect(find.textContaining('内测中 · 输入口令开启'), findsWidgets);

        // 3. Tap locked row -> opens passcode popup sheet
        await tester.tap(aiCategory);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ios-ai-lab-passcode-sheet')),
          findsOneWidget,
        );

        // 4. Tap 【Marco交流区】 link -> opens https://pd.qq.com/s/N45e3aaawv?b=9
        await tester.tap(find.byKey(const ValueKey('ios-ai-lab-community-btn')));
        await tester.pumpAndSettle();
        expect(
          openedUrls.last.toString(),
          'https://pd.qq.com/s/N45e3aaawv?b=9',
        );

        // 5. Tap paste clipboard -> auto-extracts MMAILAB1... and unlocks into IosAiSettingsPage
        await tester.tap(find.byKey(const ValueKey('ios-ai-lab-paste-btn')));
        await tester.pumpAndSettle();
        final pastedText = tester
            .widget<CupertinoTextField>(
              find.byKey(const ValueKey('ios-ai-lab-passcode-field')),
            )
            .controller
            ?.text;
        expect(pastedText, realUniversalToken);
        await tester.tap(find.byKey(const ValueKey('ios-ai-lab-unlock-btn')));
        await tester.pumpAndSettle();
        expect(
          AiLabPasscodeStore.instance.isUnlocked,
          isTrue,
          reason:
              'err=${find.byKey(const ValueKey("ios-ai-lab-gate-error")).evaluate().isNotEmpty ? tester.widget<Text>(find.byKey(const ValueKey("ios-ai-lab-gate-error"))).data : "none"} '
              'sheetStillOpen=${find.byKey(const ValueKey("ios-ai-lab-passcode-sheet")).evaluate().isNotEmpty} '
              'settingsPageOpen=${find.byKey(const ValueKey("ios-ai-settings-page")).evaluate().isNotEmpty}',
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ios-ai-lab-unlocked-card')),
          findsOneWidget,
        );
        expect(find.textContaining('channel-01'), findsWidgets);
        expect(find.textContaining('三端通用'), findsWidgets);
        expect(find.byKey(const ValueKey('ios-ai-lab-replace-btn')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-lab-lock-btn')), findsOneWidget);

        // 6. Tap "退出内测并重新锁定" -> re-locks immediately and hides AI configuration
        await tester.tap(find.byKey(const ValueKey('ios-ai-lab-lock-btn')));
        await tester.pumpAndSettle();
        expect(AiLabPasscodeStore.instance.isUnlocked, isFalse);
        expect(AiService.instance.isLabUnlocked, isFalse);
        expect(find.byKey(const ValueKey('ios-ai-lab-gate-card')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-enable-switch')), findsNothing);
      },
    );
  });
}

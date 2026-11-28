// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec, gzip;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_danmu_matcher.dart';
import 'package:marco_movie/core/ai_lab_gate.dart';
import 'package:marco_movie/core/ai_lab_passcode.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/danmu/dandanplay_provider.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/danmu/segment_cache.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/ui/ios_ai_lab_sheets.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SlowSecureCredentialStore implements SecureStorageBackend {
  final InMemorySecureCredentialStore inner = InMemorySecureCredentialStore();

  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return inner.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await inner.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await inner.delete(key);
  }
}

class _NoopDanmuProvider implements DanmuProvider {
  @override
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuCandidate>[];

  @override
  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuCandidate>[];

  @override
  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  }) async =>
      DanmuEpisodeSession(boundEpisodeId: boundEpisodeId, segmented: false);

  @override
  Future<List<DanmuItem>> fetchSegment(
    DanmuEpisodeSession session,
    DanmuSegmentDescriptor segment, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuItem>[];

  @override
  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  }) async =>
      const <DanmuItem>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Deterministic RFC 8032 test-only keypair used in unit tests alongside AiLabGate.debugPublicKeyHexOverride.
  const testEd25519PubKeyHex =
      '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8';
  const validIosExpPasscode =
      'MMAILAB1.eyJleHAiOjAsImV4cF9vYXV0aCI6dHJ1ZSwiaWF0IjoxNzk1NzAwMDAwLCJtaW5fdmMiOjgwLCJuIjoiMTEyMjMzIiwicGxhdCI6ImlwaG9uZTtwYyIsInNoYXJlZCI6dHJ1ZSwidGFnIjoiRVhQLUFETUlOIiwidiI6MX0.iJMOUXrCZaLsw3o8pzhtisBRbV0Fp_IA6AwUS0_rspsnf57L-UNFyuGdTOdXesBL3JyQraTj0PIPfMr-Mt6xBg';
  // Production-signed 3-platform permanent passcode.
  const prodSignedPasscode =
      'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwNjIxOCwidGFnIjoiUElMSVBBTEEiLCJ2IjoxfQ.zjZybgCAGD8fCzajU1ls29fSxZiX6Bpo9XTrK06KQeuLw0DBSAmZiY6ouD_OCqoz4XKYMJL9XharsLBJ0yNmDg';

  String buildJwt({
    String accountId = 'acct_ios_test_01',
    String planType = 'plus',
    String email = 'ios@ai.example',
  }) {
    final claimKey = ['https://', 'api.openai', '.com/auth'].join();
    final hdr = base64UrlEncode(utf8.encode('{"alg":"none"}')).replaceAll('=', '');
    final pay = base64UrlEncode(
      utf8.encode(
        jsonEncode({
          'email': email,
          'exp': (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 7200,
          claimKey: {
            'chatgpt_account_id': accountId,
            'chatgpt_plan_type': planType,
          },
        }),
      ),
    ).replaceAll('=', '');
    return '$hdr.$pay.sig';
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiLabGate.debugPublicKeyHexOverride = null;
    AiDanmuMatcher.debugHttpClientOverride = null;
  });

  tearDown(() {
    AiDanmuMatcher.debugHttpClientOverride = null;
    AiLabGate.debugPublicKeyHexOverride = null;
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
  });

  group('1. iOS Passcode Auto-Persistence across cold restarts', () {
    test(
      'verifyAndUnlockAiLab persists across SharedPreferences & Keychain cold restarts and explicit lockAiLab clears all',
      () async {
        AiLabGate.debugPublicKeyHexOverride = testEd25519PubKeyHex;
        final secure = _SlowSecureCredentialStore();
        final ai = AiService(
          secureStorage: secure,
          passcodeStore: AiLabPasscodeStore(targetPlatform: 'ios'),
        );
        ai.configureForTest(secureStorage: secure);

        final res = await ai.verifyAndUnlockAiLab(validIosExpPasscode);
        expect(res.isValid, isTrue);
        expect(ai.isLabUnlocked, isTrue);
        await ai.waitForPendingKeychainOpsForTest();

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(AiLabPasscodeStore.prefsPasscodeKey),
          validIosExpPasscode,
        );
        expect(
          prefs.getString(AiLabPasscodeStore.altPrefsPasscodeKey),
          validIosExpPasscode,
        );
        expect(
          await secure.inner.read(AiService.secureLabTokenSlot),
          validIosExpPasscode,
        );

        // Cold restart #1: fresh store & service, SharedPreferences + Keychain intact
        final restarted1 = AiService(
          secureStorage: secure,
          passcodeStore: AiLabPasscodeStore(targetPlatform: 'ios'),
        );
        expect(restarted1.isLabUnlocked, isFalse);
        await restarted1.ensureLoaded();
        expect(restarted1.isLabUnlocked, isTrue);
        expect(restarted1.isExperimentalOAuthAllowed, isTrue);

        // Cold restart #2: simulate iOS clearing SharedPreferences keys while Keychain remains
        await prefs.remove(AiLabPasscodeStore.prefsPasscodeKey);
        await prefs.remove(AiLabPasscodeStore.altPrefsPasscodeKey);
        final restarted2 = AiService(
          secureStorage: secure,
          passcodeStore: AiLabPasscodeStore(targetPlatform: 'ios'),
        );
        expect(restarted2.isLabUnlocked, isFalse);
        await restarted2.ensureLoaded();
        expect(restarted2.isLabUnlocked, isTrue);
        expect(
          prefs.getString(AiLabPasscodeStore.prefsPasscodeKey),
          validIosExpPasscode,
        );

        // Explicit lock removes both SharedPreferences and Keychain
        await restarted2.lockAiLab();
        await restarted2.waitForPendingKeychainOpsForTest();
        expect(restarted2.isLabUnlocked, isFalse);
        expect(prefs.getString(AiLabPasscodeStore.prefsPasscodeKey), isNull);
        expect(prefs.getString(AiLabPasscodeStore.altPrefsPasscodeKey), isNull);
        expect(await secure.inner.read(AiService.secureLabTokenSlot), isNull);

        final restarted3 = AiService(
          secureStorage: secure,
          passcodeStore: AiLabPasscodeStore(targetPlatform: 'ios'),
        );
        await restarted3.ensureLoaded();
        expect(restarted3.isLabUnlocked, isFalse);
      },
    );

    testWidgets(
      'IosAiSettingsPage waits for ensureLoaded() and renders unlocked view without re-prompting passcode',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final secure = InMemorySecureCredentialStore();
        final store = AiLabPasscodeStore();
        final ai1 = AiService(secureStorage: secure, passcodeStore: store);
        await ai1.verifyAndUnlockAiLab(prodSignedPasscode);

        // Simulate cold restart with fresh unhydrated store/service sharing same Prefs & Keychain
        final storeCold = AiLabPasscodeStore();
        final aiCold = AiService(secureStorage: secure, passcodeStore: storeCold);
        expect(aiCold.isLoaded, isFalse);
        expect(aiCold.isLabUnlocked, isFalse);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: IosAiSettingsPage(service: aiCold),
          ),
        );
        // Should not show passcode input gate while hydrating or after loaded
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-ai-lab-passcode-input')), findsNothing);
        expect(find.byKey(const ValueKey('ios-ai-enable-switch')), findsOneWidget);
        expect(find.byKey(const ValueKey('ios-ai-danmumatch-switch')), findsOneWidget);
      },
    );
  });

  group('2. Codex Model Filtering, Sanitization & HTTP 400 Auto-Heal', () {
    test(
      'parseModelsResponse filters -wm and visibility:hide slugs, extracts reasoning metadata, and avoids web/fallback pollution',
      () async {
        final rawCatalog = jsonEncode({
          'models': [
            {
              'slug': 'gpt-6.2-sol-wm',
              'display_name': 'GPT-6.2 Sol WM',
              'visibility': 'list',
              'priority': 1,
            },
            {
              'slug': 'codex-auto-review',
              'display_name': 'Codex Auto Review',
              'visibility': 'hide',
              'priority': 2,
            },
            {
              'slug': 'gpt-5.4-2026-01-15',
              'display_name': 'GPT-5.4 Dated',
              'visibility': 'list',
              'priority': 10,
            },
            {
              'slug': 'gpt-5.4',
              'display_name': 'GPT-5.4',
              'visibility': 'list',
              'priority': 10,
              'default_reasoning_level': 'medium',
              'supported_reasoning_levels': [
                {'effort': 'medium'},
                {'effort': 'high'},
              ],
            },
            {
              'slug': 'gpt-5.3-codex',
              'display_name': 'GPT-5.3 Codex',
              'visibility': 'none',
              'priority': 12,
            },
          ],
        });

        final parsed = AiService.parseModelsResponse(rawCatalog, isCodex: true);
        expect(
          parsed.map((m) => m.id).toList(),
          equals(['gpt-5.4', 'gpt-5.4-2026-01-15', 'gpt-5.3-codex']),
        );
        expect(parsed.first.defaultReasoningEffort, 'medium');
        expect(parsed.first.supportedReasoningEfforts, equals(['medium', 'high']));
        expect(AiService.sanitizeCodexModelSlug('gpt-6.2-sol-wm'), 'gpt-6.2-sol');
        expect(AiService.sanitizeCodexModelSlug('codex-auto-review'), '');

        // Live Codex fetch must NOT query web endpoint by default and must NOT append fallback models
        final requestedUrls = <String>[];
        final secure = InMemorySecureCredentialStore();
        final ai = AiService(
          secureStorage: secure,
          httpClient: MockClient((req) async {
            requestedUrls.add(req.url.toString());
            if (req.url.path.endsWith('/codex/models')) {
              return http.Response(rawCatalog, 200);
            }
            return http.Response('unexpected', 500);
          }),
        );
        ai.configureForTest(
          secureStorage: secure,
          labUnlockedForTest: true,
          experimentalOAuthForTest: true,
        );
        await ai.setOAuthSession(
          AiOAuthSession(
            accessToken: buildJwt(),
            accountId: 'acct_clean_01',
            planType: 'plus',
          ),
        );
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'gpt-6.2-sol-wm',
            fastModel: 'codex-auto-review',
          ),
        );

        final live = await ai.fetchAvailableModelOptions();
        expect(
          live.map((m) => m.id).toList(),
          equals(['gpt-5.4', 'gpt-5.4-2026-01-15', 'gpt-5.3-codex']),
        );
        expect(
          requestedUrls.any((u) => u.contains('backend-api/models')),
          isFalse,
        );
        expect(
          requestedUrls.single,
          contains('client_version=${AiService.codexClientVersion}'),
        );
        // Configured disallowed models were auto-reconciled
        expect(AiService.isDisallowedCodexModelSlug(ai.config.model), isFalse);
        expect(ai.config.fastModel, '');
      },
    );

    test(
      'Codex completion auto-heals HTTP 400 unsupported model by refreshing catalog and retrying',
      () async {
        final secure = InMemorySecureCredentialStore();
        final postModels = <String>[];
        final ai = AiService(
          secureStorage: secure,
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/codex/models')) {
              return http.Response(
                jsonEncode({
                  'models': [
                    {'slug': 'gpt-5.4', 'visibility': 'list', 'priority': 1},
                  ],
                }),
                200,
              );
            }
            if (req.url.path.endsWith('/codex/responses')) {
              final body =
                  jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
              final reqModel = body['model'] as String;
              postModels.add(reqModel);
              if (reqModel == 'retired-web-model') {
                return http.Response(
                  jsonEncode({
                    'detail':
                        "The 'retired-web-model' model is not supported when using Codex with a ChatGPT account",
                  }),
                  400,
                );
              }
              return http.Response(
                'data: {"type":"response.output_text.delta","delta":"恢复正常"}\n'
                'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":4}}}\n\n',
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
            }
            return http.Response('not found', 404);
          }),
        );
        ai.configureForTest(
          secureStorage: secure,
          codexResponsesEndpoint: 'https://chatgpt.com/backend-api/codex/responses',
          codexModelsEndpoint: 'https://chatgpt.com/backend-api/codex/models',
          labUnlockedForTest: true,
          experimentalOAuthForTest: true,
        );
        await ai.setOAuthSession(
          AiOAuthSession(
            accessToken: buildJwt(),
            accountId: 'acct_heal_01',
            planType: 'plus',
          ),
        );
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'retired-web-model',
          ),
        );

        final res = await ai.complete(
          feature: 'connection_test',
          systemPrompt: 'sys',
          userPrompt: 'hi',
          useCache: false,
        );
        expect(res.text, '恢复正常');
        expect(postModels, equals(['retired-web-model', 'gpt-5.4']));
        expect(ai.config.model, 'gpt-5.4');
      },
    );
  });

  group('3. AI Online Danmaku Matcher, Compression, Cache & Sheet', () {
    test('decodeBilibiliDanmuXml handles plain, gzip, and raw deflate XML', () {
      const sampleXml =
          '<?xml version="1.0" encoding="UTF-8"?><i><d p="12.5,1,25,16777215,1700000000,0,abc,1">前方高能</d></i>';
      final utf8Bytes = Uint8List.fromList(utf8.encode(sampleXml));
      expect(AiDanmuMatcher.decodeBilibiliDanmuXml(utf8Bytes), sampleXml);

      final gzBytes = Uint8List.fromList(gzip.encode(utf8Bytes));
      expect(AiDanmuMatcher.decodeBilibiliDanmuXml(gzBytes), sampleXml);

      final rawDeflateBytes = Uint8List.fromList(ZLibCodec(raw: true).encode(utf8Bytes));
      final decoded = AiDanmuMatcher.decodeBilibiliDanmuXml(rawDeflateBytes);
      expect(decoded, sampleXml);

      final items = DandanplayProvider.parseDanmuPayload(decoded);
      expect(items.length, 1);
      expect(items.first.text, '前方高能');
      expect(items.first.timeMs, 12500);
    });

    test(
      'autoMatchAndLoad searches Bilibili PGC and DanmuSegmentCache.bindPreloadedItems slices windows across seeks & offsets',
      () async {
        const danmuXml =
            '<?xml version="1.0" encoding="UTF-8"?><i>'
            '<d p="5.0,1,25,16777215,1700000000,0,u1,1">开局弹幕</d>'
            '<d p="38.0,1,25,16777215,1700000000,0,u2,2">第二窗口弹幕</d>'
            '</i>';
        final compressedDm =
            Uint8List.fromList(ZLibCodec(raw: true).encode(utf8.encode(danmuXml)));

        final secure = InMemorySecureCredentialStore();
        final ai = AiService(
          secureStorage: secure,
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/codex/responses')) {
              return http.Response(
                'data: {"type":"response.output_text.delta","delta":"{\\"title\\":\\"葬送的芙莉莲\\",\\"alt_titles\\":[],\\"season\\":1,\\"episode\\":2,\\"year\\":\\"2023\\",\\"is_movie\\":false}"}\n'
                'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":8}}}\n\n',
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
            }
            return http.Response('not found', 404);
          }),
        );
        ai.configureForTest(
          secureStorage: secure,
          codexResponsesEndpoint: 'https://chatgpt.com/backend-api/codex/responses',
          labUnlockedForTest: true,
          experimentalOAuthForTest: true,
        );
        await ai.setOAuthSession(AiOAuthSession(accessToken: buildJwt()));
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'gpt-5.4',
            danmuMatchEnabled: true,
          ),
        );

        final matcherHttp = MockClient((req) async {
          if (req.url.path == '/x/web-interface/search/type' &&
              req.url.queryParameters['search_type'] == 'media_bangumi') {
            return http.Response(
              jsonEncode({
                'data': {
                  'result': [
                    {'season_id': 45123, 'title': '<em>葬送的芙莉莲</em>'},
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (req.url.path == '/pgc/view/web/season') {
            return http.Response(
              jsonEncode({
                'result': {
                  'season_title': '葬送的芙莉莲',
                  'episodes': [
                    {'cid': 9001, 'title': '1', 'long_title': '冒险的终点', 'duration': 1440000},
                    {'cid': 9002, 'title': '2', 'long_title': '明明不是魔法', 'duration': 1440000},
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (req.url.path == '/x/v1/dm/list.so' &&
              req.url.queryParameters['oid'] == '9002') {
            return http.Response.bytes(compressedDm, 200);
          }
          return http.Response('{}', 200);
        });

        final matcher = AiDanmuMatcher(aiService: ai, httpClient: matcherHttp);
        final outcome = await matcher.autoMatchAndLoad(
          rawTitle: '[SubsPlease] 葬送的芙莉莲 - S01E02 [1080p HEVC]',
          rawEpisodeName: '第2集 明明不是魔法',
          fallbackEpisodeIndex: 2,
          durationSec: 1440,
        );

        expect(outcome.plan.canonicalTitle, '葬送的芙莉莲');
        expect(outcome.selected?.fetchTarget, '9002');
        expect(outcome.items.length, 2);

        final cache = DanmuSegmentCache(
          provider: _NoopDanmuProvider(),
          seekDebounceMs: 0,
        );
        cache.bindPreloadedItems(
          outcome.items,
          sessionId: 'ai_online:bilibili_pgc:9002',
          initialPositionMs: 2000,
          playing: true,
        );
        expect(
          cache.snapshotForPosition(6000).map((e) => e.text).toList(),
          equals(['开局弹幕']),
        );
        cache.onPlaybackTick(39000, playing: true);
        await cache.waitUntilIdle();
        expect(
          cache.snapshotForPosition(40000).map((e) => e.text).toList(),
          equals(['第二窗口弹幕']),
        );
        // Positive timeOffsetMs shifts danmaku earlier: at 2s + 5000ms = 7s, 5s comment already entered
        cache.setTimeOffsetMs(5000);
        cache.onPlaybackTick(2000, playing: true);
        await cache.waitUntilIdle();
        expect(
          cache.snapshotForPosition(2000).map((e) => e.text).toList(),
          equals(['开局弹幕']),
        );
        cache.dispose();
      },
    );

    test('Privacy Space hard-blocks AiDanmuMatcher with zero outbound HTTP requests', () async {
      var hits = 0;
      final matcher = AiDanmuMatcher(
        httpClient: MockClient((req) async {
          hits++;
          return http.Response('{}', 200);
        }),
      );
      AiService.instance.configureForTest(labUnlockedForTest: true);
      AiService.instance.setPrivacySessionActive(true);

      await expectLater(
        () => matcher.autoMatchAndLoad(rawTitle: '三体'),
        throwsA(
          isA<AiServiceException>().having(
            (e) => e.code,
            'code',
            AiErrorCode.privacySpaceBlocked,
          ),
        ),
      );
      expect(hits, 0);
    });

    testWidgets(
      'showIosAiDanmuMatchSheet auto-applies matched danmaku and supports AI timeline offset alignment',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        const danmuXml =
            '<?xml version="1.0" encoding="UTF-8"?><i>'
            '<d p="12.0,1,25,16777215,1700000000,0,u1,1">高能名场面</d>'
            '</i>';
        AiService.instance.configureForTest(
          secureStorage: InMemorySecureCredentialStore(),
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/codex/responses')) {
              final raw = utf8.decode(req.bodyBytes);
              if (raw.contains('时间轴')) {
                return http.Response(
                  'data: {"type":"response.output_text.delta","delta":"{\\"offset_ms\\":1500,\\"reason\\":\\"对齐1.5秒片头\\"}"}\n'
                  'data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":6}}}\n\n',
                  200,
                  headers: {'content-type': 'text/event-stream; charset=utf-8'},
                );
              }
              return http.Response(
                'data: {"type":"response.output_text.delta","delta":"{\\"title\\":\\"测试番剧\\",\\"alt_titles\\":[],\\"season\\":1,\\"episode\\":1,\\"year\\":\\"2025\\",\\"is_movie\\":false}"}\n'
                'data: {"type":"response.completed","response":{"usage":{"input_tokens":8,"output_tokens":6}}}\n\n',
                200,
                headers: {'content-type': 'text/event-stream; charset=utf-8'},
              );
            }
            return http.Response('not found', 404);
          }),
          codexResponsesEndpoint: 'https://chatgpt.com/backend-api/codex/responses',
          labUnlockedForTest: true,
          experimentalOAuthForTest: true,
        );
        await AiService.instance.setOAuthSession(
          AiOAuthSession(accessToken: buildJwt()),
        );
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'gpt-5.4',
            danmuMatchEnabled: true,
          ),
        );

        final matcher = AiDanmuMatcher(
          aiService: AiService.instance,
          httpClient: MockClient((req) async {
            if (req.url.path == '/x/web-interface/search/type' &&
                req.url.queryParameters['search_type'] == 'media_bangumi') {
              return http.Response(
                jsonEncode({
                  'data': {
                    'result': [
                      {'season_id': 777, 'title': '测试番剧'},
                    ],
                  },
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (req.url.path == '/pgc/view/web/season') {
              return http.Response(
                jsonEncode({
                  'result': {
                    'season_title': '测试番剧',
                    'episodes': [
                      {'cid': 555, 'title': '1', 'long_title': '序章', 'duration': 1420000},
                    ],
                  },
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            if (req.url.path == '/x/v1/dm/list.so') {
              return http.Response.bytes(
                Uint8List.fromList(utf8.encode(danmuXml)),
                200,
              );
            }
            return http.Response('{}', 200);
          }),
        );

        List<DanmuItem>? appliedItems;
        int? updatedOffsetMs;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: CupertinoButton(
                    key: const ValueKey('open-sheet'),
                    onPressed: () {
                      unawaited(
                        showIosAiDanmuMatchSheet(
                          ctx,
                          title: '测试番剧.E01.1080p',
                          episodeName: '第1集',
                          episodeNumber: 1,
                          durationSec: 1420,
                          currentDanmuSettings: const DanmuSettings(),
                          initialOffsetMs: 0,
                          onApplyDanmu: (_, items) => appliedItems = items,
                          onUpdateOffsetMs: (ms) => updatedOffsetMs = ms,
                          matcherOverride: matcher,
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-sheet')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );

        expect(find.byKey(const ValueKey('ios-ai-danmu-match-sheet')), findsOneWidget);
        expect(appliedItems, isNotNull);
        expect(appliedItems!.single.text, '高能名场面');

        await tester.tap(find.byKey(const ValueKey('ios-ai-danmu-ai-offset-btn')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        expect(updatedOffsetMs, 1500);
      },
    );
  });
}

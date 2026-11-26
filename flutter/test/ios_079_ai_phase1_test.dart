import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_passcode.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/ai_title_cleaner.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/ios_search_page.dart';
import 'package:marco_movie/ui/media_folder_browser_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _AiSearchFixtureCmsClient extends CmsClient {
  final Map<String, List<CmsVideo>> catalogBySite;
  final List<String> searchedKeywords = <String>[];

  _AiSearchFixtureCmsClient({required this.catalogBySite})
      : super(
          client: MockClient(
            (_) async => http.Response('{"class":[],"list":[]}', 200),
          ),
        );

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async {
    return (
      const <CmsCategory>[CmsCategory(id: '1', name: '科幻')],
      const CmsListing(videos: <CmsVideo>[]),
    );
  }

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async {
    searchedKeywords.add('${site.key}:$keyword');
    final all = catalogBySite[site.key] ?? const <CmsVideo>[];
    final kw = keyword.trim();
    final matched = all
        .where((v) => v.title.contains(kw) || kw.contains(v.title))
        .toList(growable: false);
    return CmsListing(videos: matched);
  }

  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String categoryId,
    int page, {
    List<String> childIds = const <String>[],
    CmsFilter? filter,
  }) async {
    return CmsListing(
      page: 1,
      pageCount: 1,
      videos: catalogBySite[site.key] ?? const <CmsVideo>[],
    );
  }
}

void main() {
  const permanentOfficialToken =
      'MMAILAB1.eyJleHAiOjAsImlhdCI6MTc5NTcwNjIxOCwidGFnIjoiUElMSVBBTEEiLCJ2IjoxfQ.zjZybgCAGD8fCzajU1ls29fSxZiX6Bpo9XTrK06KQeuLw0DBSAmZiY6ouD_OCqoz4XKYMJL9XharsLBJ0yNmDg';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AiLabPasscodeStore.instance.resetForTest();
    await AiLabPasscodeStore.instance.unlockWithPasscode(permanentOfficialToken);
    AiService.instance.resetForTest();
    AiTitleCleaner.instance.configureForTest(
      aiService: AiService.instance,
      clearCache: true,
    );
    IosLiquidGlassBridge.setAvailableForTest(false);
  });

  tearDown(() {
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    AiTitleCleaner.instance.configureForTest(
      aiService: AiService.instance,
      clearCache: true,
    );
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  group('AiService BYO-API protocols, Keychain isolation & guardrails', () {
    test('ships with strictly empty defaults and isolates API key in Keychain',
        () async {
      final secure = InMemorySecureCredentialStore();
      final service = AiService(secureStorage: secure);
      await service.ensureLoaded();

      expect(service.config.enabled, isFalse);
      expect(service.config.baseUrl, '');
      expect(service.config.model, '');
      expect(service.config.fastModel, '');
      expect(service.config.monthlyTokenBudget, 0);
      expect(service.config.firstUseConsentAccepted, isFalse);
      expect(service.isConfigured, isFalse);
      expect(await service.readApiKey(), '');

      const secretKey = 'test-keychain-only-token-99';
      await service.saveConfig(
        const AiConfig(
          enabled: true,
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://api.example/v1',
          model: 'model-main',
        ),
      );
      await service.setApiKey(secretKey);

      expect(service.isConfigured, isTrue);
      expect(secure.rawData[AiService.secureApiKeySlot], secretKey);

      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        final rawVal = prefs.get(k)?.toString() ?? '';
        expect(
          rawVal.contains(secretKey),
          isFalse,
          reason: 'API key must NEVER leak into SharedPreferences ($k)',
        );
      }
    });

    test(
        'formats requests & parses responses across OpenAI, Anthropic, and Gemini protocols',
        () async {
      final secure = InMemorySecureCredentialStore(<String, String>{
        AiService.secureApiKeySlot: 'test-token-alpha',
      });
      http.Request? capturedReq;

      // 1. OpenAI-compatible
      final openAiClient = MockClient((req) async {
        capturedReq = req;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'OK-OPENAI'},
                },
              ],
              'usage': {'prompt_tokens': 12, 'completion_tokens': 4},
            }),
          ),
          200,
        );
      });
      final service = AiService(
        httpClient: openAiClient,
        secureStorage: secure,
        clock: () => DateTime.utc(2026, 11, 26),
      );
      await service.saveConfig(
        const AiConfig(
          enabled: true,
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://api.example/v1/',
          model: 'chat-alpha',
        ),
      );
      final r1 = await service.complete(
        feature: 'proto_test',
        systemPrompt: 'sys-1',
        userPrompt: 'hello',
        useCache: false,
      );
      expect(capturedReq!.url.toString(), 'https://api.example/v1/chat/completions');
      expect(capturedReq!.headers['Authorization'], 'Bearer test-token-alpha');
      final body1 = jsonDecode(capturedReq!.body) as Map<String, dynamic>;
      expect(body1['model'], 'chat-alpha');
      expect((body1['messages'] as List).length, 2);
      expect(r1.text, 'OK-OPENAI');
      expect(service.monthlyUsage.totalTokens, 16);

      // Exact /chat/completions endpoint is preserved without duplication.
      expect(
        AiService.resolveEndpointUri(
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://gateway.example/custom/chat/completions',
          model: 'chat-alpha',
        ).toString(),
        'https://gateway.example/custom/chat/completions',
      );

      // 2. Anthropic Messages
      final anthropicClient = MockClient((req) async {
        capturedReq = req;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'OK-ANTHROPIC'},
              ],
              'usage': {'input_tokens': 20, 'output_tokens': 5},
            }),
          ),
          200,
        );
      });
      service.configureForTest(httpClient: anthropicClient);
      await service.saveConfig(
        const AiConfig(
          enabled: true,
          protocol: AiApiProtocol.anthropicMessages,
          baseUrl: 'https://llm.example',
          model: 'claude-style-model',
        ),
      );
      final r2 = await service.complete(
        feature: 'proto_test',
        systemPrompt: 'sys-2',
        userPrompt: 'ping',
        useCache: false,
      );
      expect(capturedReq!.url.toString(), 'https://llm.example/v1/messages');
      expect(capturedReq!.headers['x-api-key'], 'test-token-alpha');
      expect(capturedReq!.headers['anthropic-version'], '2023-06-01');
      final body2 = jsonDecode(capturedReq!.body) as Map<String, dynamic>;
      expect(body2['system'], 'sys-2');
      expect(r2.text, 'OK-ANTHROPIC');
      expect(service.monthlyUsage.totalTokens, 41);

      // 3. Google Gemini GenerateContent
      final geminiClient = MockClient((req) async {
        capturedReq = req;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'OK-GEMINI'},
                    ],
                  },
                },
              ],
              'usageMetadata': {
                'promptTokenCount': 15,
                'candidatesTokenCount': 6,
              },
            }),
          ),
          200,
        );
      });
      service.configureForTest(httpClient: geminiClient);
      await service.saveConfig(
        const AiConfig(
          enabled: true,
          protocol: AiApiProtocol.geminiGenerateContent,
          baseUrl: 'https://gemini.example/v1beta',
          model: 'gemini-flash',
        ),
      );
      final r3 = await service.complete(
        feature: 'proto_test',
        systemPrompt: 'sys-3',
        userPrompt: 'ping',
        useCache: false,
      );
      expect(
        capturedReq!.url.toString(),
        'https://gemini.example/v1beta/models/gemini-flash:generateContent',
      );
      expect(capturedReq!.headers['x-goog-api-key'], 'test-token-alpha');
      final body3 = jsonDecode(capturedReq!.body) as Map<String, dynamic>;
      expect(body3['systemInstruction'], isNotNull);
      expect(r3.text, 'OK-GEMINI');
      expect(service.monthlyUsage.totalTokens, 62);
      expect(service.monthlyUsage.requestCount, 3);
    });

    test(
        'enforces Privacy Space hard-block, SHA-256 cache deduplication, monthly token budget & rollover, and testConnection()',
        () async {
      var networkCalls = 0;
      var currentNow = DateTime.utc(2026, 11, 10);
      final mockHttp = MockClient((req) async {
        networkCalls++;
        final decoded = jsonDecode(req.body) as Map<String, dynamic>;
        final userMsg = ((decoded['messages'] as List).last as Map)['content'];
        if (userMsg == 'auth-fail') {
          return http.Response('{"error":{"message":"invalid key"}}', 401);
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'OK'},
                },
              ],
              'usage': {'prompt_tokens': 40, 'completion_tokens': 20},
            }),
          ),
          200,
        );
      });

      final service = AiService(
        httpClient: mockHttp,
        secureStorage: InMemorySecureCredentialStore(<String, String>{
          AiService.secureApiKeySlot: 'key-budget-test',
        }),
        clock: () => currentNow,
      );
      await service.saveConfig(
        const AiConfig(
          enabled: true,
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://api.example/v1',
          model: 'model-main',
          monthlyTokenBudget: 100,
        ),
      );

      // Privacy Space hard-blocks before cache or network!
      await expectLater(
        () => service.complete(
          feature: 'f1',
          userPrompt: 'secret query',
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
      expect(networkCalls, 0);

      // First call consumes 60 tokens (40 + 20) and populates cache.
      final first = await service.complete(
        feature: 'f1',
        userPrompt: 'same-query',
      );
      expect(first.fromCache, isFalse);
      expect(networkCalls, 1);
      expect(service.monthlyUsage.totalTokens, 60);

      // Repeated identical call hits SHA-256 cache at 0 network & 0 token cost.
      final second = await service.complete(
        feature: 'f1',
        userPrompt: 'same-query',
      );
      expect(second.fromCache, isTrue);
      expect(networkCalls, 1);
      expect(service.monthlyUsage.totalTokens, 60);

      // Second distinct call consumes another 60 -> total 120 (>= budget 100).
      await service.complete(feature: 'f1', userPrompt: 'second-query');
      expect(networkCalls, 2);
      expect(service.monthlyUsage.totalTokens, 120);

      // Third distinct call is auto-blocked by monthlyTokenBudget!
      await expectLater(
        () => service.complete(feature: 'f1', userPrompt: 'third-query'),
        throwsA(
          isA<AiServiceException>().having(
            (e) => e.code,
            'code',
            AiErrorCode.budgetExceeded,
          ),
        ),
      );
      expect(networkCalls, 2);

      // Advancing to next YYYY-MM month resets monthly usage automatically.
      currentNow = DateTime.utc(2026, 12, 1);
      expect(service.monthlyUsage.totalTokens, 0);
      final pingOk = await service.testConnection();
      expect(pingOk.ok, isTrue);
      expect(pingOk.messageZh, contains('连接成功'));
    });

    test('parseSearchCandidatesJson strips markdown fences and rejects URLs',
        () {
      const fenced = '''
```json
[
  {"title": "星际穿越", "year": "2014", "reason": "硬核天体物理与父女亲情太空史诗"},
  {"title": "违规外链片", "year": "2020", "reason": "看这里 https://bad.example/play.m3u8"},
  {"title": "带URL字段", "year": "2021", "reason": "正常理由", "url": "https://bad.example/v"},
  {"title": "火星救援", "year": "2015", "reason": "乐观幽默的硬核火星求生"}
]
```
''';
      final parsed = AiService.parseSearchCandidatesJson(fenced);
      expect(parsed.length, 2);
      expect(parsed[0].title, '星际穿越');
      expect(parsed[0].year, '2014');
      expect(parsed[1].title, '火星救援');
    });
  });

  group('AiTitleCleaner baseline, batching, anti-URL schema & fallback', () {
    test('cleanBaseline extracts clean title, year, and season/episode deterministically',
        () {
      final movie = AiTitleCleaner.cleanBaseline(
        '[阳光组]Interstellar.2014.2160p.UHD.BluRay.x265.10bit.HDR.mkv',
      );
      expect(movie.title, 'Interstellar');
      expect(movie.year, '2014');
      expect(movie.episodeBadge, isNull);

      final ep = AiTitleCleaner.cleanBaseline(
        '【高清】凡人修仙传.S02E15.1080p.WEB-DL.H265.AAC.mp4',
      );
      expect(ep.title, '凡人修仙传');
      expect(ep.season, 2);
      expect(ep.episode, 15);
      expect(ep.episodeBadge, 'S02E15');
    });

    test(
        'cleanBatch chunks >20 items, caches normalized names, rejects URLs, and falls back on HTTP 500',
        () async {
      var httpCalls = 0;
      var failWith500 = false;
      String? requestedModel;

      final mockClient = MockClient((req) async {
        httpCalls++;
        if (failWith500) {
          return http.Response('Internal Server Error', 500);
        }
        final decoded = jsonDecode(req.body) as Map<String, dynamic>;
        requestedModel = decoded['model'] as String?;
        final userContent =
            ((decoded['messages'] as List).last as Map)['content'] as String;
        final batchItems = jsonDecode(userContent) as List<dynamic>;
        expect(batchItems.length, lessThanOrEqualTo(20));

        final out = <Map<String, Object?>>[];
        for (final rawItem in batchItems) {
          final idx = (rawItem as Map)['index'] as int;
          final name = rawItem['name'] as String;
          if (name.contains('Injected')) {
            // Simulate malicious LLM trying to inject a URL.
            out.add(<String, Object?>{
              'index': idx,
              'title': 'https://bad.example/stream.m3u8',
              'year': '2024',
              'season': null,
              'episode': null,
            });
          } else {
            out.add(<String, Object?>{
              'index': idx,
              'title': '清洗片名_$idx',
              'year': '2024',
              'season': 1,
              'episode': idx + 1,
            });
          }
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(out)},
                },
              ],
              'usage': {'prompt_tokens': 30, 'completion_tokens': 30},
            }),
          ),
          200,
        );
      });

      final service = AiService(
        httpClient: mockClient,
        secureStorage: InMemorySecureCredentialStore(<String, String>{
          AiService.secureApiKeySlot: 'cleaner-key',
        }),
      );
      await service.saveConfig(
        const AiConfig(
          enabled: true,
          protocol: AiApiProtocol.openaiCompatible,
          baseUrl: 'https://api.example/v1',
          model: 'model-main',
          fastModel: 'model-fast-mini',
          titleCleanupEnabled: true,
        ),
      );
      final cleaner = AiTitleCleaner(aiService: service);

      // 23 unique items -> chunked into 2 requests (20 + 3).
      final inputs = <String>[
        for (var i = 0; i < 22; i++) 'Show.Name.S01E${i + 1}.2160p.WEB-DL.mkv',
        'Injected.Movie.2024.1080p.mp4',
      ];
      final cleaned = await cleaner.cleanBatch(inputs);
      expect(httpCalls, 2);
      expect(requestedModel, 'model-fast-mini');
      expect(cleaned.first.fromAi, isTrue);
      expect(cleaned.first.title, '清洗片名_0');
      expect(cleaned.first.episodeBadge, 'S01E01');

      // URL-injected item was rejected and fell back to deterministic baseline!
      expect(cleaned.last.fromAi, isFalse);
      expect(cleaned.last.title, 'Injected Movie');
      expect(cleaned.last.year, '2024');

      // Calling again with already-cleaned names hits memory cache -> 0 new HTTP calls.
      await cleaner.cleanBatch(inputs.sublist(0, 5));
      expect(httpCalls, 2);

      // Upstream HTTP 500 falls back cleanly to baseline without throwing.
      failWith500 = true;
      final fallbackRes = await cleaner.cleanBatch(const <String>[
        'Dune.Part.Two.2024.2160p.BluRay.x265.mkv',
      ]);
      expect(fallbackRes.single.fromAi, isFalse);
      expect(fallbackRes.single.title, 'Dune Part Two');
      expect(fallbackRes.single.year, '2024');
    });
  });

  group('IosAiSettingsPage & IosGlobalSearchPage AI Phase 1 widgets', () {
    testWidgets(
      'IosAiSettingsPage configures BYO-API fields, stores key in Keychain, tests connection, and clears cache',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final secure = InMemorySecureCredentialStore();
        http.Request? pingReq;
        final mockHttp = MockClient((req) async {
          pingReq = req;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'OK'},
                  },
                ],
                'usage': {'prompt_tokens': 8, 'completion_tokens': 2},
              }),
            ),
            200,
          );
        });
        AiService.instance.configureForTest(
          httpClient: mockHttp,
          secureStorage: secure,
          resetState: true,
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: IosAiSettingsPage(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ios-ai-settings-page')), findsOneWidget);
        expect(find.textContaining('BYO-API'), findsOneWidget);

        // Toggle master enable switch.
        await tester.tap(find.byKey(const ValueKey('ios-ai-enable-switch')));
        await tester.pumpAndSettle();
        expect(AiService.instance.config.enabled, isTrue);

        // Enter endpoint, API key, and model.
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-baseurl-field')),
          'https://api.example/v1',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-apikey-field')),
          'ui-test-secret-key',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-model-field')),
          'model-chat',
        );
        await tester.pumpAndSettle();

        // Tap 测试连接.
        final testBtn = find.byKey(const ValueKey('ios-ai-test-btn'));
        await tester.ensureVisible(testBtn);
        await tester.pumpAndSettle();
        await tester.tap(testBtn);
        await tester.pumpAndSettle();

        expect(pingReq, isNotNull);
        expect(pingReq!.url.toString(), 'https://api.example/v1/chat/completions');
        expect(pingReq!.headers['Authorization'], 'Bearer ui-test-secret-key');
        expect(find.textContaining('连接成功'), findsOneWidget);
        expect(secure.rawData[AiService.secureApiKeySlot], 'ui-test-secret-key');

        // Tap 清空 AI 缓存.
        final clearBtn = find.byKey(const ValueKey('ios-ai-clear-cache-btn'));
        await tester.ensureVisible(clearBtn);
        await tester.pumpAndSettle();
        await tester.tap(clearBtn);
        await tester.pumpAndSettle();
        expect(find.text('已清空 AI 本地响应缓存'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosGlobalSearchPage: unconfigured AI pill opens IosAiSettingsPage; configured AI search matches user sources with AI reasons',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{'onboarding_done_version': 1},
        );
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 's_4k',
                'name': '星河 | 4K',
                'type': 1,
                'api': 'https://xinghe.example/api',
              },
              {
                'key': 's_hd',
                'name': '极光 | 秒播',
                'type': 1,
                'api': 'https://jiguang.example/api',
              },
            ],
          }),
        );

        final cmsClient = _AiSearchFixtureCmsClient(
          catalogBySite: const <String, List<CmsVideo>>{
            's_4k': <CmsVideo>[
              CmsVideo(
                id: 'v_interstellar',
                title: '星际穿越【4K】',
                year: '2014',
                remarks: '4K HDR',
              ),
            ],
            's_hd': <CmsVideo>[
              CmsVideo(
                id: 'v_martian',
                title: '火星救援',
                year: '2015',
                remarks: 'BD中字',
              ),
              CmsVideo(
                id: 'v_noise',
                title: '无关测试综艺',
                year: '2025',
              ),
            ],
          },
        );

        final secure = InMemorySecureCredentialStore();
        final aiMockHttp = MockClient((req) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': jsonEncode([
                        {
                          'title': '星际穿越',
                          'year': '2014',
                          'reason': '黑洞引力奇观与跨越维度的父女深情',
                        },
                        {
                          'title': '火星救援',
                          'year': '2015',
                          'reason': '硬核植物学自救的太空乐观主义佳作',
                        },
                        {
                          'title': '月球',
                          'year': '2009',
                          'reason': '冷峻克制的独角戏太空悬疑经典',
                        },
                      ]),
                    },
                  },
                ],
                'usage': {'prompt_tokens': 50, 'completion_tokens': 65},
              }),
            ),
            200,
          );
        });
        AiService.instance.configureForTest(
          httpClient: aiMockHttp,
          secureStorage: secure,
          resetState: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(storage: storage, client: cmsClient),
          ),
        );
        await tester.pumpAndSettle();

        // Open Global Search.
        await tester.tap(find.byKey(const ValueKey('home-search-button')));
        await tester.pumpAndSettle();
        expect(find.byType(IosGlobalSearchPage), findsOneWidget);

        // 1. Unconfigured tap on AI 找片 opens IosAiSettingsPage!
        final aiPill = find.byKey(const ValueKey('ios-search-ai-pill'));
        expect(aiPill, findsOneWidget);
        await tester.tap(aiPill);
        await tester.pumpAndSettle();
        expect(find.byType(IosAiSettingsPage), findsOneWidget);

        // Configure BYO-API right inside IosAiSettingsPage and go back!
        await tester.tap(find.byKey(const ValueKey('ios-ai-enable-switch')));
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-baseurl-field')),
          'https://api.example/v1',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-apikey-field')),
          'search-test-key',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ios-ai-model-field')),
          'model-chat',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('settings-drawer-back')));
        await tester.pumpAndSettle();
        expect(find.byType(IosGlobalSearchPage), findsOneWidget);

        // 2. Submit natural-language search -> first-use consent dialog appears.
        await tester.enterText(
          find.byType(CupertinoTextField).last,
          '节奏紧凑的太空硬科幻电影',
        );
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ios-ai-consent-dialog')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('ios-ai-consent-accept-btn')));
        await tester.pumpAndSettle();

        // 3. Displays ONLY real playable hits from user's configured sources + AI reasons!
        expect(find.text('星际穿越'), findsWidgets);
        expect(
          find.byKey(const ValueKey('ai-reason-星际穿越')),
          findsOneWidget,
        );
        expect(find.text('黑洞引力奇观与跨越维度的父女深情'), findsOneWidget);
        expect(find.text('火星救援'), findsWidgets);
        expect(
          find.byKey(const ValueKey('ai-reason-火星救援')),
          findsOneWidget,
        );
        expect(find.text('硬核植物学自救的太空乐观主义佳作'), findsOneWidget);
        expect(find.text('无关测试综艺'), findsNothing);

        // Unmatched candidate ('月球') appears only in the plain-text footer.
        expect(
          find.byKey(const ValueKey('ios-ai-unmatched-footer')),
          findsOneWidget,
        );
        expect(find.textContaining('另有 1 部推荐未在当前片源命中：月球'), findsOneWidget);

        // 4. When AI endpoint fails (HTTP 503), gracefully falls back to normal keyword search!
        AiService.instance.configureForTest(
          httpClient: MockClient(
            (_) async => http.Response('Service Unavailable', 503),
          ),
        );
        await tester.enterText(
          find.byType(CupertinoTextField).last,
          '火星救援',
        );
        await tester.tap(find.text('搜索').last);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('ios-ai-search-fallback-notice')),
          findsOneWidget,
        );
        expect(find.text('火星救援'), findsWidgets);

        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'MediaFolderBrowserPage progressively enhances messy filenames when AI title cleanup is enabled',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage();
        final cmsClient = _AiSearchFixtureCmsClient(
          catalogBySite: const <String, List<CmsVideo>>{
            'webdav_demo': <CmsVideo>[
              CmsVideo(
                id: 'f1',
                title: '[SubGroup]Fan.Ren.Xiu.Xian.Zhuan.S01E03.2160p.WEB-DL.mkv',
                remarks: '4.2 GB',
              ),
            ],
          },
        );

        AiService.instance.configureForTest(
          httpClient: MockClient((req) async {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'content': jsonEncode([
                          {
                            'index': 0,
                            'title': '凡人修仙传',
                            'year': '2020',
                            'season': 1,
                            'episode': 3,
                          },
                        ]),
                      },
                    },
                  ],
                  'usage': {'prompt_tokens': 25, 'completion_tokens': 20},
                }),
              ),
              200,
            );
          }),
          secureStorage: InMemorySecureCredentialStore(<String, String>{
            AiService.secureApiKeySlot: 'folder-clean-key',
          }),
          resetState: true,
        );
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            protocol: AiApiProtocol.openaiCompatible,
            baseUrl: 'https://api.example/v1',
            model: 'model-chat',
            titleCleanupEnabled: true,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: MediaFolderBrowserPage(
              site: const CmsSite(
                key: 'webdav_demo',
                name: '家庭 NAS',
                type: 1,
                api: 'webdavlib://account/nas1',
              ),
              client: cmsClient,
              storage: storage,
              folderId: 'root',
              folderTitle: '剧集目录',
              onOpenVideo: (_, __) {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('凡人修仙传'), findsOneWidget);
        expect(find.text('S01E03'), findsOneWidget);
        expect(find.text('2020'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

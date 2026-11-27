// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/ai_lab_features.dart';
import 'package:marco_movie/core/ai_lab_gate.dart';
import 'package:marco_movie/core/ai_service.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/episode_scraper.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/ios_mpv_profile.dart';
import 'package:marco_movie/core/mdk_platform_player.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/ios_ai_lab_sheets.dart';
import 'package:marco_movie/ui/ios_ai_settings_page.dart';
import 'package:marco_movie/ui/ios_drive_priority_sheet.dart';
import 'package:marco_movie/ui/ios_glass_popover.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/ios_player_toolbar_sheet.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _fakeJwt(Map<String, dynamic> claims) {
  String b64u(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${b64u({'alg': 'RS256'})}.${b64u(claims)}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    IosLiquidGlassBridge.setAvailableForTest(false);
  });

  tearDown(() {
    AiLabPasscodeStore.instance.resetForTest();
    AiService.instance.resetForTest();
    IosLiquidGlassBridge.setAvailableForTest(null);
  });

  group('Batch A (Prev 1-4): Netdisk Priority, Post-Update Popup, Poster Speed & 4K Dolby Vision', () {
    testWidgets(
      'Prev-1: Manual netdisk order & default playback source mode control pickRecommendedLineIndex and UI reorder',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final storage = await StorageService.init();
        expect(storage.hasCustomDriveOrder, isFalse);

        // Manually prioritize Baidu -> Aliyun -> Quark -> UC -> 115
        await storage.setDriveOrder(
          const ['baidu', 'aliyun', 'quark', 'uc', 'pan115'],
        );
        await storage.setPreferredQuality('4k_netdisk');
        expect(storage.hasCustomDriveOrder, isTrue);
        expect(storage.driveOrder.first, 'baidu');

        const lines = <CmsLine>[
          CmsLine(
            name: '极速M3U8',
            episodes: [CmsEpisode(name: '正片', url: 'https://cdn.example/a.m3u8')],
          ),
          CmsLine(
            name: '夸克4K原画',
            episodes: [CmsEpisode(name: '4K.mkv', url: 'https://pan.quark.cn/s/1')],
          ),
          CmsLine(
            name: '百度臻彩4K',
            episodes: [CmsEpisode(name: '4K.mkv', url: 'https://pan.baidu.com/s/1')],
          ),
        ];
        // Baidu is #1 in custom drive order -> index 2 wins over Quark (index 1) and HLS (index 0)
        expect(storage.pickRecommendedLineIndex(lines), 2);

        // Switch default source mode to direct streaming -> HLS line (index 0) wins
        await storage.setPreferredQuality('1080p_direct');
        expect(storage.pickRecommendedLineIndex(lines), 0);

        // Render PlaybackSourcePriorityEditor and tap quick default drive chip for Aliyun
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: PlaybackSourcePriorityEditor(storage: storage),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('drive-quick-default-ali')));
        await tester.pumpAndSettle();
        expect(storage.preferredQuality, '4k_netdisk');
        expect(storage.driveOrder.first, 'ali');
      },
    );

    test(
      'Prev-2: OnboardingPrefs triggers post-update notice on semver or +build bump and for pre-notice existing users',
      () async {
        // 1. Fresh new install with zero local data and onboarding not yet done -> should NOT double-popup over onboarding
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final freshPrefs = await OnboardingPrefs.load();
        expect(
          freshPrefs.shouldShowPostUpdateNotice(
            '0.7.11+111',
            hasExistingUserData: false,
          ),
          isFalse,
        );

        // 2. Existing user upgrading from an older version before lastSeenAppVersion was stored -> MUST pop!
        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });
        final legacyPrefs = await OnboardingPrefs.load();
        expect(
          legacyPrefs.shouldShowPostUpdateNotice(
            '0.7.11+111',
            hasExistingUserData: true,
          ),
          isTrue,
        );

        await legacyPrefs.markPostUpdateNoticeSeen('0.7.11+111');
        expect(
          legacyPrefs.shouldShowPostUpdateNotice(
            '0.7.11+111',
            hasExistingUserData: true,
          ),
          isFalse,
        );
        // Same semver with bumped build number (+112) still pops up!
        expect(
          legacyPrefs.shouldShowPostUpdateNotice(
            '0.7.11+112',
            hasExistingUserData: true,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'Prev-3: PosterImage renders Apple TV+ loading sheen card instead of blank hole while loading, and CuratedDiscovery persists disk snapshot',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 140,
                height: 200,
                child: PosterImage(
                  url: '',
                  placeholder: SizedBox.shrink(),
                  title: '星际穿越',
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('poster-loading-sheen')), findsOneWidget);

        CuratedDiscoveryService.resetCacheForTest();
        await CuratedDiscoveryService.saveToDiskNow();
        await CuratedDiscoveryService.warmFromDisk();
        expect(CuratedDiscoveryService.isInitialized, isA<bool>());
      },
    );

    test(
      'Prev-4: iOS 4K Dolby Vision / MKV streams route to Metal MDK engine and set nv12 hwdec format on MPV fallback',
      () {
        expect(
          IosPlaybackEngineMode.fromId('mdk'),
          IosPlaybackEngineMode.mdk,
        );
        expect(MdkPlatformPlayer.isIosSupported, isTrue);
        expect(
          IosMpvProfile.isLikelyDolbyVisionMedia(
            url: 'https://cloud.example/Dune.Part.Two.2160p.DV.HDR.mkv',
            episodeName: '4K杜比视界.mkv',
          ),
          isTrue,
        );
        expect(
          IosMpvProfile.prefersIosMetalMdkWhenAvPlayerUnsupported(
            url: 'https://cloud.example/Movie.2160p.Remux.mkv',
            episodeName: '正片 4K',
          ),
          isTrue,
        );
        final props = IosMpvProfile.buildMpvProperties(
          physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
          hwdec: 'videotoolbox',
        );
        expect(props['hwdec-image-format'], 'nv12');
        expect(props['framedrop'], 'vo');
        expect(props['vd-lavc-dr'], 'yes');
      },
    );
  });

  group('Batch B (New 1-7): Customizable Toolbar, Symmetrical AI Button, Taller Popover, AI Subtitles, Movie Versions & AI Quota', () {
    testWidgets(
      'New-1 & New-2: Danmu defaults OFF, toolbar defaults to exact 9 buttons, supports custom add/remove/reorder, and renders right symmetrical AI button only when unlocked',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Danmu default must be OFF
        expect(const DanmuSettings().effectiveEnabled, isFalse);

        final storage = await StorageService.init();
        expect(
          storage.iosPlayerToolbarItems,
          const <String>[
            'episodes',
            'lines',
            'speed',
            'danmu_subtitle',
            'aspect',
            'engine',
            'audio',
            'skip_intro_outro',
            'more',
          ],
        );

        Widget buildChrome({
          required bool showAi,
          required List<String> items,
          bool isMovie = false,
        }) {
          return MaterialApp(
            home: Scaffold(
              body: IosPlayerChrome(
                title: '沙丘2',
                episodeName: '4K · 杜比视界',
                lineName: '夸克原盘',
                isLive: false,
                playing: true,
                loading: false,
                buffering: false,
                hasError: false,
                position: const Duration(minutes: 10),
                duration: const Duration(minutes: 166),
                isScrubbing: false,
                scrubPositionMs: 0,
                playbackSpeed: 1.0,
                skipIntroSec: 0,
                skipOutroSec: 0,
                specBadges: const [],
                fallbackSpecsLabel: '',
                specBadgesExpanded: false,
                isLandscape: true,
                danmuEnabled: const DanmuSettings().effectiveEnabled,
                sleepTimerActive: false,
                hasMultipleLines: true,
                storageReduceTransparency: false,
                toolbarItems: items,
                isMultiVersionMovie: isMovie,
                showAiAssistantButton: showAi,
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
          );
        }

        // 1. Locked AI Lab: right AI button hidden, all 9 default toolbar buttons present
        await tester.pumpWidget(
          buildChrome(showAi: false, items: storage.iosPlayerToolbarItems),
        );
        await tester.pump();
        for (final label in const [
          '选集',
          '线路',
          '倍速',
          '弹幕/字幕',
          '画面',
          '播放器',
          '音轨',
          '片头片尾',
          '更多',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(
          find.byKey(const Key('player-ai-assistant-button')),
          findsNothing,
        );

        // 2. Unlocked AI Lab + Multi-version Movie: right AI button symmetrical with left lock button, '选集' becomes '版本'
        await tester.pumpWidget(
          buildChrome(
            showAi: true,
            items: storage.iosPlayerToolbarItems,
            isMovie: true,
          ),
        );
        await tester.pump();
        final lockRect = tester.getRect(find.byKey(const Key('player-lock-button')));
        final aiRect = tester.getRect(
          find.byKey(const Key('player-ai-assistant-button')),
        );
        expect((lockRect.center.dy - aiRect.center.dy).abs(), lessThan(0.5));
        expect(lockRect.width, aiRect.width);
        expect(find.text('版本'), findsOneWidget);
        expect(find.text('选集'), findsNothing);

        // 3. Toolbar customizer adds 'loudness' and removes 'skip_intro_outro'
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: IosPlayerToolbarCustomizer(storage: storage),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('toolbar-remove-skip_intro_outro')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('toolbar-remove-skip_intro_outro')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('toolbar-add-loudness')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('toolbar-add-loudness')));
        await tester.pumpAndSettle();
        expect(storage.iosPlayerToolbarItems.contains('skip_intro_outro'), isFalse);
        expect(storage.iosPlayerToolbarItems.contains('loudness'), isTrue);
        expect(storage.iosPlayerToolbarItems.last, 'more');
      },
    );

    testWidgets(
      'New-3: Native & Flutter popovers expand upward near bottom dock to show >= 4 options cleanly and morph side-anchored for right AI button',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final swift = File('ios_native/MarcoLiquidGlass.swift').readAsStringSync();
        expect(swift.contains('safeAreaLayoutGuide.layoutFrame'), isTrue);
        expect(swift.contains('popover.canOverlapSourceViewRect = false'), isTrue);
        expect(swift.contains('chosenArrow = [.down]'), isTrue);
        expect(swift.contains('chosenArrow = [.right]'), isTrue);
        expect(swift.contains('useSheetFallback: chosenArrow.isEmpty'), isTrue);

        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: CupertinoButton(
                    key: const ValueKey('open-pop'),
                    onPressed: () {
                      showIosGlassPopover<void>(
                        context: ctx,
                        // Anchor near bottom toolbar (y = 352 on 390pt tall iPhone landscape)
                        anchorRect: const Rect.fromLTWH(700, 344, 48, 30),
                        title: '播放选项',
                        maxWidth: 300,
                        maxHeight: 480,
                        forceDark: true,
                        builder: (_) => ListView(
                          shrinkWrap: true,
                          children: const [
                            SizedBox(height: 48, child: Center(child: Text('选项一'))),
                            SizedBox(height: 48, child: Center(child: Text('选项二'))),
                            SizedBox(height: 48, child: Center(child: Text('选项三'))),
                            SizedBox(height: 48, child: Center(child: Text('选项四'))),
                            SizedBox(height: 48, child: Center(child: Text('选项五'))),
                          ],
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
        await tester.tap(find.byKey(const ValueKey('open-pop')));
        await tester.pumpAndSettle();

        final popRect = tester.getRect(find.byKey(const Key('ios-glass-popover-bubble')));
        expect(popRect.height, greaterThanOrEqualTo(240.0));
        expect(find.text('选项一'), findsOneWidget);
        expect(find.text('选项二'), findsOneWidget);
        expect(find.text('选项三'), findsOneWidget);
        expect(find.text('选项四'), findsOneWidget);
      },
    );

    testWidgets(
      'New-4: showIosAiSubtitleStudioSheet translates cues and mounts directly into universal overlay + live embedded line translation',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final secure = InMemorySecureCredentialStore(<String, String>{
          AiService.secureApiKeySlot: 'sk-sub-test',
        });
        final mockHttp = MockClient((req) async {
          final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
          final prompt = jsonEncode(body['messages']);
          String content = '这是实时双语翻译结果';
          if (prompt.contains('待译字幕 JSON')) {
            content = jsonEncode({
              'glossary': {'Arrakis': '厄拉科斯'},
              'items': [
                {'i': 0, 'zh': '欢迎来到厄拉科斯。'},
              ],
            });
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': content}
                  }
                ],
                'usage': {'prompt_tokens': 15, 'completion_tokens': 12},
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        AiService.instance.configureForTest(
          httpClient: mockHttp,
          secureStorage: secure,
          labUnlockedForTest: true,
          resetState: true,
        );
        await AiService.instance.setApiKey('sk-sub-test');
        await AiService.instance.saveConfig(
          const AiConfig(
            enabled: true,
            baseUrl: 'https://api.ai.example/v1',
            model: 'gpt-4.1-mini',
          ),
        );

        // 1. Live embedded subtitle line translation
        final liveZh = await AiLabService.instance.translateLiveSubtitleLine(
          seriesTitle: 'Dune',
          rawLine: 'Welcome to Arrakis.',
        );
        expect(liveZh, '这是实时双语翻译结果');

        // 2. Subtitle studio mounts cues directly to overlay callback
        List<AiSubtitleCue>? mountedCues;
        bool? mountedBilingual;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: CupertinoButton(
                    key: const ValueKey('open-sub-studio'),
                    onPressed: () {
                      showIosAiSubtitleStudioSheet(
                        ctx,
                        seriesTitle: 'Dune',
                        episodeLabel: '4K · 杜比视界',
                        skipIntroSeconds: 0,
                        currentActiveCueLines: const ['Welcome to Arrakis.'],
                        onToggleLiveEmbeddedTranslate: (_) {},
                        onApplySubtitleOverlay: (
                          cues, {
                          required bilingual,
                          required offset,
                          required label,
                        }) async {
                          mountedCues = cues;
                          mountedBilingual = bilingual;
                        },
                      );
                    },
                    child: const Text('Sub'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-sub-studio')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ai-sub-translate-mount-btn')));
        await tester.pumpAndSettle();

        expect(mountedCues, isNotNull);
        expect(mountedCues!.single.translatedText, '欢迎来到厄拉科斯。');
        expect(mountedBilingual, isTrue);
      },
    );

    testWidgets(
      'New-5: Multi-resource movies are NOT misidentified as Episode 1 / Episode 2',
      (tester) async {
        const movieResources = <CmsEpisode>[
          CmsEpisode(
            name: '奥本海默.2023.2160p.UHD.BluRay.DV.HDR.mkv',
            url: 'https://pan.quark.cn/s/op1',
          ),
          CmsEpisode(
            name: '奥本海默.2023.1080p.AAC.中英双字.mp4',
            url: 'https://pan.quark.cn/s/op2',
          ),
          CmsEpisode(
            name: '幕后制作特辑花絮.mp4',
            url: 'https://pan.quark.cn/s/op3',
          ),
        ];
        expect(
          EpisodeScraper.isLikelyMultiVersionMovie(
            movieResources,
            videoTitle: '奥本海默',
            videoTag: '剧情 / 传记 / 电影',
            videoRemarks: 'HD中字',
          ),
          isTrue,
        );

        // True episodic series must remain episodic
        const tvEpisodes = <CmsEpisode>[
          CmsEpisode(name: 'S01E01.mkv', url: 'https://cdn.example/1.mkv'),
          CmsEpisode(name: 'S01E02.mkv', url: 'https://cdn.example/2.mkv'),
        ];
        expect(
          EpisodeScraper.isLikelyMultiVersionMovie(
            tvEpisodes,
            videoTitle: '庆余年第二季',
            videoTag: '国产剧',
          ),
          isFalse,
        );

        // Verify PlayerEpisodePickerSheet shows version labels instead of #01 / #02
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: PlayerEpisodePickerSheet(
                lines: const [CmsLine(name: '夸克原盘', episodes: movieResources)],
                initialLineIndex: 0,
                activeLineIndex: 0,
                activeEpisodeIndex: 0,
                seriesTitle: '奥本海默',
                isMultiVersionMovie: true,
                onSelect: (_, __) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('4K · 杜比视界'), findsOneWidget);
        expect(find.text('#01'), findsNothing);
      },
    );

    testWidgets(
      'New-6 & New-7: Retired AI skills removed, grounded WatchBrief/PostCredits/WorkQA work, and OAuth full model catalog + 5h/weekly quota + usage detail page work end-to-end',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        // 1. Verify retired skills (台词金句 / 外语学习卡) are stripped even if persisted in legacy config JSON
        final migratedCfg = AiConfig.fromJson({
          'enabled': true,
          'customSkills': [
            {
              'id': 'builtin_quotes',
              'name': '台词金句与隐喻赏析',
              'promptTemplate': 'legacy',
            },
            {
              'id': 'builtin_lang_notes',
              'name': '外语地道表达学习卡',
              'promptTemplate': 'legacy',
            },
          ],
        });
        expect(
          migratedCfg.effectiveSkills.map((s) => s.id),
          isNot(contains('builtin_quotes')),
        );
        expect(
          migratedCfg.effectiveSkills.map((s) => s.id),
          isNot(contains('builtin_lang_notes')),
        );

        // 2. Verify OAuth model list keeps visibility="none"/"hide" models + merges full subscription catalog,
        //    captures 5h + weekly quota from wham/usage & codex headers, and renders IosAiUsageDetailPage
        final expSec = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
        final authKey = ['https://', 'api.openai', '.com/auth'].join();
        final jwt = _fakeJwt({
          'email': 'plus_vip@ai.example',
          'exp': expSec,
          authKey: {
            'chatgpt_account_id': 'acct_plus_99',
            'chatgpt_plan_type': 'plus',
          },
        });

        final mockHttp = MockClient.streaming((req, bodyStream) async {
          final bodyBytes = await bodyStream.toBytes();
          final bodyStr = utf8.decode(bodyBytes, allowMalformed: true);
          if (req.url.path.endsWith('/codex/models')) {
            final payload = jsonEncode({
              'models': [
                {
                  'slug': 'gpt-5.4',
                  'display_name': 'GPT-5.4',
                  'visibility': 'list',
                  'priority': 1,
                },
                {
                  'slug': 'o3-pro',
                  'display_name': 'o3-pro',
                  'visibility': 'none',
                  'priority': 2,
                },
              ],
            });
            return http.StreamedResponse(
              Stream.value(utf8.encode(payload)),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (req.url.path.endsWith('/wham/usage')) {
            final payload = jsonEncode({
              'plan_type': 'plus',
              'rate_limit': {
                'primary_window': {
                  'used_percent': 35,
                  'limit_window_seconds': 18000,
                  'reset_after_seconds': 7200,
                },
                'secondary_window': {
                  'used_percent': 18,
                  'limit_window_seconds': 604800,
                  'reset_after_seconds': 259200,
                },
              },
            });
            return http.StreamedResponse(
              Stream.value(utf8.encode(payload)),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (req.url.path.endsWith('/codex/responses')) {
            String answerText = 'OK';
            if (bodyStr.contains('oneLineHook')) {
              answerText = jsonEncode({
                'oneLineHook': '硬核克制的太空史诗续作',
                'highlights': ['IMAX 画幅沙虫骑行场面震撼'],
                'background': ['改编自弗兰克·赫伯特同名科幻小说'],
                'viewingNote': '建议佩戴耳机体验汉斯·季默配乐',
              });
            } else if (bodyStr.contains('has_stinger')) {
              answerText = jsonEncode({
                'status': 'none',
                'stingerSummary': '片尾字幕结束后无额外画面彩蛋，可放心离场。',
                'versionTip': '推荐优先选择 4K 杜比视界高码原盘。',
              });
            }
            final sse = [
              'event: response.output_text.delta',
              'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': answerText})}',
              '',
              'event: response.completed',
              'data: {"type":"response.completed","response":{"usage":{"input_tokens":42,"output_tokens":28}}}',
              '',
            ].join('\n');
            return http.StreamedResponse(
              Stream.value(utf8.encode(sse)),
              200,
              headers: {
                'content-type': 'text/event-stream',
                'x-codex-primary-used-percent': '38',
                'x-codex-secondary-used-percent': '19',
              },
            );
          }
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
        });

        final secure = InMemorySecureCredentialStore();
        final ai = AiService(httpClient: mockHttp, secureStorage: secure);
        ai.configureForTest(
          codexModelsEndpoint: 'https://codex.ai.example/backend-api/codex/models',
          codexResponsesEndpoint:
              'https://codex.ai.example/backend-api/codex/responses',
          codexUsageEndpoint: 'https://codex.ai.example/backend-api/wham/usage',
          labUnlockedForTest: true,
        );
        await ai.setOAuthSession(
          AiOAuthSession(
            accessToken: jwt,
            refreshToken: 'rt_plus',
            expiresAtEpochMs: expSec * 1000,
            accountId: 'acct_plus_99',
            email: 'plus_vip@ai.example',
            planType: 'plus',
          ),
        );
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.codexOAuth,
            model: 'gpt-5.4',
          ),
        );

        final models = await ai.fetchAvailableModelOptions();
        expect(
          models.map((m) => m.id),
          containsAll(['gpt-5.4', 'o3-pro', 'gpt-5.3-codex', 'o3', 'gpt-4.1', 'gpt-4o']),
        );

        final lab = AiLabService(ai);
        final brief = await lab.generateWatchBrief(title: '沙丘2', year: '2024');
        expect(brief.oneLineHook, contains('太空史诗'));
        final stinger = await lab.checkPostCreditsGuide(title: '沙丘2', year: '2024');
        expect(stinger.status, 'none');
        expect(ai.usageHistory.length, 2);
        expect(ai.subscriptionQuota?.fiveHourWindow.usedPercent, 38.0);
        expect(ai.subscriptionQuota?.weeklyWindow.usedPercent, 19.0);

        // Render IosAiSettingsPage -> verify inline 5h/weekly quota card & tap into IosAiUsageDetailPage
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: IosAiSettingsPage(service: ai),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const ValueKey('ios-ai-usage-detail-row')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-ai-sub-quota-card')), findsOneWidget);
        expect(find.textContaining('5 小时窗口额度'), findsOneWidget);
        expect(find.textContaining('7 天周额度'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('ios-ai-usage-detail-row')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-ai-usage-detail-page')), findsOneWidget);
        expect(find.textContaining('零剧透看点与设定科普'), findsWidgets);
        expect(find.textContaining('片尾彩蛋与版本提示'), findsWidgets);
      },
    );

    testWidgets(
      'New-8 (API Balance): parses Credit Grants, Billing Subscription+Usage, OpenRouter Credits, DeepSeek CNY, Moonshot/SiliconFlow, unlimited quota, blocks redirects, isolates endpoints, and renders in Settings + Usage Detail',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        // 1. Pure parser unit checks across common BYO-API schemas
        final nowMs = 1795750000000;
        final cg = AiService.parseApiBalancePayload(
          {
            'currency': 'USD',
            'total_granted': 25.0,
            'total_used': 4.25,
            'total_available': 20.75,
          },
          endpointKey: 'https://relay.ai.example/v1',
          sourceKind: 'credit_grants',
          nowMs: nowMs,
        );
        expect(cg?.supported, isTrue);
        expect(cg?.headlineTextZh, r'剩余 $20.75');
        expect(cg?.detailSubtitleZh, contains(r'已用 $4.25 / 总额 $25.00'));
        expect(cg?.usedRatio, closeTo(4.25 / 25.0, 0.001));

        final unlimited = AiService.parseApiBalancePayload(
          {'unlimited_quota': true, 'total_used': 1.5},
          endpointKey: 'https://relay.ai.example/v1',
          sourceKind: 'credit_grants',
          nowMs: nowMs,
        );
        expect(unlimited?.isUnlimited, isTrue);
        expect(unlimited?.headlineTextZh, '无限额度');

        final orCredits = AiService.parseApiBalancePayload(
          {
            'data': {'total_credits': 30.0, 'total_usage': 6.5},
          },
          endpointKey: 'https://openrouter.ai/api/v1',
          sourceKind: 'credits',
          nowMs: nowMs,
        );
        expect(orCredits?.headlineTextZh, r'剩余 $23.50');

        final dsBalance = AiService.parseApiBalancePayload(
          {
            'is_available': true,
            'balance_infos': [
              {'currency': 'CNY', 'total_balance': '48.60'},
            ],
          },
          endpointKey: 'https://api.deepseek.com/v1',
          sourceKind: 'user_balance',
          nowMs: nowMs,
        );
        expect(dsBalance?.headlineTextZh, '剩余 ¥48.60');

        final sfInfo = AiService.parseApiBalancePayload(
          {
            'data': {'totalBalance': '19.8', 'balance': '12.0'},
          },
          endpointKey: 'https://api.siliconflow.cn/v1',
          sourceKind: 'user_info',
          nowMs: nowMs,
        );
        expect(sfInfo?.headlineTextZh, '剩余 ¥19.80');

        // 2. Live probe: credit_grants 302 redirect MUST be ignored (no cross-origin leak),
        //    falling through to billing/subscription + billing/usage (cents deduction)
        final mockHttp = MockClient((req) async {
          if (req.url.path.endsWith('/dashboard/billing/credit_grants')) {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://evil.example/steal'},
            );
          }
          if (req.url.path.endsWith('/dashboard/billing/subscription')) {
            return http.Response(
              jsonEncode({'currency': 'USD', 'hard_limit_usd': 50.0}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (req.url.path.endsWith('/dashboard/billing/usage')) {
            // 1235 cents = $12.35 -> remaining $37.65
            return http.Response(
              jsonEncode({'total_usage': 1235.0}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        });

        final secure = InMemorySecureCredentialStore(<String, String>{
          AiService.secureApiKeySlot: 'sk-balance-test-key',
        });
        final ai = AiService(
          httpClient: mockHttp,
          secureStorage: secure,
          clock: () => DateTime.utc(2026, 11, 27, 12, 0),
        );
        ai.configureForTest(labUnlockedForTest: true);
        await ai.saveConfig(
          const AiConfig(
            enabled: true,
            authMode: AiAuthMode.apiKey,
            protocol: AiApiProtocol.openaiCompatible,
            baseUrl: 'https://relay.ai.example/v1',
            model: 'gpt-4.1-mini',
          ),
        );

        final liveBal = await ai.refreshApiBalance(force: true);
        expect(liveBal, isNotNull);
        expect(liveBal!.supported, isTrue);
        expect(liveBal.headlineTextZh, r'剩余 $37.65');
        expect(liveBal.totalUsed, closeTo(12.35, 0.001));
        expect(liveBal.totalGranted, closeTo(50.0, 0.001));

        // 3. Render IosAiSettingsPage & drill into IosAiUsageDetailPage -> API balance visible on both
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: IosAiSettingsPage(service: ai),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('ios-ai-api-balance-card')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios-ai-api-balance-card')), findsOneWidget);
        expect(find.textContaining(r'剩余 $37.65'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('ios-ai-usage-detail-row')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ios-ai-usage-detail-balance-card')),
          findsOneWidget,
        );
        expect(find.textContaining(r'剩余 $37.65'), findsOneWidget);

        // 4. Switching Base URL hides stale balance from the previous provider
        await ai.saveConfig(
          ai.config.copyWith(baseUrl: 'https://other.ai.example/v1'),
        );
        expect(ai.apiBalance, isNull);

        // 5. Unsupported provider degrades gracefully without throwing
        final unsupportedClient = MockClient((_) async => http.Response('{}', 404));
        ai.configureForTest(httpClient: unsupportedClient, labUnlockedForTest: true);
        final fallbackBal = await ai.refreshApiBalance(force: true);
        expect(fallbackBal?.supported, isFalse);
        expect(fallbackBal?.headlineTextZh, '当前接口未公开余额查询');
      },
    );
  });
}

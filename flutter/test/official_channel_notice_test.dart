// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/mobile_player_chrome.dart';
import 'package:marco_movie/ui/official_channel_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _R17FakePlatformPlayer extends Fake implements PlatformPlayer {
  final Map<String, String> properties = <String, String>{};

  Future<void> setProperty(String key, String value) async {
    properties[key] = value;
  }
}

class _R17FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist(<Media>[]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(seconds: 5);
  Duration durationValue = const Duration(minutes: 45);
  double volumeValue = 100.0;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();

  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => playingValue;
  @override
  bool get completed => completedValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => bufferingValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  Track get track => trackValue;
}

class _R17FakePlayerStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast();
  final heightCtrl = StreamController<int?>.broadcast();
  final trackCtrl = StreamController<Track>.broadcast();
  final tracksCtrl = StreamController<Tracks>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final bufferingCtrl = StreamController<bool>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();

  @override
  Stream<int?> get width => widthCtrl.stream;
  @override
  Stream<int?> get height => heightCtrl.stream;
  @override
  Stream<Track> get track => trackCtrl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtrl.stream;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<bool> get buffering => bufferingCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;

  Future<void> close() async {
    await Future.wait<void>(<Future<void>>[
      widthCtrl.close(),
      heightCtrl.close(),
      trackCtrl.close(),
      tracksCtrl.close(),
      positionCtrl.close(),
      durationCtrl.close(),
      playingCtrl.close(),
      bufferingCtrl.close(),
      completedCtrl.close(),
      errorCtrl.close(),
    ]);
  }
}

class _R17FakePlayer extends Fake implements Player {
  final _R17FakePlayerState _state = _R17FakePlayerState();
  final _R17FakePlayerStream _stream = _R17FakePlayerStream();
  final _R17FakePlatformPlayer _platform = _R17FakePlatformPlayer();
  bool disposed = false;

  @override
  PlatformPlayer? get platform => _platform;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      _state.playlistValue = Playlist(<Media>[playable]);
    }
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(1920);
      _stream.heightCtrl.add(1080);
      _stream.positionCtrl.add(const Duration(seconds: 1));
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double v) async {
    _state.volumeValue = v;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

class _FaultyNoticeWriteStore extends InMemorySharedPreferencesStore {
  _FaultyNoticeWriteStore(
    this.mode, {
    this.failReloadAfterRefusal = false,
  }) : super.withData({});
  final String mode;
  final bool failReloadAfterRefusal;
  bool refuseRead = false;
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${OnboardingPrefs.officialChannelNoticeVersionKey}') {
      writes++;
      if (mode != 'ok' && failReloadAfterRefusal) {
        refuseRead = true;
      }
      if (mode == 'throw') {
        throw PlatformException(
          code: 'write_failed',
          message: 'Local preference write unavailable',
        );
      }
      if (mode == 'false') {
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    if (refuseRead) {
      throw PlatformException(
        code: 'reload_unavailable',
        message: 'Reload unavailable after write failure',
      );
    }
    return super.getAll();
  }
}

void main() {
  final clipboardWrites = <String>[];

  setUp(() {
    clipboardWrites.clear();
    OhosRuntime.resetForTesting();
    PackageInfo.setMockInitialValues(
      appName: 'Marco Movie',
      packageName: 'com.pilipala.marcomovie',
      version: '0.7.7',
      buildNumber: '100',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map<dynamic, dynamic>?;
        final text = args?['text']?.toString();
        if (text != null) clipboardWrites.add(text);
        return null;
      }
      return null;
    });
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  CmsClient buildEmptyClient() => CmsClient(
        client: MockClient(
          (_) async => http.Response('{"class":[],"list":[]}', 200),
        ),
      );

  group('OnboardingPrefs official channel notice persistence', () {
    test(
      'persists acknowledgment independently of onboarding replay and OHOS',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final prefs = await OnboardingPrefs.load();
        expect(prefs.officialChannelNoticeVersion, 0);
        expect(prefs.shouldShowOfficialChannelNotice(), isTrue);

        // HarmonyOS NEXT still requires showing the official channel notice.
        OhosRuntime.debugIsOhosOverride = true;
        expect(prefs.shouldShowOfficialChannelNotice(), isTrue);
        OhosRuntime.resetForTesting();

        await prefs.markOfficialChannelNoticeSeen();
        expect(
          prefs.officialChannelNoticeVersion,
          OnboardingPrefs.currentOfficialChannelNoticeVersion,
        );
        expect(prefs.shouldShowOfficialChannelNotice(), isFalse);

        // Replaying onboarding must NOT force the install safety dialog again.
        await prefs.resetForReplay();
        expect(prefs.shouldShowOnboarding(), isTrue);
        expect(prefs.shouldShowOfficialChannelNotice(), isFalse);
      },
    );
  });

  group('First-launch official channel & author anti-tamper dialog', () {
    testWidgets(
      'shows once on fresh install with exact social handles, official site, and anti-tamper warning, then never repeats',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        final openedUris = <Uri>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: buildEmptyClient(),
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

        expect(find.byType(OfficialChannelNoticeDialog), findsOneWidget);
        expect(find.text('PILIPALA来信'), findsOneWidget);
        for (final platform in const ['小红书', 'B站', '抖音', '公众号', '视频号']) {
          expect(find.text(platform), findsOneWidget);
        }
        expect(find.text('marcotv.wlj9919.top'), findsOneWidget);
        expect(
          find.text('下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。'),
          findsOneWidget,
        );

        // Copy social account name inside dialog
        await tester.tap(
          find.byKey(const ValueKey('official-channel-copy-social')),
        );
        await tester.pump();
        expect(clipboardWrites, contains('PILIPALA来信'));
        expect(
          find.byKey(const ValueKey('official-channel-feedback')),
          findsOneWidget,
        );

        // Open official website inside dialog
        await tester.tap(
          find.byKey(const ValueKey('official-channel-open-site')),
        );
        await tester.pump();
        expect(openedUris, equals([Uri.parse('https://marcotv.wlj9919.top')]));

        // Confirm dialog -> persists flag and advances to OnboardingScreen
        await tester.tap(
          find.byKey(const ValueKey('official-channel-notice-confirm')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
        expect(find.byType(OnboardingScreen), findsOneWidget);

        final prefs = await OnboardingPrefs.load();
        expect(prefs.shouldShowOfficialChannelNotice(), isFalse);

        // Skip onboarding so cold restart tests zero-subscription repeat launch
        await tester.tap(find.byKey(const Key('onboarding_skip_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        // Second cold launch (still zero configs) must NOT show the dialog again
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final storage2 = await StorageService.init();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage2,
              client: buildEmptyClient(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
        expect(find.byType(OnboardingScreen), findsNothing);
      },
    );

    testWidgets(
      'renders cleanly without overflow at 320x568 with 2.0x text scaling in Light and Dark modes',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        for (final brightness in const [Brightness.light, Brightness.dark]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark
                  ? ThemeData.dark()
                  : ThemeData.light(),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 568),
                  textScaler: TextScaler.linear(2.0),
                ),
                child: const Scaffold(
                  body: OfficialChannelNoticeDialog(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('PILIPALA来信'), findsOneWidget);
          expect(find.text('marcotv.wlj9919.top'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('official-channel-notice-confirm')),
            findsOneWidget,
          );
        }
      },
    );
  });

  group('Settings contact & official community entries', () {
    testWidgets(
      'iOS Settings exposes author social accounts, official community link with fallback copy, and searchable about entry',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
        });
        final storage = await StorageService.init();
        await storage.saveConfig(
          '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );

        final openedUris = <Uri>[];
        var nextOpenResult = true;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: buildEmptyClient(),
              onOpenExternalUrlForTest: (uri) async {
                openedUris.add(uri);
                return nextOpenResult;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        // Open Settings tab
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();

        // Search in iOS Settings for "交流群" -> surfaces 关于与更新
        final searchField = find.descendant(
          of: find.byKey(const ValueKey('ios-settings-search')),
          matching: find.byType(EditableText),
        );
        await tester.enterText(searchField, '交流群');
        await tester.pumpAndSettle();
        expect(find.text('关于与更新'), findsOneWidget);

        // Clear search and enter 关于与更新
        await tester.enterText(searchField, '');
        await tester.pumpAndSettle();
        final aboutCat = find.byKey(const ValueKey('settings-category-about'));
        await tester.ensureVisible(aboutCat);
        await tester.pumpAndSettle();
        await tester.tap(aboutCat);
        await tester.pumpAndSettle();

        // Verify author social handles row & copy action
        final socialsRow =
            find.byKey(const ValueKey('ios-settings-author-socials'));
        await tester.ensureVisible(socialsRow);
        await tester.pumpAndSettle();
        expect(socialsRow, findsOneWidget);
        expect(find.text('联系反馈作者（各社媒账号名）'), findsOneWidget);
        expect(
          find.text('PILIPALA来信（小红书、B站、抖音、公众号、视频号）'),
          findsOneWidget,
        );
        await tester.tap(socialsRow);
        await tester.pumpAndSettle();
        expect(clipboardWrites, contains('PILIPALA来信'));
        expect(find.text('已复制作者社媒账号名'), findsOneWidget);
        await tester.tap(find.text('好'));
        await tester.pumpAndSettle();

        // Verify official community group link opens https://marcotv.wlj9919.top
        final communityRow =
            find.byKey(const ValueKey('ios-settings-official-community'));
        await tester.ensureVisible(communityRow);
        await tester.pumpAndSettle();
        expect(find.text('官网交流群'), findsOneWidget);
        expect(find.text('https://marcotv.wlj9919.top'), findsOneWidget);
        await tester.tap(communityRow);
        await tester.pumpAndSettle();
        expect(openedUris, equals([Uri.parse('https://marcotv.wlj9919.top')]));

        // Verify fallback to clipboard + alert when browser launch fails
        clipboardWrites.clear();
        nextOpenResult = false;
        await tester.tap(communityRow);
        await tester.pumpAndSettle();
        expect(clipboardWrites, contains('https://marcotv.wlj9919.top'));
        expect(find.text('已复制官网交流群链接'), findsOneWidget);
        await tester.tap(find.text('好'));
        await tester.pumpAndSettle();

        // Verify re-opening the official channel safety notice from Settings
        final noticeRow =
            find.byKey(const ValueKey('ios-settings-official-notice'));
        await tester.ensureVisible(noticeRow);
        await tester.pumpAndSettle();
        await tester.tap(noticeRow);
        await tester.pumpAndSettle();
        expect(find.byType(OfficialChannelNoticeDialog), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('official-channel-notice-confirm')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'non-iOS Flutter Settings exposes author social accounts and official community group link',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = const Size(1200, 820);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
        });
        final storage = await StorageService.init();
        await storage.saveConfig(
          '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );
        final openedUris = <Uri>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: buildEmptyClient(),
              onOpenExternalUrlForTest: (uri) async {
                openedUris.add(uri);
                return true;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();

        final socialsRow = find.byKey(const ValueKey('settings-author-socials'));
        await tester.scrollUntilVisible(
          socialsRow,
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(find.text('联系反馈作者（各社媒账号名）'), findsOneWidget);
        expect(
          find.text('PILIPALA来信（小红书、B站、抖音、公众号、视频号）'),
          findsOneWidget,
        );

        final communityRow =
            find.byKey(const ValueKey('settings-official-community'));
        await tester.scrollUntilVisible(
          communityRow,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(find.text('官网交流群'), findsOneWidget);
        expect(find.text('https://marcotv.wlj9919.top'), findsOneWidget);
        await tester.tap(communityRow);
        await tester.pumpAndSettle();
        expect(openedUris, equals([Uri.parse('https://marcotv.wlj9919.top')]));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('R15 P2 fault tolerance: preference write & clipboard/link failures', () {
    for (final mode in const ['ok', 'false', 'throw']) {
      testWidgets(
        'fresh install confirmation lets session continue when preference write mode=$mode and reconciles persisted state',
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        (tester) async {
          final originalStore = SharedPreferencesStorePlatform.instance;
          final store = _FaultyNoticeWriteStore(mode);
          SharedPreferences.setMockInitialValues(<String, Object>{});
          SharedPreferencesStorePlatform.instance = store;
          addTearDown(() {
            SharedPreferencesStorePlatform.instance = originalStore;
          });

          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final storage = await StorageService.init();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: AdaptiveShell(
                storage: storage,
                client: buildEmptyClient(),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 300));

          expect(find.byType(OfficialChannelNoticeDialog), findsOneWidget);
          final confirmFinder = find.byKey(
            const ValueKey('official-channel-notice-confirm'),
          );
          Object? callbackError;
          final dynamic onPressed =
              tester.widget<CupertinoButton>(confirmFinder).onPressed;
          try {
            await onPressed();
          } catch (e) {
            callbackError = e;
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 300));

          final marker = (await store.getAll())[
              'flutter.${OnboardingPrefs.officialChannelNoticeVersionKey}'];
          expect(callbackError, isNull);
          expect(store.writes, 1);
          expect(find.byType(OfficialChannelNoticeDialog), findsNothing);
          expect(find.byType(OnboardingScreen), findsOneWidget);

          final reloadedPrefs = await OnboardingPrefs.load();
          if (mode == 'ok') {
            expect(marker, OnboardingPrefs.currentOfficialChannelNoticeVersion);
            expect(reloadedPrefs.shouldShowOfficialChannelNotice(), isFalse);
          } else {
            expect(marker, isNull);
            expect(reloadedPrefs.shouldShowOfficialChannelNotice(), isTrue);
          }

          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    test('openOfficialChannelUrl distinguishes opened, copiedFallback, and failed',
        () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var allowClipboard = true;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (!allowClipboard) {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          final args = call.arguments as Map<dynamic, dynamic>?;
          final text = args?['text']?.toString();
          if (text != null) clipboardWrites.add(text);
        }
        return null;
      });

      expect(
        await openOfficialChannelUrl(
          OfficialChannelInfo.officialWebsiteUri,
          urlOpener: (_) async => true,
        ),
        OfficialLinkOpenStatus.opened,
      );
      expect(clipboardWrites, isEmpty);

      expect(
        await openOfficialChannelUrl(
          OfficialChannelInfo.officialWebsiteUri,
          urlOpener: (_) async => false,
        ),
        OfficialLinkOpenStatus.copiedFallback,
      );
      expect(clipboardWrites, contains(OfficialChannelInfo.officialWebsiteUrl));

      allowClipboard = false;
      expect(
        await openOfficialChannelUrl(
          OfficialChannelInfo.officialWebsiteUri,
          urlOpener: (_) async => false,
        ),
        OfficialLinkOpenStatus.failed,
      );
      expect(
        await copyOfficialChannelText(OfficialChannelInfo.authorSocialName),
        isFalse,
      );
    });

    testWidgets(
      'OfficialChannelNoticeDialog reports failure honestly and exposes selectable plain text when clipboard fails',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: OfficialChannelNoticeDialog(
                urlOpener: (_) async => false,
              ),
            ),
          ),
        );

        await tester.tap(
          find.byKey(const ValueKey('official-channel-copy-social')),
        );
        await tester.pumpAndSettle();
        final copyFeedback = tester
            .widget<Text>(find.byKey(const ValueKey('official-channel-feedback')))
            .data!;
        expect(copyFeedback.startsWith('已复制'), isFalse);
        final manualSocial = tester.widget<SelectableText>(
          find.byKey(const ValueKey('official-channel-manual-select-text')),
        );
        expect(manualSocial.data, OfficialChannelInfo.authorSocialName);

        await tester.tap(
          find.byKey(const ValueKey('official-channel-open-site')),
        );
        await tester.pumpAndSettle();
        final openFeedback = tester
            .widget<Text>(find.byKey(const ValueKey('official-channel-feedback')))
            .data!;
        expect(openFeedback.startsWith('已复制'), isFalse);
        final manualUrl = tester.widget<SelectableText>(
          find.byKey(const ValueKey('official-channel-manual-select-text')),
        );
        expect(manualUrl.data, OfficialChannelInfo.officialWebsiteUrl);
      },
    );

    testWidgets(
      'iOS Settings shows selectable manual fallback dialog when copy or open+copy fails',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        });

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
        });
        final storage = await StorageService.init();
        await storage.saveConfig(
          '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: buildEmptyClient(),
              onOpenExternalUrlForTest: (_) async => false,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        final aboutCat = find.byKey(const ValueKey('settings-category-about'));
        await tester.ensureVisible(aboutCat);
        await tester.pumpAndSettle();
        await tester.tap(aboutCat);
        await tester.pumpAndSettle();

        // Copy social name fails -> must show manual-select dialog, never "已复制"
        final socialsRow =
            find.byKey(const ValueKey('ios-settings-author-socials'));
        await tester.ensureVisible(socialsRow);
        await tester.pumpAndSettle();
        await tester.tap(socialsRow);
        await tester.pumpAndSettle();
        expect(find.text('已复制作者社媒账号名'), findsNothing);
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('official-channel-manual-select-text')),
              )
              .data,
          OfficialChannelInfo.authorSocialName,
        );
        await tester.tap(
          find.byKey(const ValueKey('official-channel-manual-copy-ok')),
        );
        await tester.pumpAndSettle();

        // Open community URL fails AND clipboard fails -> manual-select URL dialog
        final communityRow =
            find.byKey(const ValueKey('ios-settings-official-community'));
        await tester.ensureVisible(communityRow);
        await tester.pumpAndSettle();
        await tester.tap(communityRow);
        await tester.pumpAndSettle();
        expect(find.text('已复制官网交流群链接'), findsNothing);
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('official-channel-manual-select-text')),
              )
              .data,
          OfficialChannelInfo.officialCommunityUrl,
        );
        await tester.tap(
          find.byKey(const ValueKey('official-channel-manual-copy-ok')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('R16 P2 regressions: Settings origin scoping, dedup, reload failure & orientation retry', () {
    for (final mode in const ['false', 'throw']) {
      test(
        'markOfficialChannelNoticeSeen returns false when write fails ($mode) AND reload also throws',
        () async {
          final originalStore = SharedPreferencesStorePlatform.instance;
          final store = _FaultyNoticeWriteStore(
            mode,
            failReloadAfterRefusal: true,
          );
          SharedPreferences.setMockInitialValues(<String, Object>{});
          SharedPreferencesStorePlatform.instance = store;
          addTearDown(() {
            SharedPreferencesStorePlatform.instance = originalStore;
          });

          final prefs = await OnboardingPrefs.load();
          final saved = await prefs.markOfficialChannelNoticeSeen();
          expect(saved, isFalse);
          expect(store.writes, 1);

          store.refuseRead = false;
          SharedPreferences.setMockInitialValues(<String, Object>{});
          SharedPreferencesStorePlatform.instance = store;
          expect(
            (await OnboardingPrefs.load()).shouldShowOfficialChannelNotice(),
            isTrue,
          );
        },
      );
    }

    testWidgets(
      'Settings community link suppresses late failure popup after leaving About, deduplicates double tap, and retries cleanly after dismiss',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        });

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
        });
        final storage = await StorageService.init();
        await storage.saveConfig(
          '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );

        var openerCalls = 0;
        Completer<bool> activeCompleter = Completer<bool>();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: buildEmptyClient(),
              onOpenExternalUrlForTest: (_) {
                openerCalls++;
                return activeCompleter.future;
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        final aboutCat = find.byKey(const ValueKey('settings-category-about'));
        await tester.ensureVisible(aboutCat);
        await tester.pumpAndSettle();
        await tester.tap(aboutCat);
        await tester.pumpAndSettle();

        final communityRow =
            find.byKey(const ValueKey('ios-settings-official-community'));
        await tester.ensureVisible(communityRow);
        await tester.pumpAndSettle();

        // 1. Leave About while open+clipboard failure is pending -> 0 dialogs!
        await tester.tap(communityRow);
        await tester.pump();
        expect(openerCalls, 1);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(communityRow, findsNothing);
        activeCompleter.complete(false);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsNothing,
        );

        // 2. Re-enter About, tap twice while pending -> 1 call, 1 dialog!
        await tester.ensureVisible(aboutCat);
        await tester.pumpAndSettle();
        await tester.tap(aboutCat);
        await tester.pumpAndSettle();
        await tester.ensureVisible(communityRow);
        await tester.pumpAndSettle();

        activeCompleter = Completer<bool>();
        await tester.tap(communityRow);
        await tester.pump();
        await tester.tap(communityRow);
        await tester.pump();
        expect(openerCalls, 2);
        activeCompleter.complete(false);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('official-channel-manual-select-text')),
              )
              .data,
          OfficialChannelInfo.officialCommunityUrl,
        );

        // 3. Dismiss dialog -> tapping again retries cleanly!
        await tester.tap(
          find.byKey(const ValueKey('official-channel-manual-copy-ok')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsNothing,
        );

        activeCompleter = Completer<bool>();
        await tester.tap(communityRow);
        await tester.pump();
        expect(openerCalls, 3);
        activeCompleter.complete(false);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('official-channel-manual-copy-ok')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'Settings author social copy suppresses late dialog after leaving About and deduplicates in-flight taps',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var clipboardCalls = 0;
        Completer<void> pendingCopy = Completer<void>();
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCalls++;
            await pendingCopy.future;
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        });

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        SharedPreferences.setMockInitialValues(<String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
        });
        final storage = await StorageService.init();
        await storage.saveConfig(
          '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: AdaptiveShell(
              storage: storage,
              client: buildEmptyClient(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        final aboutCat = find.byKey(const ValueKey('settings-category-about'));
        await tester.ensureVisible(aboutCat);
        await tester.pumpAndSettle();
        await tester.tap(aboutCat);
        await tester.pumpAndSettle();

        final socialsRow =
            find.byKey(const ValueKey('ios-settings-author-socials'));
        await tester.ensureVisible(socialsRow);
        await tester.pumpAndSettle();

        // Double tap while pending -> only 1 clipboard call, leave About -> 0 dialogs
        await tester.tap(socialsRow);
        await tester.pump();
        await tester.tap(socialsRow);
        await tester.pump();
        expect(clipboardCalls, 1);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        pendingCopy.complete();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'MobilePlayerChrome.setOrientationMonitoring(true) recovers after host_unavailable during engine handoff gap',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var nativeCalls = 0;
        var hostAttached = false;
        messenger.setMockMethodCallHandler(
          MobilePlayerChrome.iosSystemChromeChannel,
          (call) async {
            if (call.method == 'setOrientationMonitoring') {
              nativeCalls++;
              if (!hostAttached && call.arguments == true) {
                throw PlatformException(
                  code: 'host_unavailable',
                  message: 'No attached FlutterViewController',
                );
              }
              return null;
            }
            return null;
          },
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            MobilePlayerChrome.iosSystemChromeChannel,
            null,
          );
        });

        final chrome = MobilePlayerChrome();
        // Attempt during handoff gap fails recoverably -> resets flag
        await chrome.setOrientationMonitoring(true);
        expect(nativeCalls, 1);

        // Once engine reattaches to B, retry invokes native channel again
        hostAttached = true;
        await chrome.setOrientationMonitoring(true);
        expect(nativeCalls, 2);
        await chrome.setOrientationMonitoring(false);
        expect(nativeCalls, 3);
      },
    );
  });

  group(
    'R17/R18 P2 regressions: PlayerScreen host-epoch recovery & notice/settings clipboard guards',
    () {
      for (final mode in <String>[
        'healthy-owner',
        'attached-then-replaced',
        'short-silent-gap',
        'long-silent-gap',
        'long-gap-with-resume',
        'gap-exit',
      ]) {
        testWidgets(
          'PlayerScreen follows engine host for physical orientation monitoring (mode=$mode)',
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            IosLiquidGlassBridge.setAvailableForTest(false);
            String? currentHost =
                (mode == 'healthy-owner' || mode == 'attached-then-replaced')
                ? 'A'
                : null;
            String? registeredHost;
            var enableRequests = 0;
            var enableSuccesses = 0;
            var disableRequests = 0;
            var landscapeRequests = 0;
            var active = false;

            messenger.setMockMethodCallHandler(
              MobilePlayerChrome.iosSystemChromeChannel,
              (call) async {
                if (call.method == 'setOrientationMonitoring') {
                  if (call.arguments == true) {
                    enableRequests++;
                    if (currentHost == null) {
                      throw PlatformException(code: 'host_unavailable');
                    }
                    registeredHost = currentHost;
                    active = true;
                    enableSuccesses++;
                  } else {
                    active = false;
                    registeredHost = null;
                    disableRequests++;
                  }
                } else if (call.method == 'requestOrientation' &&
                    call.arguments == 'landscape') {
                  landscapeRequests++;
                }
                return null;
              },
            );
            messenger.setMockMethodCallHandler(
              const MethodChannel('marco_movie/ios_avplayer_events'),
              (_) async => null,
            );
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              (call) async {
                switch (call.method) {
                  case 'getTelemetry':
                    return <String, Object?>{
                      'thermalState': 'nominal',
                      'physicalMemoryBytes': 6442450944,
                      'isPipSupported': true,
                      'isPipPossible': false,
                      'isPipActive': false,
                      'systemVolume': 0.5,
                      'isAirPlayActive': false,
                    };
                  case 'getSystemVolume':
                    return 0.5;
                  default:
                    return true;
                }
              },
            );
            addTearDown(() {
              messenger.setMockMethodCallHandler(
                MobilePlayerChrome.iosSystemChromeChannel,
                null,
              );
              messenger.setMockMethodCallHandler(
                const MethodChannel('marco_movie/ios_avplayer_events'),
                null,
              );
              messenger.setMockMethodCallHandler(
                IosAvPlayerController.defaultChannel,
                null,
              );
            });

            SharedPreferences.setMockInitialValues(<String, Object>{
              StorageService.keyMediaDiskCacheLimitMb: 0,
              StorageService.keyDiskCacheMaxMb: 0,
            });
            final storage = await StorageService.init();
            final prefs = PlayerHudPrefs(isDesktop: false);
            final avCtrl = IosAvPlayerController(
              platformOverride: TargetPlatform.iOS,
              isOhosOverride: false,
              isWebOverride: false,
            );
            final fakePlayer = _R17FakePlayer();
            const site = CmsSite(
              key: 'vod1',
              name: '测试源',
              type: 1,
              api: 'https://vod.example/api',
            );
            const video = CmsVideo(
              id: 'r17_v1',
              title: '宿主恢复测试片',
              lines: <CmsLine>[
                CmsLine(
                  name: '主线',
                  episodes: <CmsEpisode>[
                    CmsEpisode(name: '第1集', url: 'https://cdn.example/1.mp4'),
                  ],
                ),
              ],
            );

            final nav = GlobalKey<NavigatorState>();
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: nav,
                initialRoute: '/player',
                theme: ThemeData.dark(),
                home: const SizedBox(),
                routes: <String, WidgetBuilder>{
                  '/player': (_) => PlayerScreen(
                        site: site,
                        video: video,
                        initialLineIndex: 0,
                        initialEpisodeIndex: 0,
                        initialPositionMs: 0,
                        storage: storage,
                        debugPlayer: fakePlayer,
                        debugIosAvPlayerController: avCtrl,
                        debugVideoSurface: const ColoredBox(color: Colors.black),
                        debugHudPrefs: prefs,
                      ),
                },
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 120));
            expect(enableRequests, 1);
            final playerElement = tester.element(find.byType(PlayerScreen));

            if (mode == 'gap-exit') {
              // Exiting while host is still unavailable must cancel pending
              // retry timers without sending spurious disable or later enables.
              expect(await nav.currentState!.maybePop(), isTrue);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 700));
              await tester.pump(const Duration(seconds: 6));
              expect(enableRequests, 1);
              expect(enableSuccesses, 0);
              expect(disableRequests, 0);
              return;
            }

            if (mode == 'attached-then-replaced') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await tester.pump();
              currentHost = null;
              registeredHost = null;
              active = false;
              currentHost = 'B';
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
              tester.view.physicalSize = const Size(394, 852);
              await tester.pump();
            } else if (mode == 'short-silent-gap') {
              currentHost = 'B';
            } else if (mode.startsWith('long-')) {
              for (var i = 0; i < 48; i++) {
                await tester.pump(const Duration(milliseconds: 100));
              }
              expect(enableRequests, 5);
              currentHost = 'B';
              if (mode == 'long-gap-with-resume') {
                tester.binding.handleAppLifecycleStateChanged(
                  AppLifecycleState.inactive,
                );
                await tester.pump();
                tester.binding.handleAppLifecycleStateChanged(
                  AppLifecycleState.resumed,
                );
              }
            }
            for (var i = 0; i < 15; i++) {
              await tester.pump(const Duration(milliseconds: 500));
            }

            expect(
              tester.element(find.byType(PlayerScreen)),
              same(playerElement),
            );
            if (mode == 'healthy-owner') {
              expect(enableRequests, 1);
            } else if (mode == 'attached-then-replaced' ||
                mode == 'short-silent-gap') {
              expect(enableRequests, 2);
            } else {
              expect(enableRequests, 6);
            }
            expect(registeredHost, currentHost);
            expect(active, isTrue);

            final done = Completer<void>();
            await messenger.handlePlatformMessage(
              MobilePlayerChrome.iosSystemChromeChannel.name,
              MobilePlayerChrome.iosSystemChromeChannel.codec.encodeMethodCall(
                const MethodCall('physicalOrientationChanged', 'landscapeLeft'),
              ),
              (_) => done.complete(),
            );
            await done.future;
            await tester.pump();
            expect(landscapeRequests, 1);

            expect(await nav.currentState!.maybePop(), isTrue);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            expect(disableRequests, 1);
          },
        );
      }

      testWidgets(
        'MobilePlayerChrome.close() compensates if an in-flight enable succeeds after close',
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        (tester) async {
          final messenger = TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger;
          final pendingEnable = Completer<void>();
          final calls = <bool>[];
          messenger.setMockMethodCallHandler(
            MobilePlayerChrome.iosSystemChromeChannel,
            (call) async {
              if (call.method == 'setOrientationMonitoring') {
                final enabled = call.arguments as bool;
                calls.add(enabled);
                if (enabled) {
                  await pendingEnable.future;
                }
              }
              return null;
            },
          );
          addTearDown(() {
            messenger.setMockMethodCallHandler(
              MobilePlayerChrome.iosSystemChromeChannel,
              null,
            );
          });

          final chrome = MobilePlayerChrome();
          final enableFuture = chrome.setOrientationMonitoring(true);
          expect(calls, <bool>[true]);

          await chrome.close();
          expect(calls, <bool>[true]);

          pendingEnable.complete();
          await enableFuture;
          await tester.pump();
          expect(calls, <bool>[true, false]);
        },
      );

      for (final mode in <String>[
        'back-reenter-copy-fail',
        'stay-copy-fail',
        'leave-no-copy-fail',
        'stay-fail',
      ]) {
        testWidgets(
          'Settings stale external link never overwrites newer explicit copy or abandoned clipboard (mode=$mode)',
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });

            SharedPreferences.setMockInitialValues(<String, Object>{
              OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
              OnboardingPrefs.officialChannelNoticeVersionKey:
                  OnboardingPrefs.currentOfficialChannelNoticeVersion,
            });
            final storage = await StorageService.init();
            await storage.saveConfig(
              '{"sites":[{"key":"test","name":"测试源","type":1,"api":"https://source.example/api"}]}',
            );

            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            var clipboard = 'preexisting-user-clipboard';
            final writes = <String>[];
            messenger.setMockMethodCallHandler(SystemChannels.platform, (
              call,
            ) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
                writes.add(clipboard);
              } else if (call.method == 'Clipboard.getData') {
                return <String, dynamic>{'text': clipboard};
              }
              return null;
            });

            final pending = Completer<bool>();
            var opens = 0;
            await tester.pumpWidget(
              MaterialApp(
                home: AdaptiveShell(
                  storage: storage,
                  client: buildEmptyClient(),
                  onOpenExternalUrlForTest: (_) {
                    opens++;
                    return pending.future;
                  },
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 500));

            await tester.tap(find.text('设置').last);
            await tester.pumpAndSettle();
            final about = find.byKey(const ValueKey('settings-category-about'));
            final link =
                find.byKey(const ValueKey('ios-settings-official-community'));
            final social =
                find.byKey(const ValueKey('ios-settings-author-socials'));

            Future<void> enterAbout() async {
              await tester.ensureVisible(about);
              await tester.pumpAndSettle();
              await tester.tap(about);
              await tester.pumpAndSettle();
            }

            await enterAbout();
            await tester.ensureVisible(link);
            await tester.pumpAndSettle();
            await tester.tap(link);
            await tester.pump();
            expect(opens, 1);
            expect(writes, isEmpty);

            if (mode == 'back-reenter-copy-fail') {
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
              await enterAbout();
              await tester.ensureVisible(social);
              await tester.pumpAndSettle();
              await tester.tap(social);
              await tester.pumpAndSettle();
              expect(clipboard, OfficialChannelInfo.authorSocialName);
              await tester.tap(find.text('好'));
              await tester.pumpAndSettle();
            } else if (mode == 'stay-copy-fail') {
              await tester.ensureVisible(social);
              await tester.pumpAndSettle();
              await tester.tap(social);
              await tester.pumpAndSettle();
              expect(clipboard, OfficialChannelInfo.authorSocialName);
              await tester.tap(find.text('好'));
              await tester.pumpAndSettle();
            } else if (mode == 'leave-no-copy-fail') {
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
            }

            pending.complete(false);
            await tester.pumpAndSettle();

            final pasted = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
            final visibleDialogs = find.text('好').evaluate().length;
            if (mode == 'stay-fail') {
              expect(pasted, OfficialChannelInfo.officialCommunityUrl);
              expect(writes, <String>[
                OfficialChannelInfo.officialCommunityUrl,
              ]);
              expect(visibleDialogs, 1);
            } else if (mode == 'leave-no-copy-fail') {
              expect(pasted, 'preexisting-user-clipboard');
              expect(writes, isEmpty);
              expect(visibleDialogs, 0);
            } else {
              expect(pasted, OfficialChannelInfo.authorSocialName);
              expect(writes, <String>[OfficialChannelInfo.authorSocialName]);
              expect(visibleDialogs, 0);
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          },
        );
      }

      testWidgets(
        'OfficialChannelNoticeDialog protects newer explicit copy and dismissed dialog from stale website fallback',
        (tester) async {
          final messenger = TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger;
          var clipboard = 'initial';
          final writes = <String>[];
          messenger.setMockMethodCallHandler(SystemChannels.platform, (
            call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
              writes.add(clipboard);
            } else if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': clipboard};
            }
            return null;
          });

          // 1. Stay in dialog: open site pending -> copy social name -> open site fails
          final pending1 = Completer<bool>();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: OfficialChannelNoticeDialog(
                  urlOpener: (_) => pending1.future,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(
            find.byKey(const ValueKey('official-channel-open-site')),
          );
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('official-channel-copy-social')),
          );
          await tester.pumpAndSettle();
          expect(clipboard, OfficialChannelInfo.authorSocialName);

          pending1.complete(false);
          await tester.pumpAndSettle();
          expect(
            (await Clipboard.getData(Clipboard.kTextPlain))?.text,
            OfficialChannelInfo.authorSocialName,
          );
          expect(writes, <String>[OfficialChannelInfo.authorSocialName]);
          expect(
            find.textContaining(OfficialChannelInfo.authorSocialName),
            findsWidgets,
          );

          // 2. Dismiss dialog while open site pending -> no clipboard overwrite
          writes.clear();
          clipboard = 'after-close';
          final pending2 = Completer<bool>();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: OfficialChannelNoticeDialog(
                  urlOpener: (_) => pending2.future,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('official-channel-open-site')),
          );
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();

          pending2.complete(false);
          await tester.pump();
          expect(
            (await Clipboard.getData(Clipboard.kTextPlain))?.text,
            'after-close',
          );
          expect(writes, isEmpty);
        },
      );

      for (final mode in <String>[
        'stay',
        'confirm-closing',
        'barrier-closing',
        'disposed',
      ]) {
        testWidgets(
          'showOfficialChannelNoticeDialog Cupertino route invalidates pending website fallback on dismiss (mode=$mode)',
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            const initialClip = '原剪贴板内容';
            var clipboard = initialClip;
            final writes = <String>[];
            messenger.setMockMethodCallHandler(SystemChannels.platform, (
              call,
            ) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'] as String;
                writes.add(clipboard);
              } else if (call.method == 'Clipboard.getData') {
                return <String, dynamic>{'text': clipboard};
              }
              return null;
            });

            final external = Completer<bool>();
            var openerCalls = 0;
            bool? acknowledged;
            final allowBarrier = mode == 'barrier-closing';
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (ctx) => CupertinoButton(
                      onPressed: () async {
                        acknowledged = await showOfficialChannelNoticeDialog(
                          ctx,
                          barrierDismissible: allowBarrier,
                          urlOpener: (_) {
                            openerCalls++;
                            return external.future;
                          },
                        );
                      },
                      child: const Text('打开公告'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('打开公告'));
            await tester.pumpAndSettle();

            final popup = tester.element(
              find.byType(OfficialChannelNoticeDialog),
            );
            final route = ModalRoute.of(popup)!;
            expect(route.isCurrent, isTrue);

            await tester.tap(
              find.byKey(const ValueKey('official-channel-open-site')),
            );
            await tester.pump();
            expect(openerCalls, 1);

            if (mode == 'confirm-closing' || mode == 'disposed') {
              await tester.tap(
                find.byKey(const ValueKey('official-channel-notice-confirm')),
              );
              await tester.pump();
              if (mode == 'disposed') {
                await tester.pumpAndSettle();
              } else {
                await tester.pump(const Duration(milliseconds: 40));
                expect(popup.mounted, isTrue);
              }
              expect(acknowledged, isTrue);
              expect(route.isCurrent, isFalse);
            } else if (mode == 'barrier-closing') {
              await tester.tapAt(const Offset(5, 5));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 40));
              expect(popup.mounted, isTrue);
              expect(route.isCurrent, isFalse);
            }

            external.complete(false);
            await tester.pumpAndSettle();

            final pasted = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
            if (mode == 'stay') {
              expect(pasted, OfficialChannelInfo.officialWebsiteUrl);
              expect(writes, <String>[OfficialChannelInfo.officialWebsiteUrl]);
              await tester.tap(
                find.byKey(const ValueKey('official-channel-notice-confirm')),
              );
              await tester.pumpAndSettle();
            } else {
              expect(pasted, initialClip);
              expect(writes, isEmpty);
            }
          },
        );
      }

      for (final mode in <String>[
        'same-host',
        'handoff-exit-before-retry',
        'handoff-exit-after-retry',
        'handoff-exit-before-b',
      ]) {
        testWidgets(
          'PlayerScreen revokes native orientation intent on exit even after mid-handoff host_unavailable (mode=$mode)',
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            IosLiquidGlassBridge.setAvailableForTest(false);
            String? host = 'A';
            String? observer;
            var nativeDesired = false;
            var enableRequests = 0;
            var disableRequests = 0;
            var adds = 0;
            var removes = 0;

            void detachObserver() {
              if (observer != null) {
                removes++;
                observer = null;
              }
            }

            void attachObserver() {
              if (host != null && observer != host) {
                detachObserver();
                observer = host;
                adds++;
              }
            }

            void viewDidAppear(String id) {
              host = id;
              if (nativeDesired) {
                attachObserver();
              }
            }

            messenger.setMockMethodCallHandler(
              MobilePlayerChrome.iosSystemChromeChannel,
              (call) async {
                if (call.method == 'setOrientationMonitoring' &&
                    call.arguments == true) {
                  enableRequests++;
                  if (host == null) {
                    detachObserver();
                    throw PlatformException(code: 'host_unavailable');
                  }
                  nativeDesired = true;
                  attachObserver();
                } else if (call.method == 'setOrientationMonitoring') {
                  disableRequests++;
                  nativeDesired = false;
                  detachObserver();
                }
                return null;
              },
            );
            messenger.setMockMethodCallHandler(
              const MethodChannel('marco_movie/ios_avplayer_events'),
              (_) async => null,
            );
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              (call) async {
                switch (call.method) {
                  case 'getTelemetry':
                    return <String, Object?>{
                      'thermalState': 'nominal',
                      'physicalMemoryBytes': 6442450944,
                      'isPipSupported': true,
                      'isPipPossible': false,
                      'isPipActive': false,
                      'systemVolume': 0.5,
                      'isAirPlayActive': false,
                    };
                  case 'getSystemVolume':
                    return 0.5;
                  default:
                    return true;
                }
              },
            );
            addTearDown(() {
              messenger.setMockMethodCallHandler(
                MobilePlayerChrome.iosSystemChromeChannel,
                null,
              );
              messenger.setMockMethodCallHandler(
                const MethodChannel('marco_movie/ios_avplayer_events'),
                null,
              );
              messenger.setMockMethodCallHandler(
                IosAvPlayerController.defaultChannel,
                null,
              );
            });

            SharedPreferences.setMockInitialValues(<String, Object>{
              StorageService.keyMediaDiskCacheLimitMb: 0,
              StorageService.keyDiskCacheMaxMb: 0,
            });
            final storage = await StorageService.init();
            final prefs = PlayerHudPrefs(isDesktop: false);
            final avCtrl = IosAvPlayerController(
              platformOverride: TargetPlatform.iOS,
              isOhosOverride: false,
              isWebOverride: false,
            );
            final fakePlayer = _R17FakePlayer();
            const site = CmsSite(
              key: 'vod1',
              name: '测试源',
              type: 1,
              api: 'https://vod.example/api',
            );
            const video = CmsVideo(
              id: 'r19_v1',
              title: '退场注销测试片',
              lines: <CmsLine>[
                CmsLine(
                  name: '主线',
                  episodes: <CmsEpisode>[
                    CmsEpisode(name: '第1集', url: 'https://cdn.example/1.mp4'),
                  ],
                ),
              ],
            );

            final nav = GlobalKey<NavigatorState>();
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: nav,
                initialRoute: '/player',
                theme: ThemeData.dark(),
                home: const SizedBox(),
                routes: <String, WidgetBuilder>{
                  '/player': (_) => PlayerScreen(
                        site: site,
                        video: video,
                        initialLineIndex: 0,
                        initialEpisodeIndex: 0,
                        initialPositionMs: 0,
                        storage: storage,
                        debugPlayer: fakePlayer,
                        debugIosAvPlayerController: avCtrl,
                        debugVideoSurface: const ColoredBox(color: Colors.black),
                        debugHudPrefs: prefs,
                      ),
                },
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 120));
            expect(observer, 'A');
            expect(adds, 1);

            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            await tester.pump();
            if (mode != 'same-host') {
              host = null;
              detachObserver();
            }
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pump();
            expect(nativeDesired, isTrue);

            if (mode != 'same-host' && mode != 'handoff-exit-before-b') {
              viewDidAppear('B');
              expect(observer, 'B');
              await tester.pump(const Duration(milliseconds: 50));
            }
            if (mode == 'handoff-exit-after-retry') {
              await tester.pump(const Duration(milliseconds: 250));
              await tester.pump();
            }

            expect(await nav.currentState!.maybePop(), isTrue);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            expect(find.byType(PlayerScreen), findsNothing);

            if (mode == 'handoff-exit-before-b') {
              viewDidAppear('B');
            }
            await tester.pump(const Duration(seconds: 5));

            expect(enableRequests, mode == 'handoff-exit-after-retry' ? 3 : 2);
            expect(disableRequests, 1);
            expect(observer, isNull);
            expect(nativeDesired, isFalse);
            expect(removes, adds);
          },
        );
      }
    },
  );
}

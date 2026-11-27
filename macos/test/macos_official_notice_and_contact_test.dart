// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/macos_official_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

ThemeData _testMacTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor:
        isDark ? AppleColors.background : ApplePalette.light.background,
    useMaterial3: true,
  );
}

CmsClient _emptyClient() => CmsClient(
      client: MockClient(
        (_) async => http.Response('{"class":[],"list":[]}', 200),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    OhosRuntime.debugIsOhosOverride = null;
  });

  group('macOS first-launch official channel & security notice', () {
    testWidgets(
      'fresh macOS install shows official notice BEFORE onboarding, blocks backdrop dismiss, supports copy/open, then launches onboarding after confirm',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1100, 760);
        await tester.binding.setSurfaceSize(const Size(1100, 760));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final openedUrls = <String>[];
        final copiedTexts = <String>[];
        final storage = await initTestStorage();

        await tester.pumpWidget(
          MaterialApp(
            theme: _testMacTheme(Brightness.dark),
            home: AdaptiveShell(
              storage: storage,
              client: _emptyClient(),
              onOpenExternalUrlForTest: (uri) async {
                openedUrls.add(uri.toString());
                return true;
              },
              onCopyTextForTest: (text) async {
                copiedTexts.add(text);
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 250));

        // 1. Official notice dialog must appear FIRST; onboarding must wait.
        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsOneWidget,
        );
        expect(find.byType(OnboardingScreen), findsNothing);

        // 2. Verify all required author/social/website/security copy is shown.
        expect(find.text(MacosOfficialInfo.authorSocialName), findsOneWidget);
        for (final platform in MacosOfficialInfo.socialPlatforms) {
          expect(find.text(platform), findsOneWidget);
        }
        expect(
          find.text(MacosOfficialInfo.officialWebsiteDisplay),
          findsOneWidget,
        );
        expect(find.text(MacosOfficialInfo.securityWarning), findsOneWidget);

        // 3. Tapping outside backdrop must NOT dismiss or mark acknowledged.
        await tester.tapAt(const Offset(6, 6));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsOneWidget,
        );
        final prefsBeforeConfirm = await MacosOfficialNoticePrefs.load();
        expect(prefsBeforeConfirm.isAcknowledged, isFalse);

        // 4. Copying social name and opening official website work inside dialog.
        await tester.tap(find.byKey(const ValueKey('macos-copy-social-name')));
        await tester.pump();
        expect(copiedTexts, contains('PILIPALA来信'));
        expect(
          find.byKey(const ValueKey('macos-official-notice-feedback')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('macos-official-notice-open-site')),
        );
        await tester.pump();
        expect(openedUrls, equals(['https://marcotv.wlj9919.top']));
        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsOneWidget,
        );

        // 5. Confirming closes dialog, persists ack, and proceeds to OnboardingScreen.
        await tester.tap(
          find.byKey(const ValueKey('macos-official-notice-confirm')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 350));

        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsNothing,
        );
        final prefsAfterConfirm = await MacosOfficialNoticePrefs.load();
        expect(prefsAfterConfirm.isAcknowledged, isTrue);
        expect(
          prefsAfterConfirm.acknowledgedVersion,
          MacosOfficialNoticePrefs.currentVersion,
        );
        expect(find.byType(OnboardingScreen), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
      },
    );

    testWidgets(
      'existing upgraded macOS user sees official notice once, enters Home without re-running onboarding, and never sees notice on subsequent launches',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1100, 760);
        await tester.binding.setSurfaceSize(const Size(1100, 760));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // Simulate an existing macOS 0.6.0 user who already has config & completed onboarding,
        // but has never seen the new macOS official notice key.
        final storage = await initTestStorage(
          initialPrefs: const {
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          },
        );
        await storage.saveConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'demo',
                'name': '演示源',
                'type': 1,
                'api': 'https://vod.example/api',
              },
            ],
          }),
          origin: 'https://vod.example/config.json',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: _testMacTheme(Brightness.light),
            home: AdaptiveShell(storage: storage, client: _emptyClient()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsOneWidget,
        );
        expect(find.byType(OnboardingScreen), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('macos-official-notice-confirm')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsNothing,
        );
        expect(find.byType(OnboardingScreen), findsNothing);

        // Cold relaunch with persisted SharedPreferences: notice must NOT reappear.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            theme: _testMacTheme(Brightness.light),
            home: AdaptiveShell(storage: storage, client: _emptyClient()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(
          find.byKey(const ValueKey('macos-official-notice-dialog')),
          findsNothing,
        );
        expect(find.byType(OnboardingScreen), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));
      },
    );

    testWidgets(
      'strictly macOS-only: iOS, Windows, and HarmonyOS NEXT do NOT show official notice dialog or macOS settings contact section',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1100, 760);
        await tester.binding.setSurfaceSize(const Size(1100, 760));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        for (final tc in const <(TargetPlatform, bool)>[
          (TargetPlatform.windows, false),
          (TargetPlatform.iOS, false),
          (TargetPlatform.macOS, true), // HarmonyOS guard even if platform is macOS
        ]) {
          debugDefaultTargetPlatformOverride = tc.$1;
          OhosRuntime.debugIsOhosOverride = tc.$2;
          try {
            final storage = await initTestStorage(
              initialPrefs: const {
                OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
              },
            );
            await tester.pumpWidget(
              MaterialApp(
                home: AdaptiveShell(storage: storage, client: _emptyClient()),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));

            expect(
              find.byKey(const ValueKey('macos-official-notice-dialog')),
              findsNothing,
              reason: 'Official notice must not appear on ${tc.$1} (ohos=${tc.$2})',
            );

            // Switch to Settings tab and verify macOS-only contact section is absent.
            final settingsTab = find.text('设置').last;
            await tester.tap(settingsTab);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));

            expect(
              find.byKey(const ValueKey('macos-settings-contact-section')),
              findsNothing,
              reason: 'macOS contact section must stay macOS-only (${tc.$1}, ohos=${tc.$2})',
            );

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          } finally {
            debugDefaultTargetPlatformOverride = null;
            OhosRuntime.debugIsOhosOverride = null;
          }
        }
      },
    );
  });

  group('macOS Settings contact/feedback & official website group link', () {
    testWidgets(
      'Settings renders author social accounts and official group link (https://marcotv.wlj9919.top) without overflow at minimum macOS window size, opens contact sheet and handles browser launch fallback',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        // Test at minimum macOS desktop size (720x520) to guarantee zero overflow.
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(720, 520);
        await tester.binding.setSurfaceSize(const Size(720, 520));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final openedUrls = <String>[];
        final copiedTexts = <String>[];
        var allowLaunch = true;

        final storage = await initTestStorage(
          initialPrefs: const {
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
            MacosOfficialNoticePrefs.acknowledgedVersionKey:
                MacosOfficialNoticePrefs.currentVersion,
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: _testMacTheme(Brightness.dark),
            home: AdaptiveShell(
              storage: storage,
              client: _emptyClient(),
              onOpenExternalUrlForTest: (uri) async {
                openedUrls.add(uri.toString());
                return allowLaunch;
              },
              onCopyTextForTest: (text) async {
                copiedTexts.add(text);
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Navigate to Settings tab.
        await tester.tap(find.text('设置').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // Scroll to the bottom to reveal the macOS contact & official group section.
        final listView = find.byType(ListView).first;
        await tester.drag(listView, const Offset(0, -800));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.byKey(const ValueKey('macos-settings-contact-section')),
          findsOneWidget,
        );
        expect(find.textContaining('PILIPALA来信'), findsOneWidget);
        expect(
          find.textContaining('小红书、B站、抖音、公众号、视频号'),
          findsOneWidget,
        );
        expect(find.text('官网交流群链接'), findsOneWidget);
        expect(find.textContaining('marcotv.wlj9919.top'), findsWidgets);
        expect(find.text(MacosOfficialInfo.securityWarning), findsOneWidget);

        // 1. Tap 官网交流群链接 -> opens https://marcotv.wlj9919.top directly.
        final groupRow = find.byKey(
          const ValueKey('macos-settings-official-group'),
        );
        await tester.ensureVisible(groupRow);
        await tester.pump();
        await tester.tap(groupRow);
        await tester.pump();
        expect(openedUrls, equals(['https://marcotv.wlj9919.top']));

        // 2. When browser launch fails, falls back to copying URL + showing notice.
        allowLaunch = false;
        await tester.tap(groupRow);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(copiedTexts, contains('https://marcotv.wlj9919.top'));
        expect(find.text('已复制官网地址'), findsOneWidget);
        await tester.tap(find.text('好'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // 3. Tap 联系反馈作者 -> opens MacosAuthorContactSheet with copy & open actions.
        allowLaunch = true;
        final contactRow = find.byKey(
          const ValueKey('macos-settings-contact-author'),
        );
        await tester.ensureVisible(contactRow);
        await tester.pump();
        await tester.tap(contactRow);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.byKey(const ValueKey('macos-author-contact-sheet')),
          findsOneWidget,
        );
        for (final platform in MacosOfficialInfo.socialPlatforms) {
          expect(find.text(platform), findsOneWidget);
        }

        final copySocialBtn = find.byKey(
          const ValueKey('macos-contact-sheet-copy-social'),
        );
        await tester.ensureVisible(copySocialBtn);
        await tester.tap(copySocialBtn);
        await tester.pump();
        expect(copiedTexts, contains('PILIPALA来信'));
        expect(
          find.byKey(const ValueKey('macos-contact-sheet-feedback')),
          findsOneWidget,
        );

        final openGroupBtn = find.byKey(
          const ValueKey('macos-contact-sheet-open-group'),
        );
        await tester.ensureVisible(openGroupBtn);
        await tester.tap(openGroupBtn);
        await tester.pump();
        expect(openedUrls.last, 'https://marcotv.wlj9919.top');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
      },
    );
  });

  group('MacosOfficialNoticePrefs unit tests', () {
    test('defaults unacknowledged, marks acknowledged, respects macOS flag', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await MacosOfficialNoticePrefs.load();
      expect(prefs.acknowledgedVersion, 0);
      expect(prefs.isAcknowledged, isFalse);
      expect(prefs.shouldShow(isMacosOverride: true), isTrue);
      expect(prefs.shouldShow(isMacosOverride: false), isFalse);

      await prefs.markAcknowledged();
      expect(prefs.acknowledgedVersion, MacosOfficialNoticePrefs.currentVersion);
      expect(prefs.isAcknowledged, isTrue);
      expect(prefs.shouldShow(isMacosOverride: true), isFalse);
    });
  });
}

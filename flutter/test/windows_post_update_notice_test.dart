// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/official_channel_notice.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:marco_movie/ui/windows_update_notice.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _StubClient extends CmsClient {
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const <CmsCategory>[CmsCategory(id: '1', name: '电影')],
        const CmsListing(
          videos: <CmsVideo>[CmsVideo(id: 'v1', title: '测试影片')],
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    OhosRuntime.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('WindowsPostUpdateNoticePrefs unit behavior', () {
    test('normalizes version+build tags and tracks once per version', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(WindowsPostUpdateNoticePrefs.normalizeVersionTag('', '80'), '');
      expect(
        WindowsPostUpdateNoticePrefs.normalizeVersionTag('0.7.3', '80'),
        '0.7.3+80',
      );
      expect(
        WindowsPostUpdateNoticePrefs.displayVersionFromTag('0.7.3+80'),
        '0.7.3',
      );

      final prefs = await WindowsPostUpdateNoticePrefs.load();
      expect(prefs.shouldShowForVersion(''), isFalse);
      expect(prefs.shouldShowForVersion('0.7.3+80'), isTrue);

      final saved = await prefs.markVersionSeen('0.7.3+80');
      expect(saved, isTrue);
      expect(prefs.shouldShowForVersion('0.7.3+80'), isFalse);
      expect(prefs.shouldShowForVersion('0.7.4+81'), isTrue);

      final reloaded = await WindowsPostUpdateNoticePrefs.load();
      expect(reloaded.lastSeenVersion, '0.7.3+80');
      expect(reloaded.shouldShowForVersion('0.7.3+80'), isFalse);
      expect(reloaded.shouldShowForVersion('0.7.4+81'), isTrue);
    });
  });

  group('WindowsPostUpdateNoticeDialog UI & fallback guards', () {
    for (final brightness in <Brightness>[Brightness.dark, Brightness.light]) {
      for (final size in <Size>[const Size(720, 520), const Size(1280, 800)]) {
        testWidgets(
          'renders cleanly without overflow at $size ($brightness) and opens donate URL',
          (tester) async {
            await tester.binding.setSurfaceSize(size);
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              return tester.binding.setSurfaceSize(null);
            });

            final openedUris = <Uri>[];
            var confirmed = false;

            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: brightness),
                home: Builder(
                  builder: (ctx) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () async {
                          confirmed = await showWindowsPostUpdateNoticeDialog(
                            ctx,
                            isUpgrade: true,
                            versionLabel: '0.7.3',
                            urlOpener: (uri) async {
                              openedUris.add(uri);
                              return true;
                            },
                            onConfirm: () async => true,
                          );
                        },
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            );

            await tester.tap(find.text('open'));
            await tester.pumpAndSettle();

            expect(
              find.byKey(const ValueKey('windows-post-update-notice-dialog')),
              findsOneWidget,
            );
            expect(find.textContaining('0.7.3'), findsWidgets);
            expect(find.textContaining('谨防受骗'), findsWidgets);
            expect(find.textContaining('官网为唯一更新渠道'), findsWidgets);
            expect(
              find.textContaining(OfficialChannelInfo.officialWebsiteDisplay),
              findsWidgets,
            );
            expect(tester.takeException(), isNull);

            // Tap donate button -> must launch exact #donate anchor URL
            await tester.tap(
              find.byKey(const ValueKey('windows-post-update-donate-btn')),
            );
            await tester.pumpAndSettle();
            expect(
              openedUris,
              contains(Uri.parse('https://marcotv.wlj9919.top/movie/#donate')),
            );

            // Tap confirm button -> closes cleanly
            await tester.tap(
              find.byKey(const ValueKey('windows-post-update-confirm-btn')),
            );
            await tester.pumpAndSettle();
            expect(confirmed, isTrue);
            expect(
              find.byKey(const ValueKey('windows-post-update-notice-dialog')),
              findsNothing,
            );
          },
        );
      }
    }

    testWidgets(
      'donate button falls back to clipboard and then manual selectable dialog',
      (tester) async {
        String? clipboardText;
        var allowClipboard = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (!allowClipboard) {
              throw PlatformException(code: 'denied', message: 'no clipboard');
            }
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    showWindowsPostUpdateNoticeDialog(
                      ctx,
                      isUpgrade: true,
                      versionLabel: '0.7.3',
                      urlOpener: (_) async => false,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Fallback 1: browser launch fails, clipboard succeeds
        await tester.tap(
          find.byKey(const ValueKey('windows-post-update-donate-btn')),
        );
        await tester.pumpAndSettle();
        expect(clipboardText, OfficialChannelInfo.officialDonateUrl);
        expect(find.textContaining('已复制官网捐赠区地址'), findsOneWidget);

        // Fallback 2: both browser launch and clipboard fail -> manual selectable dialog
        allowClipboard = false;
        await tester.tap(
          find.byKey(const ValueKey('windows-post-update-donate-btn')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('official-channel-manual-copy-dialog')),
          findsOneWidget,
        );
        expect(
          find.text(OfficialChannelInfo.officialDonateUrl),
          findsWidgets,
        );
      },
    );
  });

  group('AdaptiveShell Windows post-update launch orchestration', () {
    testWidgets(
      'pops once on Windows upgrade, skips second launch, re-pops on next version, and never double-pops on fresh install',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        const size = Size(1280, 800);
        await tester.binding.setSurfaceSize(size);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          return tester.binding.setSurfaceSize(null);
        });

        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcomovie',
          version: '0.7.3',
          buildNumber: '80',
          buildSignature: '',
        );

        final storage = await initTestStorage(initialPrefs: <String, Object>{
          WindowsPostUpdateNoticePrefs.versionKey: '0.7.2+79',
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
        });
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 's1',
                  'name': '源1',
                  'type': 1,
                  'api': 'https://owned.invalid/api',
                },
              ],
            })));

        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final openedUris = <Uri>[];

        Future<void> mountShell() async {
          await tester.pumpWidget(
            MaterialApp(
              builder: (_, child) =>
                  WindowsAppearanceScope(controller: appearance, child: child!),
              home: AdaptiveShell(
                storage: storage,
                client: _StubClient(),
                onSetPreventCloseForTest: (_) async {},
                onOpenExternalUrlForTest: (uri) async {
                  openedUris.add(uri);
                  return true;
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        // Launch 1 on 0.7.3+80 -> MUST pop post-update notice once
        await mountShell();
        expect(
          find.byKey(const ValueKey('windows-post-update-notice-dialog')),
          findsOneWidget,
        );
        expect(find.textContaining('已更新至 v0.7.3'), findsOneWidget);

        // Dismiss via confirm button
        await tester.tap(
          find.byKey(const ValueKey('windows-post-update-confirm-btn')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-post-update-notice-dialog')),
          findsNothing,
        );

        // Also check Settings -> 更多设置 -> 捐赠支持作者 row
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('更多设置').first);
        await tester.pumpAndSettle();
        final donateRow =
            find.byKey(const ValueKey('windows-settings-donate-support'));
        await tester.scrollUntilVisible(
          donateRow,
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(donateRow);
        await tester.pumpAndSettle();
        expect(openedUris, contains(OfficialChannelInfo.officialDonateUri));

        // Unmount & Launch 2 on SAME version 0.7.3+80 -> must NOT pop again
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await mountShell();
        expect(
          find.byKey(const ValueKey('windows-post-update-notice-dialog')),
          findsNothing,
        );

        // Bump mock version to 0.7.4+81 & Launch 3 -> MUST pop again!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcomovie',
          version: '0.7.4',
          buildNumber: '81',
          buildSignature: '',
        );
        await mountShell();
        expect(
          find.byKey(const ValueKey('windows-post-update-notice-dialog')),
          findsOneWidget,
        );
        expect(find.textContaining('已更新至 v0.7.4'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'non-Windows platforms (macOS / iOS) NEVER trigger WindowsPostUpdateNoticeDialog',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        PackageInfo.setMockInitialValues(
          appName: 'Marco Movie',
          packageName: 'com.pilipala.marcomovie',
          version: '0.7.3',
          buildNumber: '80',
          buildSignature: '',
        );
        final storage = await initTestStorage(initialPrefs: <String, Object>{
          OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          OnboardingPrefs.officialChannelNoticeVersionKey:
              OnboardingPrefs.currentOfficialChannelNoticeVersion,
        });
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'sites': [
                {
                  'key': 's1',
                  'name': '源1',
                  'type': 1,
                  'api': 'https://owned.invalid/api',
                },
              ],
            })));

        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveShell(
              storage: storage,
              client: _StubClient(),
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('windows-post-update-notice-dialog')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}

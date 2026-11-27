import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/main.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';

class _DelayedSecureStore implements SecureCredentialStore {
  final Completer<void> gate;
  final Map<String, String> values;
  int readCount = 0;

  _DelayedSecureStore(this.gate, [Map<String, String>? initial])
      : values = Map<String, String>.of(initial ?? const {});

  @override
  Future<String?> read(String key) async {
    readCount++;
    await gate.future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await gate.future;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    await gate.future;
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
  });

  group('iOS 14 Cold Launch & Dock Regression Tests', () {
    testWidgets(
      'AppleLiquidGlassDock renders visible high-contrast icons and labels in Dark and Light modes on iOS 14-25',
      (tester) async {
        IosLiquidGlassBridge.setAvailableForTest(false);
        tester.view.physicalSize = const Size(834, 1112); // iPad Pro 10.5"
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        for (final brightness in const [Brightness.dark, Brightness.light]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.light(),
              darkTheme: ThemeData.dark(),
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              home: Scaffold(
                bottomNavigationBar: Center(
                  heightFactor: 1,
                  child: AppleLiquidGlassDock(
                    selectedIndex: 0,
                    onSelect: (_) {},
                    isLandscape: false,
                    items: const [
                      (CupertinoIcons.house, CupertinoIcons.house_fill, '主页'),
                      (CupertinoIcons.tv, CupertinoIcons.tv_fill, '直播'),
                      (
                        CupertinoIcons.rectangle_stack,
                        CupertinoIcons.rectangle_stack_fill,
                        '片库',
                      ),
                      (
                        CupertinoIcons.gear_alt,
                        CupertinoIcons.gear_alt_fill,
                        '设置',
                      ),
                    ],
                    onSearch: () {},
                  ),
                ),
                body: const SizedBox.expand(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          for (final label in const ['主页', '直播', '片库', '设置']) {
            expect(find.text(label), findsOneWidget);
          }
          for (final kind in const ['home', 'live', 'library', 'settings']) {
            final iconFinder = find.byKey(ValueKey('marco-dock-icon-$kind'));
            expect(iconFinder, findsOneWidget);
            final icon = tester.widget<Icon>(iconFinder);
            expect(icon.color, isNotNull);
            if (kind != 'home') {
              if (brightness == Brightness.dark) {
                expect(
                  icon.color!.computeLuminance(),
                  greaterThan(0.55),
                  reason: 'Dark mode inactive icon $kind must remain bright',
                );
              } else {
                expect(
                  icon.color!.computeLuminance(),
                  lessThan(0.25),
                  reason: 'Light mode inactive icon $kind must remain dark',
                );
              }
            }
          }
          expect(find.byKey(const ValueKey('home-search-button')), findsOneWidget);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosRootTabNavigatorObserver and rootTabSuppression auto-hide native dock on pushed routes & playback',
      (tester) async {
        final recordedVisibility = <bool>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'setRootTabVisible') {
            final args = call.arguments;
            if (args is Map && args['visible'] is bool) {
              recordedVisibility.add(args['visible'] as bool);
            } else if (args is bool) {
              recordedVisibility.add(args);
            }
          }
          return null;
        });
        IosLiquidGlassBridge.setAvailableForTest(true);

        final observer = IosRootTabNavigatorObserver();
        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            navigatorObservers: [observer],
            home: const Scaffold(body: Text('Root Shell')),
          ),
        );
        expect(IosRootTabNavigatorObserver.secondaryRouteDepth.value, 0);

        navKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Playback Route')),
          ),
        );
        await tester.pumpAndSettle();
        expect(IosRootTabNavigatorObserver.secondaryRouteDepth.value, 1);

        final release1 = IosLiquidGlassBridge.acquireRootTabSuppression();
        final release2 = IosLiquidGlassBridge.acquireRootTabSuppression();
        expect(IosLiquidGlassBridge.rootTabSuppressionCount.value, 2);
        expect(recordedVisibility, contains(false));

        // Releasing the same token twice must remain idempotent.
        release1();
        release1();
        expect(IosLiquidGlassBridge.rootTabSuppressionCount.value, 1);
        release2();
        expect(IosLiquidGlassBridge.rootTabSuppressionCount.value, 0);

        navKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(IosRootTabNavigatorObserver.secondaryRouteDepth.value, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'IosLiquidGlassBridge.ensureInitialized retries cleanly after cold-start MissingPluginException',
      (tester) async {
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
          if (call.method == 'capabilities') {
            calls++;
            if (calls == 1) {
              throw MissingPluginException('Channel not yet registered');
            }
            return <String, dynamic>{
              'available': true,
              'reduceTransparency': false,
              'sceneActive': true,
            };
          }
          return null;
        });

        final first = await IosLiquidGlassBridge.ensureInitialized();
        expect(first, isFalse);
        expect(IosLiquidGlassBridge.isAvailable, isFalse);

        final second = await IosLiquidGlassBridge.ensureInitialized();
        expect(second, isTrue);
        expect(IosLiquidGlassBridge.isAvailable, isTrue);
        expect(calls, 2);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'StorageService.init retries transient cold-start SharedPreferences failures and defers Keychain hydration when requested',
      () async {
        SharedPreferences.setMockInitialValues({});
        var attempts = 0;
        final gate = Completer<void>();
        final delayedSecure = _DelayedSecureStore(
          gate,
          {StorageService.keyWebdavPass: 'secret-token'},
        );

        final storage = await StorageService.init(
          secureStore: delayedSecure,
          deferSecureCredentialHydration: true,
          prefsLoader: () async {
            attempts++;
            if (attempts < 3) {
              throw MissingPluginException('Plugin registration racing cold launch');
            }
            return SharedPreferences.getInstance();
          },
        );

        expect(attempts, 3);
        // StorageService.init returned BEFORE the blocked Keychain gate completed.
        expect(gate.isCompleted, isFalse);
        expect(storage.webdavPass, isEmpty);

        gate.complete();
        await storage.waitForCredentialsReady();
        expect(storage.webdavPass, 'secret-token');
      },
    );

    testWidgets(
      'MarcoBootstrapApp paints adaptive Frame 1 immediately and recovers from startup failures via retry',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final gate = Completer<MarcoAppBootstrapResult>();
        var runs = 0;

        await tester.pumpWidget(
          MarcoBootstrapApp(
            bootstrapper: () async {
              runs++;
              if (runs == 1) {
                return gate.future;
              }
              final storage = await StorageService.init();
              return (storage: storage, client: CmsClient());
            },
            appBuilder: (_, __) => const MaterialApp(
              home: Scaffold(body: Text('Marco Ready')),
            ),
          ),
        );

        // Frame 1 renders immediately with dark adaptive background (not blank white).
        final surface = tester.widget<ColoredBox>(
          find.byKey(const ValueKey('marco-bootstrap-surface')),
        );
        expect(surface.color, AppleColors.background);
        expect(find.byKey(const ValueKey('marco-bootstrap-spinner')), findsOneWidget);

        // Simulate transient startup failure -> shows retry button instead of silent white screen.
        gate.completeError(StateError('cold start storage failed'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('marco-bootstrap-retry')), findsOneWidget);

        // Tap retry -> recovers cleanly into the main app.
        await tester.tap(find.byKey(const ValueKey('marco-bootstrap-retry')));
        await tester.pumpAndSettle();
        expect(find.text('Marco Ready'), findsOneWidget);
        expect(runs, 2);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

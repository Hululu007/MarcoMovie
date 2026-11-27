// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/launch_diagnostics.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/main.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/mobile_player_chrome.dart';
import 'package:marco_movie/ui/onboarding/onboarding_screen.dart';
import 'package:marco_movie/ui/player/desktop_player_hud.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'test_storage_helper.dart';

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = false;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
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

class _FakePlayerStream extends Fake implements PlayerStream {
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
  final subtitleCtrl = StreamController<List<String>>.broadcast();
  final bufferCtrl = StreamController<Duration>.broadcast();
  final logCtrl = StreamController<PlayerLog>.broadcast();
  final audioParamsCtrl = StreamController<AudioParams>.broadcast();
  final videoParamsCtrl = StreamController<VideoParams>.broadcast();

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
  @override
  Stream<List<String>> get subtitle => subtitleCtrl.stream;
  @override
  Stream<Duration> get buffer => bufferCtrl.stream;
  @override
  Stream<PlayerLog> get log => logCtrl.stream;
  @override
  Stream<AudioParams> get audioParams => audioParamsCtrl.stream;
  @override
  Stream<VideoParams> get videoParams => videoParamsCtrl.stream;

  Future<void> close() async {
    await Future.wait([
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
      subtitleCtrl.close(),
      bufferCtrl.close(),
      logCtrl.close(),
      audioParamsCtrl.close(),
      videoParamsCtrl.close(),
    ]);
  }
}

class _FakePlayer extends Fake implements Player {
  final _FakePlayerState _state = _FakePlayerState();
  final _FakePlayerStream _stream = _FakePlayerStream();
  final List<String> openedUris = <String>[];
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;

  @override
  PlayerStream get stream => _stream;

  @override
  PlayerState get state => _state;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedUris.add(playable.uri);
      _state.playlistValue = Playlist([playable]);
    } else if (playable is Playlist) {
      _state.playlistValue = playable;
    }
    _state.playingValue = play;
    _state.durationValue = const Duration(minutes: 45);
    _stream.durationCtrl.add(_state.durationValue);
    _stream.playingCtrl.add(play);
    if (play) {
      _state.positionValue = const Duration(seconds: 2);
      _stream.positionCtrl.add(_state.positionValue);
    }
  }

  void emitCompleted() {
    _state.completedValue = true;
    _stream.completedCtrl.add(true);
  }

  @override
  Future<void> play() async {
    _state.playingValue = true;
    _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    _state.playingValue = false;
    _stream.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async => _state.playingValue ? pause() : play();

  @override
  Future<void> seek(Duration position) async {
    _state.positionValue = position;
    _stream.positionCtrl.add(position);
  }

  @override
  Future<void> setRate(double rate) async {
    _state.rateValue = rate;
  }

  @override
  Future<void> setVolume(double volume) async {
    _state.volumeValue = volume;
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> setVideoTrack(VideoTrack track) async {}

  @override
  Future<void> stop() async {
    _state.playingValue = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _stream.close();
  }
}

class _NonStartingFakePlayer extends _FakePlayer {
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedUris.add(playable.uri);
      _state.playlistValue = Playlist([playable]);
    } else if (playable is Playlist) {
      _state.playlistValue = playable;
    }
    // Simulate a player that enters buffering and never actually starts playing.
    _state.playingValue = false;
    _state.bufferingValue = true;
    _stream.bufferingCtrl.add(true);
    _stream.playingCtrl.add(false);
  }
}

class _TempPathProvider extends PathProviderPlatform {
  final Directory root;
  _TempPathProvider(this.root);

  @override
  Future<String?> getDownloadsPath() async => '${root.path}/downloads';
  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

class _MutableDetailClient extends CmsClient {
  CmsVideo? overrideVideo;

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
    CmsSite source,
    CmsVideo item,
    Iterable<CmsSite> candidates, {
    bool forceRefresh = false,
  }) async {
    return (source, overrideVideo ?? item);
  }

  @override
  Future<CmsListing> fetchSearch(
    CmsSite site,
    String keyword, {
    int page = 1,
  }) async =>
      const CmsListing();

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async =>
      const (<CmsCategory>[], CmsListing());
}

CmsVideo _buildLongDrama({
  required String id,
  required String title,
  int episodeCount = 120,
  bool includeSecondLine = true,
  bool prependPrologue = false,
}) {
  final eps1 = <CmsEpisode>[
    if (prependPrologue)
      CmsEpisode(
        name: '先导片',
        url: 'https://media.example/$id/line1/ep_prologue.m3u8',
      ),
    for (int i = 1; i <= episodeCount; i++)
      CmsEpisode(
        name: '第$i集',
        url: 'https://media.example/$id/line1/ep_$i.m3u8',
      ),
  ];
  final lines = <CmsLine>[
    CmsLine(id: '${id}_l1', name: '主线路', episodes: eps1),
    if (includeSecondLine)
      CmsLine(
        id: '${id}_l2',
        name: '备用线路',
        episodes: [
          for (int i = 1; i <= episodeCount; i++)
            CmsEpisode(
              name: '第$i集',
              url: 'https://media.example/$id/line2/ep_$i.m3u8',
            ),
        ],
      ),
  ];
  return CmsVideo(
    id: id,
    title: title,
    year: '2026',
    remarks: '更新至第$episodeCount集',
    description: '用于验证剧集序号圆圈滑动、卡片联动、播放状态归属与临时正倒序的测试剧集。',
    lines: lines,
  );
}

BoxDecoration _circleBoxDecoration(WidgetTester tester, Finder boxFinder) {
  final container = tester.widget<AnimatedContainer>(boxFinder);
  return container.decoration! as BoxDecoration;
}

bool _isSolidWhiteCircle(WidgetTester tester, Finder boxFinder) {
  final deco = _circleBoxDecoration(tester, boxFinder);
  return deco.color == Colors.white;
}

bool _isOutlinedBrowsingCircle(WidgetTester tester, Finder boxFinder) {
  final deco = _circleBoxDecoration(tester, boxFinder);
  final border = deco.border as Border?;
  return deco.color != Colors.white &&
      border != null &&
      border.top.color == Colors.white &&
      border.top.width >= 1.5;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    OhosRuntime.resetForTesting();
    MarcoLaunchDiagnostics.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(false);
    IosLiquidGlassBridge.setReduceTransparencyForTest(false);
    PackageInfo.setMockInitialValues(
      appName: 'Marco Movie',
      packageName: 'com.pilipala.marcomovie',
      version: '0.7.6',
      buildNumber: '99',
      buildSignature: '',
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    OhosRuntime.resetForTesting();
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
      MobilePlayerChrome.iosSystemChromeChannel,
      null,
    );
  });

  group('Requirement 1: iPad fullscreen system bars & control safe-area avoidance',
      () {
    test(
      'MobilePlayerChrome decouples orientation from fullscreen immersive mode on iOS',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final platformModes = <String>[];
        final orientations = <List<dynamic>>[];
        final iosImmersiveCalls = <bool>[];
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            platformModes.add(call.arguments as String);
          } else if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(List<dynamic>.from(call.arguments as List));
          }
          return null;
        });
        messenger.setMockMethodCallHandler(
          MobilePlayerChrome.iosSystemChromeChannel,
          (call) async {
            if (call.method == 'setImmersive' && call.arguments is bool) {
              iosImmersiveCalls.add(call.arguments as bool);
            }
            return null;
          },
        );

        final chrome = MobilePlayerChrome();
        await chrome.setImmersive(true, force: true);
        expect(chrome.isImmersive, isTrue);
        expect(iosImmersiveCalls, [true]);
        expect(platformModes.last, 'SystemUiMode.immersiveSticky');

        // Request portrait orientation (e.g. iPad portrait or Split View):
        // MUST NOT clear immersive mode or send edgeToEdge.
        await chrome.setOrientation(false);
        expect(chrome.isImmersive, isTrue);
        expect(iosImmersiveCalls, [true]);
        expect(platformModes.where((m) => m == 'SystemUiMode.edgeToEdge'), isEmpty);

        // Request landscape orientation via setLandscape(syncImmersive: false):
        await chrome.setLandscape(true, syncImmersive: false);
        expect(chrome.isImmersive, isTrue);
        expect(iosImmersiveCalls, [true]);

        // Exiting player explicitly restores normal system bars.
        await chrome.setImmersive(false, force: true);
        expect(chrome.isImmersive, isFalse);
        expect(iosImmersiveCalls.last, isFalse);
        expect(platformModes.last, 'SystemUiMode.edgeToEdge');
      },
    );

    testWidgets(
      'iPad fullscreen (landscape, portrait, Split View, AVPlayer & MPV) hides system bars, avoids top status bar / bottom Home indicator when HUD visible, re-syncs on resume, and restores on exit',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final platformModes = <String>[];
        final iosImmersiveCalls = <bool>[];
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            platformModes.add(call.arguments as String);
          }
          return null;
        });
        messenger.setMockMethodCallHandler(
          MobilePlayerChrome.iosSystemChromeChannel,
          (call) async {
            if (call.method == 'setImmersive' && call.arguments is bool) {
              iosImmersiveCalls.add(call.arguments as bool);
            }
            return null;
          },
        );

        final storage = await initTestStorage();
        const site = CmsSite(
          key: 'ipad_hud_site',
          name: 'iPad 测试源',
          type: 1,
          api: 'https://ipad.example/api',
          isPrivate: true,
        );
        const video = CmsVideo(
          id: 'ipad_vid_1',
          title: '深空彼岸',
          lines: [
            CmsLine(
              id: 'l1',
              name: '4K',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://media.example/ep1.m3u8'),
                CmsEpisode(name: '第2集', url: 'https://media.example/ep2.m3u8'),
              ],
            ),
          ],
        );

        for (final engineMode in const ['avplayer', 'mpv']) {
          await storage.setIosPlaybackEngineMode(engineMode);
          for (final config in const [
            (
              name: 'iPad landscape fullscreen',
              size: Size(1024, 768),
              padding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              viewPadding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              expectImmersive: true,
            ),
            (
              name: 'iPad immersive zero-padding transient bar floor',
              size: Size(1024, 768),
              padding: FakeViewPadding.zero,
              viewPadding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              expectImmersive: true,
            ),
            (
              name: 'iPad portrait fullscreen',
              size: Size(768, 1024),
              padding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              viewPadding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              expectImmersive: true,
            ),
            (
              name: 'iPad 2/3 Split View 678pt',
              size: Size(678, 768),
              padding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              viewPadding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              expectImmersive: true,
            ),
            (
              name: 'iPad 1/2 Split View 507pt windowed',
              size: Size(507, 1024),
              padding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              viewPadding: FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0),
              expectImmersive: false,
            ),
          ]) {
            iosImmersiveCalls.clear();
            platformModes.clear();

            tester.view.devicePixelRatio = 1.0;
            tester.view.physicalSize = config.size;
            tester.view.padding = config.padding;
            tester.view.viewPadding = config.viewPadding;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.view.resetPadding();
              tester.view.resetViewPadding();
            });

            final fakePlayer = _FakePlayer();
            final navKey = GlobalKey<NavigatorState>();
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navKey,
                home: const Scaffold(body: Center(child: Text('ORIGIN_PAGE'))),
              ),
            );
            unawaited(
              navKey.currentState!.push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    site: site,
                    video: video,
                    storage: storage,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    debugPlayer: fakePlayer,
                    debugVideoSurface: const SizedBox.expand(
                      child: ColoredBox(
                        key: ValueKey('test-video-surface'),
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));

            // 1. Immersive system bars active on iPad fullscreen & 2/3 Split View.
            expect(
              iosImmersiveCalls,
              isNotEmpty,
              reason: '${config.name} ($engineMode) must notify native chrome',
            );
            expect(
              iosImmersiveCalls.last,
              config.expectImmersive,
              reason: '${config.name} ($engineMode) immersive expectation mismatch',
            );

            // 2. Fullscreen video surface stays full-bleed edge-to-edge.
            final videoRect = tester.getRect(
              find.byKey(const ValueKey('test-video-surface')),
            );
            expect(videoRect.width, closeTo(config.size.width, 1.0));
            if (config.expectImmersive) {
              expect(videoRect.height, closeTo(config.size.height, 1.0));
            }

            // 3. Top header clears iPad status bar & multitasking pill (>= 24pt).
            final topBoxFinder = find.byKey(const Key('ios-player-top-header-box'));
            if (topBoxFinder.evaluate().isNotEmpty) {
              final topRect = tester.getRect(topBoxFinder);
              expect(
                topRect.top,
                greaterThanOrEqualTo(24.0),
                reason:
                    '${config.name} ($engineMode) top controls must not overlap time/battery/multitasking bar',
              );
            } else {
              // Narrow portrait companion mode still keeps top back button >= 24pt.
              final backFinder = find.byIcon(CupertinoIcons.chevron_back);
              expect(backFinder, findsWidgets);
              expect(
                tester.getRect(backFinder.first).top,
                greaterThanOrEqualTo(24.0),
              );
            }

            // 4. Bottom progress deck clears iPad Home indicator zone (>= 20pt).
            final bottomBoxFinder =
                find.byKey(const Key('ios-player-bottom-deck-box'));
            if (config.expectImmersive) {
              expect(bottomBoxFinder, findsOneWidget);
              final bottomRect = tester.getRect(bottomBoxFinder);
              expect(
                config.size.height - bottomRect.bottom,
                greaterThanOrEqualTo(20.0),
                reason:
                    '${config.name} ($engineMode) bottom progress bar must clear Home indicator gesture zone',
              );

              // 5. Auto-hide keeps immersive true; tapping restores HUD safely.
              await tester.pump(const Duration(seconds: 6));
              expect(iosImmersiveCalls.last, isTrue);
              await tester.tapAt(
                Offset(config.size.width * 0.5, config.size.height * 0.5),
              );
              await tester.pump(const Duration(milliseconds: 300));
              expect(
                tester.getRect(topBoxFinder).top,
                greaterThanOrEqualTo(24.0),
              );
              expect(
                config.size.height - tester.getRect(bottomBoxFinder).bottom,
                greaterThanOrEqualTo(20.0),
              );

              // 6. Background/lock -> resume re-asserts native immersive mode.
              final callsBeforeResume = iosImmersiveCalls.length;
              tester.binding
                  .handleAppLifecycleStateChanged(AppLifecycleState.paused);
              await tester.pump();
              tester.binding
                  .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
              await tester.pump(const Duration(milliseconds: 100));
              expect(iosImmersiveCalls.length, greaterThan(callsBeforeResume));
              expect(iosImmersiveCalls.last, isTrue);
            }

            // 7. Exit player restores normal system bars.
            navKey.currentState!.pop();
            await tester.pumpAndSettle();
            expect(iosImmersiveCalls.last, isFalse);
            expect(platformModes.last, 'SystemUiMode.edgeToEdge');
            expect(find.text('ORIGIN_PAGE'), findsOneWidget);
          }
        }
      },
    );

    test(
      'prepare_platform.py native iOS controller allows Home indicator auto-hide (no .bottom deferral), handles forced immersive refresh & branded LaunchScreen',
      () {
        final scriptFile = File('prepare_platform.py');
        expect(scriptFile.existsSync(), isTrue);
        final src = scriptFile.readAsStringSync();

        // Apple UIKit disables prefersHomeIndicatorAutoHidden if .bottom is deferred.
        expect(
          src.contains('return marcoImmersiveMode ? [.top] : []'),
          isTrue,
          reason: 'Must defer [.top] only so Home indicator fades out on iPad',
        );
        expect(
          src.contains('[.top, .bottom]'),
          isFalse,
          reason: 'Deferring .bottom blocks prefersHomeIndicatorAutoHidden on iPad',
        );
        expect(src.contains('func applyImmersiveMode(_ immersive: Bool, force: Bool = false)'), isTrue);
        expect(src.contains('collectFlutterControllers'), isTrue);
        expect(src.contains('viewSafeAreaInsetsDidChange'), isTrue);
        expect(src.contains('didBecomeActiveNotification'), isTrue);
        expect(src.contains('didActivateNotification'), isTrue);
        expect(src.contains('def _install_ios_branded_launch_screen'), isTrue);
        expect(src.contains('[MarcoLaunch] stage=native_did_finish_launching'), isTrue);
        expect(src.contains('[MarcoLaunch] stage=native_vc_view_did_appear'), isTrue);
      },
    );
  });

  group('Requirement 2: iPad first-install launch resilience & recovery', () {
    testWidgets(
      'Throwing bootstrapper recovers on retry without leaving white screen',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final storage = await initTestStorage();
        final client = _MutableDetailClient();
        var calls = 0;

        await tester.pumpWidget(
          MarcoBootstrapApp(
            bootstrapTimeout: const Duration(seconds: 3),
            bootstrapper: () async {
              calls++;
              if (calls == 1) {
                throw StateError('simulated keychain init error');
              }
              return (storage: storage, client: client);
            },
            appBuilder: (_, __) => const MaterialApp(
              home: Scaffold(body: Center(child: Text('RECOVERED_HOME'))),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('初始化未完成，请重试'), findsOneWidget);
        expect(find.byKey(const ValueKey('marco-bootstrap-retry')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('marco-bootstrap-retry')));
        await tester.pumpAndSettle();

        expect(calls, 2);
        expect(find.text('RECOVERED_HOME'), findsOneWidget);
        expect(
          MarcoLaunchDiagnostics.entries.map((e) => e.stage),
          containsAllInOrder([
            'bootstrap_attempt',
            'bootstrap_error',
            'bootstrap_attempt',
            'bootstrap_ready',
          ]),
        );
      },
    );

    testWidgets(
      'Hung/never-returning init triggers bounded timeout, recovers on retry, and ignores late stale completion or error',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final storageGood = await initTestStorage();
        final storageStale = await initTestStorage();
        final client = _MutableDetailClient();
        final staleCompleter = Completer<MarcoAppBootstrapResult>();
        var calls = 0;

        await tester.pumpWidget(
          MarcoBootstrapApp(
            bootstrapTimeout: const Duration(milliseconds: 300),
            bootstrapper: () {
              calls++;
              if (calls == 1) {
                return staleCompleter.future;
              }
              return Future.value((storage: storageGood, client: client));
            },
            appBuilder: (s, _) => MaterialApp(
              home: Scaffold(
                body: Center(
                  child: Text(
                    identical(s, storageGood) ? 'GOOD_RECOVERED' : 'STALE_OVERWRITE',
                  ),
                ),
              ),
            ),
          ),
        );

        // Immediately renders branded bootstrap surface on Frame 1.
        expect(find.byKey(const ValueKey('marco-bootstrap-surface')), findsOneWidget);
        expect(find.byKey(const ValueKey('marco-bootstrap-spinner')), findsOneWidget);

        // Exceed bounded timeout -> surfaces retry action instead of infinite white/spinner.
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('初始化响应超时，请重试'), findsOneWidget);
        expect(find.byKey(const ValueKey('marco-bootstrap-retry')), findsOneWidget);

        // Tap retry -> recovers to good app.
        await tester.tap(find.byKey(const ValueKey('marco-bootstrap-retry')));
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(find.text('GOOD_RECOVERED'), findsOneWidget);

        // Late completion from attempt 1 MUST NOT overwrite already-recovered UI.
        staleCompleter.complete((storage: storageStale, client: client));
        await tester.pumpAndSettle();
        expect(find.text('GOOD_RECOVERED'), findsOneWidget);
        expect(find.text('STALE_OVERWRITE'), findsNothing);

        // Second sub-case: late ERROR from a timed-out attempt 1 also MUST NOT overwrite recovered UI.
        final staleErrCompleter = Completer<MarcoAppBootstrapResult>();
        var errCalls = 0;
        await tester.pumpWidget(
          MarcoBootstrapApp(
            key: const ValueKey('bootstrap-late-error-case'),
            bootstrapTimeout: const Duration(milliseconds: 250),
            bootstrapper: () {
              errCalls++;
              if (errCalls == 1) {
                return staleErrCompleter.future;
              }
              return Future.value((storage: storageGood, client: client));
            },
            appBuilder: (_, __) => const MaterialApp(
              home: Scaffold(body: Center(child: Text('RECOVERED_FROM_TIMEOUT'))),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('初始化响应超时，请重试'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('marco-bootstrap-retry')));
        await tester.pumpAndSettle();
        expect(find.text('RECOVERED_FROM_TIMEOUT'), findsOneWidget);

        staleErrCompleter.completeError(StateError('late stale failure'));
        await tester.pumpAndSettle();
        expect(find.text('RECOVERED_FROM_TIMEOUT'), findsOneWidget);
        expect(find.text('初始化未完成，请重试'), findsNothing);
      },
    );

    testWidgets(
      'First-install offline with zero subscriptions on iPad Light Mode enters operable UI, navigates into a page and returns',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1024, 768);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearPlatformBrightnessTestValue();
        });

        final storage = await initTestStorage();
        final client = _MutableDetailClient();

        await tester.pumpWidget(
          MarcoBootstrapApp(
            bootstrapper: () async => (storage: storage, client: client),
          ),
        );
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }

        // First launch shows official channel safety dialog first, then renders
        // OnboardingScreen (interactive) or operable welcome Home
        // (never pure white blank, never stuck on Logo).
        final noticeConfirm = find.byKey(
          const ValueKey('official-channel-notice-confirm'),
        );
        if (noticeConfirm.evaluate().isNotEmpty) {
          expect(find.text('PILIPALA来信'), findsOneWidget);
          expect(find.text('marcotv.wlj9919.top'), findsOneWidget);
          await tester.tap(noticeConfirm);
          for (int i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 150));
          }
        }
        if (find.byType(OnboardingScreen).evaluate().isNotEmpty) {
          final skipFinder = find.text('跳过');
          final skipEnFinder = find.text('Skip');
          if (skipFinder.evaluate().isNotEmpty) {
            await tester.tap(skipFinder.first);
          } else if (skipEnFinder.evaluate().isNotEmpty) {
            await tester.tap(skipEnFinder.first);
          }
          for (int i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 150));
          }
        }
        expect(find.byType(AdaptiveShell), findsOneWidget);
        expect(
          MarcoLaunchDiagnostics.entries.map((e) => e.stage),
          containsAllInOrder([
            'bootstrap_attempt',
            'bootstrap_ready',
            'shell_interactive',
          ]),
        );

        // Verify operable offline welcome Home (zero subscriptions) on iPad Light Mode,
        // enter AddResourceLibraryView ("添加资源库") and return cleanly back to Home.
        expect(find.text('导入配置地址或 JSON'), findsOneWidget);
        await tester.tap(find.text('导入配置地址或 JSON'));
        for (int i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(find.text('添加资源库'), findsWidgets);

        await tester.binding.handlePopRoute();
        for (int i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(find.byType(AdaptiveShell), findsOneWidget);
        expect(find.text('导入配置地址或 JSON'), findsOneWidget);
      },
    );
  });

  group(
    'Requirements 3 & 4: Draggable episode circles, card linking, confirmed playing marker, >100 pagination & ephemeral ascending sort',
    () {
      const testSite = CmsSite(
        key: 'ep_sync_site',
        name: '剧集测试源',
        type: 1,
        api: 'https://series.example/api',
      );

      testWidgets(
        'Zero history shows 0 solid white circles; dragging from circle center scrolls strip & page with 0 player launches',
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(390, 844);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final storage = await initTestStorage();
          final client = _MutableDetailClient();
          final drama = _buildLongDrama(id: 'drama_zero', title: '无记录剧集', episodeCount: 40);
          var playerOpenCount = 0;

          await tester.pumpWidget(
            MaterialApp(
              home: DetailScreen(
                site: testSite,
                initialVideo: drama,
                client: client,
                storage: storage,
                debugPlayerBuilder: (_, __, ___, ____, _____, ______) {
                  playerOpenCount++;
                  return const Scaffold(body: Text('FAKE_PLAYER'));
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Ensure episode section is visible.
          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-quick-episodes-strip')),
          );
          await tester.pumpAndSettle();

          // Zero watch history -> NO circle should be marked solid white (ep 1 NOT falsely marked!).
          for (int i = 0; i < 6; i++) {
            final box = find.byKey(ValueKey('ep_circle_box_0_$i'));
            if (box.evaluate().isNotEmpty) {
              expect(
                _isSolidWhiteCircle(tester, box),
                isFalse,
                reason: 'Episode ${i + 1} must NOT be falsely marked played with zero history',
              );
            }
          }

          // Horizontal drag starting dead-center on circle 3 scrolls the circle strip without opening player.
          final circleStripFinder =
              find.byKey(const ValueKey('detail-quick-episodes-strip'));
          final circleScrollable = tester.state<ScrollableState>(
            find.descendant(
              of: circleStripFinder,
              matching: find.byType(Scrollable),
            ),
          );
          final beforeHoriz = circleScrollable.position.pixels;
          final circle3Center = tester.getCenter(
            find.byKey(const ValueKey('ep_circle_0_2')),
          );
          await tester.dragFrom(circle3Center, const Offset(-220, 0));
          await tester.pumpAndSettle();

          expect(
            circleScrollable.position.pixels,
            greaterThan(beforeHoriz + 60),
            reason: 'Dragging horizontally from center of a circle must scroll strip',
          );
          expect(playerOpenCount, 0, reason: 'Dragging circles must never open player');

          // Vertical drag starting from a visible circle still scrolls the Detail page vertically.
          final pageScrollFinder = find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          );
          final pageScrollable = tester.state<ScrollableState>(
            pageScrollFinder.first,
          );
          final beforeVert = pageScrollable.position.pixels;
          final visibleCircle = find.byKey(const ValueKey('ep_circle_0_5')).evaluate().isNotEmpty
              ? find.byKey(const ValueKey('ep_circle_0_5'))
              : find.byKey(const ValueKey('ep_circle_0_4'));
          // Drag down (+180) if already near bottom, otherwise up (-180).
          final dragDy = beforeVert > 80 ? 180.0 : -180.0;
          await tester.dragFrom(
            tester.getCenter(visibleCircle),
            Offset(0, dragDy),
          );
          await tester.pumpAndSettle();
          expect(
            (pageScrollable.position.pixels - beforeVert).abs(),
            greaterThan(10),
            reason: 'Vertical drag from a circle must still scroll the page',
          );
          expect(playerOpenCount, 0);
        },
      );

      testWidgets(
        'Flow 1 + failed playback + reverse card-to-circle sync + identity across lines/refresh + 50/51 & 100/101 boundaries',
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(430, 932);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final storage = await initTestStorage();
          final client = _MutableDetailClient();
          final drama = _buildLongDrama(id: 'drama_120', title: '长安百集测试剧', episodeCount: 120);

          // Seed confirmed watch history at Episode 12 (index 11).
          await storage.upsertWatchHistory(
            WatchHistoryEntry(
              site: testSite.key,
              id: drama.id,
              title: drama.title,
              line: '主线路',
              episode: '第12集',
              index: 11,
              position: 120000,
              duration: 2400000,
              updated: 1000,
            ),
            immediate: true,
            triggerSync: false,
          );

          final launchedTargets = <(int lineIdx, int epIdx)>[];
          bool simulateNextOpenFailure = true;
          int? autoAdvanceToEpIdx;

          await tester.pumpWidget(
            MaterialApp(
              home: DetailScreen(
                site: testSite,
                initialVideo: drama,
                client: client,
                storage: storage,
                debugPlayerBuilder: (ctx, site, video, lineIdx, epIdx, resumeMs) {
                  launchedTargets.add((lineIdx, epIdx));
                  return Scaffold(
                    body: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('PLAYER_OPENED_${lineIdx}_$epIdx'),
                        ElevatedButton(
                          key: const ValueKey('sim-player-exit'),
                          onPressed: () async {
                            if (!simulateNextOpenFailure) {
                              final finalIdx = autoAdvanceToEpIdx ?? epIdx;
                              final ep = video.lines[lineIdx].episodes[finalIdx];
                              await storage.upsertWatchHistory(
                                WatchHistoryEntry(
                                  site: site.key,
                                  id: video.id,
                                  title: video.title,
                                  line: video.lines[lineIdx].name,
                                  episode: ep.name,
                                  index: finalIdx,
                                  position: 45000,
                                  duration: 2400000,
                                  updated: DateTime.now().millisecondsSinceEpoch,
                                ),
                                immediate: true,
                                triggerSync: false,
                              );
                            }
                            if (ctx.mounted) Navigator.of(ctx).pop();
                          },
                          child: const Text('EXIT_PLAYER'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-quick-episodes-strip')),
          );
          await tester.pumpAndSettle();

          // Scroll circle strip so circles 12..18 are visible.
          ScrollableState currentCircleScroll() => tester.state<ScrollableState>(
                find.descendant(
                  of: find.byKey(const ValueKey('detail-quick-episodes-strip')),
                  matching: find.byType(Scrollable),
                ),
              );
          currentCircleScroll().position.jumpTo(560);
          await tester.pumpAndSettle();

          // Verify Episode 12 (index 11) is solid white; Episode 18 (index 17) is NOT.
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
            isTrue,
            reason: 'Episode 12 must be solid white while playing',
          );
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_17'))),
            isFalse,
          );

          // Step 1: Tap circle 18 -> 0 player opens! Moves bottom card 18 into view,
          // keeps circle 12 solid white, outlines circle 18 as browsing focus.
          await tester.tap(find.byKey(const ValueKey('ep_circle_0_17')));
          await tester.pumpAndSettle();

          expect(
            launchedTargets,
            isEmpty,
            reason: 'Tapping episode circle MUST open player 0 times',
          );
          expect(find.byKey(const ValueKey('ep_card_0_17')), findsOneWidget);
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
            isTrue,
            reason: 'Episode 12 must stay solid white after browsing to 18',
          );
          expect(
            _isOutlinedBrowsingCircle(
              tester,
              find.byKey(const ValueKey('ep_circle_box_0_17')),
            ),
            isTrue,
            reason: 'Episode 18 should show browsing outline without stealing solid white',
          );

          // Step 2: Tap card 18, playback FAILS (does not confirm/save) -> opens once,
          // returning leaves Episode 12 solid white!
          simulateNextOpenFailure = true;
          await tester.tap(find.byKey(const ValueKey('ep_card_0_17')));
          await tester.pumpAndSettle();
          expect(launchedTargets, [(0, 17)]);
          await tester.tap(find.byKey(const ValueKey('sim-player-exit')));
          await tester.pumpAndSettle();

          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
            isTrue,
            reason: 'Failed playback must NOT move solid white marker away from Ep 12',
          );
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_17'))),
            isFalse,
          );

          // Step 3: Tap card 18 -> opens player once for Ep 18 -> auto-advances to Ep 19
          // -> return to Detail -> Ep 19 circle is now solid white!
          launchedTargets.clear();
          simulateNextOpenFailure = false;
          autoAdvanceToEpIdx = 18; // Episode 19 (0-based 18)
          await tester.tap(find.byKey(const ValueKey('ep_card_0_17')));
          await tester.pumpAndSettle();
          expect(
            launchedTargets,
            [(0, 17)],
            reason: 'Tapping episode card 18 must open player exactly once for index 17',
          );
          await tester.tap(find.byKey(const ValueKey('sim-player-exit')));
          await tester.pumpAndSettle();

          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_18'))),
            isTrue,
            reason: 'After auto-advancing to Ep 19 and returning, circle 19 must be solid white',
          );
          // Scroll circle strip slightly left to confirm Ep 12 lost solid white.
          currentCircleScroll().position.jumpTo(480);
          await tester.pumpAndSettle();
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
            isFalse,
          );
          // Scroll back to Ep 19 before Step 4 reverse-drag check.
          currentCircleScroll().position.jumpTo(760);
          await tester.pumpAndSettle();

          // Step 4: Reverse link — drag bottom cards strip horizontally and settle ->
          // top circle strip updates browsing highlight & keeps matching circle visible.
          final cardStrip =
              find.byKey(const ValueKey('detail-episode-cards-strip'));
          await tester.drag(cardStrip, const Offset(360, 0));
          await tester.pumpAndSettle();
          // After scrolling back left by ~2 cards, browsing focus moves off ep 19 while ep 19 stays solid white.
          expect(
            find.byKey(const ValueKey('ep_circle_box_0_16')).evaluate().isNotEmpty ||
                find.byKey(const ValueKey('ep_circle_box_0_15')).evaluate().isNotEmpty,
            isTrue,
          );

          // Step 5: Identity across line switch -> open source picker sheet and switch to 备用线路;
          // same index 18 on 备用线路 MUST NOT be marked solid white!
          await tester.tap(find.byKey(const ValueKey('source_picker_button')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('备用线路').first);
          await tester.pumpAndSettle();
          currentCircleScroll().position.jumpTo(760);
          await tester.pumpAndSettle();
          final line2Ep19 = find.byKey(const ValueKey('ep_circle_box_1_18'));
          if (line2Ep19.evaluate().isNotEmpty) {
            expect(
              _isSolidWhiteCircle(tester, line2Ep19),
              isFalse,
              reason: 'Switching line must NOT mis-highlight same index on another line',
            );
          }

          // Switch back to 主线路 -> Ep 19 is solid white again.
          await tester.tap(find.byKey(const ValueKey('source_picker_button')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('主线路').first);
          await tester.pumpAndSettle();

          Future<void> scrollCirclesToEnd() async {
            for (int k = 0; k < 3; k++) {
              final s = currentCircleScroll();
              s.position.jumpTo(s.position.maxScrollExtent);
              await tester.pumpAndSettle();
            }
          }

          // Step 6: Pagination boundary 50/51 -> jump to Ep 50 (index 49), play & auto-next to Ep 51 (index 50)
          // -> Detail switches to page 1 (51 · 100) and highlights Ep 51 solid white!
          await scrollCirclesToEnd();
          await tester.tap(find.byKey(const ValueKey('ep_circle_0_49')));
          await tester.pumpAndSettle();
          autoAdvanceToEpIdx = 50; // Episode 51 (crosses 50/51 boundary!)
          await tester.tap(find.byKey(const ValueKey('ep_card_0_49')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('sim-player-exit')));
          await tester.pumpAndSettle();

          expect(
            find.byKey(const ValueKey('ep_circle_box_0_50')),
            findsOneWidget,
            reason: 'Crossing 50/51 boundary must advance pagination to 51 · 100',
          );
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_50'))),
            isTrue,
          );

          // Step 7: Pagination boundary 100/101 -> Ep 100 (index 99) auto-nexts to Ep 101 (index 100)
          // -> Detail switches to page 2 (101 · 120) and highlights Ep 101 solid white!
          await scrollCirclesToEnd();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('ep_circle_0_99')));
          await tester.pumpAndSettle();
          autoAdvanceToEpIdx = 100; // Episode 101 (crosses 100/101 boundary!)
          await tester.tap(find.byKey(const ValueKey('ep_card_0_99')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('sim-player-exit')));
          await tester.pumpAndSettle();

          expect(
            find.byKey(const ValueKey('ep_circle_box_0_100')),
            findsOneWidget,
            reason: 'Crossing 100/101 boundary must advance pagination to 101 · 120',
          );
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_100'))),
            isTrue,
          );

          // Step 8: Episode insertion on refresh shifts indices -> identity follows 第101集 (now raw index 101)!
          client.overrideVideo = _buildLongDrama(
            id: 'drama_120',
            title: '长安百集测试剧',
            episodeCount: 120,
            prependPrologue: true,
          );
          // Re-load detail with shifted list by pulling down from top to trigger forceRefresh.
          final pageScroll = tester.state<ScrollableState>(
            find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            ).first,
          );
          pageScroll.position.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.dragFrom(const Offset(215, 220), const Offset(0, 260));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-quick-episodes-strip')),
          );
          await tester.pumpAndSettle();
          // Tap 3rd page pill (101 · 121) and check raw index 101 (第101集) is solid white, NOT index 100 (第100集).
          await tester.tap(find.byKey(const ValueKey('ep_page_pill_2')));
          await tester.pumpAndSettle();
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_101'))),
            isTrue,
            reason: 'After inserting 先导片 at index 0, solid white must stay glued to 第101集 (index 101)',
          );
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_100'))),
            isFalse,
            reason: 'Old index 100 (now 第100集) must NOT inherit solid white marker',
          );
        },
      );

      testWidgets(
        'Flow 2: Legacy episodes_descending=true is ignored on iOS; Drama A descending -> returning from player keeps descending -> Drama B defaults ascending -> re-entering Drama A defaults ascending; Player picker defaults ascending & auto-next stays chronological',
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(430, 932);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final storage = await initTestStorage();
          // Simulate legacy/backup install that had persisted episodes_descending = true!
          await storage.setEpisodesDescending(true);
          expect(storage.episodesDescending, isTrue);

          final client = _MutableDetailClient();
          final dramaA = _buildLongDrama(id: 'drama_a', title: '测试剧集A', episodeCount: 60);
          final dramaB = _buildLongDrama(id: 'drama_b', title: '测试剧集B', episodeCount: 30);

          await storage.upsertWatchHistory(
            WatchHistoryEntry(
              site: testSite.key,
              id: dramaA.id,
              title: dramaA.title,
              line: '主线路',
              episode: '第12集',
              index: 11,
              position: 60000,
              duration: 2400000,
              updated: 1000,
            ),
            immediate: true,
            triggerSync: false,
          );

          final navKey = GlobalKey<NavigatorState>();
          void openDrama(CmsVideo v) {
            navKey.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => DetailScreen(
                  site: testSite,
                  initialVideo: v,
                  client: client,
                  storage: storage,
                  debugPlayerBuilder: (ctx, _, __, ___, ____, _____) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        key: const ValueKey('pop-temp-player'),
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('BACK_TO_DETAIL'),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navKey,
              home: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton(
                        key: const ValueKey('open-drama-a'),
                        onPressed: () => openDrama(dramaA),
                        child: const Text('OPEN_A'),
                      ),
                      ElevatedButton(
                        key: const ValueKey('open-drama-b'),
                        onPressed: () => openDrama(dramaB),
                        child: const Text('OPEN_B'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // 1. Open Drama A -> MUST default to ascending even though legacy storage had true!
          await tester.tap(find.byKey(const ValueKey('open-drama-a')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-episode-sort-toggle')),
          );
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.byKey(const ValueKey('detail-episode-sort-toggle')),
              matching: find.text('正序'),
            ),
            findsOneWidget,
          );
          expect(find.text('1 · 50'), findsOneWidget);
          // Drama A has confirmed history at Ep 12, so Fix 3 automatically scrolls Ep 12 into view.
          expect(find.byKey(const ValueKey('ep_circle_0_11')), findsOneWidget);
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
            isTrue,
          );

          // 2. Toggle Drama A to descending -> circles, cards, and range pills reorder synchronously,
          // and Ep 12 (solid white) is automatically brought into the viewport WITHOUT manual scrolling!
          await tester.tap(find.byKey(const ValueKey('detail-episode-sort-toggle')));
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.byKey(const ValueKey('detail-episode-sort-toggle')),
              matching: find.text('倒序'),
            ),
            findsOneWidget,
          );
          expect(find.text('60 · 11'), findsOneWidget);
          expect(find.byKey(const ValueKey('ep_circle_box_0_11')), findsOneWidget);
          expect(find.byKey(const ValueKey('ep_card_0_11')), findsOneWidget);
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
            isTrue,
            reason:
                'Toggling descending must keep solid white glued to Ep 12 and bring it into view automatically',
          );

          // 3. Open Player from Drama A and return to the SAME Drama A on stack -> preserves temporary descending!
          await tester.tap(find.byKey(const ValueKey('ep_circle_0_11')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('ep_card_0_11')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('pop-temp-player')));
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.byKey(const ValueKey('detail-episode-sort-toggle')),
              matching: find.text('倒序'),
            ),
            findsOneWidget,
            reason: 'Returning from player to same Detail route must keep temporary descending sort',
          );

          // 4. Exit Drama A and open Drama B -> defaults to ascending!
          navKey.currentState!.pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('open-drama-b')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-episode-sort-toggle')),
          );
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.byKey(const ValueKey('detail-episode-sort-toggle')),
              matching: find.text('正序'),
            ),
            findsOneWidget,
            reason: 'Opening Drama B must default to ascending',
          );
          expect(find.byKey(const ValueKey('ep_circle_0_0')), findsOneWidget);

          // 5. Exit Drama B and re-enter Drama A -> defaults to ascending again!
          navKey.currentState!.pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('open-drama-a')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-episode-sort-toggle')),
          );
          await tester.pumpAndSettle();

          expect(
            find.descendant(
              of: find.byKey(const ValueKey('detail-episode-sort-toggle')),
              matching: find.text('正序'),
            ),
            findsOneWidget,
            reason: 'Exiting and re-entering Drama A must reset to ascending',
          );
          expect(find.text('1 · 50'), findsOneWidget);

          // 6. PlayerEpisodePickerSheet defaults to ascending every time it opens fresh.
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PlayerEpisodePickerSheet(
                  lines: dramaA.lines,
                  initialLineIndex: 0,
                  activeLineIndex: 0,
                  activeEpisodeIndex: 11,
                  onSelect: (_, __) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('player-episodes-sort-toggle')),
              matching: find.text('正序'),
            ),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('player-episodes-sort-toggle')));
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('player-episodes-sort-toggle')),
              matching: find.text('倒序'),
            ),
            findsOneWidget,
          );
          expect(find.text('60-21'), findsOneWidget);

          // Fresh reopen with new key resets to ascending.
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PlayerEpisodePickerSheet(
                  key: const ValueKey('fresh-picker-open'),
                  lines: dramaA.lines,
                  initialLineIndex: 0,
                  activeLineIndex: 0,
                  activeEpisodeIndex: 11,
                  onSelect: (_, __) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('player-episodes-sort-toggle')),
              matching: find.text('正序'),
            ),
            findsOneWidget,
          );

          // 7. Auto-next in PlayerScreen still advances chronologically (Ep 18 -> Ep 19)
          // even when legacy storage has episodes_descending == true!
          final fakePlayer = _FakePlayer();
          final confirmedEvents = <PlayerPlaybackConfirmation>[];
          final localDrama = CmsVideo(
            id: 'drama_a_local',
            title: '测试剧集A',
            lines: [
              CmsLine(
                id: 'local_l1',
                name: '主线路',
                episodes: [
                  for (int i = 1; i <= 25; i++)
                    CmsEpisode(name: '第$i集', url: 'file:///tmp/drama_a_ep_$i.mp4'),
                ],
              ),
            ],
          );
          await storage.setAutoNext(true);
          await tester.pumpWidget(
            MaterialApp(
              home: PlayerScreen(
                site: testSite,
                video: localDrama,
                storage: storage,
                initialLineIndex: 0,
                initialEpisodeIndex: 17, // Ep 18
                debugPlayer: fakePlayer,
                debugVideoSurface: const ColoredBox(color: Colors.black),
                onPlaybackConfirmed: confirmedEvents.add,
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(confirmedEvents, isNotEmpty);
          expect(confirmedEvents.last.episodeIndex, 17);
          expect(confirmedEvents.last.episodeUrl, endsWith('ep_18.mp4'));

          // Emit completion -> must auto-advance chronologically to Ep 19 (index 18), NOT Ep 17!
          fakePlayer.emitCompleted();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            confirmedEvents.last.episodeIndex,
            18,
            reason: 'Auto-next must advance chronologically from Ep 18 to Ep 19 regardless of descending UI',
          );
          expect(confirmedEvents.last.episodeUrl, endsWith('ep_19.mp4'));
        },
      );

      testWidgets(
        'iPad wide Detail (1024x768) & in-line multi-season episodes keep circle tap at 0 player launches, card tap at 1 launch, and never mis-highlight across seasons',
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        (tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(1024, 768);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final storage = await initTestStorage();
          final client = _MutableDetailClient();
          const seasonVideo = CmsVideo(
            id: 'multi_season_ipad',
            title: '多季长剧',
            year: '2026',
            remarks: '两季全',
            description: 'iPad 宽屏与同线路多季选集测试。',
            lines: [
              CmsLine(
                id: 'ms_l1',
                name: '4K主线',
                episodes: [
                  CmsEpisode(name: 'S01E01', url: 'https://media.example/ms/s1e1.m3u8'),
                  CmsEpisode(name: 'S01E02', url: 'https://media.example/ms/s1e2.m3u8'),
                  CmsEpisode(name: 'S01E03', url: 'https://media.example/ms/s1e3.m3u8'),
                  CmsEpisode(name: 'S02E01', url: 'https://media.example/ms/s2e1.m3u8'),
                  CmsEpisode(name: 'S02E02', url: 'https://media.example/ms/s2e2.m3u8'),
                  CmsEpisode(name: 'S02E03', url: 'https://media.example/ms/s2e3.m3u8'),
                ],
              ),
            ],
          );
          await storage.upsertWatchHistory(
            WatchHistoryEntry(
              site: testSite.key,
              id: seasonVideo.id,
              title: seasonVideo.title,
              line: '4K主线',
              episode: 'S01E02',
              index: 1,
              position: 60000,
              duration: 2400000,
              updated: 1000,
            ),
            immediate: true,
            triggerSync: false,
          );

          final launched = <(int, int)>[];
          await tester.pumpWidget(
            MaterialApp(
              home: DetailScreen(
                site: testSite,
                initialVideo: seasonVideo,
                client: client,
                storage: storage,
                debugPlayerBuilder: (ctx, _, __, lineIdx, epIdx, ___) {
                  launched.add((lineIdx, epIdx));
                  return Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        key: const ValueKey('ipad-season-exit'),
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('DONE'),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-quick-episodes-strip')),
          );
          await tester.pumpAndSettle();

          // Season 1: S01E02 (raw index 1) is solid white; tapping circle S01E03 opens player 0 times.
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_1'))),
            isTrue,
          );
          await tester.tap(find.byKey(const ValueKey('ep_circle_0_2')));
          await tester.pumpAndSettle();
          expect(launched, isEmpty);

          // Tapping card S01E03 opens player once with exact raw index 2.
          await tester.tap(find.byKey(const ValueKey('ep_card_0_2')));
          await tester.pumpAndSettle();
          expect(launched, [(0, 2)]);
          await tester.tap(find.byKey(const ValueKey('ipad-season-exit')));
          await tester.pumpAndSettle();

          // Switch to Season 2 (in-line season pill): S02E02 (raw index 4, same local position 1)
          // MUST NOT be marked solid white!
          await tester.tap(find.byKey(const ValueKey('season_pill_inline_2')));
          await tester.pumpAndSettle();
          expect(
            _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_4'))),
            isFalse,
            reason: 'Switching to Season 2 must NOT mis-highlight same local index',
          );
        },
      );
    },
  );

  group('Rework 1–6 Regressions (2026-11-25 Independent Review)', () {
    const reviewSite = CmsSite(
      key: 'rework_site',
      name: '返修验证源',
      type: 1,
      api: 'https://rework.example/api',
    );

    testWidgets(
      'R1: Real AVPlayer event path keeps Ep 12 solid white & history untouched on readyToPlay / paused non-zero seek / buffer fallback failure, and switches to Ep 18 only on actual playing',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        const avMethodCh = MethodChannel('test/rework_ios_avplayer');
        const avEventCh = EventChannel('test/rework_ios_avplayer_events');
        final openedUrls = <String>[];
        messenger.setMockMethodCallHandler(avMethodCh, (call) async {
          if (call.method == 'open') {
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            openedUrls.add(args['url']?.toString() ?? '');
            return true;
          }
          if (call.method == 'seek') return true;
          return null;
        });
        messenger.setMockMethodCallHandler(
          MethodChannel(avEventCh.name),
          (call) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(avMethodCh, null);
          messenger.setMockMethodCallHandler(MethodChannel(avEventCh.name), null);
        });

        final storage = await initTestStorage();
        await storage.setIosPlaybackEngineMode('avplayer');
        final client = _MutableDetailClient();
        final drama = _buildLongDrama(
          id: 'av_real_drama',
          title: '真 AVPlayer 确认剧',
          episodeCount: 30,
          includeSecondLine: false,
        );
        final ep12Url = drama.lines[0].episodes[11].url;
        final ep18Url = drama.lines[0].episodes[17].url;

        await storage.upsertWatchHistory(
          WatchHistoryEntry(
            site: reviewSite.key,
            id: drama.id,
            title: drama.title,
            line: drama.lines[0].name,
            lineId: drama.lines[0].id,
            episode: '第12集',
            episodeUrl: ep12Url,
            index: 11,
            position: 95000,
            duration: 2400000,
            updated: 1000,
          ),
          immediate: true,
          triggerSync: false,
        );

        late IosAvPlayerController activeAvCtrl;
        final navKey = GlobalKey<NavigatorState>();

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navKey,
            home: DetailScreen(
              site: reviewSite,
              initialVideo: drama,
              client: client,
              storage: storage,
              debugPlayerWithConfirmationBuilder: (
                ctx,
                site,
                video,
                lineIdx,
                epIdx,
                resumeMs,
                onPlaybackConfirmed,
              ) {
                activeAvCtrl = IosAvPlayerController(
                  channelOverride: avMethodCh,
                  eventChannelOverride: avEventCh,
                  platformOverride: TargetPlatform.iOS,
                  isOhosOverride: false,
                  isWebOverride: false,
                );
                return PlayerScreen(
                  site: site,
                  video: video,
                  storage: storage,
                  initialLineIndex: lineIdx,
                  initialEpisodeIndex: epIdx,
                  initialPositionMs: resumeMs,
                  onPlaybackConfirmed: onPlaybackConfirmed,
                  debugIosAvPlayerController: activeAvCtrl,
                  debugPlayer: _NonStartingFakePlayer(),
                  debugVideoSurface: const ColoredBox(color: Colors.black),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-quick-episodes-strip')),
        );
        await tester.pumpAndSettle();

        // Ep 12 is initially solid white and already brought into view.
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
          isTrue,
        );

        // Scroll slightly to tap circle 18 and bring card 18 into view.
        final circleScroll = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('detail-quick-episodes-strip')),
            matching: find.byType(Scrollable),
          ),
        );
        circleScroll.position.jumpTo(560);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ep_circle_0_17')));
        await tester.pumpAndSettle();

        // Sub-case A: Open Ep 18 via real AVPlayer path -> readyToPlay + non-zero paused/buffering
        // resume seek position -> user exits BEFORE actual playback starts.
        await tester.tap(find.byKey(const ValueKey('ep_card_0_17')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(openedUrls, hasLength(1));
        expect(openedUrls.last, endsWith('.m3u8'));

        activeAvCtrl.handleNativeEvent(const {
          'type': 'ready',
          'durationMs': 2400000,
          'positionMs': 0,
        });
        await tester.pump(const Duration(milliseconds: 100));
        activeAvCtrl.handleNativeEvent(const {
          'type': 'playbackState',
          'playing': false,
          'buffering': true,
          'positionMs': 95000,
          'durationMs': 2400000,
        });
        await tester.pump(const Duration(milliseconds: 100));

        // Must NOT overwrite history yet.
        expect(storage.getWatchHistory().first.episode, '第12集');
        expect(storage.getWatchHistory().first.episodeUrl, ep12Url);

        navKey.currentState!.pop();
        await tester.pumpAndSettle();
        activeAvCtrl.dispose();

        // Returning to Detail: Ep 12 MUST remain solid white and history unchanged.
        expect(storage.getWatchHistory().first.episode, '第12集');
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
          isTrue,
          reason: 'readyToPlay + paused/buffering seek must NOT steal white marker from Ep 12',
        );
        circleScroll.position.jumpTo(680);
        await tester.pumpAndSettle();
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_17'))),
          isFalse,
        );

        // Sub-case B: Open Ep 18 -> readyToPlay -> buffer failure (`fallbackToMpv`) where fallback
        // MPV never starts playing -> user exits -> Ep 12 MUST remain solid white!
        await tester.tap(find.byKey(const ValueKey('ep_circle_0_17')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ep_card_0_17')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        activeAvCtrl.handleNativeEvent(const {
          'type': 'ready',
          'durationMs': 2400000,
          'positionMs': 0,
        });
        await tester.pump(const Duration(milliseconds: 80));
        activeAvCtrl.handleNativeEvent(const {
          'type': 'fallbackToMpv',
          'reason': 'buffer_stalled_failed',
          'positionMs': 0,
        });
        await tester.pump(const Duration(milliseconds: 200));

        navKey.currentState!.pop();
        await tester.pumpAndSettle();
        activeAvCtrl.dispose();

        expect(storage.getWatchHistory().first.episode, '第12集');
        circleScroll.position.jumpTo(560);
        await tester.pumpAndSettle();
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
          isTrue,
          reason: 'Ready then buffer failure must keep Ep 12 solid white',
        );

        // Sub-case C: Open Ep 18 -> ready -> actual playing (`playing: true, buffering: false`) ->
        // history updates to Ep 18 with lineId + episodeUrl, and Ep 18 becomes solid white!
        circleScroll.position.jumpTo(680);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ep_circle_0_17')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ep_card_0_17')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        activeAvCtrl.handleNativeEvent(const {
          'type': 'ready',
          'durationMs': 2400000,
          'positionMs': 0,
        });
        await tester.pump(const Duration(milliseconds: 80));
        activeAvCtrl.handleNativeEvent(const {
          'type': 'playbackState',
          'playing': true,
          'buffering': false,
          'rate': 1.0,
          'positionMs': 1500,
          'durationMs': 2400000,
        });
        await tester.pump(const Duration(milliseconds: 120));

        navKey.currentState!.pop();
        await tester.pumpAndSettle();
        activeAvCtrl.dispose();

        final latestHistory = storage.getWatchHistory().first;
        expect(latestHistory.episode, '第18集');
        expect(latestHistory.lineId, drama.lines[0].id);
        expect(
          latestHistory.effectiveMediaId,
          WatchHistoryEntry.mediaIdentityForUrl(ep18Url),
        );
        expect(latestHistory.toJson().containsKey('episodeUrl'), isFalse);
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_17'))),
          isTrue,
          reason: 'Confirmed actual AVPlayer playback must move solid white marker to Ep 18',
        );
      },
    );

    testWidgets(
      'R2: Duplicate-named lines do not cross-highlight; deleting played duplicate-named file B never transfers solid white to A; ambiguous legacy history never guesses',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // Part A: Two lines BOTH named '主线' with distinct IDs and URLs.
        final storageA = await initTestStorage();
        final clientA = _MutableDetailClient();
        const dupLinesVideo = CmsVideo(
          id: 'dup_lines_vid',
          title: '同名线路剧',
          lines: [
            CmsLine(
              id: 'main_line_1',
              name: '主线',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://media.example/dup/l1_1.m3u8'),
                CmsEpisode(name: '第2集', url: 'https://media.example/dup/l1_2.m3u8'),
                CmsEpisode(name: '第3集', url: 'https://media.example/dup/l1_3.m3u8'),
              ],
            ),
            CmsLine(
              id: 'main_line_2',
              name: '主线',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://media.example/dup/l2_1.m3u8'),
                CmsEpisode(name: '第2集', url: 'https://media.example/dup/l2_2.m3u8'),
                CmsEpisode(name: '第3集', url: 'https://media.example/dup/l2_3.m3u8'),
              ],
            ),
          ],
        );
        await storageA.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'rework_site',
            id: 'dup_lines_vid',
            title: '同名线路剧',
            line: '主线',
            lineId: 'main_line_1',
            episode: '第2集',
            episodeUrl: 'https://media.example/dup/l1_2.m3u8',
            index: 1,
            position: 45000,
            duration: 1800000,
            updated: 2000,
          ),
          immediate: true,
          triggerSync: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              site: reviewSite,
              initialVideo: dupLinesVideo,
              client: clientA,
              storage: storageA,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-quick-episodes-strip')),
        );
        await tester.pumpAndSettle();

        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_1'))),
          isTrue,
        );

        // Switch to 2nd '主线' via source picker -> its ep 2 MUST NOT turn white!
        await tester.tap(find.byKey(const ValueKey('source_picker_button')));
        await tester.pumpAndSettle();
        final secondLineTile = find.text('主线');
        await tester.tap(secondLineTile.last);
        await tester.pumpAndSettle();
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_1_1'))),
          isFalse,
          reason: 'Unplayed second line with same name must NEVER inherit white marker',
        );

        // Part B: Same line with two duplicate-named files A and B -> play B -> refresh deletes B
        // leaving only A -> A MUST NOT inherit solid white!
        final storageB = await initTestStorage();
        final clientB = _MutableDetailClient();
        const dupFilesBoth = CmsVideo(
          id: 'dup_files_vid',
          title: '同名文件剧',
          lines: [
            CmsLine(
              id: 'single_line',
              name: '网盘主线',
              episodes: [
                CmsEpisode(name: '正片', url: 'https://media.example/same/file_a.mp4'),
                CmsEpisode(name: '正片', url: 'https://media.example/same/file_b.mp4'),
              ],
            ),
          ],
        );
        const dupFilesOnlyA = CmsVideo(
          id: 'dup_files_vid',
          title: '同名文件剧',
          lines: [
            CmsLine(
              id: 'single_line',
              name: '网盘主线',
              episodes: [
                CmsEpisode(name: '正片', url: 'https://media.example/same/file_a.mp4'),
              ],
            ),
          ],
        );
        await storageB.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'rework_site',
            id: 'dup_files_vid',
            title: '同名文件剧',
            line: '网盘主线',
            lineId: 'single_line',
            episode: '正片',
            episodeUrl: 'https://media.example/same/file_b.mp4',
            index: 1,
            position: 60000,
            duration: 1800000,
            updated: 3000,
          ),
          immediate: true,
          triggerSync: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              key: const ValueKey('dup-files-detail'),
              site: reviewSite,
              initialVideo: dupFilesBoth,
              client: clientB,
              storage: storageB,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-quick-episodes-strip')),
        );
        await tester.pumpAndSettle();

        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_1'))),
          isTrue,
          reason: 'Played file B should be solid white',
        );
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_0'))),
          isFalse,
          reason: 'Unplayed same-named file A must NOT be solid white',
        );

        // Refresh deletes B, leaving only A -> A must NOT inherit solid white!
        clientB.overrideVideo = dupFilesOnlyA;
        final pageScroll = tester.state<ScrollableState>(
          find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ).first,
        );
        pageScroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.dragFrom(const Offset(215, 220), const Offset(0, 260));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-quick-episodes-strip')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ep_circle_box_0_1')), findsNothing);
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_0'))),
          isFalse,
          reason: 'After file B is deleted, remaining same-named file A must NOT inherit white marker',
        );

        // Part C: Legacy history lacking lineId & episodeUrl on duplicate-named files -> never guess!
        final storageC = await initTestStorage();
        await storageC.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'rework_site',
            id: 'dup_files_vid',
            title: '同名文件剧',
            line: '网盘主线',
            episode: '正片',
            index: 1,
            position: 60000,
            duration: 1800000,
            updated: 3000,
          ),
          immediate: true,
          triggerSync: false,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              key: const ValueKey('dup-files-legacy'),
              site: reviewSite,
              initialVideo: dupFilesBoth,
              client: _MutableDetailClient(),
              storage: storageC,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-quick-episodes-strip')),
        );
        await tester.pumpAndSettle();

        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_0'))),
          isFalse,
        );
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_1'))),
          isFalse,
          reason: 'Ambiguous legacy history without episodeUrl must never guess among duplicate names',
        );
      },
    );

    testWidgets(
      'R3: 120-ep drama auto-scrolls Ep 87 on open and Ep 12 on descending toggle so both circle and card are on screen with zero manual paging/scrolling',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(430, 932);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final drama = _buildLongDrama(
          id: 'drama_auto_scroll_120',
          title: '百二十集定位验证剧',
          episodeCount: 120,
          includeSecondLine: false,
        );

        // Case 1: Ep 87 record -> opens on page 51 · 100 with both circle 87 and card 87 on screen.
        final storage87 = await initTestStorage();
        await storage87.upsertWatchHistory(
          WatchHistoryEntry(
            site: reviewSite.key,
            id: drama.id,
            title: drama.title,
            line: drama.lines[0].name,
            lineId: drama.lines[0].id,
            episode: '第87集',
            episodeUrl: drama.lines[0].episodes[86].url,
            index: 86,
            position: 120000,
            duration: 2400000,
            updated: 5000,
          ),
          immediate: true,
          triggerSync: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              key: const ValueKey('auto-scroll-ep87'),
              site: reviewSite,
              initialVideo: drama,
              client: _MutableDetailClient(),
              storage: storage87,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-quick-episodes-strip')),
        );
        await tester.pumpAndSettle();

        final circle87 = find.byKey(const ValueKey('ep_circle_0_86'));
        final card87 = find.byKey(const ValueKey('ep_card_0_86'));
        expect(circle87, findsOneWidget);
        expect(card87, findsOneWidget);
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_86'))),
          isTrue,
        );
        final circle87Rect = tester.getRect(circle87);
        final card87Rect = tester.getRect(card87);
        expect(circle87Rect.center.dx, inInclusiveRange(0.0, 430.0));
        expect(card87Rect.center.dx, inInclusiveRange(0.0, 430.0));

        // Case 2: Ep 12 record -> toggle descending -> switches to page 3 (20 · 1) with both
        // circle 12 and card 12 on screen without any manual paging or horizontal scrolling.
        final storage12 = await initTestStorage();
        await storage12.upsertWatchHistory(
          WatchHistoryEntry(
            site: reviewSite.key,
            id: drama.id,
            title: drama.title,
            line: drama.lines[0].name,
            lineId: drama.lines[0].id,
            episode: '第12集',
            episodeUrl: drama.lines[0].episodes[11].url,
            index: 11,
            position: 120000,
            duration: 2400000,
            updated: 5000,
          ),
          immediate: true,
          triggerSync: false,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              key: const ValueKey('auto-scroll-ep12-desc'),
              site: reviewSite,
              initialVideo: drama,
              client: _MutableDetailClient(),
              storage: storage12,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('detail-episode-sort-toggle')),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('detail-episode-sort-toggle')));
        await tester.pumpAndSettle();

        expect(find.text('20 · 1'), findsOneWidget);
        final circle12 = find.byKey(const ValueKey('ep_circle_0_11'));
        final card12 = find.byKey(const ValueKey('ep_card_0_11'));
        expect(circle12, findsOneWidget);
        expect(card12, findsOneWidget);
        expect(
          _isSolidWhiteCircle(tester, find.byKey(const ValueKey('ep_circle_box_0_11'))),
          isTrue,
        );
        expect(tester.getRect(circle12).center.dx, inInclusiveRange(0.0, 430.0));
        expect(tester.getRect(card12).center.dx, inInclusiveRange(0.0, 430.0));
      },
    );

    testWidgets(
      'R5: Stalled startup preserves storage_init_start stage, late stale attempt never overwrites theme / DownloadService client / duplicates tasks, and non-iOS is not forced onto 12s timeout',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final origPathProvider = PathProviderPlatform.instance;
        final origTheme = AppleTheme.mode.value;
        final tmpDir = Directory.systemTemp.createTempSync('marco-r5-bootstrap-');
        final supportDir = Directory('${tmpDir.path}/support')
          ..createSync(recursive: true);
        final downloadsFile = File('${supportDir.path}/marco_downloads.json');
        final seededTask = DownloadTask(
          id: 'seed_task_1',
          siteKey: 'rework_site',
          siteName: '返修验证源',
          siteApi: 'https://rework.example/api',
          siteType: 1,
          videoId: 'vid_1',
          title: '离线测试剧',
          poster: '',
          lineName: '主线',
          episodeName: '第1集',
          episodeIndex: 0,
          sourceUrl: 'https://media.example/dl/ep1.mp4',
          headers: const {},
          createdAt: 1700000000000,
          status: DownloadStatus.paused,
          progress: 0.5,
        );
        downloadsFile.writeAsStringSync(jsonEncode([seededTask.toJson()]));
        PathProviderPlatform.instance = _TempPathProvider(tmpDir);
        DownloadService.instance.resetForTesting();
        addTearDown(() {
          DownloadService.instance.resetForTesting();
          PathProviderPlatform.instance = origPathProvider;
          AppleTheme.mode.value = origTheme;
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {}
        });

        final storageA = await initTestStorage(
          initialPrefs: const {'app_theme_mode': 'light'},
        );
        final storageB = await initTestStorage(
          initialPrefs: const {'app_theme_mode': 'dark'},
        );
        final clientA = _MutableDetailClient();
        final clientB = _MutableDetailClient();
        final completerA = Completer<MarcoAppBootstrapResult>();
        var attempts = 0;

        await tester.pumpWidget(
          MarcoBootstrapApp(
            bootstrapTimeout: const Duration(milliseconds: 250),
            bootstrapper: () {
              attempts++;
              if (attempts == 1) {
                MarcoLaunchDiagnostics.record('storage_init_start');
                return completerA.future;
              }
              MarcoLaunchDiagnostics.record('storage_init_start');
              MarcoLaunchDiagnostics.record('storage_init_done');
              return Future.value((storage: storageB, client: clientB));
            },
            appBuilder: (_, __) => const MaterialApp(
              home: Scaffold(body: Center(child: Text('RETRY_B_READY'))),
            ),
          ),
        );

        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('初始化响应超时，请重试'), findsOneWidget);
        expect(
          find.textContaining('storage_init_start'),
          findsOneWidget,
          reason: 'Timeout UI must preserve last actual working stage (storage_init_start)',
        );
        expect(find.textContaining('bootstrap_timeout'), findsNothing);

        // User retries -> Attempt B wins and applies dark theme + clientB + loads 1 task.
        await tester.tap(find.byKey(const ValueKey('marco-bootstrap-retry')));
        await tester.pumpAndSettle();
        for (int i = 0; i < 25 && DownloadService.instance.tasks.isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(find.text('RETRY_B_READY'), findsOneWidget);
        expect(AppleTheme.mode.value, ThemeMode.dark);
        expect(identical(DownloadService.instance.debugClient, clientB), isTrue);
        expect(DownloadService.instance.tasks.length, 1);

        // Late resolution of Attempt A MUST NOT overwrite theme, replace clientB, or duplicate task.
        completerA.complete((storage: storageA, client: clientA));
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();

        expect(
          AppleTheme.mode.value,
          ThemeMode.dark,
          reason: 'Late stale attempt A must NOT overwrite winning theme',
        );
        expect(
          identical(DownloadService.instance.debugClient, clientB),
          isTrue,
          reason: 'Late stale attempt A must NOT replace DownloadService client',
        );
        expect(
          DownloadService.instance.tasks.length,
          1,
          reason: 'Late stale attempt A must NOT duplicate persisted download task',
        );

        // Even a direct repeated DownloadService.init call stays deduplicated by task.id.
        await tester.runAsync(() => DownloadService.instance.init(clientB));
        expect(DownloadService.instance.tasks.length, 1);
      },
    );

    testWidgets(
      'R5b: Non-iOS platform (Windows) is not forced onto iOS 12s bootstrap timeout',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final storage = await initTestStorage();
        final client = _MutableDetailClient();
        final slowCompleter = Completer<MarcoAppBootstrapResult>();

        await tester.pumpWidget(
          MarcoBootstrapApp(
            bootstrapper: () => slowCompleter.future,
            appBuilder: (_, __) => const MaterialApp(
              home: Scaffold(body: Center(child: Text('WINDOWS_READY'))),
            ),
          ),
        );

        // Advance well beyond iOS's 12s timeout -> Windows must NOT time out.
        await tester.pump(const Duration(seconds: 15));
        expect(find.text('初始化响应超时，请重试'), findsNothing);

        slowCompleter.complete((storage: storage, client: client));
        await tester.pumpAndSettle();
        expect(find.text('WINDOWS_READY'), findsOneWidget);
      },
    );

    testWidgets(
      'R6: iPad 507x1024 Split View ignored rotation never shows false landscape toast; actual window resize confirms toast',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(507, 1024);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20, left: 0, right: 0);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
          tester.view.resetViewPadding();
        });

        final requestedModes = <String>[];
        messenger.setMockMethodCallHandler(
          MobilePlayerChrome.iosSystemChromeChannel,
          (call) async {
            if (call.method == 'requestOrientation') {
              requestedModes.add(call.arguments?.toString() ?? '');
            }
            return null;
          },
        );

        final storage = await initTestStorage();
        final fakePlayer = _FakePlayer();
        const video = CmsVideo(
          id: 'split_view_vid',
          title: '分屏测试片',
          lines: [
            CmsLine(
              id: 'sv1',
              name: '主线',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://media.example/sv/1.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: reviewSite,
              video: video,
              storage: storage,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Tap portrait companion expand button in 507x1024 Split View; native ignores rotation.
        final expandBtn = find.byKey(const Key('ios-portrait-companion-fullscreen-btn'));
        expect(expandBtn, findsOneWidget);
        await tester.tap(expandBtn);
        await tester.pump(const Duration(milliseconds: 300));

        expect(requestedModes, contains('landscape'));
        expect(
          find.text('已切换为全屏横屏观看'),
          findsNothing,
          reason: 'Must NOT claim switched to fullscreen landscape when Split View window stays 507x1024',
        );

        // Now tap again and simulate actual window resize to landscape 1024x768 -> toast confirmed!
        await tester.tap(expandBtn);
        await tester.pump(const Duration(milliseconds: 50));
        tester.view.physicalSize = const Size(1024, 768);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text('已切换为全屏横屏观看'),
          findsOneWidget,
          reason: 'Actual window orientation change to landscape should confirm toast',
        );
      },
    );

    testWidgets(
      'R6b: Desktop Windows 1280x720 player top overlay offset is not inflated by iPad 28pt floor',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.padding = FakeViewPadding.zero;
        tester.view.viewPadding = FakeViewPadding.zero;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
          tester.view.resetViewPadding();
        });

        final storage = await initTestStorage();
        final fakePlayer = _FakePlayer();
        const video = CmsVideo(
          id: 'win_overlay_vid',
          title: '桌面端测试片',
          lines: [
            CmsLine(
              id: 'w1',
              name: '主线',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://media.example/win/1.m3u8'),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: reviewSite,
              video: video,
              storage: storage,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Hold right arrow key on Windows to show DesktopScrubPreviewCapsule at `topOverlayOffset`.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 450));
        final capsule = find.byType(DesktopScrubPreviewCapsule);
        expect(capsule, findsOneWidget);
        final topY = tester.getRect(capsule).top;
        // On Windows with viewPadding.top == 0 and top bar visible, topOverlayOffset is 84.0
        // (NOT 112.0 = 28 + 84 from iPad's 28pt status-bar floor).
        expect(
          topY,
          lessThan(100.0),
          reason: 'Windows desktop top overlay must not include iPad 28pt safe floor',
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 200));
      },
    );
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, PointerDeviceKind;
import 'package:window_manager/window_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/app_log.dart';
import 'core/cms_client.dart';
import 'core/download_service.dart';
import 'core/launch_diagnostics.dart';
import 'core/macos_window_bounds.dart';
import 'core/mdk_platform_player.dart';
import 'core/ohos_runtime.dart';
import 'core/storage_service.dart';
import 'core/video_kernel.dart';
import 'core/windows_profile_dir.dart';
import 'core/windows_window_bounds.dart';
import 'ui/adaptive_shell.dart';
import 'ui/apple_theme.dart';
import 'ui/ios_launch_splash.dart';
import 'ui/ios_liquid_glass.dart';
import 'ui/tv/tv_living_room_shell.dart';
import 'ui/windows_title_bar.dart';
import 'ui/windows_appearance.dart';
typedef MarcoAppBootstrapResult = ({StorageService storage, CmsClient client});

bool _isIosAppPlatform() =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.iOS &&
    !OhosRuntime.isOhos;

/// Pure initialization step with ZERO global singleton mutations so a timed-out
/// or superseded attempt that resolves late can never overwrite theme, native
/// appearance, log directory, or DownloadService state of a newer attempt.
Future<MarcoAppBootstrapResult> _defaultBootstrapApp() async {
  if (_isIosAppPlatform()) {
    MarcoLaunchDiagnostics.record('ios_bridge_init_start');
    try {
      await IosLiquidGlassBridge.ensureInitialized()
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('IosLiquidGlassBridge init skipped: $e');
    }
  }
  MarcoLaunchDiagnostics.record('storage_init_start');
  final storage = await StorageService.init(
    deferSecureCredentialHydration: !kIsWeb && Platform.isIOS,
  );
  MarcoLaunchDiagnostics.record(
    'storage_init_done',
    'subs=${storage.getSubscriptions().length}',
  );
  final client = CmsClient();
  return (storage: storage, client: client);
}

/// Applies global app-level side effects ONLY for the winning bootstrap attempt
/// after stale-attempt verification passes.
void _applyWinningBootstrapSideEffects(MarcoAppBootstrapResult result) {
  final storage = result.storage;
  final client = result.client;
  if (!kIsWeb &&
      Platform.isWindows &&
      defaultTargetPlatform == TargetPlatform.windows) {
    final boundsController = WindowsWindowBoundsController.installShared(storage);
    unawaited(boundsController.restoreOnStartup());
  }
  AppLog.instance.setLogDirectory(
    Directory('${storage.dataDirectory.path}/logs'),
  );
  GlassworkBackdrop.reduceTransparency.value = false;
  GlassworkBackdrop.intensity.value = 0.68;
  AppleTheme.mode.value = AppleTheme.fromPref(storage.appThemeMode);
  if (_isIosAppPlatform()) {
    unawaited(
      IosLiquidGlassBridge.setAppearanceMode(storage.appThemeMode)
          .catchError((_) {}),
    );
  }
  if (!kIsWeb &&
      Platform.isMacOS &&
      defaultTargetPlatform == TargetPlatform.macOS) {
    final macBounds = MacosWindowBoundsController.installShared(storage);
    unawaited(macBounds.syncOnStartup(initialThemeMode: AppleTheme.mode.value));
    AppleTheme.mode.addListener(() {
      macBounds.applyAppearanceMode(AppleTheme.mode.value);
    });
  }
  // Do not block Windows/desktop first frame on DownloadService disk/folder
  // probing or completed-file checks; restore runs asynchronously in background
  // while newly clicked downloads merge safely into the queue.
  unawaited(
    DownloadService.instance.init(client).catchError((Object e) {
      debugPrint('DownloadService init warning: $e');
    }),
  );
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  configureWindowsDataDirOverride(args);
  AppLog.init();
  MarcoLaunchDiagnostics.record('dart_main');
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Uncaught platform error: $error');
    return true;
  };
  // On iOS/iPadOS, never block `runApp` on an unused HarmonyOS probe channel:
  // painting Frame 1 synchronously inside `didFinishLaunchingWithOptions`
  // prevents iPadOS Home Screen icon-zoom transactions from stalling on an
  // unpresented CAMetalLayer surface.
  if (!kIsWeb && !Platform.isIOS) {
    await OhosRuntime.ensureInitialized();
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(720, 520));
    if (Platform.isWindows) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.setBackgroundColor(AppleColors.background);
    }
  }
  // On desktop platforms libmpv is the primary player; on iOS AVPlayer is
  // default and Mpv.framework is initialized lazily inside VideoKernel.create()
  // so cold launch never stalls on a 20 MB dlopen before painting Frame 1.
  if (!OhosRuntime.isOhos && !Platform.isIOS) {
    VideoKernel.ensureMediaKitInitialized();
    if (Platform.isWindows) {
      MdkPlatformPlayer.ensureInitialized();
    }
  }
  try {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppleColors.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  } catch (_) {}
  runApp(const MarcoBootstrapApp());
}

/// Immediately paints Frame 1 so iOS never stays frozen on LaunchScreen while
/// storage/plugin channels finish cold-start registration, surfaces an iOS
/// bounded timeout & retryable recovery screen if initialization throws or
/// stalls, and prevents any delayed stale attempt from mutating global state or
/// overwriting an already-recovered app.
class MarcoBootstrapApp extends StatefulWidget {
  static const Duration defaultIosBootstrapTimeout = Duration(seconds: 12);

  @visibleForTesting
  final Future<MarcoAppBootstrapResult> Function()? bootstrapper;

  @visibleForTesting
  final Widget Function(StorageService storage, CmsClient client)? appBuilder;

  @visibleForTesting
  final Duration? bootstrapTimeout;

  const MarcoBootstrapApp({
    super.key,
    this.bootstrapper,
    this.appBuilder,
    this.bootstrapTimeout,
  });

  @override
  State<MarcoBootstrapApp> createState() => _MarcoBootstrapAppState();
}

class _MarcoBootstrapAppState extends State<MarcoBootstrapApp>
    with WidgetsBindingObserver {
  MarcoAppBootstrapResult? _ready;
  Object? _error;
  bool _timedOut = false;
  String _failedStage = 'none';
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      MarcoLaunchDiagnostics.record('flutter_first_frame');
    });
    unawaited(_startBootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // When iPadOS attaches/resizes the UIWindowScene after a Home Screen launch,
    // force a fresh Flutter frame so the surface never remains blank.
    WidgetsBinding.instance.scheduleFrame();
    if (mounted && _ready == null) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  Future<void> _startBootstrap() async {
    if (_ready != null) return;
    final runId = ++_attempt;
    final attempt = MarcoLaunchDiagnostics.beginAttempt(runId);
    MarcoLaunchDiagnostics.record('bootstrap_attempt', 'attempt=$runId');
    if (mounted && (_error != null || _timedOut)) {
      setState(() {
        _error = null;
        _timedOut = false;
        _failedStage = 'none';
      });
    }
    final Duration? effectiveTimeout = widget.bootstrapTimeout ??
        (_isIosAppPlatform()
            ? MarcoBootstrapApp.defaultIosBootstrapTimeout
            : null);
    try {
      final future = attempt.run(widget.bootstrapper ?? _defaultBootstrapApp);
      final result = effectiveTimeout != null
          ? await future.timeout(effectiveTimeout)
          : await future;
      if (!mounted || runId != _attempt || _ready != null) return;
      _applyWinningBootstrapSideEffects(result);
      MarcoLaunchDiagnostics.record('bootstrap_ready', 'attempt=$runId');
      setState(() {
        _ready = result;
        _error = null;
        _timedOut = false;
        _failedStage = 'none';
      });
    } on TimeoutException catch (error, stackTrace) {
      debugPrint(
        'MarcoBootstrapApp: startup timed out (attempt=$runId): $error\n$stackTrace',
      );
      if (!mounted || runId != _attempt || _ready != null) return;
      final stalledStage = attempt.workingStage;
      MarcoLaunchDiagnostics.record(
        'bootstrap_timeout',
        'attempt=$runId last=$stalledStage',
      );
      setState(() {
        _error = error;
        _timedOut = true;
        _failedStage = stalledStage;
      });
    } on Object catch (error, stackTrace) {
      debugPrint(
        'MarcoBootstrapApp: startup failed (attempt=$runId): $error\n$stackTrace',
      );
      if (!mounted || runId != _attempt || _ready != null) return;
      final failedStage = attempt.workingStage;
      MarcoLaunchDiagnostics.record(
        'bootstrap_error',
        'attempt=$runId stage=$failedStage $error',
      );
      setState(() {
        _error = error;
        _timedOut = false;
        _failedStage = failedStage;
      });
    } finally {
      MarcoLaunchDiagnostics.endAttempt(attempt);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready != null) {
      if (widget.appBuilder != null) {
        return widget.appBuilder!(ready.storage, ready.client);
      }
      return MarcoMovieApp(storage: ready.storage, client: ready.client);
    }
    final platformBrightness =
        View.maybeOf(context)?.platformDispatcher.platformBrightness ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final isDark = platformBrightness == Brightness.dark;
    final bg = isDark ? AppleColors.background : ApplePalette.light.background;
    final fg =
        isDark ? AppleColors.labelPrimary : ApplePalette.light.labelPrimary;
    final secondaryFg =
        isDark ? AppleColors.labelSecondary : ApplePalette.light.labelSecondary;
    final isIosStyleLaunch = _isIosAppPlatform();
    Widget buildStatusAccessory(BuildContext innerContext) {
      if (_error == null) {
        return CupertinoActivityIndicator(
          key: const ValueKey('marco-bootstrap-spinner'),
          animating: !View.of(innerContext)
              .platformDispatcher
              .accessibilityFeatures
              .disableAnimations,
          radius: isIosStyleLaunch ? 10 : 12,
          color: secondaryFg,
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _timedOut ? '初始化响应超时，请重试' : '初始化未完成，请重试',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: fg,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _timedOut
                ? '本地存储或系统服务响应过慢（阶段：$_failedStage），点击重新加载即可恢复。'
                : '$_error',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: secondaryFg,
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 18),
          CupertinoButton.filled(
            key: const ValueKey('marco-bootstrap-retry'),
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 10,
            ),
            onPressed: () => unawaited(_startBootstrap()),
            child: const Text('重新加载'),
          ),
        ],
      );
    }

    return MediaQuery.fromView(
      view: View.of(context),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: isDark ? ThemeData.dark() : ThemeData.light(),
          child: Builder(
            builder: (innerContext) => ColoredBox(
              key: const ValueKey('marco-bootstrap-surface'),
              color: bg,
              child: isIosStyleLaunch
                  ? IosLaunchStageView(
                      isDark: isDark,
                      showWordmark: _error == null,
                      bottomAccessory: buildStatusAccessory(innerContext),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MarcoBrandLogo(
                              iconSize: 56,
                              fontSize: 20,
                              stacked: true,
                              forceLightInk: isDark,
                            ),
                            const SizedBox(height: 22),
                            buildStatusAccessory(innerContext),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  static bool get isDesktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux ||
          (OhosRuntime.isOhos &&
              OhosRuntime.deviceProfile.deviceType.toLowerCase() == '2in1'));

  @override
  Set<PointerDeviceKind> get dragDevices => isDesktopPlatform
      ? const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        }
      : const {
          PointerDeviceKind.touch,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        };
}

class MarcoMovieApp extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  static const List<String> _cjkFontFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Heiti SC',
    'SimHei',
  ];
  const MarcoMovieApp({
    super.key,
    required this.storage,
    required this.client,
  });

  @override
  State<MarcoMovieApp> createState() => _MarcoMovieAppState();
}

class _MarcoMovieAppState extends State<MarcoMovieApp> {
  final IosRootTabNavigatorObserver _rootTabNavigatorObserver =
      IosRootTabNavigatorObserver();

  @override
  Widget build(BuildContext context) {
    final isWin = defaultTargetPlatform == TargetPlatform.windows;
    final primaryFont = isWin ? 'Microsoft YaHei UI' : null;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppleTheme.mode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          scrollBehavior: const AppScrollBehavior(),
          navigatorObservers: <NavigatorObserver>[_rootTabNavigatorObserver],
          title: 'Marco Movie',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: ThemeData(
            brightness: Brightness.light,
            fontFamily: primaryFont,
            fontFamilyFallback: MarcoMovieApp._cjkFontFallback,
            scaffoldBackgroundColor: ApplePalette.light.background,
            canvasColor: ApplePalette.light.groupedPrimary,
            primaryColor: ApplePalette.light.accent,
            cupertinoOverrideTheme: CupertinoThemeData(
              brightness: Brightness.light,
              primaryColor: ApplePalette.light.accent,
              scaffoldBackgroundColor: ApplePalette.light.background,
              barBackgroundColor: ApplePalette.light.navBarBg,
              textTheme: CupertinoTextThemeData(
                primaryColor: ApplePalette.light.labelPrimary,
                textStyle: TextStyle(
                  color: ApplePalette.light.labelPrimary,
                  fontFamily: primaryFont,
                  fontFamilyFallback: MarcoMovieApp._cjkFontFallback,
                ),
              ),
            ),
            colorScheme: ColorScheme.light(
              primary: ApplePalette.light.accent,
              secondary: AppleColors.systemIndigo,
              surface: ApplePalette.light.groupedPrimary,
              error: AppleColors.systemRed,
            ),
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
                TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
                TargetPlatform.windows: WindowsSmoothPageTransitionsBuilder(),
                TargetPlatform.android: CupertinoPageTransitionsBuilder(),
              },
            ),
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.black.withValues(alpha: 0.05),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: primaryFont,
            fontFamilyFallback: MarcoMovieApp._cjkFontFallback,
            scaffoldBackgroundColor: AppleColors.background,
            canvasColor: AppleColors.groupedPrimary,
            primaryColor: AppleColors.systemBlue,
            cupertinoOverrideTheme: CupertinoThemeData(
              brightness: Brightness.dark,
              primaryColor: AppleColors.systemBlue,
              scaffoldBackgroundColor: AppleColors.background,
              barBackgroundColor: const Color(0xB81C1C1E),
              textTheme: CupertinoTextThemeData(
                primaryColor: AppleColors.labelPrimary,
                textStyle: TextStyle(
                  color: AppleColors.labelPrimary,
                  fontFamily: primaryFont,
                  fontFamilyFallback: MarcoMovieApp._cjkFontFallback,
                ),
              ),
            ),
            colorScheme: const ColorScheme.dark(
              primary: AppleColors.systemBlue,
              secondary: AppleColors.systemIndigo,
              surface: AppleColors.groupedPrimary,
              error: AppleColors.systemRed,
            ),
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
                TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
                TargetPlatform.windows: WindowsSmoothPageTransitionsBuilder(),
                TargetPlatform.android: CupertinoPageTransitionsBuilder(),
              },
            ),
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.white10,
            useMaterial3: true,
          ),
          builder: (context, child) {
            if (child == null) return const SizedBox.shrink();
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final overlayStyle = isDark
                ? const SystemUiOverlayStyle(
                    statusBarBrightness: Brightness.dark,
                    statusBarIconBrightness: Brightness.light,
                    systemNavigationBarColor: AppleColors.background,
                    systemNavigationBarIconBrightness: Brightness.light,
                  )
                : SystemUiOverlayStyle(
                    statusBarBrightness: Brightness.light,
                    statusBarIconBrightness: Brightness.dark,
                    systemNavigationBarColor: ApplePalette.light.background,
                    systemNavigationBarIconBrightness: Brightness.dark,
                  );
            final wrapped = (!kIsWeb &&
                    Platform.isWindows &&
                    !Platform.environment.containsKey('FLUTTER_TEST'))
                ? WindowsImmersiveFrame(child: child)
                : (_isIosAppPlatform()
                    ? IosLaunchCurtainHost(child: child)
                    : child);
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: overlayStyle,
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontFamily: primaryFont,
                  fontFamilyFallback: MarcoMovieApp._cjkFontFallback,
                ),
                child: isWin
                    ? WindowsAppearanceHost(
                        directory: widget.storage.dataDirectory,
                        child: wrapped,
                      )
                    : wrapped,
              ),
            );
          },
          home: ValueListenableBuilder<int>(
            valueListenable: OhosRuntime.uiModeRevision,
            builder: (context, _, __) {
              if (OhosRuntime.shouldUseTvUi(widget.storage.tvUiMode)) {
                return TvLivingRoomShell(
                  storage: widget.storage,
                  client: widget.client,
                );
              }
              return AdaptiveShell(
                storage: widget.storage,
                client: widget.client,
              );
            },
          ),
        );
      },
    );
  }
}

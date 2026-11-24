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
import 'core/ohos_runtime.dart';
import 'core/storage_service.dart';
import 'core/video_kernel.dart';
import 'ui/adaptive_shell.dart';
import 'ui/apple_theme.dart';
import 'ui/ios_liquid_glass.dart';
import 'ui/tv/tv_living_room_shell.dart';
import 'ui/windows_title_bar.dart';
import 'ui/windows_appearance.dart';

typedef MarcoAppBootstrapResult = ({StorageService storage, CmsClient client});

Future<MarcoAppBootstrapResult> _defaultBootstrapApp() async {
  try {
    await IosLiquidGlassBridge.ensureInitialized()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('IosLiquidGlassBridge init skipped: $e');
  }
  final storage = await StorageService.init(
    deferSecureCredentialHydration: !kIsWeb && Platform.isIOS,
  );
  AppLog.instance.setLogDirectory(
    Directory('${storage.dataDirectory.path}/logs'),
  );
  GlassworkBackdrop.reduceTransparency.value = false;
  GlassworkBackdrop.intensity.value = 0.68;
  AppleTheme.mode.value = AppleTheme.fromPref(storage.appThemeMode);
  unawaited(
    IosLiquidGlassBridge.setAppearanceMode(storage.appThemeMode)
        .timeout(const Duration(seconds: 2))
        .catchError((_) {}),
  );
  final client = CmsClient();
  unawaited(
    DownloadService.instance.init(client).catchError((Object e) {
      debugPrint('DownloadService init warning: $e');
    }),
  );
  return (storage: storage, client: client);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Uncaught platform error: $error');
    return true;
  };
  await OhosRuntime.ensureInitialized();
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
/// storage/plugin channels finish cold-start registration, and surfaces a
/// retryable recovery screen if initialization fails instead of dying silently.
class MarcoBootstrapApp extends StatefulWidget {
  @visibleForTesting
  final Future<MarcoAppBootstrapResult> Function()? bootstrapper;

  @visibleForTesting
  final Widget Function(StorageService storage, CmsClient client)? appBuilder;

  const MarcoBootstrapApp({
    super.key,
    this.bootstrapper,
    this.appBuilder,
  });

  @override
  State<MarcoBootstrapApp> createState() => _MarcoBootstrapAppState();
}

class _MarcoBootstrapAppState extends State<MarcoBootstrapApp> {
  MarcoAppBootstrapResult? _ready;
  Object? _error;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_startBootstrap());
  }

  Future<void> _startBootstrap() async {
    final runId = ++_attempt;
    if (mounted && _error != null) {
      setState(() => _error = null);
    }
    try {
      final result = await (widget.bootstrapper ?? _defaultBootstrapApp)();
      if (!mounted || runId != _attempt) return;
      setState(() {
        _ready = result;
        _error = null;
      });
    } on Object catch (error, stackTrace) {
      debugPrint('MarcoBootstrapApp: startup failed: $error\n$stackTrace');
      if (!mounted || runId != _attempt) return;
      setState(() => _error = error);
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
    return MediaQuery.fromView(
      view: View.of(context),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: isDark ? ThemeData.dark() : ThemeData.light(),
          child: ColoredBox(
            key: const ValueKey('marco-bootstrap-surface'),
            color: bg,
            child: Center(
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
                    if (_error == null)
                      CupertinoActivityIndicator(
                        key: const ValueKey('marco-bootstrap-spinner'),
                        radius: 12,
                        color: secondaryFg,
                      )
                    else ...[
                      Text(
                        '初始化未完成，请重试',
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
                        '$_error',
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
                  ],
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
                : child;
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

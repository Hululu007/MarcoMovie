import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'package:window_manager/window_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'core/app_log.dart';
import 'core/cms_client.dart';
import 'core/download_service.dart';
import 'core/storage_service.dart';
import 'ui/adaptive_shell.dart';
import 'ui/apple_theme.dart';
import 'ui/windows_title_bar.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();
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
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('MediaKit init warning: $e');
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
  final storage = await StorageService.init();
  AppLog.instance.setLogDirectory(Directory('${storage.dataDirectory.path}/logs'));
  GlassworkBackdrop.reduceTransparency.value = storage.glassBlurLevel == 'solid';
  GlassworkBackdrop.intensity.value = storage.glassBlurStrength;
  final client = CmsClient();
  try {
    await DownloadService.instance.init(client);
  } catch (e) {
    debugPrint('DownloadService init warning: $e');
  }
  runApp(MarcoMovieApp(storage: storage, client: client));
}
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  static bool get isDesktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

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

class MarcoMovieApp extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final isWin = defaultTargetPlatform == TargetPlatform.windows;
    final primaryFont = isWin ? 'Microsoft YaHei UI' : null;
    return MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      title: 'Marco Movie',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: primaryFont,
        fontFamilyFallback: _cjkFontFallback,
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
              fontFamilyFallback: _cjkFontFallback,
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
        final wrapped = (!kIsWeb &&
                Platform.isWindows &&
                !Platform.environment.containsKey('FLUTTER_TEST'))
            ? WindowsImmersiveFrame(child: child)
            : child;
        return DefaultTextStyle.merge(
          style: TextStyle(
            fontFamily: primaryFont,
            fontFamilyFallback: _cjkFontFallback,
          ),
          child: wrapped,
        );
      },
      home: AdaptiveShell(storage: storage, client: client),
    );
  }
}

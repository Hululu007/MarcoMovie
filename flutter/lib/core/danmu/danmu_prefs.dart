import 'package:shared_preferences/shared_preferences.dart';

import '../ohos_runtime.dart';
import 'block_filter.dart';
import 'dandanplay_provider.dart';

/// Immutable user preferences for the segmented danmu engine and layer.
///
/// Self-contained persistence via [SharedPreferences] using `danmu_*` keys
/// without touching `storage_service.dart`. Default `serverUrls` is strictly `""`.
class DanmuSettings {
  static const List<double> areaOptions = <double>[0.25, 0.50, 0.75, 1.00];
  static const List<double> speedOptions = <double>[0.75, 1.00, 1.25, 1.50];

  final bool enabled;
  final String serverUrls;
  final String appId;
  final String appSecret;
  final double opacity;
  final double displayArea;
  final double fontSize;
  final double speedMultiplier;
  final int timeOffsetMs;
  final bool showScroll;
  final bool showTop;
  final bool showBottom;
  final int maxRows;
  final List<String> blockRules;

  const DanmuSettings({
    this.enabled = false,
    this.serverUrls = DandanplayProvider.defaultServerUrls,
    this.appId = '',
    this.appSecret = '',
    this.opacity = 0.85,
    this.displayArea = 0.50,
    this.fontSize = 20.0,
    this.speedMultiplier = 1.0,
    this.timeOffsetMs = 0,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.maxRows = 14,
    this.blockRules = const <String>[],
  });

  /// HarmonyOS NEXT guard: always disabled on OHOS.
  bool get effectiveEnabled => !OhosRuntime.isOhos && enabled;

  List<String> get normalizedOrigins =>
      DandanplayProvider.parseConfiguredOrigins(serverUrls);

  DanmuBlockFilter buildBlockFilter() => DanmuBlockFilter.compile(blockRules);

  DandanplayProvider buildProvider() => DandanplayProvider(
        multilineServerUrls: serverUrls,
        appId: appId,
        appSecret: appSecret,
      );

  DanmuSettings copyWith({
    bool? enabled,
    String? serverUrls,
    String? appId,
    String? appSecret,
    double? opacity,
    double? displayArea,
    double? fontSize,
    double? speedMultiplier,
    int? timeOffsetMs,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    int? maxRows,
    List<String>? blockRules,
  }) {
    return DanmuSettings(
      enabled: enabled ?? this.enabled,
      serverUrls: (serverUrls ?? this.serverUrls).trim(),
      appId: (appId ?? this.appId).trim(),
      appSecret: (appSecret ?? this.appSecret).trim(),
      opacity: clampOpacity(opacity ?? this.opacity),
      displayArea: snapArea(displayArea ?? this.displayArea),
      fontSize: clampFontSize(fontSize ?? this.fontSize),
      speedMultiplier: snapSpeed(speedMultiplier ?? this.speedMultiplier),
      timeOffsetMs: clampTimeOffsetMs(timeOffsetMs ?? this.timeOffsetMs),
      showScroll: showScroll ?? this.showScroll,
      showTop: showTop ?? this.showTop,
      showBottom: showBottom ?? this.showBottom,
      maxRows: clampMaxRows(maxRows ?? this.maxRows),
      blockRules: sanitizeBlockRules(blockRules ?? this.blockRules),
    );
  }

  static double clampOpacity(double value) {
    final c = value.clamp(0.20, 1.00);
    return (c * 20).round() / 20.0;
  }

  static double snapArea(double value) {
    var best = areaOptions[1];
    var bestDiff = double.infinity;
    for (final opt in areaOptions) {
      final d = (opt - value).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = opt;
      }
    }
    return best;
  }

  static double clampFontSize(double lp) => lp.clamp(14.0, 32.0).roundToDouble();

  static double snapSpeed(double value) {
    var best = speedOptions[1];
    var bestDiff = double.infinity;
    for (final opt in speedOptions) {
      final d = (opt - value).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = opt;
      }
    }
    return best;
  }

  static int clampTimeOffsetMs(int offsetMs) {
    final c = offsetMs.clamp(-30000, 30000);
    return (c / 500.0).round() * 500;
  }

  static int clampMaxRows(int rows) => rows.clamp(2, 14);

  static List<String> sanitizeBlockRules(Iterable<String> rawRules) {
    final out = <String>[];
    for (final raw in rawRules) {
      if (out.length >= DanmuBlockFilter.maxRules) break;
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      if (DanmuBlockFilter.validateRule(trimmed).valid &&
          !out.contains(trimmed)) {
        out.add(trimmed);
      }
    }
    return List<String>.unmodifiable(out);
  }
}

class DanmuPrefs {
  static const String keyEnabled = 'danmu_enabled';
  static const String keyServerUrls = 'danmu_server_urls';
  static const String keyAppId = 'danmu_app_id';
  static const String keyAppSecret = 'danmu_app_secret';
  static const String keyOpacity = 'danmu_opacity';
  static const String keyDisplayArea = 'danmu_display_area';
  static const String keyFontSize = 'danmu_font_size';
  static const String keySpeedMultiplier = 'danmu_speed_multiplier';
  static const String keyTimeOffsetMs = 'danmu_time_offset_ms';
  static const String keyShowScroll = 'danmu_show_scroll';
  static const String keyShowTop = 'danmu_show_top';
  static const String keyShowBottom = 'danmu_show_bottom';
  static const String keyMaxRows = 'danmu_max_rows';
  static const String keyBlockRules = 'danmu_block_rules';

  static Future<DanmuSettings> load({SharedPreferences? prefs}) async {
    if (OhosRuntime.isOhos) {
      return const DanmuSettings(enabled: false);
    }
    final sp = prefs ?? await SharedPreferences.getInstance();
    final rawRules = sp.getStringList(keyBlockRules) ?? const <String>[];
    return DanmuSettings(
      enabled: sp.getBool(keyEnabled) ?? false,
      serverUrls: sp.getString(keyServerUrls) ?? DandanplayProvider.defaultServerUrls,
      appId: sp.getString(keyAppId) ?? '',
      appSecret: sp.getString(keyAppSecret) ?? '',
      opacity: DanmuSettings.clampOpacity(sp.getDouble(keyOpacity) ?? 0.85),
      displayArea: DanmuSettings.snapArea(sp.getDouble(keyDisplayArea) ?? 0.50),
      fontSize: DanmuSettings.clampFontSize(sp.getDouble(keyFontSize) ?? 20.0),
      speedMultiplier:
          DanmuSettings.snapSpeed(sp.getDouble(keySpeedMultiplier) ?? 1.0),
      timeOffsetMs:
          DanmuSettings.clampTimeOffsetMs(sp.getInt(keyTimeOffsetMs) ?? 0),
      showScroll: sp.getBool(keyShowScroll) ?? true,
      showTop: sp.getBool(keyShowTop) ?? true,
      showBottom: sp.getBool(keyShowBottom) ?? true,
      maxRows: DanmuSettings.clampMaxRows(sp.getInt(keyMaxRows) ?? 14),
      blockRules: DanmuSettings.sanitizeBlockRules(rawRules),
    );
  }

  static Future<void> save(
    DanmuSettings settings, {
    SharedPreferences? prefs,
  }) async {
    if (OhosRuntime.isOhos) return;
    final sp = prefs ?? await SharedPreferences.getInstance();
    await sp.setBool(keyEnabled, settings.enabled);
    await sp.setString(keyServerUrls, settings.serverUrls);
    await sp.setString(keyAppId, settings.appId);
    await sp.setString(keyAppSecret, settings.appSecret);
    await sp.setDouble(keyOpacity, DanmuSettings.clampOpacity(settings.opacity));
    await sp.setDouble(
      keyDisplayArea,
      DanmuSettings.snapArea(settings.displayArea),
    );
    await sp.setDouble(keyFontSize, DanmuSettings.clampFontSize(settings.fontSize));
    await sp.setDouble(
      keySpeedMultiplier,
      DanmuSettings.snapSpeed(settings.speedMultiplier),
    );
    await sp.setInt(
      keyTimeOffsetMs,
      DanmuSettings.clampTimeOffsetMs(settings.timeOffsetMs),
    );
    await sp.setBool(keyShowScroll, settings.showScroll);
    await sp.setBool(keyShowTop, settings.showTop);
    await sp.setBool(keyShowBottom, settings.showBottom);
    await sp.setInt(keyMaxRows, DanmuSettings.clampMaxRows(settings.maxRows));
    await sp.setStringList(
      keyBlockRules,
      DanmuSettings.sanitizeBlockRules(settings.blockRules),
    );
  }
}

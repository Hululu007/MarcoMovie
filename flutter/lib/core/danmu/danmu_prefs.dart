// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../ohos_runtime.dart';
import 'block_filter.dart';
import 'dandanplay_provider.dart';
import 'danmu_source_sync.dart';

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
  static const String keySourcesInitialized = 'danmu_sources_initialized';
  static const String keySourcesUpdatedAt = 'danmu_sources_updated_at';
  static const String keySourcesRevision = 'danmu_sources_revision';
  static const String keySourcesClearedAt = 'danmu_sources_cleared_at';
  static const String keySourcesAuthHints = 'danmu_sources_auth_hints';
  static const String keySourcesBaseSnapshot = 'danmu_sources_sync_base_v1';
  static const String keyPendingAuthOrigins = 'danmu_pending_auth_origins';

  /// Optional listener invoked when user mutates danmu source addresses/order
  /// so WebDAV auto-sync can schedule a background sync automatically.
  static void Function()? onSourcesChanged;

  static final Expando<void Function()> _prefsSourcesChangedHooks =
      Expando<void Function()>();

  /// Binds a per-[SharedPreferences] mutation hook so multiple isolated
  /// [StorageService] profiles do not cross-trigger auto-sync.
  static void registerSourcesChangedHook(
    SharedPreferences prefs,
    void Function()? listener,
  ) {
    _prefsSourcesChangedHooks[prefs] = listener;
  }

  static Future<void> clearPendingAuthOrigins({
    SharedPreferences? prefs,
  }) async {
    if (OhosRuntime.isOhos) return;
    final sp = prefs ?? await SharedPreferences.getInstance();
    await sp.setString(keyPendingAuthOrigins, '[]');
  }

  static List<String> _readStringSetJson(SharedPreferences sp, String key) {
    final raw = (sp.getString(key) ?? '').trim();
    if (raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return List<String>.unmodifiable(
          decoded
              .map((e) => (e ?? '').toString().trim())
              .where((s) => s.isNotEmpty),
        );
      }
    } catch (_) {}
    return const <String>[];
  }

  static bool _sameOriginOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<List<String>> loadPendingAuthOrigins({
    SharedPreferences? prefs,
  }) async {
    if (OhosRuntime.isOhos) return const <String>[];
    final sp = prefs ?? await SharedPreferences.getInstance();
    return readPendingAuthOriginsSync(sp);
  }

  static List<String> readPendingAuthOriginsSync(SharedPreferences sp) {
    if (OhosRuntime.isOhos) return const <String>[];
    final appId = (sp.getString(keyAppId) ?? '').trim();
    final appSecret = (sp.getString(keyAppSecret) ?? '').trim();
    if (appId.isNotEmpty && appSecret.isNotEmpty) {
      return const <String>[];
    }
    final activeOrigins = DandanplayProvider.parseConfiguredOrigins(
      sp.getString(keyServerUrls) ?? '',
    ).toSet();
    return List<String>.unmodifiable(
      _readStringSetJson(sp, keyPendingAuthOrigins)
          .where((u) => activeOrigins.contains(u)),
    );
  }

  static ({
    DanmuSourceSyncDocument local,
    DanmuSourceSyncDocument? base,
    bool hasLocalCredentials,
    List<String> pendingAuthOrigins,
  }) readSyncStateSync(SharedPreferences sp) {
    final rawUrls =
        sp.getString(keyServerUrls) ?? DandanplayProvider.defaultServerUrls;
    final origins = DandanplayProvider.parseConfiguredOrigins(rawUrls);
    final appId = (sp.getString(keyAppId) ?? '').trim();
    final appSecret = (sp.getString(keyAppSecret) ?? '').trim();
    final hasCreds = appId.isNotEmpty && appSecret.isNotEmpty;

    final authHints = _readStringSetJson(sp, keySourcesAuthHints).toSet();
    final entries = origins
        .map(
          (url) => DanmuSyncSourceEntry(
            url: url,
            requiresAuth: hasCreds || authHints.contains(url),
          ),
        )
        .toList(growable: false);

    final updatedAt = sp.getInt(keySourcesUpdatedAt) ?? 0;
    final revision = sp.getInt(keySourcesRevision) ?? 0;
    final clearedAt = sp.getInt(keySourcesClearedAt) ?? 0;
    final initialized = (sp.getBool(keySourcesInitialized) ?? false) ||
        origins.isNotEmpty ||
        updatedAt > 0 ||
        clearedAt > 0;

    final localDoc = DanmuSourceSyncDocument(
      updatedAt: updatedAt,
      revision: revision,
      clearedAt: clearedAt,
      initialized: initialized,
      sources: entries,
    );
    final baseDoc = DanmuSourceSyncDocument.tryParseJson(
      sp.getString(keySourcesBaseSnapshot),
      treatAsRemote: false,
    );
    return (
      local: localDoc,
      base: baseDoc,
      hasLocalCredentials: hasCreds,
      pendingAuthOrigins: readPendingAuthOriginsSync(sp),
    );
  }

  /// Applies a merged/restored [DanmuSourceSyncDocument] to [prefs] while
  /// strictly preserving local device `appId` and `appSecret`.
  static Future<void> applySyncedDocument(
    DanmuSourceSyncDocument doc, {
    required SharedPreferences prefs,
    required List<String> pendingAuthOrigins,
  }) async {
    if (OhosRuntime.isOhos) return;
    final normalized = doc.copyWith(
      initialized: true,
      sources: DanmuSourceSyncDocument.sanitizeEntries(doc.sources),
    );
    await prefs.setString(keyServerUrls, normalized.toMultilineServerUrls());
    await prefs.setBool(keySourcesInitialized, true);
    await prefs.setInt(keySourcesUpdatedAt, normalized.updatedAt);
    await prefs.setInt(keySourcesRevision, normalized.revision);
    await prefs.setInt(keySourcesClearedAt, normalized.clearedAt);
    final authHints = normalized.sources
        .where((s) => s.requiresAuth)
        .map((s) => s.url)
        .toList(growable: false);
    await prefs.setString(keySourcesAuthHints, jsonEncode(authHints));
    await prefs.setString(
      keySourcesBaseSnapshot,
      jsonEncode(normalized.toLocalSnapshotMap()),
    );
    await prefs.setString(
      keyPendingAuthOrigins,
      jsonEncode(pendingAuthOrigins),
    );
  }

  static Future<DanmuSettings> load({SharedPreferences? prefs}) async {
    if (OhosRuntime.isOhos) return const DanmuSettings();
    final sp = prefs ?? await SharedPreferences.getInstance();
    return DanmuSettings(
      enabled: sp.getBool(keyEnabled) ?? false,
      serverUrls:
          sp.getString(keyServerUrls) ?? DandanplayProvider.defaultServerUrls,
      appId: sp.getString(keyAppId) ?? '',
      appSecret: sp.getString(keyAppSecret) ?? '',
      opacity: DanmuSettings.clampOpacity(sp.getDouble(keyOpacity) ?? 0.85),
      displayArea:
          DanmuSettings.snapArea(sp.getDouble(keyDisplayArea) ?? 0.50),
      fontSize:
          DanmuSettings.clampFontSize(sp.getDouble(keyFontSize) ?? 20.0),
      speedMultiplier:
          DanmuSettings.snapSpeed(sp.getDouble(keySpeedMultiplier) ?? 1.0),
      timeOffsetMs: DanmuSettings.clampTimeOffsetMs(
        sp.getInt(keyTimeOffsetMs) ?? 0,
      ),
      showScroll: sp.getBool(keyShowScroll) ?? true,
      showTop: sp.getBool(keyShowTop) ?? true,
      showBottom: sp.getBool(keyShowBottom) ?? true,
      maxRows: DanmuSettings.clampMaxRows(sp.getInt(keyMaxRows) ?? 14),
      blockRules: DanmuSettings.sanitizeBlockRules(
        sp.getStringList(keyBlockRules) ?? const <String>[],
      ),
    );
  }

  static Future<void> save(
    DanmuSettings settings, {
    SharedPreferences? prefs,
    bool markExplicitSourcesEdit = false,
    bool triggerSync = true,
    int? nowMs,
  }) async {
    if (OhosRuntime.isOhos) return;
    final sp = prefs ?? await SharedPreferences.getInstance();
    final prevOrigins = DandanplayProvider.parseConfiguredOrigins(
      sp.getString(keyServerUrls) ?? '',
    );
    final nextOrigins = DandanplayProvider.parseConfiguredOrigins(
      settings.serverUrls,
    );
    final originsChanged = !_sameOriginOrder(prevOrigins, nextOrigins);
    final hasCreds =
        settings.appId.trim().isNotEmpty && settings.appSecret.trim().isNotEmpty;
    final prevAuthHints = _readStringSetJson(sp, keySourcesAuthHints).toSet();

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

    final nextAuthHints = <String>{
      for (final u in nextOrigins)
        if (hasCreds || prevAuthHints.contains(u)) u,
    };
    final authHintsChanged =
        nextAuthHints.length != prevAuthHints.length ||
            !nextAuthHints.containsAll(prevAuthHints);

    if (hasCreds) {
      await sp.setString(keyPendingAuthOrigins, '[]');
    } else if (originsChanged) {
      final activeSet = nextOrigins.toSet();
      final filteredPending = _readStringSetJson(sp, keyPendingAuthOrigins)
          .where((u) => activeSet.contains(u))
          .toList(growable: false);
      await sp.setString(keyPendingAuthOrigins, jsonEncode(filteredPending));
    }

    if (originsChanged || markExplicitSourcesEdit || authHintsChanged) {
      final ts = math.max(
        nowMs ?? DateTime.now().millisecondsSinceEpoch,
        (sp.getInt(keySourcesUpdatedAt) ?? 0) + 1,
      );
      final rev = (sp.getInt(keySourcesRevision) ?? 0) + 1;
      await sp.setBool(keySourcesInitialized, true);
      await sp.setInt(keySourcesUpdatedAt, ts);
      await sp.setInt(keySourcesRevision, rev);
      await sp.setInt(keySourcesClearedAt, nextOrigins.isEmpty ? ts : 0);
      await sp.setString(
        keySourcesAuthHints,
        jsonEncode(nextAuthHints.toList(growable: false)),
      );
      if (triggerSync) {
        _prefsSourcesChangedHooks[sp]?.call();
        onSourcesChanged?.call();
      }
    }
  }
}

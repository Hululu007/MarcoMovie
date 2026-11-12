import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'catpaw_host.dart';
import 'cms_parser.dart';
import 'csp_bridge.dart';
import 'models.dart';
import 'quark_account.dart';
import 'netdisk_session.dart';
/// Persistent preferences and backup serializer compatible with Android `Prefs.java`.
class StorageService {
  static const String syncSchema = 'marco-movie-sync';
  static const int syncVersion = 2;
  static const String defaultSyncFileName = 'marco-movie-sync.json';
  static const int maxSyncTombstones = 300;
  static const int maxSyncPayloadBytes = 8 * 1024 * 1024;
  static const String keyOrigin = 'origin';
  static const String keyRawConfig = 'config_raw_json';
  static const String keySelectedSite = 'selected_site';
  static const String keyPreferredSite = 'preferred_site';
  static const String keyPreferredLine = 'preferred_line';
  static const String keyWatchHistory = 'watch_history';
  static const String keyFavorites = 'favorites';
  static const String keyPrivateFavorites = 'private_favorites';
  static const String keySearchHistory = 'global_search_history';
  static const String keyPrivateSearchHistory = 'private_search_history';
  static const String keyEpisodesDescending = 'episodes_descending';
  static const String keyPlaySpeed = 'play_speed';
  static const String keyAutoNext = 'auto_next';
  static const String keySkipIntroSec = 'skip_intro_sec';
  static const String keySkipOutroSec = 'skip_outro_sec';
  static const String keyRepeatMode = 'repeat_mode';
  static const String keyQuarkCookie = 'netdisk_quark_cookie';
  static const String keyUcCookie = 'netdisk_uc_cookie';
  static const String keyBaiduCookie = 'netdisk_baidu_cookie';
  static const String keyAliToken = 'netdisk_ali_token';
  static const String keyDriveOrder = 'netdisk_drive_order';
  static const String keyDepots = 'saved_depots';
  static const String keyActiveDepotName = 'active_depot_name';
  static const String keySubscriptions = 'saved_subscriptions';
  static const String keyPrivacyPassword = 'privacy_password';
  static const String keyWallpaperPreset = 'wallpaper_preset';
  static const String keyCustomWallpaperUrl = 'custom_wallpaper_url';
  static const String keyAmbientGlow = 'ambient_glow_enabled';
  static const String keyGlassBlurLevel = 'glass_blur_level';
  static const String keyGlassBlurStrength = 'glass_blur_strength';
  static const String keyGridDensity = 'grid_density';
  static const String keyShowHeroBanner = 'show_hero_banner';
  static const String keyShowContinueWatching = 'show_continue_watching';
  static const String keyCardSubtitleMode = 'card_subtitle_mode';
  static const String keyPreferredQuality = 'preferred_quality';
  static const String keyDefaultAspectMode = 'default_aspect_mode';
  static const String keyPlayerKernel = 'player_kernel';
  static const String keyWebdavUrl = 'webdav_url';
  static const String keyWebdavUser = 'webdav_user';
  static const String keyWebdavPass = 'webdav_pass';
  static const String keyWebdavAuto = 'webdav_auto';
  static const String keyWebdavSyncSubs = 'webdav_sync_subs';
  static const String keySyncTombstones = 'sync_tombstones';
  static const String keySyncLastTime = 'sync_last_time';
  static const String keySyncLastStatus = 'sync_last_status';
  static const String keyVideoSkipRecords = 'video_skip_records';
  static const String keyPlayerAlwaysShowClock = 'player_always_show_clock';
  static const int maxVideoSkipRecords = 500;
  final SharedPreferences _prefs;
  final ValueNotifier<int> watchHistoryRevision = ValueNotifier<int>(0);
  final Map<String, ({int intro, int outro, int updated})>
      _privateVideoSkipRecords =
      <String, ({int intro, int outro, int updated})>{};
  Timer? _autoSyncTimer;
  bool _syncInFlight = false;
  int _lastHistoryAutoPushMs = 0;
  static final Expando<QuarkAccountProvider> _quarkProviders = Expando();
  QuarkAccountProvider get quarkAccounts => _quarkProviders[_prefs] ??=
      QuarkAccountProvider(
        readCredential: () => getNetdiskCred('quark'),
        writeCredential: (value) async { await _prefs.setString(keyQuarkCookie, value); },
      );
  Future<void> _subscriptionQueue = Future<void>.value();
  StorageService(this._prefs);
  Future<T> _editSubscriptions<T>(Future<T> Function() edit) {
    final next = _subscriptionQueue.then((_) => edit());
    _subscriptionQueue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
  static Future<StorageService> init() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService(prefs);
  }
  String get configOrigin => _prefs.getString(keyOrigin) ?? '';
  String get rawConfig => _prefs.getString(keyRawConfig) ?? '';
  String get selectedSiteKey => _prefs.getString(keySelectedSite) ?? '';
  String get activeDepotName => _prefs.getString(keyActiveDepotName) ?? '';
  bool get episodesDescending => _prefs.getBool(keyEpisodesDescending) ?? false;
  double get playSpeed =>
      (_prefs.getDouble(keyPlaySpeed) ?? 1.0).clamp(0.5, 2.0);
  bool get autoNext => _prefs.getBool(keyAutoNext) ?? true;
  int get skipIntroSec => (_prefs.getInt(keySkipIntroSec) ?? 0).clamp(0, 600);
  int get skipOutroSec => (_prefs.getInt(keySkipOutroSec) ?? 0).clamp(0, 600);
  bool get playerAlwaysShowClock =>
      _prefs.getBool(keyPlayerAlwaysShowClock) ?? false;
  String get repeatMode => _prefs.getString(keyRepeatMode) ?? 'off';
  String get wallpaperPreset =>
      _prefs.getString(keyWallpaperPreset) ?? 'obsidian';
  String get customWallpaperUrl =>
      _prefs.getString(keyCustomWallpaperUrl) ?? '';
  bool get ambientGlowEnabled => _prefs.getBool(keyAmbientGlow) ?? true;
  String get glassBlurLevel =>
      _prefs.getString(keyGlassBlurLevel) ?? 'standard';
  double get glassBlurStrength {
    final saved = _prefs.getDouble(keyGlassBlurStrength);
    if (saved != null) return saved.clamp(0.0, 1.0);
    return switch (glassBlurLevel) {
      'solid' => 0.0,
      'light' => 0.35,
      'deep' => 1.0,
      _ => 0.68,
    };
  }
  String get gridDensity => _prefs.getString(keyGridDensity) ?? 'standard';
  bool get showHeroBanner => _prefs.getBool(keyShowHeroBanner) ?? true;
  bool get showContinueWatching =>
      _prefs.getBool(keyShowContinueWatching) ?? true;
  String get cardSubtitleMode =>
      _prefs.getString(keyCardSubtitleMode) ?? 'remarks';
  String get preferredQuality =>
      _prefs.getString(keyPreferredQuality) ?? '4k_netdisk';
  String get defaultAspectMode =>
      _prefs.getString(keyDefaultAspectMode) ?? 'contain';
  String get playerKernel =>
      _prefs.getString(keyPlayerKernel) ?? 'exo';
  String get quarkCookie => _prefs.getString(keyQuarkCookie) ?? '';
  String get ucCookie => _prefs.getString(keyUcCookie) ?? '';
  String get baiduCookie => _prefs.getString(keyBaiduCookie) ?? '';
  String get aliToken => _prefs.getString(keyAliToken) ?? '';
  List<String> get driveOrder {
    const defaults = ['quark', 'uc', 'baidu', 'ali'];
    final raw = _prefs.getStringList(keyDriveOrder);
    if (raw == null || raw.isEmpty) return defaults;
    final out = <String>[
      for (final d in raw)
        if (defaults.contains(d)) d,
    ];
    for (final d in defaults) {
      if (!out.contains(d)) out.add(d);
    }
    return out;
  }
  List<CmsDepot> getSavedDepots() {
    final raw = _prefs.getString(keyDepots) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => CmsDepot.fromJson(Map<String, dynamic>.from(m)))
          .where((d) => d.url.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
  static final RegExp _hashedPinPattern =
      RegExp(r'^sha256:(\d+):([0-9a-f]{64})$');
  static String _hashPin(String pin) =>
      sha256.convert(utf8.encode('mm_pin_v1:$pin')).toString();

  String get privacyPassword => _prefs.getString(keyPrivacyPassword) ?? '';
  bool get hasPrivacyPassword => privacyPassword.trim().isNotEmpty;
  int get privacyPasswordLength {
    final saved = privacyPassword.trim();
    final match = _hashedPinPattern.firstMatch(saved);
    if (match != null) {
      return (int.tryParse(match.group(1)!) ?? 4).clamp(4, 8);
    }
    return saved.length.clamp(4, 8);
  }
  bool get hasPrivacyConfigured =>
      hasPrivacyPassword ||
      getSubscriptions().any((s) => s.isEffectivelyPrivate);
  bool verifyPrivacyPassword(String input) {
    final trimmed = input.trim();
    final saved = privacyPassword.trim();
    if (saved.isEmpty || trimmed.isEmpty) return false;
    final match = _hashedPinPattern.firstMatch(saved);
    if (match != null) {
      final expectedLen = int.tryParse(match.group(1)!) ?? 0;
      return trimmed.length == expectedLen &&
          _hashPin(trimmed) == match.group(2);
    }
    return trimmed == saved;
  }
  Future<void> setPrivacyPassword(String password) async {
    final trimmed = password.trim();
    if (trimmed.isEmpty) {
      await _prefs.setString(keyPrivacyPassword, '');
      return;
    }
    await _prefs.setString(
      keyPrivacyPassword,
      'sha256:${trimmed.length}:${_hashPin(trimmed)}',
    );
  }

  List<SubscriptionEntry> getSubscriptions() {
    final raw = _prefs.getString(keySubscriptions) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => SubscriptionEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((s) => s.id.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  List<String> getSubscriptionGroups({bool includePrivate = false}) {
    final groups = <String>['默认分组'];
    for (final s in getSubscriptions()) {
      if (!includePrivate && s.isEffectivelyPrivate) continue;
      final g = s.group.trim();
      if (g.isNotEmpty && !groups.contains(g)) {
        groups.add(g);
      }
    }
    return groups;
  }

  Future<void> saveSubscriptions(List<SubscriptionEntry> subs) async {
    try {
      final saved = await _prefs.setString(
        keySubscriptions,
        jsonEncode(subs.map((s) => s.toJson()).toList()),
      );
      if (!saved) throw StateError('订阅变更未能保存，请重试');
    } catch (_) {
      // The plugin updates its cache before the platform write completes.
      // Re-read disk so a failed write does not look like a successful deletion.
      await _prefs.reload();
      rethrow;
    }
  }

  Future<CmsConfig?> upsertSubscriptions(
    List<SubscriptionEntry> incoming, {
    List<CmsDepot>? depots,
    String? activeDepotName,
  }) => _editSubscriptions(() => _upsertSubscriptions(incoming,
      depots: depots, activeDepotName: activeDepotName));

  Future<CmsConfig?> _upsertSubscriptions(
    List<SubscriptionEntry> incoming, {
    List<CmsDepot>? depots,
    String? activeDepotName,
  }) async {
    if (incoming.isEmpty) return loadSavedConfig();
    final current = getSubscriptions().toList();
    // Migrate legacy single config into subscriptions list if not yet present
    if (!_prefs.containsKey(keySubscriptions) && rawConfig.trim().isNotEmpty) {
      try {
        final legacyParsed = CmsParser.parseConfig(
          rawConfig,
          origin: configOrigin,
        );
        final fmt = CmsParser.detectSubscriptionFormat(
          rawConfig,
          origin: configOrigin,
        );
        current.add(
          SubscriptionEntry(
            id: 'legacy_primary',
            name: this.activeDepotName.isNotEmpty
                ? this.activeDepotName
                : (configOrigin.isNotEmpty
                    ? (Uri.tryParse(configOrigin)?.host ?? '默认仓库')
                    : '默认配置'),
            url: configOrigin,
            group: '默认分组',
            format: legacyParsed.depots.isNotEmpty ? '多仓' : fmt,
            isPrivate: false,
            enabled: true,
            rawContent: rawConfig,
            siteCount: legacyParsed.supportedSites.length,
            liveCount: legacyParsed.lives.length,
            updatedAt: DateTime.now().millisecondsSinceEpoch - 1000,
          ),
        );
      } catch (_) {}
    }
    _ownLegacyDepots(current);
    for (var index = 0; index < incoming.length; index++) {
      final original = incoming[index];
      final entry = index == 0 ? original.copyWith(
        depots: depots ?? original.depots,
        activeDepotName: activeDepotName ?? original.activeDepotName,
      ) : original;
      final existingIdx = current.indexWhere(
        (s) =>
            s.id == entry.id ||
            (s.group == entry.group && s.isEffectivelyPrivate == entry.isEffectivelyPrivate &&
              (entry.warehouseUrl.isNotEmpty ? s.warehouseUrl == entry.warehouseUrl :
                (s.warehouseUrl.isEmpty && entry.url.isNotEmpty && s.url == entry.url))),
      );
      if (existingIdx >= 0) {
        current[existingIdx] = entry.copyWith(id: current[existingIdx].id);
      } else {
        current.add(entry);
      }
    }
    await saveSubscriptions(current);

    final nowSync = DateTime.now().millisecondsSinceEpoch;
    final tombs = _readSyncTombstones();
    var tombsChanged = false;
    for (final s in incoming) {
      if (!s.isEffectivelyPrivate && s.rawContent.isNotEmpty) {
        final pubRaw = _publicRawConfig(s.rawContent, s.url);
        if (pubRaw.isNotEmpty) {
          final syncKey = canonicalSubscriptionSyncKey(
            s.url,
            pubRaw,
            warehouseUrl: s.warehouseUrl,
          );
          if (tombs.remove('sub:$syncKey') != null) {
            tombsChanged = true;
          }
        }
      }
    }
    if (tombsChanged) {
      await _writeSyncTombstones(tombs);
    }
    if (webdavSyncSubs && incoming.any((s) => !s.isEffectivelyPrivate)) {
      scheduleAutoWebdavSync(immediate: true, nowMs: nowSync);
    }

    final primary = incoming.first;
    if (primary.rawContent.isNotEmpty && !primary.isEffectivelyPrivate) {
      await _prefs.setString(keyRawConfig, primary.rawContent);
      await _prefs.setString(keyOrigin, primary.url);
    }
    // Directories now belong to registry entries, including private subscriptions.
    await _prefs.setString(keyDepots, '[]');
    if (!primary.isEffectivelyPrivate) {
      await _prefs.setString(keyActiveDepotName, activeDepotName ?? primary.activeDepotName);
    }
    final merged = loadSavedConfig();
    if (merged != null &&
        merged.publicSupportedSites.isNotEmpty &&
        !merged.supportedSites.any((s) => s.key == selectedSiteKey)) {
      final preferredDefault = merged.publicSupportedSites.firstWhere(
        (s) => !CspBridge.isBannerNoticeSite(s),
        orElse: () => merged.publicSupportedSites.first,
      );
      await _prefs.setString(
        keySelectedSite,
        preferredDefault.key,
      );
    }
    return merged;
  }

  Future<CmsConfig?> removeSubscription(String id) =>
      _editSubscriptions(() => _removeSubscription(id));

  Future<CmsConfig?> _removeSubscription(String id) async {
    final current = getSubscriptions();
    final removed = current.where((s) => s.id == id).toList();
    if (removed.isEmpty) return loadSavedConfig();
    final next = current.where((s) {
      if (s.id == id) return false;
      // Older first-time pasted imports created these two IDs from the same
      // payload. Remove that known accidental twin, not independent subscriptions.
      if (removed.isNotEmpty &&
          ((id == 'legacy_primary' && s.id == 'sub_primary') ||
           (id == 'sub_primary' && s.id == 'legacy_primary'))) {
        final old = removed.first;
        if (s.url.isEmpty && old.url.isEmpty && s.rawContent == old.rawContent &&
            s.group == old.group && s.isEffectivelyPrivate == old.isEffectivelyPrivate) {
          return false;
        }
      }
      return true;
    }).toList();
    // Move old global warehouse directories to their surviving owner before
    // clearing the compatibility mirror. Never transfer a removed owner's dirs.
    _ownLegacyDepots(next);
    // The persisted registry, including [], is authoritative before legacy cleanup.
    await saveSubscriptions(next);
    final nowSync = DateTime.now().millisecondsSinceEpoch;
    final tombs = _readSyncTombstones();
    var hadPublicRemoval = false;
    for (final old in removed) {
      if (!old.isEffectivelyPrivate) {
        final pubRaw = _publicRawConfig(old.rawContent, old.url);
        final syncKey = canonicalSubscriptionSyncKey(
          old.url,
          pubRaw.isNotEmpty ? pubRaw : old.rawContent,
          warehouseUrl: old.warehouseUrl,
        );
        tombs['sub:$syncKey'] = nowSync;
        hadPublicRemoval = true;
      }
    }
    if (hadPublicRemoval) {
      await _writeSyncTombstones(tombs);
      if (webdavSyncSubs) {
        scheduleAutoWebdavSync(immediate: true, nowMs: nowSync);
      }
    }
    final public = next.where((s) => !s.isEffectivelyPrivate).toList();
    await _prefs.setString(keyRawConfig, public.isEmpty ? '' : public.first.rawContent);
    await _prefs.setString(keyOrigin, public.isEmpty ? '' : public.first.url);
    await _prefs.setString(keyDepots, '[]');
    await _prefs.setString(keyActiveDepotName, public.isEmpty ? '' : public.first.activeDepotName);
    final config = loadSavedConfig();
    final sites = config?.publicSupportedSites ?? const <CmsSite>[];
    if (!sites.any((s) => s.key == selectedSiteKey)) {
      await _prefs.setString(keySelectedSite, sites.isEmpty ? '' : sites.first.key);
    }
    if (!sites.any((s) => s.key == (_prefs.getString(keyPreferredSite) ?? ''))) {
      await _prefs.remove(keyPreferredSite);
    }
    return config;
  }

  void _ownLegacyDepots(List<SubscriptionEntry> subscriptions) {
    final legacyOwner = subscriptions.indexWhere((s) => !s.isEffectivelyPrivate &&
        s.url == configOrigin && (s.format == '多仓' || s.id == 'legacy_primary'));
    if (legacyOwner >= 0) {
      final owner = subscriptions[legacyOwner];
      final dirs = <String, CmsDepot>{
        for (final d in [...getSavedDepots(), ...owner.depots]) d.url: d,
      };
      subscriptions[legacyOwner] = owner.copyWith(depots: dirs.values.toList(),
        activeDepotName: owner.activeDepotName.isNotEmpty ? owner.activeDepotName : activeDepotName);
    }
  }

  Future<CmsConfig?> toggleSubscriptionPrivacy(
    String id,
    bool isPrivate,
  ) => _editSubscriptions(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = getSubscriptions();
    final next = <SubscriptionEntry>[];
    final tombs = _readSyncTombstones();
    var tombsChanged = false;
    var shouldSchedule = false;
    for (final s in current) {
      if (s.id == id) {
        final wasPrivate = s.isEffectivelyPrivate;
        final updated = s.copyWith(isPrivate: isPrivate, updatedAt: now);
        final nowPrivate = updated.isEffectivelyPrivate;
        if (wasPrivate != nowPrivate && s.rawContent.isNotEmpty) {
          final pubRaw = _publicRawConfig(s.rawContent, s.url);
          final syncKey = canonicalSubscriptionSyncKey(
            s.url,
            pubRaw.isNotEmpty ? pubRaw : s.rawContent,
            warehouseUrl: s.warehouseUrl,
          );
          if (nowPrivate) {
            tombs['sub:$syncKey'] = now;
          } else {
            tombs.remove('sub:$syncKey');
          }
          tombsChanged = true;
          shouldSchedule = true;
        }
        next.add(updated);
      } else {
        next.add(s);
      }
    }
    await saveSubscriptions(next);
    if (tombsChanged) {
      await _writeSyncTombstones(tombs);
    }
    if (shouldSchedule && webdavSyncSubs) {
      scheduleAutoWebdavSync(immediate: true, nowMs: now);
    }
    return loadSavedConfig();
  });

  Future<CmsConfig?> toggleSubscriptionEnabled(String id, bool enabled) => _editSubscriptions(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var touchedPublic = false;
    final next = [
      for (final s in getSubscriptions())
        if (s.id == id)
          (() {
            if (!s.isEffectivelyPrivate) touchedPublic = true;
            return s.copyWith(enabled: enabled, updatedAt: now);
          })()
        else
          s,
    ];
    await saveSubscriptions(next);
    if (touchedPublic && webdavSyncSubs) {
      scheduleAutoWebdavSync(immediate: true, nowMs: now);
    }
    return loadSavedConfig();
  });

  Future<CmsConfig?> updateSubscriptionGroup(String id, String group) => _editSubscriptions(() async {
    final cleanGroup = group.trim().isEmpty ? '默认分组' : group.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    final tombs = _readSyncTombstones();
    var tombsChanged = false;
    var shouldSchedule = false;
    final next = <SubscriptionEntry>[];
    for (final s in getSubscriptions()) {
      if (s.id == id) {
        final wasPrivate = s.isEffectivelyPrivate;
        final updated = s.copyWith(group: cleanGroup, updatedAt: now);
        final nowPrivate = updated.isEffectivelyPrivate;
        if (wasPrivate != nowPrivate && s.rawContent.isNotEmpty) {
          final pubRaw = _publicRawConfig(s.rawContent, s.url);
          final syncKey = canonicalSubscriptionSyncKey(
            s.url,
            pubRaw.isNotEmpty ? pubRaw : s.rawContent,
            warehouseUrl: s.warehouseUrl,
          );
          if (nowPrivate) {
            tombs['sub:$syncKey'] = now;
            tombsChanged = true;
          } else {
            if (tombs.remove('sub:$syncKey') != null) tombsChanged = true;
          }
        }
        if (!wasPrivate || !nowPrivate) shouldSchedule = true;
        next.add(updated);
      } else {
        next.add(s);
      }
    }
    await saveSubscriptions(next);
    if (tombsChanged) {
      await _writeSyncTombstones(tombs);
    }
    if (shouldSchedule && webdavSyncSubs) {
      scheduleAutoWebdavSync(immediate: true, nowMs: now);
    }
    return loadSavedConfig();
  });

  String _siteIdentity(CmsSite s) => jsonEncode([s.subscriptionId, s.sourceKey, s.api]);
  Map<String, String> _pickerIdentities(Iterable<CmsSite> sites) {
    final identities = <String, String>{};
    for (final site in sites) {
      final canonical = _siteIdentity(site);
      identities[canonical] = canonical;
      identities[jsonEncode([site.subscriptionId, site.key, site.api])] = canonical;
      identities[jsonEncode([site.subscriptionId, '${site.sourceKey}_${site.subscriptionId}', site.api])] = canonical;
    }
    return identities;
  }
  static const _siteOrder = 'picker_site_order';
  static const _removedSites = 'picker_removed_sites';
  static const _siteAliases = 'site_key_aliases';
  Map<String, String> _savedAliases() {
    try { return Map<String, String>.from(jsonDecode(_prefs.getString(_siteAliases) ?? '{}')); } catch (_) { return {}; }
  }

  Future<void> savePickerEdits(List<CmsSite> ordered, List<CmsSite> removed) => _editSubscriptions(() async {
    final oldOrder = _prefs.getStringList(_siteOrder) ?? [];
    final ids = ordered.map(_siteIdentity).toList();
    final hidden = {...?_prefs.getStringList(_removedSites), ...removed.map(_siteIdentity)};
    try {
      final orderSaved = await _prefs.setStringList(_siteOrder, [...ids, ...oldOrder.where((id) => !ids.contains(id))]);
      if (!orderSaved) throw StateError('线路顺序未能保存，请重试');
      final removalSaved = await _prefs.setStringList(_removedSites, hidden.toList());
      if (!removalSaved) throw StateError('线路删除未能保存，请重试');
    } catch (_) {
      await _prefs.reload();
      rethrow;
    }
  });

  CmsConfig? loadSavedConfig() {
    final config = _loadImportedConfig();
    if (config == null) return null;
    final identities = _pickerIdentities(config.sites);
    final hidden = (_prefs.getStringList(_removedSites) ?? []).map((id) => identities[id] ?? id).toSet();
    final byId = {for (final s in config.sites) if (!hidden.contains(_siteIdentity(s))) _siteIdentity(s): s};
    final sites = <CmsSite>[];
    for (final id in _prefs.getStringList(_siteOrder) ?? const <String>[]) {
      final site = byId.remove(identities[id] ?? id);
      if (site != null) sites.add(site);
    }
    return CmsConfig(sites: [...sites, ...byId.values], lives: config.lives,
        depots: config.depots, parses: config.parses, spider: config.spider);
  }

  CmsConfig? _loadImportedConfig() {
    final subs = getSubscriptions().where((s) => s.enabled).toList();
    final savedDepots = getSavedDepots();
    final aliases = _savedAliases();
    if (_prefs.containsKey(keySubscriptions)) {
      if (getSubscriptions().isEmpty) return null;
      final mergedSites = <CmsSite>[];
      final mergedLives = <LiveSource>[];
      final mergedDepots = <CmsDepot>[];
      final mergedParses = <CmsParse>[];
      final seenDepotUrls = <String>{};
      final seenParseUrls = <String>{};
      final legacyOwners = subs.where((s) => !s.isEffectivelyPrivate &&
          s.url == configOrigin && (s.format == '多仓' || s.id == 'legacy_primary'));
      if (legacyOwners.isNotEmpty) {
        final owner = legacyOwners.first;
        for (final d in savedDepots) {
          if (seenDepotUrls.add('${owner.id}|${d.url}')) {
            mergedDepots.add(CmsDepot(name: d.name, url: d.url, subscriptionId: owner.id));
          }
        }
      }
      final seenSiteKeys = <String>{};
      String spider = '';

      for (final sub in subs) {
        if (sub.rawContent.trim().isEmpty) continue;
        try {
          final parsed = CmsParser.parseConfig(
            sub.rawContent,
            origin: sub.url,
            defaultGroup: sub.group,
            isPrivate: sub.isEffectivelyPrivate,
            subscriptionId: sub.id,
            defaultName: sub.name,
          );
          if (spider.isEmpty && parsed.spider.isNotEmpty) {
            spider = parsed.spider;
          }
          for (final p in parsed.parses) {
            if (seenParseUrls.add(p.url) && mergedParses.length < 100) {
              mergedParses.add(p);
            }
          }
          for (final d in [...sub.depots, ...parsed.depots]) {
            if (!sub.isEffectivelyPrivate && seenDepotUrls.add('${sub.id}|${d.url}')) {
              mergedDepots.add(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id));
            }
          }
          for (final site in parsed.sites) {
            var uniqueKey = aliases[jsonEncode([sub.id, site.key, site.api])] ?? site.key;
            if (!seenSiteKeys.add(uniqueKey)) {
              uniqueKey = '${site.key}_${sub.id}';
              seenSiteKeys.add(uniqueKey);
            }
            mergedSites.add(
              site.copyWith(
                key: uniqueKey,
                group: site.group.isEmpty ? sub.group : site.group,
                isPrivate: site.isEffectivelyPrivate || sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
              ),
            );
          }
          for (final live in parsed.lives) {
            mergedLives.add(
              live.copyWith(
                group: live.group.isEmpty ? sub.group : live.group,
                isPrivate: live.isEffectivelyPrivate || sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
              ),
            );
          }
        } catch (_) {}
      }
      {
        return CmsConfig(
          sites: mergedSites,
          lives: mergedLives,
          depots: mergedDepots,
          parses: mergedParses,
          spider: spider,
        );
      }
    }

    final raw = rawConfig;
    if (raw.trim().isEmpty) return null;
    try {
      final parsed = CmsParser.parseConfig(raw, origin: configOrigin);
      if (parsed.depots.isEmpty && savedDepots.isNotEmpty) {
        return CmsConfig(
          sites: parsed.sites,
          lives: parsed.lives,
          depots: savedDepots,
          parses: parsed.parses,
          spider: parsed.spider,
        );
      }
      return parsed;
    } catch (_) {
      return null;
    }
  }
  Future<CmsConfig> saveConfig(
    String rawJson, {
    String origin = '',
    List<CmsDepot>? depots,
    String? activeDepotName,
    String group = '默认分组',
    bool isPrivate = false,
    String customName = '',
  }) async {
    final parsed = CmsParser.parseConfig(
      rawJson,
      origin: origin,
      defaultGroup: group,
      isPrivate: isPrivate,
      defaultName: customName,
    );
    // upsert migrates only pre-existing legacy data, before storing this import.
    final effectiveDepots = depots ?? parsed.depots;
    final fmt = CmsParser.detectSubscriptionFormat(rawJson, origin: origin);
    final entryName = customName.trim().isNotEmpty
        ? customName.trim()
        : ((activeDepotName != null && activeDepotName.trim().isNotEmpty)
            ? activeDepotName.trim()
            : (parsed.sites.length == 1
                ? parsed.sites.first.name
                : (origin.trim().isNotEmpty
                    ? (Uri.tryParse(origin.trim())?.host ?? '订阅资源')
                    : '$fmt 订阅')));
    await upsertSubscriptions([
      SubscriptionEntry(
        id: origin.trim().isNotEmpty
            ? 'sub_${origin.trim().hashCode.abs()}'
            : 'sub_primary',
        name: entryName,
        url: origin.trim(),
        group: group.trim().isEmpty ? '默认分组' : group.trim(),
        format: effectiveDepots.isNotEmpty ? '多仓' : fmt,
        isPrivate: isPrivate,
        enabled: true,
        rawContent: rawJson,
        depots: effectiveDepots,
        activeDepotName: activeDepotName ?? '',
        siteCount: parsed.supportedSites.length,
        liveCount: parsed.lives.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    final merged = loadSavedConfig() ??
        CmsConfig(
          sites: parsed.sites,
          lives: parsed.lives,
          depots: effectiveDepots,
          parses: parsed.parses,
          spider: parsed.spider,
        );
    final visibleSites =
        isPrivate ? merged.supportedSites : merged.publicSupportedSites;
    if (visibleSites.isNotEmpty &&
        !visibleSites.any((s) => s.key == selectedSiteKey)) {
      await _prefs.setString(keySelectedSite, visibleSites.first.key);
    } else if (merged.supportedSites.isEmpty && merged.sites.isNotEmpty) {
      await _prefs.setString(keySelectedSite, merged.sites.first.key);
    }
    return merged;
  }
  String get preferredSiteKey {
    final key = _prefs.getString(keyPreferredSite) ?? '';
    return (loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[])
        .any((s) => s.key == key) ? key : '';
  }
  String get preferredLineName => _prefs.getString(keyPreferredLine) ?? '';
  Future<void> setPreferredSiteKey(String key) async {
    if (key.isNotEmpty && !(loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[])
        .any((s) => s.key == key)) throw const FormatException('请选择已启用的公开片源');
    await _prefs.setString(keyPreferredSite, key);
  }
  Future<void> setPreferredLineName(String name) => _prefs.setString(keyPreferredLine, name);
  List<CmsSite> prioritizeSites(Iterable<CmsSite> sites) {
    final all = sites.toList();
    final key = preferredSiteKey;
    return [...all.where((s) => s.key == key), ...all.where((s) => s.key != key)];
  }

  Future<void> setSelectedSiteKey(String key) async {
    await _prefs.setString(keySelectedSite, key);
  }
  Future<void> setEpisodesDescending(bool value) async {
    await _prefs.setBool(keyEpisodesDescending, value);
  }
  Future<void> setPlaySpeed(double speed) async {
    await _prefs.setDouble(keyPlaySpeed, speed.clamp(0.5, 2.0));
  }
  Future<void> setAutoNext(bool value) async {
    await _prefs.setBool(keyAutoNext, value);
  }
  Future<void> setSkipIntroSec(int seconds) async {
    await _prefs.setInt(keySkipIntroSec, seconds.clamp(0, 600));
  }
  Future<void> setSkipOutroSec(int seconds) async {
    await _prefs.setInt(keySkipOutroSec, seconds.clamp(0, 600));
  }
  Future<void> setPlayerAlwaysShowClock(bool value) async {
    await _prefs.setBool(keyPlayerAlwaysShowClock, value);
  }
  static String _videoSkipKey(String siteKey, String videoId) {
    final s = siteKey.trim();
    final v = videoId.trim();
    if (s.isEmpty || v.isEmpty) return '';
    return '$s\n$v';
  }
  bool _isPrivateVideoSkip(String siteKey, bool isPrivate) =>
      isPrivate || _privateSiteKeySet().contains(siteKey.trim());
  Map<String, ({int intro, int outro, int updated})>
      _readPublicVideoSkipRecords() {
    final raw = _prefs.getString(keyVideoSkipRecords) ?? '{}';
    final out = <String, ({int intro, int outro, int updated})>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final k = entry.key.toString();
          final v = entry.value;
          if (k.isEmpty || v is! Map) continue;
          final intro = ((v['intro'] as num?)?.toInt() ?? 0).clamp(0, 600);
          final outro = ((v['outro'] as num?)?.toInt() ?? 0).clamp(0, 600);
          final updated = (v['updated'] as num?)?.toInt() ?? 0;
          if (intro > 0 || outro > 0) {
            out[k] = (intro: intro, outro: outro, updated: updated);
          }
        }
      }
    } catch (_) {}
    return out;
  }
  Future<void> _writePublicVideoSkipRecords(
    Map<String, ({int intro, int outro, int updated})> records,
  ) async {
    final entries = records.entries
        .where((e) => e.value.intro > 0 || e.value.outro > 0)
        .toList()
      ..sort((a, b) => b.value.updated.compareTo(a.value.updated));
    final bounded = entries.take(maxVideoSkipRecords);
    final payload = <String, Map<String, int>>{
      for (final e in bounded)
        e.key: {
          'intro': e.value.intro,
          'outro': e.value.outro,
          'updated': e.value.updated,
        },
    };
    await _prefs.setString(keyVideoSkipRecords, jsonEncode(payload));
  }
  int getVideoSkipIntroSec(
    String siteKey,
    String videoId, {
    bool isPrivate = false,
  }) {
    final key = _videoSkipKey(siteKey, videoId);
    if (key.isEmpty) return 0;
    if (_isPrivateVideoSkip(siteKey, isPrivate)) {
      return _privateVideoSkipRecords[key]?.intro ?? 0;
    }
    return _readPublicVideoSkipRecords()[key]?.intro ?? 0;
  }
  int getVideoSkipOutroSec(
    String siteKey,
    String videoId, {
    bool isPrivate = false,
  }) {
    final key = _videoSkipKey(siteKey, videoId);
    if (key.isEmpty) return 0;
    if (_isPrivateVideoSkip(siteKey, isPrivate)) {
      return _privateVideoSkipRecords[key]?.outro ?? 0;
    }
    return _readPublicVideoSkipRecords()[key]?.outro ?? 0;
  }
  Future<void> setVideoSkipIntroSec(
    String siteKey,
    String videoId,
    int seconds, {
    bool isPrivate = false,
  }) async {
    final key = _videoSkipKey(siteKey, videoId);
    if (key.isEmpty) return;
    final clamped = seconds.clamp(0, 600);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isPrivateVideoSkip(siteKey, isPrivate)) {
      final prev = _privateVideoSkipRecords[key];
      final outro = prev?.outro ?? 0;
      if (clamped <= 0 && outro <= 0) {
        _privateVideoSkipRecords.remove(key);
      } else {
        _privateVideoSkipRecords[key] =
            (intro: clamped, outro: outro, updated: now);
      }
      return;
    }
    final records = _readPublicVideoSkipRecords();
    final prev = records[key];
    final outro = prev?.outro ?? 0;
    if (clamped <= 0 && outro <= 0) {
      records.remove(key);
    } else {
      records[key] = (intro: clamped, outro: outro, updated: now);
    }
    await _writePublicVideoSkipRecords(records);
  }
  Future<void> setVideoSkipOutroSec(
    String siteKey,
    String videoId,
    int seconds, {
    bool isPrivate = false,
  }) async {
    final key = _videoSkipKey(siteKey, videoId);
    if (key.isEmpty) return;
    final clamped = seconds.clamp(0, 600);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isPrivateVideoSkip(siteKey, isPrivate)) {
      final prev = _privateVideoSkipRecords[key];
      final intro = prev?.intro ?? 0;
      if (intro <= 0 && clamped <= 0) {
        _privateVideoSkipRecords.remove(key);
      } else {
        _privateVideoSkipRecords[key] =
            (intro: intro, outro: clamped, updated: now);
      }
      return;
    }
    final records = _readPublicVideoSkipRecords();
    final prev = records[key];
    final intro = prev?.intro ?? 0;
    if (intro <= 0 && clamped <= 0) {
      records.remove(key);
    } else {
      records[key] = (intro: intro, outro: clamped, updated: now);
    }
    await _writePublicVideoSkipRecords(records);
  }
  int countVideoSkipRecords({bool forPrivate = false}) {
    if (forPrivate) {
      return _privateVideoSkipRecords.values
          .where((e) => e.intro > 0 || e.outro > 0)
          .length;
    }
    final privKeys = _privateSiteKeySet();
    return _readPublicVideoSkipRecords().entries.where((e) {
      final site = e.key.split('\n').first;
      return !privKeys.contains(site) &&
          (e.value.intro > 0 || e.value.outro > 0);
    }).length;
  }
  Future<void> clearVideoSkipRecords({bool forPrivate = false}) async {
    if (forPrivate) {
      _privateVideoSkipRecords.clear();
      return;
    }
    await _prefs.remove(keyVideoSkipRecords);
  }
  void clearPrivateVideoSkipRecords() {
    _privateVideoSkipRecords.clear();
  }
  static int defaultSkipSecondsFromPlayback({
    required bool isIntro,
    required int savedSec,
    required Duration position,
    required Duration duration,
  }) {
    final posSec = position.inSeconds;
    final durSec = duration.inSeconds;
    if (isIntro) {
      if (posSec >= 1 && posSec <= 600) {
        return posSec;
      }
      return savedSec.clamp(0, 600);
    }
    if (durSec > 0 && posSec > 0 && durSec > posSec) {
      final remainSec = durSec - posSec;
      if (remainSec >= 1 && remainSec <= 600) {
        return remainSec;
      }
    }
    return savedSec.clamp(0, 600);
  }
  Future<void> setRepeatMode(String mode) async {
    await _prefs.setString(keyRepeatMode, mode);
  }
  Future<void> setWallpaperPreset(String preset) async {
    await _prefs.setString(keyWallpaperPreset, preset.trim());
  }
  Future<void> setCustomWallpaperUrl(String url) async {
    await _prefs.setString(keyCustomWallpaperUrl, url.trim());
  }
  Future<void> setAmbientGlowEnabled(bool enabled) async {
    await _prefs.setBool(keyAmbientGlow, enabled);
  }
  Future<void> setGlassBlurLevel(String level) async {
    final trimmed = level.trim();
    await _prefs.setString(keyGlassBlurLevel, trimmed);
    final mapped = switch (trimmed) {
      'solid' => 0.0,
      'light' => 0.35,
      'deep' => 1.0,
      _ => 0.68,
    };
    await _prefs.setDouble(keyGlassBlurStrength, mapped);
  }
  Future<void> setGlassBlurStrength(double strength) async {
    final clamped = strength.clamp(0.0, 1.0);
    await _prefs.setDouble(keyGlassBlurStrength, clamped);
    final level = clamped <= 0.05
        ? 'solid'
        : clamped < 0.50
            ? 'light'
            : clamped < 0.85
                ? 'standard'
                : 'deep';
    await _prefs.setString(keyGlassBlurLevel, level);
  }
  Future<void> setGridDensity(String density) async {
    await _prefs.setString(keyGridDensity, density.trim());
  }
  Future<void> setShowHeroBanner(bool show) async {
    await _prefs.setBool(keyShowHeroBanner, show);
  }
  Future<void> setShowContinueWatching(bool show) async {
    await _prefs.setBool(keyShowContinueWatching, show);
  }
  Future<void> setCardSubtitleMode(String mode) async {
    await _prefs.setString(keyCardSubtitleMode, mode.trim());
  }
  Future<void> setPreferredQuality(String quality) async {
    await _prefs.setString(keyPreferredQuality, quality.trim());
  }
  Future<void> setDefaultAspectMode(String mode) async {
    await _prefs.setString(keyDefaultAspectMode, mode.trim());
  }
  Future<void> setPlayerKernel(String kernel) async {
    await _prefs.setString(keyPlayerKernel, kernel.trim());
  }
  /// Selects the recommended line index from [lines] based on [preferredQuality]
  /// and the user's configured Netdisk drive order.
  int pickRecommendedLineIndex(List<CmsLine> lines) {
    final preferred = lines.indexWhere((line) => line.name == preferredLineName && line.episodes.isNotEmpty);
    if (preferred >= 0) return preferred;
    if (lines.isEmpty) return 0;
    final pref = preferredQuality;
    if (pref == 'auto') return 0;
    bool isNetdiskLine(String name) {
      final n = name.toLowerCase();
      return n.contains('4k') ||
          n.contains('原画') ||
          n.contains('夸父') ||
          n.contains('夸克') ||
          n.contains('优汐') ||
          n.contains('uc') ||
          n.contains('嘟嘟') ||
          n.contains('百度') ||
          n.contains('阿狸') ||
          n.contains('阿里');
    }
    if (pref == '4k_netdisk') {
      // First check according to driveOrder
      for (final drive in driveOrder) {
        final alias = switch (drive) {
          'quark' => '夸',
          'uc' => '优',
          'baidu' => '嘟',
          'ali' => '阿',
          _ => '',
        };
        if (alias.isNotEmpty) {
          final idx = lines.indexWhere((l) => l.name.contains(alias));
          if (idx >= 0) return idx;
        }
      }
      final idx = lines.indexWhere((l) => isNetdiskLine(l.name));
      if (idx >= 0) return idx;
    } else if (pref == '1080p_direct') {
      final idx = lines.indexWhere(
        (l) =>
            !isNetdiskLine(l.name) &&
            (l.name.contains('蓝光') ||
                l.name.contains('超清') ||
                l.name.contains('1080') ||
                l.name.contains('暴风') ||
                l.name.contains('天堂') ||
                l.name.contains('非凡') ||
                l.name.contains('量子')),
      );
      if (idx >= 0) return idx;
      final nonNetdisk = lines.indexWhere((l) => !isNetdiskLine(l.name));
      if (nonNetdisk >= 0) return nonNetdisk;
    } else if (pref == 'fast_hls') {
      final idx = lines.indexWhere((l) => !isNetdiskLine(l.name));
      if (idx >= 0) return idx;
    }
    return 0;
  }
  String getNetdiskCred(String driveKey) {
    switch (driveKey) {
      case 'quark':
        return quarkCookie;
      case 'uc':
        return ucCookie;
      case 'baidu':
        return baiduCookie;
      case 'ali':
        return aliToken;
      default:
        return '';
    }
  }
  bool isNetdiskLoggedIn(String driveKey) {
    final credential = getNetdiskCred(driveKey).trim();
    if (driveKey == 'quark') {
      return QuarkAccountSession.tryParseCredential(credential) != null;
    }
    return NetdiskSession.isUsable(driveKey, credential);
  }
  String netdiskCredential(String driveKey) {
    return getNetdiskCred(driveKey);
  }
  Future<void> setNetdiskCredential(String driveKey, String value) {
    return setNetdiskCred(driveKey, value);
  }
  Future<void> setNetdiskCred(String driveKey, String value) async {
    final trimmed = value.trim();
    switch (driveKey) {
      case 'quark':
        quarkAccounts.invalidate();
        await _prefs.setString(keyQuarkCookie, trimmed);
        break;
      case 'uc':
        await _prefs.setString(keyUcCookie, trimmed);
        break;
      case 'baidu':
        await _prefs.setString(keyBaiduCookie, trimmed);
        break;
      case 'ali':
        await _prefs.setString(keyAliToken, trimmed);
        break;
    }
    unawaited(CatPawHost.instance.syncNetdiskConfig());
  }
  Future<void> setDriveOrder(List<String> order) async {
    await _prefs.setStringList(keyDriveOrder, order);
  }
  Set<String> _privateSiteKeySet() {
    final cfg = loadSavedConfig();
    if (cfg == null) return const <String>{};
    return <String>{
      for (final s in cfg.sites)
        if (s.isEffectivelyPrivate) s.key,
    };
  }
  List<WatchHistoryEntry> getWatchHistory() {
    final raw = _prefs.getString(keyWatchHistory) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final privKeys = _privateSiteKeySet();
      return list
          .whereType<Map>()
          .map((m) => WatchHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((e) => !privKeys.contains(e.site))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
  Future<void> upsertWatchHistory(WatchHistoryEntry entry) async {
    if (_privateSiteKeySet().contains(entry.site)) {
      return;
    }
    final updated = CmsParser.upsertHistory(getWatchHistory(), entry);
    await _prefs.setString(
      keyWatchHistory,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    watchHistoryRevision.value++;
    scheduleAutoWebdavSync();
  }
  Future<void> removeWatchHistoryItem(String siteKey, String videoId) async {
    final targetKey = '$siteKey\n$videoId';
    final updated =
        getWatchHistory().where((e) => e.key != targetKey).toList();
    await _prefs.setString(
      keyWatchHistory,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    watchHistoryRevision.value++;
    await _recordSyncTombstone(
      'hist:$targetKey',
      DateTime.now().millisecondsSinceEpoch,
    );
    scheduleAutoWebdavSync(immediate: true);
  }
  Future<void> clearWatchHistory() async {
    final existing = getWatchHistory();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing.isNotEmpty) {
      final tombs = _readSyncTombstones();
      for (final e in existing) {
        tombs['hist:${e.key}'] = now;
      }
      await _writeSyncTombstones(tombs);
    }
    await _prefs.setString(keyWatchHistory, '[]');
    watchHistoryRevision.value++;
    scheduleAutoWebdavSync(immediate: true);
  }
  List<FavoriteEntry> getFavorites({bool forPrivate = false}) {
    final storageKey = forPrivate ? keyPrivateFavorites : keyFavorites;
    final raw = _prefs.getString(storageKey) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final privKeys = _privateSiteKeySet();
      return list
          .whereType<Map>()
          .map((m) => FavoriteEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((f) => forPrivate ? true : !privKeys.contains(f.site))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
  bool isFavorite(
    String siteKey,
    String videoId, {
    bool forPrivate = false,
  }) {
    final effectivePrivate = forPrivate || _privateSiteKeySet().contains(siteKey);
    final target = '$siteKey\n$videoId';
    return getFavorites(forPrivate: effectivePrivate)
        .any((f) => f.key == target);
  }
  Future<bool> toggleFavorite(CmsSite site, CmsVideo video) async {
    final forPrivate =
        site.isEffectivelyPrivate || _privateSiteKeySet().contains(site.key);
    final storageKey = forPrivate ? keyPrivateFavorites : keyFavorites;
    final current = getFavorites(forPrivate: forPrivate).toList();
    final targetKey = '${site.key}\n${video.id}';
    final existingIdx = current.indexWhere((f) => f.key == targetKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    bool nowFav;
    if (existingIdx >= 0) {
      current.removeAt(existingIdx);
      nowFav = false;
    } else {
      current.insert(
        0,
        FavoriteEntry(
          site: site.key,
          id: video.id,
          title: video.title,
          poster: video.poster,
          remarks: video.remarks,
          updated: now,
        ),
      );
      if (current.length > CmsParser.maxFavoriteEntries) {
        current.removeRange(CmsParser.maxFavoriteEntries, current.length);
      }
      nowFav = true;
    }
    await _prefs.setString(
      storageKey,
      jsonEncode(current.map((e) => e.toJson()).toList()),
    );
    if (!forPrivate) {
      final tombs = _readSyncTombstones();
      if (nowFav) {
        tombs['add:$targetKey'] = now;
        tombs.remove('fav:$targetKey');
      } else {
        tombs['fav:$targetKey'] = now;
        tombs.remove('add:$targetKey');
      }
      await _writeSyncTombstones(tombs);
      scheduleAutoWebdavSync(immediate: true, nowMs: now);
    }
    return nowFav;
  }
  List<String> getSearchHistory({bool forPrivate = false}) {
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    final raw = _prefs.getString(storageKey) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
  Future<void> addSearchKeyword(
    String keyword, {
    bool forPrivate = false,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    final list =
        getSearchHistory(forPrivate: forPrivate).where((k) => k != trimmed).toList();
    list.insert(0, trimmed);
    if (list.length > 16) list.removeRange(16, list.length);
    await _prefs.setString(storageKey, jsonEncode(list));
  }
  Future<void> clearSearchHistory({bool forPrivate = false}) async {
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    await _prefs.setString(storageKey, '[]');
  }
  /// Exports a backup JSON string compatible with both Android (`MarcoMovie-1`) and Flutter.
  String publicSupportedKey() {
    final publicSites = loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[];
    return publicSites.any((s) => s.key == selectedSiteKey) ? selectedSiteKey : '';
  }
  String _publicRawConfig(String raw, String origin) {
    if (raw.isEmpty) return raw;
    final parsed = CmsParser.parseConfig(raw, origin: origin);
    if (parsed.sites.every((s) => s.isEffectivelyPrivate) &&
        parsed.lives.every((s) => s.isEffectivelyPrivate) && parsed.depots.isEmpty) return '';
    if (!parsed.sites.any((s) => s.isEffectivelyPrivate) && !parsed.lives.any((s) => s.isEffectivelyPrivate)) return raw;
    bool privateItem(dynamic item) {
      if (item is! Map) return false;
      final flag = item['isPrivate'] ?? item['private'] ?? item['hidden'];
      final space = (item['space'] ?? '').toString().trim().toLowerCase();
      final group = (item['group'] ?? '').toString();
      return flag == true ||
          flag == 1 ||
          flag == 'true' ||
          flag == '1' ||
          space == 'private' ||
          group.contains('隐私') ||
          group.contains('私密');
    }
    try {
      final value = jsonDecode(CmsParser.stripJsonComments(CmsParser.unpackConfigText(raw)));
      if (value is Map) {
        if (value['api'] != null && privateItem(value)) return '{"sites":[]}';
        for (final key in ['sites', 'lives']) {
          if (value[key] is List) value[key] = (value[key] as List).where((entry) => !privateItem(entry)).toList();
          else if (value[key] is Map && privateItem(value[key])) value[key] = [];
        }
        return jsonEncode(value);
      }
    } catch (_) { /* Inline playlists have no JSON container to filter. */ }
    return jsonEncode({
      'spider': parsed.spider,
      if (parsed.parses.isNotEmpty)
        'parses': [
          for (final p in parsed.parses)
            {
              'name': p.name,
              'url': p.url,
              'type': p.type,
              if (p.headers.isNotEmpty) 'header': p.headers,
            },
        ],
      'sites': [for (final s in parsed.sites.where((s) => !s.isEffectivelyPrivate)) {
        'key': s.key, 'name': s.name, 'api': s.api, 'type': s.type,
        'playUrl': s.playUrl, 'ext': s.rawExtension ?? s.ext, 'header': s.headers, 'group': s.group, 'searchable': s.searchable,
        if (s.pluginReference.isNotEmpty) 'jar': s.pluginReference,
      }],
      'lives': [for (final l in parsed.publicLives) {
        'name': l.name, 'url': l.url, 'header': l.headers, 'group': l.group,
        if (l.inlineContent.isNotEmpty) ...jsonDecode(l.inlineContent) as Map,
        if (l.plugin != null) ...{
          'api': l.plugin!.api, 'ext': l.plugin!.rawExtension ?? l.plugin!.ext,
          if (l.plugin!.pluginReference.isNotEmpty) 'jar': l.plugin!.pluginReference,
        },
      }],
    });
  }

  static const _appearanceStrings = [keyWallpaperPreset, keyGlassBlurLevel, keyGridDensity,
    keyCardSubtitleMode, keyPreferredQuality, keyDefaultAspectMode, keyPreferredLine];
  static const _appearanceBooleans = [keyAmbientGlow, keyShowHeroBanner, keyShowContinueWatching];

  String exportBackupJson() {
    final all = getSubscriptions();
    final public = all.where((s) => !s.isEffectivelyPrivate).map((s) => s.copyWith(rawContent: _publicRawConfig(s.rawContent, s.url))).where((s) => s.rawContent.isNotEmpty).toList();
    final primary = public.isEmpty ? null : public.first;
    final publicIds = (_loadImportedConfig()?.sites ?? const <CmsSite>[]).where((s) => !s.isEffectivelyPrivate).map(_siteIdentity).toSet();
    final identityAliases = _pickerIdentities(_loadImportedConfig()?.sites ?? const <CmsSite>[]);
    final publicSites = (_loadImportedConfig()?.sites ?? const <CmsSite>[]).where((s) => !s.isEffectivelyPrivate).toList();
    final aliases = <String, String>{};
    for (final sub in public) {
      final parsed = CmsParser.parseConfig(sub.rawContent, origin: sub.url, subscriptionId: sub.id);
      for (final site in parsed.sites) {
        final existingKey = _savedAliases()[jsonEncode([sub.id, site.key, site.api])] ?? site.key;
        final matches = publicSites.where((s) => s.subscriptionId == sub.id && s.api == site.api &&
            (s.key == existingKey || s.key == '${site.key}_${sub.id}'));
        if (matches.isNotEmpty) aliases[jsonEncode([sub.id, site.key, site.api])] = matches.first.key;
      }
    }
    String exportedIdentity(String identity) {
      if (all.isNotEmpty) return identity;
      final parts = (jsonDecode(identity) as List).toList();
      parts[0] = 'restored_primary';
      return jsonEncode(parts);
    }
    return CmsParser.encodeBackupPayload(
      origin: !_prefs.containsKey(keySubscriptions) ? configOrigin : primary?.url ?? '',
      rawConfig: !_prefs.containsKey(keySubscriptions) ? _publicRawConfig(rawConfig, configOrigin) : primary?.rawContent ?? '',
      settings: <String, dynamic>{
        if (_prefs.containsKey(keySubscriptions)) keySubscriptions: public.map((s) => s.toJson()).toList(),
        for (final key in [_siteOrder, _removedSites]) key: (_prefs.getStringList(key) ?? []).map((id) => identityAliases[id] ?? id).where(publicIds.contains).map(exportedIdentity).toList(),
        _siteAliases: aliases,
        keyPreferredSite: preferredSiteKey,
        for (final key in _appearanceStrings) if (_prefs.containsKey(key)) key: _prefs.getString(key),
        for (final key in _appearanceBooleans) if (_prefs.containsKey(key)) key: _prefs.getBool(key),
        keySkipIntroSec: skipIntroSec,
        keySkipOutroSec: skipOutroSec,
        keyRepeatMode: repeatMode,
        keySelectedSite: publicSupportedKey(),
        keyWatchHistory: _prefs.getString(keyWatchHistory) ?? '[]',
        keyFavorites: _prefs.getString(keyFavorites) ?? '[]',
        keySearchHistory: _prefs.getString(keySearchHistory) ?? '[]',
        keyEpisodesDescending: episodesDescending,
        keyPlaySpeed: playSpeed,
        keyAutoNext: autoNext,
      },
    );
  }
  static String? _normalizeJsonArraySetting(dynamic value, {bool search = false}) {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! List) throw const FormatException('备份记录必须是列表');
    for (final item in decoded) {
      if (search) {
        if (item is! String) throw const FormatException('搜索记录格式无效');
      } else {
        if (item is! Map || item['site'] is! String || item['id'] is! String ||
            (item['site'] as String).isEmpty || (item['id'] as String).isEmpty) {
          throw const FormatException('观看记录或收藏缺少来源及影片标识');
        }
        for (final field in ['position', 'duration', 'index', 'updated']) {
          if (item.containsKey(field) && (item[field] is! num || item[field] < 0)) {
            throw FormatException('备份记录的 $field 无效');
          }
        }
      }
    }
    return jsonEncode(decoded);
  }
  /// Imports a backup JSON generated by either Android TV/Phone or Windows/Mac/iOS.
  /// Validates all fields before mutating preferences so failed restores preserve existing state.
  Future<CmsConfig?> importBackupJson(String rawBackup) async {
    final decoded = CmsParser.decodeBackupPayload(rawBackup);
    final settings = decoded.settings;
    final nextHistory = settings.containsKey(keyWatchHistory)
        ? _normalizeJsonArraySetting(settings[keyWatchHistory])
        : null;
    final nextFavorites = settings.containsKey(keyFavorites)
        ? _normalizeJsonArraySetting(settings[keyFavorites])
        : null;
    final nextSearch = settings.containsKey(keySearchHistory)
        ? _normalizeJsonArraySetting(settings[keySearchHistory], search: true)
        : null;
    if (settings.containsKey(keyPreferredSite) && settings[keyPreferredSite] is! String) {
      throw const FormatException('偏好源设置格式无效');
    }
    final incomingAliases = settings[_siteAliases];
    if (incomingAliases != null && (incomingAliases is! Map || incomingAliases.entries.any((e) => e.key is! String || e.value is! String || (e.value as String).isEmpty))) {
      throw const FormatException('来源标识记录无效');
    }
    final aliases = incomingAliases == null ? <String, String>{} : Map<String, String>.from(incomingAliases as Map);
    for (final identity in aliases.keys) {
      final parts = jsonDecode(identity);
      if (parts is! List || parts.length != 3 || parts.any((p) => p is! String)) throw const FormatException('来源标识记录无效');
    }
    final pickerEdits = <String, List<String>>{};
    final privateIdentities = (_loadImportedConfig()?.sites ?? const <CmsSite>[]).where((s) => s.isEffectivelyPrivate).map(_siteIdentity).toSet();
    for (final key in [_siteOrder, _removedSites]) {
      final value = settings[key];
      if (value == null) continue;
      if (value is! List || value.any((v) => v is! String)) throw const FormatException('线路排序记录无效');
      for (final identity in value.cast<String>()) {
        final parts = jsonDecode(identity);
        if (parts is! List || parts.length != 3 || parts.any((p) => p is! String) || privateIdentities.contains(identity)) {
          throw const FormatException('线路排序标识无效');
        }
      }
      pickerEdits[key] = value.cast<String>();
    }
    for (final key in _appearanceStrings) {
      if (settings.containsKey(key) && settings[key] is! String) throw const FormatException('外观设置格式无效');
    }
    for (final key in _appearanceBooleans) {
      if (settings.containsKey(key) && settings[key] is! bool) throw const FormatException('外观设置格式无效');
    }
    final incoming = <SubscriptionEntry>[];
    final ids = <String>{};
    final updatedSubs = settings[keySubscriptions];
    if (updatedSubs != null) {
      if (updatedSubs is! List) throw const FormatException('订阅列表格式无效');
      for (final item in updatedSubs) {
        if (item is! Map) throw const FormatException('订阅条目格式无效');
        final sub = SubscriptionEntry.fromJson(Map<String, dynamic>.from(item));
        if (sub.id.isEmpty || !ids.add(sub.id) || sub.isEffectivelyPrivate || sub.rawContent.isEmpty) {
          throw const FormatException('常规备份包含无效订阅');
        }
        CmsParser.parseConfig(sub.rawContent, origin: sub.url);
        incoming.add(sub);
      }
    } else if (decoded.rawConfig.isNotEmpty) {
      incoming.add(SubscriptionEntry(id: 'restored_primary', name: '已恢复的订阅',
          url: decoded.origin, rawContent: decoded.rawConfig));
    }
    final incomingIds = incoming.map((s) => s.id).toSet();
    final rawIdentities = <String>{};
    for (final sub in incoming) {
      final parsed = CmsParser.parseConfig(sub.rawContent, origin: sub.url);
      for (final site in parsed.sites) {
        rawIdentities.add(jsonEncode([sub.id, site.key, site.api]));
      }
    }
    if (aliases.keys.any((identity) => !rawIdentities.contains(identity)) ||
        aliases.values.toSet().length != aliases.length ||
        pickerEdits.values.expand((v) => v).any((identity) =>
            !incomingIds.contains((jsonDecode(identity) as List).first))) {
      throw const FormatException('线路管理记录与订阅不匹配');
    }
    if (updatedSubs != null || incoming.isNotEmpty) {
      final privateSubs = getSubscriptions().where((s) => s.isEffectivelyPrivate).toList();
      final privateIds = privateSubs.map((s) => s.id).toSet();
      if (incoming.any((s) => privateIds.contains(s.id))) throw const FormatException('订阅标识冲突');
      await saveSubscriptions([...incoming, ...privateSubs]);
      if (incoming.isEmpty) {
        await _prefs.remove(keyRawConfig);
        await _prefs.remove(keyOrigin);
      }
    }
    final privateSubIds = getSubscriptions().where((s) => s.isEffectivelyPrivate).map((s) => s.id).toSet();
    final retainedAliases = _savedAliases()..removeWhere((key, _) {
      try { return !privateSubIds.contains((jsonDecode(key) as List).first); } catch (_) { return true; }
    });
    retainedAliases.addAll(aliases);
    await _prefs.setString(_siteAliases, jsonEncode(retainedAliases));
    for (final entry in pickerEdits.entries) {
      final retainedPrivate = (_prefs.getStringList(entry.key) ?? []).where(privateIdentities.contains);
      await _prefs.setStringList(entry.key, [...entry.value, ...retainedPrivate]);
    }
    for (final key in _appearanceStrings) {
      if (settings[key] is String) await _prefs.setString(key, settings[key] as String);
    }
    for (final key in _appearanceBooleans) {
      if (settings[key] is bool) await _prefs.setBool(key, settings[key] as bool);
    }
    for (final key in [keySkipIntroSec, keySkipOutroSec]) {
      final value = settings[key];
      if (value is int && value >= 0 && value <= 600) await _prefs.setInt(key, value);
    }
    if (['off','one','all'].contains(settings[keyRepeatMode])) await setRepeatMode(settings[keyRepeatMode] as String);
    CmsConfig? parsedConfig = decoded.parsedConfig;
    if (decoded.rawConfig.isNotEmpty) {
      await _prefs.setString(keyRawConfig, decoded.rawConfig);
      await _prefs.setString(keyOrigin, decoded.origin);
      if (parsedConfig != null &&
          parsedConfig.supportedSites.isNotEmpty &&
          !parsedConfig.supportedSites.any((s) => s.key == selectedSiteKey)) {
        await _prefs.setString(
          keySelectedSite,
          parsedConfig.supportedSites.first.key,
        );
      }
    }
    if (settings[keyPreferredSite] is String) {
      final key = settings[keyPreferredSite] as String;
      final exists = (loadSavedConfig()?.publicSupportedSites ?? const <CmsSite>[]).any((s) => s.key == key);
      await setPreferredSiteKey(exists ? key : '');
    }
    if (settings[keySelectedSite] is String) {
      await setSelectedSiteKey(settings[keySelectedSite] as String);
    }
    if (nextHistory != null) {
      await _prefs.setString(keyWatchHistory, nextHistory);
      watchHistoryRevision.value++;
    }
    if (nextFavorites != null) {
      await _prefs.setString(keyFavorites, nextFavorites);
    }
    if (nextSearch != null) {
      await _prefs.setString(keySearchHistory, nextSearch);
    }
    if (settings[keyEpisodesDescending] is bool) {
      await setEpisodesDescending(settings[keyEpisodesDescending] as bool);
    }
    if (settings[keyPlaySpeed] is num) {
      final speed = (settings[keyPlaySpeed] as num).toDouble();
      if (speed >= 0.5 && speed <= 2.0) {
        await setPlaySpeed(speed);
      }
    }
    if (settings[keyAutoNext] is bool) {
      await setAutoNext(settings[keyAutoNext] as bool);
    }
    return loadSavedConfig();
  }

  // ===========================================================================
  // Multi-Device Cloud Sync v2 (WebDAV & LAN Peer-to-Peer)
  // ===========================================================================

  String get webdavUrl => (_prefs.getString(keyWebdavUrl) ?? '').trim();
  String get webdavUser => (_prefs.getString(keyWebdavUser) ?? '').trim();
  String get webdavPass => _prefs.getString(keyWebdavPass) ?? '';
  bool get webdavAuto => _prefs.getBool(keyWebdavAuto) ?? true;
  bool get webdavSyncSubs => _prefs.getBool(keyWebdavSyncSubs) ?? true;
  int get syncLastTime => _prefs.getInt(keySyncLastTime) ?? 0;
  String get syncLastStatus => _prefs.getString(keySyncLastStatus) ?? '';
  bool get isWebdavConfigured => webdavUrl.isNotEmpty;

  String get syncStatusSummary {
    if (!isWebdavConfigured) {
      if (syncLastTime > 0 && syncLastStatus.isNotEmpty) {
        return '局域网同步 · $syncLastStatus';
      }
      return '支持 WebDAV（坚果云 / NAS / Alist）与局域网多端进度及订阅同步';
    }
    final mode = webdavAuto ? '自动同步已开启' : '手动同步';
    if (syncLastStatus.isNotEmpty) {
      return '$mode · $syncLastStatus';
    }
    return '$mode · $webdavUrl';
  }

  void cancelPendingAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  Future<void> saveWebdavConfig({
    required String url,
    required String user,
    required String pass,
    required bool auto,
    bool? syncSubs,
  }) async {
    await _prefs.setString(keyWebdavUrl, url.trim());
    await _prefs.setString(keyWebdavUser, user.trim());
    await _prefs.setString(keyWebdavPass, pass);
    await _prefs.setBool(keyWebdavAuto, auto);
    if (syncSubs != null) {
      await _prefs.setBool(keyWebdavSyncSubs, syncSubs);
    }
    if (!auto || url.trim().isEmpty) {
      cancelPendingAutoSync();
    }
  }

  Future<void> setWebdavSyncSubs(bool enabled) async {
    await _prefs.setBool(keyWebdavSyncSubs, enabled);
  }

  static bool _isHttpOriginUrl(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  /// Canonical cross-platform subscription sync identity matching Android `ConfigLibrary.identity`:
  /// lowercase SHA-256 hex of `"url:<httpOrigin>"` when an HTTP(S) warehouse/origin URL exists,
  /// otherwise `"local:<rawContent>"`.
  static String canonicalSubscriptionSyncKey(
    String url,
    String rawContent, {
    String warehouseUrl = '',
  }) {
    final effectiveHttp = _isHttpOriginUrl(warehouseUrl)
        ? warehouseUrl.trim()
        : (_isHttpOriginUrl(url) ? url.trim() : '');
    final input = effectiveHttp.isNotEmpty
        ? 'url:$effectiveHttp'
        : 'local:$rawContent';
    return sha256.convert(utf8.encode(input)).toString();
  }

  static bool _isLocalFileSubscription(String url, String rawContent) {
    final trimmedUrl = url.trim().toLowerCase();
    if (trimmedUrl.startsWith('file:')) return true;
    return trimmedUrl.isEmpty && rawContent.contains('file:///');
  }

  List<SubscriptionEntry> _collectPublicSyncSubscriptions() {
    final result = <SubscriptionEntry>[];
    final seenSyncKeys = <String>{};
    if (_prefs.containsKey(keySubscriptions)) {
      for (final s in getSubscriptions()) {
        if (s.isEffectivelyPrivate) continue;
        if (_isLocalFileSubscription(s.url, s.rawContent)) continue;
        final pubRaw = _publicRawConfig(s.rawContent, s.url);
        if (pubRaw.trim().isEmpty) continue;
        final syncKey = canonicalSubscriptionSyncKey(
          s.url,
          pubRaw,
          warehouseUrl: s.warehouseUrl,
        );
        if (!seenSyncKeys.add(syncKey)) continue;
        result.add(
          s.copyWith(
            isPrivate: false,
            rawContent: pubRaw,
            updatedAt: s.updatedAt > 0 ? s.updatedAt : 1,
          ),
        );
      }
      return result;
    }
    if (rawConfig.trim().isNotEmpty && !_isLocalFileSubscription(configOrigin, rawConfig)) {
      final pubRaw = _publicRawConfig(rawConfig, configOrigin);
      if (pubRaw.trim().isNotEmpty) {
        try {
          final parsed = CmsParser.parseConfig(pubRaw, origin: configOrigin);
          final fmt = CmsParser.detectSubscriptionFormat(pubRaw, origin: configOrigin);
          result.add(
            SubscriptionEntry(
              id: 'legacy_primary',
              name: activeDepotName.isNotEmpty
                  ? activeDepotName
                  : (configOrigin.isNotEmpty
                      ? (Uri.tryParse(configOrigin)?.host ?? '默认订阅')
                      : '默认订阅'),
              url: configOrigin,
              group: '默认分组',
              format: parsed.depots.isNotEmpty ? '多仓' : fmt,
              isPrivate: false,
              enabled: true,
              rawContent: pubRaw,
              siteCount: parsed.supportedSites.length,
              liveCount: parsed.lives.length,
              updatedAt: 1,
            ),
          );
        } catch (_) {}
      }
    }
    return result;
  }

  Map<String, int> _readSyncTombstones() {
    final raw = _prefs.getString(keySyncTombstones) ?? '{}';
    final out = <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final k = entry.key.toString();
          final v = (entry.value as num?)?.toInt() ?? 0;
          if (k.isNotEmpty && v > 0) {
            out[k] = v;
          }
        }
      }
    } catch (_) {}
    return _boundSyncTombstones(out);
  }

  Map<String, int> _boundSyncTombstones(Map<String, int> input) {
    if (input.length <= maxSyncTombstones) return input;
    final entries = input.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return <String, int>{
      for (final e in entries.take(maxSyncTombstones)) e.key: e.value,
    };
  }

  Future<void> _writeSyncTombstones(Map<String, int> tombs) async {
    final bounded = _boundSyncTombstones(tombs);
    await _prefs.setString(keySyncTombstones, jsonEncode(bounded));
  }

  Future<void> _recordSyncTombstone(String key, int timestampMs) async {
    if (key.isEmpty || timestampMs <= 0) return;
    final tombs = _readSyncTombstones();
    tombs[key] = timestampMs;
    await _writeSyncTombstones(tombs);
  }

  static String resolveWebdavFileUrl(String rawUrl) {
    var trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('请填写 WebDAV 服务器地址');
    }
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('仅支持 HTTP 或 HTTPS WebDAV 地址');
    }
    final path = uri.path;
    if (path.toLowerCase().endsWith('.json')) {
      return trimmed;
    }
    final host = uri.host.toLowerCase();
    final isJianguoyun =
        host == 'jianguoyun.com' || host.endsWith('.jianguoyun.com');
    final isRootPath =
        path.isEmpty || path == '/' || path == '/dav' || path == '/dav/';
    final folderPrefix = (isJianguoyun && isRootPath) ? 'MarcoMovie/' : '';
    return trimmed.endsWith('/')
        ? '$trimmed$folderPrefix$defaultSyncFileName'
        : '$trimmed/$folderPrefix$defaultSyncFileName';
  }

  static String resolveLanSyncEndpoint(String rawUrl) {
    var trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('请填写对方设备的局域网同步地址');
    }
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      const httpPrefix = 'http://';
      trimmed = '$httpPrefix$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('请输入有效的局域网同步地址');
    }
    return trimmed.endsWith('/sync') ? trimmed : '$trimmed/sync';
  }

  String exportSyncPayload({
    int? nowMs,
    List<dynamic>? preservedRemoteSubscriptions,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final hist = getWatchHistory().map((e) => e.toJson()).toList();
    final localFavEntries = getFavorites(forPrivate: false);
    final favs = localFavEntries.map((f) => f.toJson()).toList();
    final tombs = _readSyncTombstones();
    for (final f in localFavEntries) {
      if (f.updated > 0) {
        final addKey = 'add:${f.key}';
        final prev = tombs[addKey] ?? 0;
        if (f.updated > prev) tombs[addKey] = f.updated;
      }
    }
    List<dynamic>? subsPayload;
    if (webdavSyncSubs) {
      final pubSubs = _collectPublicSyncSubscriptions();
      subsPayload = [
        for (final s in pubSubs)
          {
            'syncKey': canonicalSubscriptionSyncKey(
              s.url,
              s.rawContent,
              warehouseUrl: s.warehouseUrl,
            ),
            ...s.toJson(),
            'isPrivate': false,
          },
      ];
    } else if (preservedRemoteSubscriptions != null) {
      subsPayload = preservedRemoteSubscriptions;
    }
    return jsonEncode({
      'schema': syncSchema,
      'version': syncVersion,
      'updated': now,
      'watch_history': hist,
      'favorites': favs,
      if (subsPayload != null) 'subscriptions': subsPayload,
      'tombstones': _boundSyncTombstones(tombs),
    });
  }

  static String _subscriptionSnapshotDigest(List<SubscriptionEntry> subs) {
    return jsonEncode([
      for (final s in subs)
        [
          canonicalSubscriptionSyncKey(
            s.url,
            s.rawContent,
            warehouseUrl: s.warehouseUrl,
          ),
          s.name,
          s.url,
          s.group,
          s.format,
          s.enabled,
          s.rawContent,
          s.warehouseUrl,
          s.activeDepotName,
          s.depots.map((d) => d.toJson()).toList(),
        ],
    ]);
  }

  Future<
    ({
      int historyCount,
      int favoriteCount,
      int subscriptionCount,
      bool changed,
      bool subscriptionsChanged,
      String payloadJson,
    })
  >
  mergeSyncPayload(String? remotePayloadRaw, {int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final localHist = getWatchHistory();
    final localFavs = getFavorites(forPrivate: false);
    final localTombs = _readSyncTombstones();
    for (final f in localFavs) {
      if (f.updated > 0) {
        final addKey = 'add:${f.key}';
        final prev = localTombs[addKey] ?? 0;
        if (f.updated > prev) localTombs[addKey] = f.updated;
      }
    }

    final beforeHistJson = jsonEncode(localHist.map((e) => e.toJson()).toList());
    final beforeFavsJson = jsonEncode(localFavs.map((f) => f.toJson()).toList());
    final localPublicSubs = _collectPublicSyncSubscriptions();

    if (remotePayloadRaw == null || remotePayloadRaw.trim().isEmpty) {
      final payload = exportSyncPayload(nowMs: now);
      return (
        historyCount: localHist.length,
        favoriteCount: localFavs.length,
        subscriptionCount: webdavSyncSubs ? localPublicSubs.length : 0,
        changed: false,
        subscriptionsChanged: false,
        payloadJson: payload,
      );
    }

    if (utf8.encode(remotePayloadRaw).length > maxSyncPayloadBytes) {
      throw const FormatException('远端同步文件超过 8 MB 大小限制');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(remotePayloadRaw);
    } catch (_) {
      throw const FormatException('远端同步数据不是有效的 JSON 格式');
    }
    if (decoded is! Map) {
      throw const FormatException('远端同步数据格式无效');
    }

    final schema = (decoded['schema'] ?? '').toString();
    final format = (decoded['format'] ?? '').toString();
    final remoteHist = <WatchHistoryEntry>[];
    final remoteFavs = <FavoriteEntry>[];
    final remoteTombs = <String, int>{};
    final remoteSubsRaw = <Map<String, dynamic>>[];
    List<dynamic>? preservedRemoteSubs;

    if (schema == syncSchema) {
      final rh =
          decoded['watch_history'] ??
          decoded['history'] ??
          decoded['watchHistory'];
      if (rh is List) {
        for (final item in rh.whereType<Map>()) {
          final e = WatchHistoryEntry.fromJson(Map<String, dynamic>.from(item));
          if (e.site.isNotEmpty && e.id.isNotEmpty) remoteHist.add(e);
        }
      }
      final rf = decoded['favorites'];
      if (rf is List) {
        for (final item in rf.whereType<Map>()) {
          final map = Map<String, dynamic>.from(item);
          map['updated'] ??= map['addedAt'];
          final f = FavoriteEntry.fromJson(map);
          if (f.site.isNotEmpty && f.id.isNotEmpty) {
            remoteFavs.add(f);
            if (f.updated > 0) {
              final addKey = 'add:${f.key}';
              final prev = remoteTombs[addKey] ?? 0;
              if (f.updated > prev) remoteTombs[addKey] = f.updated;
            }
          }
        }
      }
      final rs = decoded['subscriptions'];
      if (rs is List) {
        preservedRemoteSubs = rs;
        for (final item in rs.whereType<Map>()) {
          remoteSubsRaw.add(Map<String, dynamic>.from(item));
        }
      }
      final rt = decoded['tombstones'];
      if (rt is Map) {
        for (final entry in rt.entries) {
          final k = entry.key.toString();
          final v = (entry.value as num?)?.toInt() ?? 0;
          if (k.isNotEmpty && v > 0) remoteTombs[k] = v;
        }
      }
    } else if (format == 'MarcoMovie-1' || schema == 'marco-movie-backup') {
      final settings = decoded['settings'];
      if (settings is Map) {
        final rhRaw = settings[keyWatchHistory];
        final rhList = rhRaw is String ? jsonDecode(rhRaw) : rhRaw;
        if (rhList is List) {
          for (final item in rhList.whereType<Map>()) {
            final e = WatchHistoryEntry.fromJson(Map<String, dynamic>.from(item));
            if (e.site.isNotEmpty && e.id.isNotEmpty) remoteHist.add(e);
          }
        }
        final rfRaw = settings[keyFavorites];
        final rfList = rfRaw is String ? jsonDecode(rfRaw) : rfRaw;
        if (rfList is List) {
          for (final item in rfList.whereType<Map>()) {
            final f = FavoriteEntry.fromJson(Map<String, dynamic>.from(item));
            if (f.site.isNotEmpty && f.id.isNotEmpty) remoteFavs.add(f);
          }
        }
        final rsRaw = settings[keySubscriptions];
        if (rsRaw is List) {
          preservedRemoteSubs = rsRaw;
          for (final item in rsRaw.whereType<Map>()) {
            remoteSubsRaw.add(Map<String, dynamic>.from(item));
          }
        }
      }
      if (remoteSubsRaw.isEmpty) {
        final rawCfg = (decoded['rawConfig'] ?? decoded['config'] ?? '').toString();
        final orig = (decoded['origin'] ?? '').toString();
        if (rawCfg.trim().isNotEmpty) {
          remoteSubsRaw.add({
            'id': 'backup_primary',
            'name': orig.isNotEmpty ? (Uri.tryParse(orig)?.host ?? '备份订阅') : '备份订阅',
            'url': orig,
            'rawContent': rawCfg,
            'enabled': true,
            'updatedAt': (decoded['exportedAt'] as num?)?.toInt() ?? 1,
          });
        }
      }
    } else {
      throw const FormatException('远端同步文件格式不受支持');
    }

    // 1. Merge tombstones
    final mergedTombs = <String, int>{...localTombs};
    for (final entry in remoteTombs.entries) {
      final prev = mergedTombs[entry.key] ?? 0;
      if (entry.value > prev) {
        mergedTombs[entry.key] = entry.value;
      }
    }
    for (final k in mergedTombs.keys.toList()) {
      if (k.startsWith('fav:')) {
        final rawKey = k.substring(4);
        final delTs = mergedTombs[k];
        final addTs = mergedTombs['add:$rawKey'];
        if (delTs != null && addTs != null) {
          if (addTs > delTs) {
            mergedTombs.remove(k);
          } else {
            mergedTombs.remove('add:$rawKey');
          }
        }
      }
    }

    // 2. Optionally merge public subscriptions BEFORE filtering history/favorites so private keys stay isolated
    var subscriptionsChanged = false;
    var finalSubCount = 0;
    if (webdavSyncSubs) {
      await _editSubscriptions(() async {
        final currentAll = getSubscriptions();
        final localPrivateSubs =
            currentAll.where((s) => s.isEffectivelyPrivate).toList();
        final localFileSubs = currentAll
            .where(
              (s) =>
                  !s.isEffectivelyPrivate &&
                  _isLocalFileSubscription(s.url, s.rawContent),
            )
            .toList();
        final privateSyncKeys = <String>{
          for (final p in localPrivateSubs)
            if (p.rawContent.isNotEmpty)
              canonicalSubscriptionSyncKey(
                p.url,
                p.rawContent,
                warehouseUrl: p.warehouseUrl,
              ),
        };
        final reservedIds = <String>{
          for (final p in localPrivateSubs) p.id,
          for (final f in localFileSubs) f.id,
        };

        final currentPublic = _collectPublicSyncSubscriptions();
        final beforeSubsDigest = _subscriptionSnapshotDigest(currentPublic);
        final hadRegistry = _prefs.containsKey(keySubscriptions);

        final subByKey = <String, SubscriptionEntry>{};
        for (final s in currentPublic) {
          final syncKey = canonicalSubscriptionSyncKey(
            s.url,
            s.rawContent,
            warehouseUrl: s.warehouseUrl,
          );
          final delTs = mergedTombs['sub:$syncKey'] ?? 0;
          if (delTs > 0) {
            if (s.updatedAt > delTs) {
              mergedTombs.remove('sub:$syncKey');
            } else {
              continue;
            }
          }
          subByKey[syncKey] = s;
          reservedIds.add(s.id);
        }

        for (final rawMap in remoteSubsRaw) {
          final candidate = SubscriptionEntry.fromJson(rawMap);
          if (candidate.isEffectivelyPrivate) continue;
          if (_isLocalFileSubscription(candidate.url, candidate.rawContent)) {
            continue;
          }
          if (candidate.rawContent.trim().isEmpty) continue;
          final String pubRaw;
          final CmsConfig parsed;
          try {
            pubRaw = _publicRawConfig(candidate.rawContent, candidate.url);
            if (pubRaw.trim().isEmpty) continue;
            parsed = CmsParser.parseConfig(pubRaw, origin: candidate.url);
          } catch (_) {
            continue;
          }
          final syncKey = canonicalSubscriptionSyncKey(
            candidate.url,
            pubRaw,
            warehouseUrl: candidate.warehouseUrl,
          );
          if (privateSyncKeys.contains(syncKey)) continue;
          final delTs = mergedTombs['sub:$syncKey'] ?? 0;
          final incomingTs = candidate.updatedAt > 0 ? candidate.updatedAt : 1;
          if (delTs > 0) {
            if (incomingTs > delTs) {
              mergedTombs.remove('sub:$syncKey');
            } else {
              continue;
            }
          }
          final fmt = candidate.format.trim().isNotEmpty
              ? candidate.format.trim()
              : (parsed.depots.isNotEmpty
                  ? '多仓'
                  : CmsParser.detectSubscriptionFormat(
                      pubRaw,
                      origin: candidate.url,
                    ));
          final cleanName = candidate.name.trim().isNotEmpty
              ? candidate.name.trim()
              : (candidate.url.isNotEmpty
                  ? (Uri.tryParse(candidate.url)?.host ?? '云端订阅')
                  : '云端订阅');
          final existing = subByKey[syncKey];
          if (existing == null) {
            var assignedId = candidate.id.trim();
            if (assignedId.isEmpty || reservedIds.contains(assignedId)) {
              assignedId = 'sub_${syncKey.substring(0, 12)}';
              var suffix = 1;
              while (reservedIds.contains(assignedId)) {
                assignedId = 'sub_${syncKey.substring(0, 10)}_$suffix';
                suffix++;
              }
            }
            reservedIds.add(assignedId);
            subByKey[syncKey] = SubscriptionEntry(
              id: assignedId,
              name: cleanName,
              url: candidate.url.trim(),
              group: candidate.group.trim().isEmpty ? '默认分组' : candidate.group.trim(),
              format: fmt,
              isPrivate: false,
              enabled: candidate.enabled,
              rawContent: pubRaw,
              siteCount: parsed.supportedSites.length,
              liveCount: parsed.lives.length,
              updatedAt: incomingTs,
              warehouseUrl: candidate.warehouseUrl,
              activeDepotName: candidate.activeDepotName,
              depots: candidate.depots.isNotEmpty ? candidate.depots : parsed.depots,
            );
          } else if (incomingTs > existing.updatedAt) {
            subByKey[syncKey] = existing.copyWith(
              name: cleanName,
              url: candidate.url.trim(),
              group: candidate.group.trim().isEmpty ? '默认分组' : candidate.group.trim(),
              format: fmt,
              isPrivate: false,
              enabled: candidate.enabled,
              rawContent: pubRaw,
              siteCount: parsed.supportedSites.length,
              liveCount: parsed.lives.length,
              updatedAt: incomingTs,
              warehouseUrl: candidate.warehouseUrl,
              activeDepotName: candidate.activeDepotName,
              depots: candidate.depots.isNotEmpty ? candidate.depots : existing.depots,
            );
          }
        }

        final mergedPublic = subByKey.values.toList();
        finalSubCount = mergedPublic.length;
        final afterSubsDigest = _subscriptionSnapshotDigest(mergedPublic);
        if (afterSubsDigest != beforeSubsDigest ||
            (!hadRegistry && mergedPublic.isNotEmpty)) {
          subscriptionsChanged = true;
          await saveSubscriptions([
            ...mergedPublic,
            ...localFileSubs,
            ...localPrivateSubs,
          ]);
          final primary = mergedPublic.isNotEmpty
              ? mergedPublic.first
              : (localFileSubs.isNotEmpty ? localFileSubs.first : null);
          await _prefs.setString(keyRawConfig, primary?.rawContent ?? '');
          await _prefs.setString(keyOrigin, primary?.url ?? '');
          await _prefs.setString(keyDepots, '[]');
          await _prefs.setString(
            keyActiveDepotName,
            primary?.activeDepotName ?? '',
          );
          final reloaded = loadSavedConfig();
          final pubSites = reloaded?.publicSupportedSites ?? const <CmsSite>[];
          if (pubSites.isNotEmpty &&
              !pubSites.any((s) => s.key == selectedSiteKey)) {
            final preferredDefault = pubSites.firstWhere(
              (s) => !CspBridge.isBannerNoticeSite(s),
              orElse: () => pubSites.first,
            );
            await _prefs.setString(keySelectedSite, preferredDefault.key);
          } else if (pubSites.isEmpty && selectedSiteKey.isNotEmpty) {
            final allSites = reloaded?.supportedSites ?? const <CmsSite>[];
            if (!allSites.any((s) => s.key == selectedSiteKey)) {
              await _prefs.setString(keySelectedSite, '');
            }
          }
        }
      });
    }

    // 3. Merge watch history (LWW per key + deletion tombstones)
    final privKeys = _privateSiteKeySet();
    final histByKey = <String, WatchHistoryEntry>{};
    for (final e in [...localHist, ...remoteHist]) {
      if (privKeys.contains(e.site)) continue;
      final delTs = mergedTombs['hist:${e.key}'] ?? 0;
      if (delTs > 0) {
        if (e.updated > delTs) {
          mergedTombs.remove('hist:${e.key}');
        } else {
          continue;
        }
      }
      final existing = histByKey[e.key];
      if (existing == null ||
          e.updated > existing.updated ||
          (e.updated == existing.updated && e.position > existing.position)) {
        histByKey[e.key] = e;
      }
    }
    final mergedHist = histByKey.values.toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    if (mergedHist.length > CmsParser.maxHistoryEntries) {
      mergedHist.removeRange(
        CmsParser.maxHistoryEntries,
        mergedHist.length,
      );
    }

    // 4. Merge favorites
    final favByKey = <String, FavoriteEntry>{};
    for (final f in [...localFavs, ...remoteFavs]) {
      if (privKeys.contains(f.site)) continue;
      final delTs = mergedTombs['fav:${f.key}'] ?? 0;
      final addTs = mergedTombs['add:${f.key}'] ?? f.updated;
      if (delTs > 0 && delTs >= addTs) {
        continue;
      }
      final existing = favByKey[f.key];
      if (existing == null || f.updated > existing.updated) {
        favByKey[f.key] = addTs > f.updated
            ? FavoriteEntry(
                site: f.site,
                id: f.id,
                title: f.title,
                poster: f.poster,
                remarks: f.remarks,
                updated: addTs,
              )
            : f;
      }
    }
    final mergedFavs = favByKey.values.toList()
      ..sort((a, b) {
        final ta = mergedTombs['add:${a.key}'] ?? a.updated;
        final tb = mergedTombs['add:${b.key}'] ?? b.updated;
        return tb.compareTo(ta);
      });
    if (mergedFavs.length > CmsParser.maxFavoriteEntries) {
      mergedFavs.removeRange(CmsParser.maxFavoriteEntries, mergedFavs.length);
    }

    final nextHistJson = jsonEncode(mergedHist.map((e) => e.toJson()).toList());
    final nextFavsJson = jsonEncode(mergedFavs.map((f) => f.toJson()).toList());
    await _prefs.setString(keyWatchHistory, nextHistJson);
    await _prefs.setString(keyFavorites, nextFavsJson);
    await _writeSyncTombstones(mergedTombs);
    if (nextHistJson != beforeHistJson) {
      watchHistoryRevision.value++;
    }

    final changed =
        subscriptionsChanged ||
        nextHistJson != beforeHistJson ||
        nextFavsJson != beforeFavsJson;
    final payloadJson = exportSyncPayload(
      nowMs: now,
      preservedRemoteSubscriptions: preservedRemoteSubs,
    );
    return (
      historyCount: mergedHist.length,
      favoriteCount: mergedFavs.length,
      subscriptionCount: finalSubCount,
      changed: changed,
      subscriptionsChanged: subscriptionsChanged,
      payloadJson: payloadJson,
    );
  }

  void scheduleAutoWebdavSync({bool immediate = false, int? nowMs}) {
    if (!webdavAuto || !isWebdavConfigured) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int delayMs;
    if (immediate) {
      delayMs = 2500;
      _autoSyncTimer?.cancel();
    } else {
      final elapsed = _lastHistoryAutoPushMs > 0
          ? now - _lastHistoryAutoPushMs
          : 45000;
      if (elapsed < 45000) {
        if (_autoSyncTimer?.isActive == true) return;
        delayMs = (45000 - elapsed).clamp(3000, 45000);
      } else {
        delayMs = 3000;
        _autoSyncTimer?.cancel();
      }
    }
    _autoSyncTimer = Timer(Duration(milliseconds: delayMs), () {
      _lastHistoryAutoPushMs = DateTime.now().millisecondsSinceEpoch;
      syncWithWebdav().ignore();
    });
  }

  Map<String, String> _webdavHeaders({bool jsonContent = false}) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
      if (jsonContent) 'Content-Type': 'application/json; charset=utf-8',
    };
    if (webdavUser.isNotEmpty || webdavPass.isNotEmpty) {
      final token = base64Encode(utf8.encode('$webdavUser:$webdavPass'));
      headers['Authorization'] = 'Basic $token';
    }
    return headers;
  }

  static String _formatWebdavWriteError(int code) {
    if (code == 404 || code == 409) {
      return 'WebDAV 写入失败 (HTTP $code)：目标文件夹不存在或不可写。坚果云请在地址后加一个文件夹名，例如 https://dav.jianguoyun.com/dav/MarcoMovie/';
    }
    if (code == 405) {
      return 'WebDAV 写入失败 (HTTP 405)：服务器不允许写入';
    }
    if (code == 423) {
      return 'WebDAV 写入失败 (HTTP 423)：文件被锁定';
    }
    if (code == 507) {
      return 'WebDAV 写入失败 (HTTP 507)：空间不足';
    }
    return 'WebDAV 写入失败 (HTTP $code)';
  }

  Future<void> _ensureWebdavCollections(http.Client client, Uri fileUri) async {
    final segments = fileUri.pathSegments;
    if (segments.length <= 1) return;
    for (var i = 0; i < segments.length - 1; i++) {
      final subPath = '/${segments.sublist(0, i + 1).join('/')}/';
      final collUri = fileUri.replace(path: subPath);
      final req = http.Request('MKCOL', collUri)..headers.addAll(_webdavHeaders());
      try {
        final streamed =
            await client.send(req).timeout(const Duration(seconds: 10));
        final status = streamed.statusCode;
        if (status == 401 || status == 403) {
          throw FormatException('WebDAV 权限验证失败 (HTTP $status)');
        }
      } on FormatException {
        rethrow;
      } catch (e) {
        // Continue creating intermediate directories
      }
    }
  }

  String _formatSyncSuccessSummary(
    String prefix,
    int nowMs, {
    required int historyCount,
    required int favoriteCount,
    required int subscriptionCount,
  }) {
    final dt = DateTime.fromMillisecondsSinceEpoch(nowMs);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final subSegment = webdavSyncSubs ? ' · 订阅 $subscriptionCount' : '';
    return '$prefix $hh:$mm（历史 $historyCount · 收藏 $favoriteCount$subSegment）';
  }

  Future<
    ({
      int historyCount,
      int favoriteCount,
      int subscriptionCount,
      bool changed,
      bool subscriptionsChanged,
    })
  >
  syncWithWebdav({http.Client? client}) async {
    if (_syncInFlight) {
      throw StateError('正在同步中，请稍候');
    }
    final targetUrl = resolveWebdavFileUrl(webdavUrl);
    _syncInFlight = true;
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final uri = Uri.parse(targetUrl);
      String? remoteBody;
      final getResp = await httpClient
          .get(uri, headers: _webdavHeaders())
          .timeout(const Duration(seconds: 15));
      if (getResp.statusCode >= 200 && getResp.statusCode < 300) {
        if (getResp.bodyBytes.length > maxSyncPayloadBytes) {
          throw const FormatException('远端同步文件超过 8 MB 大小限制');
        }
        remoteBody = utf8.decode(getResp.bodyBytes);
      } else if (getResp.statusCode == 404) {
        remoteBody = null;
      } else if (getResp.statusCode == 401 || getResp.statusCode == 403) {
        throw FormatException(
          'WebDAV 认证失败 (HTTP ${getResp.statusCode})，请检查账号与应用密码',
        );
      } else {
        throw FormatException('WebDAV 读取失败 (HTTP ${getResp.statusCode})');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final merged = await mergeSyncPayload(remoteBody, nowMs: now);
      final encodedPayload = utf8.encode(merged.payloadJson);
      if (encodedPayload.length > maxSyncPayloadBytes) {
        throw const FormatException('本地待同步数据超过 8 MB 大小限制');
      }

      var putResp = await httpClient
          .put(
            uri,
            headers: _webdavHeaders(jsonContent: true),
            body: encodedPayload,
          )
          .timeout(const Duration(seconds: 15));

      if (putResp.statusCode == 404 || putResp.statusCode == 409) {
        await _ensureWebdavCollections(httpClient, uri);
        putResp = await httpClient
            .put(
              uri,
              headers: _webdavHeaders(jsonContent: true),
              body: encodedPayload,
            )
            .timeout(const Duration(seconds: 15));
      }

      if (putResp.statusCode == 401 || putResp.statusCode == 403) {
        throw FormatException('WebDAV 写入被拒绝 (HTTP ${putResp.statusCode})');
      }
      if (putResp.statusCode < 200 || putResp.statusCode >= 300) {
        throw FormatException(_formatWebdavWriteError(putResp.statusCode));
      }

      _lastHistoryAutoPushMs = now;
      await _prefs.setInt(keySyncLastTime, now);
      await _prefs.setString(
        keySyncLastStatus,
        _formatSyncSuccessSummary(
          '同步成功',
          now,
          historyCount: merged.historyCount,
          favoriteCount: merged.favoriteCount,
          subscriptionCount: merged.subscriptionCount,
        ),
      );
      return (
        historyCount: merged.historyCount,
        favoriteCount: merged.favoriteCount,
        subscriptionCount: merged.subscriptionCount,
        changed: merged.changed,
        subscriptionsChanged: merged.subscriptionsChanged,
      );
    } catch (e) {
      await _prefs.setString(keySyncLastStatus, '上次失败：$e');
      rethrow;
    } finally {
      _syncInFlight = false;
      if (ownsClient) httpClient.close();
    }
  }

  Future<
    ({
      int historyCount,
      int favoriteCount,
      int subscriptionCount,
      bool changed,
      bool subscriptionsChanged,
    })
  >
  syncWithLanPeer(String rawLanUrl, {http.Client? client}) async {
    if (_syncInFlight) {
      throw StateError('正在同步中，请稍候');
    }
    final endpoint = resolveLanSyncEndpoint(rawLanUrl);
    _syncInFlight = true;
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final localPayload = exportSyncPayload(nowMs: now);
      final encodedLocal = utf8.encode(localPayload);
      if (encodedLocal.length > maxSyncPayloadBytes) {
        throw const FormatException('本地待同步数据超过 8 MB 大小限制');
      }
      final resp = await httpClient
          .post(
            Uri.parse(endpoint),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: encodedLocal,
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 410) {
        throw const FormatException('对方设备的局域网同步会话已过期，请重新打开');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw FormatException('局域网同步未成功 (HTTP ${resp.statusCode})');
      }
      if (resp.bodyBytes.length > maxSyncPayloadBytes) {
        throw const FormatException('远端同步文件超过 8 MB 大小限制');
      }
      final merged = await mergeSyncPayload(
        utf8.decode(resp.bodyBytes),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _prefs.setInt(keySyncLastTime, now);
      await _prefs.setString(
        keySyncLastStatus,
        _formatSyncSuccessSummary(
          '局域网同步',
          now,
          historyCount: merged.historyCount,
          favoriteCount: merged.favoriteCount,
          subscriptionCount: merged.subscriptionCount,
        ),
      );
      return (
        historyCount: merged.historyCount,
        favoriteCount: merged.favoriteCount,
        subscriptionCount: merged.subscriptionCount,
        changed: merged.changed,
        subscriptionsChanged: merged.subscriptionsChanged,
      );
    } finally {
      _syncInFlight = false;
      if (ownsClient) httpClient.close();
    }
  }
}

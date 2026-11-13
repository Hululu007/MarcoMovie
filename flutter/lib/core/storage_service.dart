import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'catpaw_host.dart';
import 'cms_parser.dart';
import 'csp_bridge.dart';
import 'models.dart';
import 'quark_account.dart';
import 'netdisk_session.dart';
import 'secure_credential_store.dart';
import 'storage_file_store.dart';

export 'storage_file_store.dart';

typedef Pbkdf2ComputeRunner = Future<T> Function<T>(
  FutureOr<T> Function() computation,
);

Future<T> _defaultIsolatePbkdf2Runner<T>(FutureOr<T> Function() computation) =>
    Isolate.run<T>(computation);

/// Persistent preferences and backup serializer compatible with Android `Prefs.java`.
class StorageService {
  static const String syncSchema = 'marco-movie-sync';
  static const int syncVersion = 2;
  static const String defaultSyncFileName = 'marco-movie-sync.json';
  static const int maxSyncTombstones = 300;
  static const int maxSyncPayloadBytes = 8 * 1024 * 1024;
  static const double minPlaySpeed = 0.5;
  static const double maxPlaySpeed = 3.0;
  static const String keyOrigin = 'origin';
  static const String keyRawConfig = 'config_raw_json';
  static const String keySelectedSite = 'selected_site';
  static const String keyPreferredSite = 'preferred_site';
  static const String keyPreferredLine = 'preferred_line';
  static const String keyWatchHistory = 'watch_history';
  static const String keyHistoryCorrupted = 'watch_history_corrupted';
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
  static const String _subscriptionsFileName = 'subscriptions.json';
  static const String _watchHistoryFileName = 'watch_history.json';
  static const List<Duration> _atomicRenameRetryDelays = <Duration>[
    Duration(milliseconds: 20),
    Duration(milliseconds: 50),
    Duration(milliseconds: 100),
  ];

  final SharedPreferences _prefs;
  final Directory? _explicitDataDirectory;
  final StorageFileStore _fileStore;
  @visibleForTesting
  static Directory? debugOverrideDataDirectory;
  static Directory? _cachedProductionDataDir;
  static int _tmpWriteSequence = 0;

  static const String _keyTestDataDir = '_test_storage_data_dir';
  static const String _keyTestStorageNamespace = '_test_storage_namespace';
  static int _nextTestNamespaceId = 0;
  static final Expando<String> _prefsNamespaceFallback = Expando<String>();
  static final Map<String, InMemoryStorageFileStore> _testMemoryFileStores =
      <String, InMemoryStorageFileStore>{};
  static final Map<String, InMemorySecureCredentialStore>
      _testMemorySecureStores = <String, InMemorySecureCredentialStore>{};

  final ValueNotifier<int> watchHistoryRevision = ValueNotifier<int>(0);
  final ValueNotifier<bool> historyCorruptionNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> subscriptionsCorruptionNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> credentialMigrationFailureNotifier =
      ValueNotifier<bool>(false);
  bool _historyCorrupted = false;
  bool get isHistoryCorrupted => _historyCorrupted;
  bool _subscriptionsCorrupted = false;
  bool _subscriptionsCorruptionNoticeConsumed = false;
  bool get isSubscriptionsCorrupted => _subscriptionsCorrupted;
  bool _credentialMigrationNoticeConsumed = false;
  String? _credentialMigrationBackupPath;
  String? get credentialMigrationBackupPath => _credentialMigrationBackupPath;
  @visibleForTesting
  bool get hasCachedSubscriptions => _subscriptionsCache != null;

  /// Consumes the pending one-time UI notice for corrupted subscriptions.
  bool consumeSubscriptionsCorruptionNotice() {
    if (!_subscriptionsCorrupted || _subscriptionsCorruptionNoticeConsumed) {
      return false;
    }
    _subscriptionsCorruptionNoticeConsumed = true;
    return true;
  }

  /// Consumes the pending one-time UI notice when legacy credential decryption failed.
  bool consumeCredentialMigrationFailureNotice() {
    if (!credentialMigrationFailureNotifier.value ||
        _credentialMigrationNoticeConsumed) {
      return false;
    }
    _credentialMigrationNoticeConsumed = true;
    credentialMigrationFailureNotifier.value = false;
    final store = _secureStore;
    if (store is DefaultSecureCredentialStore) {
      store.acknowledgeLegacyMigrationFailure();
    }
    return true;
  }

  /// Explicitly clears subscription write-protection when resetting corrupted state.
  void resetSubscriptionsWriteProtection() {
    _subscriptionsCorrupted = false;
    _subscriptionsCorruptionNoticeConsumed = false;
    subscriptionsCorruptionNotifier.value = false;
  }

  /// Clears subscription write-protection and re-reads `subscriptions.json` from disk.
  /// Returns `true` if subscriptions loaded cleanly, or `false` if still corrupted.
  Future<bool> reloadSubscriptionsFromDisk() =>
      _runSequentialMutation(() async {
        resetSubscriptionsWriteProtection();
        _invalidateConfigCache();
        try {
          await _fileStore.ensureInitialized();
        } on Object catch (e) {
          debugPrint('StorageService: reloadSubscriptionsFromDisk init warning: $e');
        }
        final subs = getSubscriptions();
        if (_subscriptionsCorrupted) {
          return false;
        }
        final public = subs.where((s) => !s.isEffectivelyPrivate).toList();
        if (public.isNotEmpty) {
          await _prefs.setString(keyRawConfig, public.first.rawContent);
          await _prefs.setString(keyOrigin, public.first.url);
          await _prefs.setString(keyActiveDepotName, public.first.activeDepotName);
        }
        _invalidateConfigCache();
        return true;
      });

  final Map<String, ({int intro, int outro, int updated})>
      _privateVideoSkipRecords =
      <String, ({int intro, int outro, int updated})>{};
  Timer? _autoSyncTimer;
  bool _syncInFlight = false;
  bool _resyncRequested = false;
  bool _resyncImmediate = false;
  int _lastHistoryAutoPushMs = 0;
  http.Client? _webdavTestClient;

  static final Set<String> _noConditionalWriteHosts = <String>{};

  @visibleForTesting
  void setWebdavClientForTesting(http.Client? client) {
    _webdavTestClient = client;
  }

  @visibleForTesting
  bool get hasPendingAutoSyncForTesting => _autoSyncTimer?.isActive ?? false;

  @visibleForTesting
  int get lastHistoryAutoPushMsForTesting => _lastHistoryAutoPushMs;
  static final Expando<QuarkAccountProvider> _quarkProviders = Expando();
  static final Expando<Map<String, String>> _credentialCaches = Expando();
  QuarkAccountProvider get quarkAccounts => _quarkProviders[_prefs] ??=
      QuarkAccountProvider(
        readCredential: () => getNetdiskCred('quark'),
        writeCredential: (value) => _writeSecret(keyQuarkCookie, value),
      );
  final SecureCredentialStore _secureStore;
  final Pbkdf2ComputeRunner _pbkdf2Runner;
  Map<String, String> get _credentialCache =>
      _credentialCaches[_prefs] ??= <String, String>{};

  Future<void> _writeSecret(String key, String value) async {
    final hadPrevious = _credentialCache.containsKey(key);
    final previousValue = _credentialCache[key];
    if (value.isEmpty) {
      _credentialCache.remove(key);
    } else {
      _credentialCache[key] = value;
    }
    try {
      if (value.isEmpty) {
        await _secureStore.delete(key);
      } else {
        await _secureStore.write(key, value);
      }
      await _prefs.remove(key);
    } on Object {
      if (hadPrevious && previousValue != null) {
        _credentialCache[key] = previousValue;
      } else {
        _credentialCache.remove(key);
      }
      rethrow;
    }
  }
  @visibleForTesting
  SecureCredentialStore get secureStoreForTesting => _secureStore;
  @visibleForTesting
  StorageFileStore get fileStoreForTesting => _fileStore;
  Future<void> _mutationQueue = Future<void>.value();
  CmsConfig? _cachedConfig;
  Set<String>? _cachedPrivateKeys;
  int _configRevision = 0;
  List<WatchHistoryEntry>? _historyCache;
  List<WatchHistoryEntry>? _allHistoryCache;
  List<SubscriptionEntry>? _subscriptionsCache;

  int _lastHistoryDiskWriteMs = 0;
  bool _historyDirty = false;
  Timer? _historyFlushTimer;

  int get configRevision => _configRevision;
  Directory get dataDirectory =>
      _explicitDataDirectory ??
      debugOverrideDataDirectory ??
      _cachedProductionDataDir ??
      Directory('${Directory.systemTemp.path}/marco_movie_data');

  void _invalidateConfigCache() {
    _cachedConfig = null;
    _cachedPrivateKeys = null;
    _historyCache = null;
    _subscriptionsCache = null;
    _configRevision++;
  }

  static String _resolveOrAssignTestNamespaceSync(SharedPreferences prefs) {
    final saved = prefs.getString(_keyTestStorageNamespace);
    if (saved != null && saved.isNotEmpty) {
      _prefsNamespaceFallback[prefs] = saved;
      return saved;
    }
    final cached = _prefsNamespaceFallback[prefs];
    if (cached != null) return cached;
    final assigned = 'test_ns_${++_nextTestNamespaceId}';
    _prefsNamespaceFallback[prefs] = assigned;
    unawaited(
      prefs.setString(_keyTestStorageNamespace, assigned).catchError((Object e) {
        debugPrint('StorageService: test namespace persist skipped: $e');
        return false;
      }),
    );
    return assigned;
  }

  static Future<String> _ensureTestNamespaceAsync(
    SharedPreferences prefs,
  ) async {
    final saved = prefs.getString(_keyTestStorageNamespace);
    if (saved != null && saved.isNotEmpty) {
      _prefsNamespaceFallback[prefs] = saved;
      return saved;
    }
    final assigned =
        _prefsNamespaceFallback[prefs] ?? 'test_ns_${++_nextTestNamespaceId}';
    _prefsNamespaceFallback[prefs] = assigned;
    try {
      await prefs.setString(_keyTestStorageNamespace, assigned);
    } on Object catch (e) {
      debugPrint('StorageService: test namespace persist skipped: $e');
    }
    return assigned;
  }

  static Directory _resolveFallbackDataDir(SharedPreferences prefs) {
    final saved = prefs.getString(_keyTestDataDir);
    if (saved != null && saved.isNotEmpty) {
      final d = Directory(saved);
      if (!d.existsSync()) {
        try {
          d.createSync(recursive: true);
        } on Object catch (e) {
          debugPrint('StorageService: create fallback dir failed: $e');
        }
      }
      return d;
    }
    final d = Directory.systemTemp.createTempSync('marco_movie_data_');
    unawaited(prefs.setString(_keyTestDataDir, d.path));
    return d;
  }

  static ({
    Directory? dir,
    StorageFileStore fileStore,
    SecureCredentialStore secureStore,
  }) _resolveBackingStores(
    SharedPreferences prefs, {
    Directory? dataDirectory,
    SecureCredentialStore? secureStore,
    StorageFileStore? fileStore,
  }) {
    final explicitDir = dataDirectory ?? debugOverrideDataDirectory;
    final isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');

    if (fileStore != null) {
      final resolvedSecure = secureStore ??
          (explicitDir != null
              ? DefaultSecureCredentialStore(dataDirectory: explicitDir)
              : (isFlutterTest
                  ? _testMemorySecureStores.putIfAbsent(
                      _resolveOrAssignTestNamespaceSync(prefs),
                      InMemorySecureCredentialStore.new,
                    )
                  : DefaultSecureCredentialStore(
                      dataDirectory:
                          _cachedProductionDataDir ?? _resolveFallbackDataDir(prefs),
                    )));
      return (
        dir: explicitDir,
        fileStore: fileStore,
        secureStore: resolvedSecure,
      );
    }

    if (explicitDir == null && isFlutterTest) {
      final ns = _resolveOrAssignTestNamespaceSync(prefs);
      return (
        dir: null,
        fileStore: _testMemoryFileStores.putIfAbsent(
          ns,
          InMemoryStorageFileStore.new,
        ),
        secureStore: secureStore ??
            _testMemorySecureStores.putIfAbsent(
              ns,
              InMemorySecureCredentialStore.new,
            ),
      );
    }

    final resolvedDir =
        explicitDir ?? _cachedProductionDataDir ?? _resolveFallbackDataDir(prefs);
    return (
      dir: resolvedDir,
      fileStore: DiskStorageFileStore(resolvedDir),
      secureStore:
          secureStore ?? DefaultSecureCredentialStore(dataDirectory: resolvedDir),
    );
  }

  StorageService._internal(
    this._prefs, {
    required Directory? explicitDataDirectory,
    required StorageFileStore fileStore,
    required SecureCredentialStore secureStore,
    Pbkdf2ComputeRunner? pbkdf2Runner,
  })  : _explicitDataDirectory = explicitDataDirectory,
        _fileStore = fileStore,
        _secureStore = secureStore,
        _pbkdf2Runner = pbkdf2Runner ?? _defaultIsolatePbkdf2Runner {
    _historyCorrupted = _prefs.getBool(keyHistoryCorrupted) ?? false;
    if (_historyCorrupted) {
      historyCorruptionNotifier.value = true;
    }
  }

  factory StorageService(
    SharedPreferences prefs, {
    Directory? dataDirectory,
    SecureCredentialStore? secureStore,
    StorageFileStore? fileStore,
    Pbkdf2ComputeRunner? pbkdf2Runner,
  }) {
    final resolved = _resolveBackingStores(
      prefs,
      dataDirectory: dataDirectory,
      secureStore: secureStore,
      fileStore: fileStore,
    );
    return StorageService._internal(
      prefs,
      explicitDataDirectory: resolved.dir,
      fileStore: resolved.fileStore,
      secureStore: resolved.secureStore,
      pbkdf2Runner: pbkdf2Runner,
    );
  }

  Future<void> _atomicWriteFile(String fileName, String content) async {
    await _fileStore.ensureInitialized();
    final seq = ++_tmpWriteSequence;
    final tmpFileName =
        '$fileName.${DateTime.now().microsecondsSinceEpoch}_$seq.tmp';
    await _fileStore.writeStringAndFlush(tmpFileName, content);
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= _atomicRenameRetryDelays.length; attempt++) {
      try {
        await _fileStore.rename(tmpFileName, fileName);
        return;
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        if (attempt < _atomicRenameRetryDelays.length) {
          await Future<void>.delayed(_atomicRenameRetryDelays[attempt]);
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  Future<void> _initializeStorage() async {
    try {
      await _fileStore.ensureInitialized();
    } on Object catch (e) {
      debugPrint('StorageService: ensureInitialized warning: $e');
    }
    await _cleanupLeftoverTempFiles();
    await _migrateCredentialsIfNeeded();
    await _migrateFromPrefsIfNeeded();
    getSubscriptions();
  }

  Future<void> _cleanupLeftoverTempFiles() async {
    try {
      final names = _fileStore.listFileNamesSync();
      for (final name in names) {
        if (!name.endsWith('.tmp')) continue;
        if (name.startsWith('$_subscriptionsFileName.') ||
            name.startsWith('$_watchHistoryFileName.') ||
            name.startsWith('${DefaultSecureCredentialStore.legacyFileName}.')) {
          try {
            await _fileStore.deleteFile(name);
          } on Object catch (e) {
            debugPrint('StorageService: cleanup temp file $name failed: $e');
          }
        }
      }
    } on Object catch (e) {
      debugPrint('StorageService: scan leftover temp files failed: $e');
    }
  }

  Future<void> _migrateCredentialsIfNeeded() async {
    final store = _secureStore;
    if (store is DefaultSecureCredentialStore) {
      try {
        await store.ensureInitialized();
      } on Object catch (e) {
        debugPrint('StorageService: ensureInitialized secure store failed: $e');
      }
    }
    for (final key in [
      keyWebdavPass,
      keyQuarkCookie,
      keyUcCookie,
      keyBaiduCookie,
      keyAliToken,
    ]) {
      if (_prefs.containsKey(key)) {
        final plain = _prefs.getString(key) ?? '';
        _credentialCache[key] = plain;
        try {
          if (plain.isNotEmpty) {
            await _secureStore.write(key, plain);
          }
          await _prefs.remove(key);
        } on Object catch (e) {
          debugPrint('StorageService: migrate pref $key to secure store failed: $e');
        }
      } else {
        try {
          final secVal = await _secureStore.read(key);
          if (secVal != null && secVal.isNotEmpty) {
            _credentialCache[key] = secVal;
          }
        } on Object catch (e) {
          debugPrint('StorageService: read $key from secure store failed: $e');
        }
      }
    }
    if (store is DefaultSecureCredentialStore && store.didLegacyMigrationFail) {
      _credentialMigrationBackupPath = store.legacyBackupPath;
      _credentialMigrationNoticeConsumed = false;
      credentialMigrationFailureNotifier.value = true;
    }
  }

  bool get _hasAuthoritativeSubscriptions =>
      getSubscriptions().isNotEmpty ||
      _fileStore.existsSync(_subscriptionsFileName) ||
      _prefs.containsKey(keySubscriptions);

  Future<void> _migrateFromPrefsIfNeeded() async {
    // 1. Subscriptions migration: ONLY when subscriptions.json does not exist yet (M-F3).
    // Keep saved_subscriptions mirror in prefs for safe downgrade compatibility.
    if (!await _fileStore.exists(_subscriptionsFileName) &&
        _prefs.containsKey(keySubscriptions)) {
      final raw = _prefs.getString(keySubscriptions);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            await _atomicWriteFile(_subscriptionsFileName, raw);
          }
        } on Object catch (e) {
          debugPrint('StorageService: skip malformed subscriptions migration: $e');
        }
      }
    }

    // 2. Watch history migration: ONLY when watch_history.json does not exist yet (M-F3).
    // Keep watch_history mirror in prefs for safe downgrade compatibility.
    if (!await _fileStore.exists(_watchHistoryFileName) &&
        _prefs.containsKey(keyWatchHistory)) {
      final raw = _prefs.getString(keyWatchHistory);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            await _atomicWriteFile(_watchHistoryFileName, raw);
          }
        } on Object catch (e) {
          // Leave corrupt prefs unmigrated so getWatchHistory() detects and backs it up.
          debugPrint('StorageService: skip malformed watch_history migration: $e');
        }
      }
    }
  }

  Future<T> _runSequentialMutation<T>(Future<T> Function() mutation) {
    final next = _mutationQueue.then((_) async {
      return await mutation();
    });
    _mutationQueue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<T> _editSubscriptions<T>(Future<T> Function() edit) {
    return _runSequentialMutation(() async {
      _invalidateConfigCache();
      final res = await edit();
      _invalidateConfigCache();
      return res;
    });
  }

  static Future<Directory> resolveDataDirectory({
    Directory? overrideDir,
    SharedPreferences? prefs,
  }) async {
    if (overrideDir != null) return overrideDir;
    if (debugOverrideDataDirectory != null) return debugOverrideDataDirectory!;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      if (prefs != null) {
        return _resolveFallbackDataDir(prefs);
      }
      return Directory('${Directory.systemTemp.path}/marco_movie_data');
    }
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/data');
      _cachedProductionDataDir = dir;
      return dir;
    } on Object catch (e) {
      debugPrint('StorageService: getApplicationSupportDirectory fallback: $e');
      if (prefs != null) {
        return _resolveFallbackDataDir(prefs);
      }
      return Directory('${Directory.systemTemp.path}/marco_movie_data');
    }
  }

  static Future<StorageService> init({
    Directory? dataDirectory,
    SecureCredentialStore? secureStore,
    StorageFileStore? fileStore,
    Pbkdf2ComputeRunner? pbkdf2Runner,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final explicitDir = dataDirectory ?? debugOverrideDataDirectory;
    final isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');

    if (fileStore == null && explicitDir == null && isFlutterTest) {
      final ns = await _ensureTestNamespaceAsync(prefs);
      final service = StorageService._internal(
        prefs,
        explicitDataDirectory: null,
        fileStore: _testMemoryFileStores.putIfAbsent(
          ns,
          InMemoryStorageFileStore.new,
        ),
        secureStore: secureStore ??
            _testMemorySecureStores.putIfAbsent(
              ns,
              InMemorySecureCredentialStore.new,
            ),
        pbkdf2Runner: pbkdf2Runner,
      );
      await service._initializeStorage();
      return service;
    }

    final dir = fileStore != null && explicitDir == null && isFlutterTest
        ? null
        : await resolveDataDirectory(overrideDir: dataDirectory, prefs: prefs);
    final service = StorageService(
      prefs,
      dataDirectory: dir,
      secureStore: secureStore,
      fileStore: fileStore,
      pbkdf2Runner: pbkdf2Runner,
    );
    await service._initializeStorage();
    return service;
  }
  String get configOrigin => _prefs.getString(keyOrigin) ?? '';
  String get rawConfig => _prefs.getString(keyRawConfig) ?? '';
  String get selectedSiteKey => _prefs.getString(keySelectedSite) ?? '';
  String get activeDepotName => _prefs.getString(keyActiveDepotName) ?? '';
  bool get episodesDescending => _prefs.getBool(keyEpisodesDescending) ?? false;
  double get playSpeed =>
      (_prefs.getDouble(keyPlaySpeed) ?? 1.0).clamp(minPlaySpeed, maxPlaySpeed);
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
  String get quarkCookie =>
      _credentialCache[keyQuarkCookie] ?? _prefs.getString(keyQuarkCookie) ?? '';
  String get ucCookie =>
      _credentialCache[keyUcCookie] ?? _prefs.getString(keyUcCookie) ?? '';
  String get baiduCookie =>
      _credentialCache[keyBaiduCookie] ?? _prefs.getString(keyBaiduCookie) ?? '';
  String get aliToken =>
      _credentialCache[keyAliToken] ?? _prefs.getString(keyAliToken) ?? '';
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
    } on Object catch (e) {
      debugPrint('StorageService: getSavedDepots parse failed: $e');
      return const [];
    }
  }
  static final RegExp _pbkdf2PinPattern =
      RegExp(r'^pbkdf2:sha256:(?:(\d+):)?(\d+):([0-9a-fA-F]{32}):([0-9a-fA-F]{64})$');
  static final RegExp _legacySha256PinPattern =
      RegExp(r'^sha256:(\d+):([0-9a-fA-F]{64})$');
  static String _legacyHashPin(String pin) =>
      sha256.convert(utf8.encode('mm_pin_v1:$pin')).toString();

  static Uint8List pbkdf2Sha256(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    final hmac = Hmac(sha256, password);
    final s1 = Uint8List(salt.length + 4);
    s1.setRange(0, salt.length, salt);
    s1[salt.length] = 0;
    s1[salt.length + 1] = 0;
    s1[salt.length + 2] = 0;
    s1[salt.length + 3] = 1;

    var u = Uint8List.fromList(hmac.convert(s1).bytes);
    final result = Uint8List.fromList(u);

    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return result.sublist(0, keyLength);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _hexDecode(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static String _hexEncode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get privacyPassword => _prefs.getString(keyPrivacyPassword) ?? '';
  bool get hasPrivacyPassword => privacyPassword.trim().isNotEmpty;
  int get privacyPasswordLength {
    final saved = privacyPassword.trim();
    final pbMatch = _pbkdf2PinPattern.firstMatch(saved);
    if (pbMatch != null) {
      final lenStr = pbMatch.group(1);
      if (lenStr != null && lenStr.isNotEmpty) {
        return (int.tryParse(lenStr) ?? 4).clamp(4, 8);
      }
      return 4;
    }
    final match = _legacySha256PinPattern.firstMatch(saved);
    if (match != null) {
      return (int.tryParse(match.group(1)!) ?? 4).clamp(4, 8);
    }
    return saved.length.clamp(4, 8);
  }
  bool get hasPrivacyConfigured =>
      hasPrivacyPassword ||
      getSubscriptions().any((s) => s.isEffectivelyPrivate);

  static bool _verifyPbkdf2InIsolate(
    Uint8List passwordBytes,
    Uint8List saltBytes,
    int iterations,
    Uint8List expectedHash,
  ) {
    final derived = pbkdf2Sha256(passwordBytes, saltBytes, iterations, 32);
    return _constantTimeEquals(derived, expectedHash);
  }

  static String _deriveFormattedPinInIsolate(
    String trimmedPin,
    Uint8List salt,
  ) {
    const iterations = 100000;
    final derived = pbkdf2Sha256(utf8.encode(trimmedPin), salt, iterations, 32);
    final saltHex = _hexEncode(salt);
    final hashHex = _hexEncode(derived);
    return 'pbkdf2:sha256:${trimmedPin.length}:$iterations:$saltHex:$hashHex';
  }

  static Uint8List _generatePinSalt() {
    final rand = Random.secure();
    final salt = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      salt[i] = rand.nextInt(256);
    }
    return salt;
  }

  Future<bool> verifyPrivacyPassword(String input) async {
    final trimmed = input.trim();
    final saved = privacyPassword.trim();
    if (saved.isEmpty || trimmed.isEmpty) return false;
    final runner = _pbkdf2Runner;

    final pbMatch = _pbkdf2PinPattern.firstMatch(saved);
    if (pbMatch != null) {
      final lenStr = pbMatch.group(1);
      if (lenStr != null && lenStr.isNotEmpty) {
        final expectedLen = int.tryParse(lenStr) ?? 0;
        if (trimmed.length != expectedLen) return false;
      }
      final iterations = int.tryParse(pbMatch.group(2)!) ?? 0;
      if (iterations < 100000 || iterations > 1000000) {
        return false;
      }
      final pwdBytes = Uint8List.fromList(utf8.encode(trimmed));
      final saltBytes = _hexDecode(pbMatch.group(3)!);
      final expectedBytes = _hexDecode(pbMatch.group(4)!);
      return runner(
        () => _verifyPbkdf2InIsolate(
          pwdBytes,
          saltBytes,
          iterations,
          expectedBytes,
        ),
      );
    }

    final match = _legacySha256PinPattern.firstMatch(saved);
    if (match != null) {
      final expectedLen = int.tryParse(match.group(1)!) ?? 0;
      final legacyHash = match.group(2)!;
      if (trimmed.length == expectedLen &&
          _constantTimeEquals(
            utf8.encode(_legacyHashPin(trimmed)),
            utf8.encode(legacyHash),
          )) {
        final salt = _generatePinSalt();
        final upgraded = await runner(
          () => _deriveFormattedPinInIsolate(trimmed, salt),
        );
        await _prefs.setString(keyPrivacyPassword, upgraded);
        return true;
      }
      return false;
    }

    if (saved.startsWith('pbkdf2:') ||
        saved.startsWith('sha256:') ||
        saved.contains(':')) {
      return false;
    }

    if (_constantTimeEquals(utf8.encode(trimmed), utf8.encode(saved))) {
      final salt = _generatePinSalt();
      final upgraded = await runner(
        () => _deriveFormattedPinInIsolate(trimmed, salt),
      );
      await _prefs.setString(keyPrivacyPassword, upgraded);
      return true;
    }
    return false;
  }

  Future<void> setPrivacyPassword(String password) async {
    final trimmed = password.trim();
    if (trimmed.isEmpty) {
      await _prefs.setString(keyPrivacyPassword, '');
      return;
    }
    final salt = _generatePinSalt();
    final runner = _pbkdf2Runner;
    final formatted = await runner(
      () => _deriveFormattedPinInIsolate(trimmed, salt),
    );
    await _prefs.setString(keyPrivacyPassword, formatted);
  }

  void _handleSubscriptionsCorruption({
    List<int>? rawBytes,
    String? rawCorruptString,
    Object? error,
  }) {
    final alreadyCorrupted = _subscriptionsCorrupted;
    _subscriptionsCorrupted = true;
    subscriptionsCorruptionNotifier.value = true;
    if (alreadyCorrupted) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    List<int>? bytesToQuarantine = rawBytes;
    if (bytesToQuarantine == null &&
        rawCorruptString != null &&
        rawCorruptString.isNotEmpty) {
      bytesToQuarantine = utf8.encode(rawCorruptString);
    }
    if (bytesToQuarantine == null &&
        _fileStore.existsSync(_subscriptionsFileName)) {
      try {
        bytesToQuarantine = _fileStore.readBytesSync(_subscriptionsFileName);
      } on Object catch (e) {
        debugPrint('StorageService: read corrupt subscriptions bytes failed: $e');
      }
    }
    bytesToQuarantine ??= utf8.encode(
      jsonEncode({
        'quarantinedAt': ts,
        'reason': 'read_or_parse_failure',
        'error': error?.toString() ?? 'unknown',
      }),
    );
    try {
      final alreadyQuarantinedSame = _fileStore
          .listFileNamesSync()
          .where((name) =>
              name.startsWith('subscriptions_corrupt_') &&
              name.endsWith('.json'))
          .any((name) {
        try {
          final existing = _fileStore.readBytesSync(name);
          return listEquals(existing, bytesToQuarantine);
        } on Object catch (e) {
          debugPrint('StorageService: inspect quarantine $name failed: $e');
          return false;
        }
      });
      if (!alreadyQuarantinedSame) {
        _fileStore.writeBytesSync(
          'subscriptions_corrupt_$ts.json',
          bytesToQuarantine,
        );
      }
    } on Object catch (e) {
      debugPrint('StorageService: quarantine subscriptions failed: $e');
    }
  }

  List<SubscriptionEntry> getSubscriptions() {
    if (_subscriptionsCache != null) return _subscriptionsCache!;
    if (_subscriptionsCorrupted) {
      // Never cache an empty list when subscriptions are write-protected.
      return const [];
    }
    if (_fileStore.existsSync(_subscriptionsFileName)) {
      List<int>? rawBytes;
      try {
        rawBytes = _fileStore.readBytesSync(_subscriptionsFileName);
        if (rawBytes.isEmpty) {
          throw const FormatException('subscriptions.json is empty');
        }
        final content = utf8.decode(rawBytes);
        final trimmed = content.trim();
        if (trimmed.isEmpty) {
          throw const FormatException('subscriptions.json is blank');
        }
        final list = jsonDecode(trimmed);
        if (list is! List) {
          throw const FormatException('subscriptions.json root is not a JSON array');
        }
        final entries = <SubscriptionEntry>[];
        for (final item in list) {
          if (item is! Map) {
            throw const FormatException('subscriptions.json element is not an object');
          }
          final entry = SubscriptionEntry.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (entry.id.isNotEmpty) {
            entries.add(entry);
          }
        }
        final unmodifiable = List<SubscriptionEntry>.unmodifiable(entries);
        _subscriptionsCache = unmodifiable;
        return unmodifiable;
      } on Object catch (e) {
        debugPrint('StorageService: getSubscriptions read/parse failed: $e');
        _handleSubscriptionsCorruption(rawBytes: rawBytes, error: e);
        return const [];
      }
    }
    if (!_prefs.containsKey(keySubscriptions)) {
      _subscriptionsCache = const [];
      return const [];
    }
    final raw = _prefs.getString(keySubscriptions) ?? '';
    if (raw.trim().isEmpty) {
      _subscriptionsCache = const [];
      return const [];
    }
    try {
      final list = jsonDecode(raw);
      if (list is! List) {
        throw const FormatException('saved_subscriptions is not a JSON array');
      }
      final entries = <SubscriptionEntry>[];
      for (final item in list) {
        if (item is! Map) {
          throw const FormatException('saved_subscriptions element is not an object');
        }
        final entry = SubscriptionEntry.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (entry.id.isNotEmpty) {
          entries.add(entry);
        }
      }
      final unmodifiable = List<SubscriptionEntry>.unmodifiable(entries);
      _subscriptionsCache = unmodifiable;
      return unmodifiable;
    } on Object catch (e) {
      debugPrint('StorageService: saved_subscriptions prefs parse failed: $e');
      _handleSubscriptionsCorruption(rawCorruptString: raw, error: e);
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
    if (!_subscriptionsCorrupted &&
        _subscriptionsCache == null &&
        _fileStore.existsSync(_subscriptionsFileName)) {
      getSubscriptions();
    }
    if (_subscriptionsCorrupted) {
      throw StateError(
        '本地订阅文件读取或解析异常，已开启写保护（已隔离至 subscriptions_corrupt_*），拒绝覆盖保存',
      );
    }
    final hadPreviousFile = _fileStore.existsSync(_subscriptionsFileName);
    List<int>? previousBytes;
    if (hadPreviousFile) {
      try {
        previousBytes = _fileStore.readBytesSync(_subscriptionsFileName);
      } on Object catch (e) {
        _handleSubscriptionsCorruption(error: e);
        throw StateError(
          '本地订阅文件读取异常，已开启写保护（已隔离至 subscriptions_corrupt_*），拒绝覆盖保存',
        );
      }
    }

    _invalidateConfigCache();
    final jsonStr = jsonEncode(subs.map((s) => s.toJson()).toList());
    try {
      await _atomicWriteFile(_subscriptionsFileName, jsonStr);
    } on Object catch (e) {
      debugPrint('StorageService: saveSubscriptions file write failed: $e');
      _invalidateConfigCache();
      rethrow;
    }

    // Update prefs mirror ONLY after the file write succeeds (B8 + M-F3).
    try {
      final ok = await _prefs.setString(keySubscriptions, jsonStr);
      if (!ok) {
        throw StateError('Failed to save subscriptions');
      }
    } on Object catch (e) {
      debugPrint('StorageService: saveSubscriptions prefs mirror failed: $e');
      try {
        if (hadPreviousFile && previousBytes != null) {
          await _atomicWriteFile(
            _subscriptionsFileName,
            utf8.decode(previousBytes),
          );
        } else if (!hadPreviousFile) {
          await _fileStore.deleteFile(_subscriptionsFileName);
        }
      } on Object catch (rollbackError) {
        debugPrint('StorageService: rollback subscriptions file failed: $rollbackError');
      }
      _invalidateConfigCache();
      await _prefs.reload();
      if (e is StateError) rethrow;
      throw StateError('Failed to save subscriptions: $e');
    }

    _subscriptionsCache = List<SubscriptionEntry>.unmodifiable(subs);
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
    _invalidateConfigCache();
    final current = getSubscriptions().toList();
    // Migrate legacy single config into subscriptions list if not yet present
    if (getSubscriptions().isEmpty && !_hasAuthoritativeSubscriptions && rawConfig.trim().isNotEmpty) {
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
      } on Object catch (e) {
        debugPrint('StorageService: legacy config synthesis skipped: $e');
      }
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
        !merged.availableSites.any((s) => s.key == selectedSiteKey)) {
      final availPublic = merged.publicAvailableSites;
      if (availPublic.isNotEmpty) {
        final preferredDefault = availPublic.firstWhere(
          (s) => !CspBridge.isBannerNoticeSite(s),
          orElse: () => availPublic.first,
        );
        await _prefs.setString(
          keySelectedSite,
          preferredDefault.key,
        );
      } else if (merged.sites.any((s) => s.key == selectedSiteKey)) {
        await _prefs.setString(keySelectedSite, '');
      }
    }
    return merged;
  }

  Future<CmsConfig?> removeSubscription(String id) =>
      _editSubscriptions(() => _removeSubscription(id));

  Future<CmsConfig?> deleteSubscription(String id) => removeSubscription(id);

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
    _invalidateConfigCache();
    final config = loadSavedConfig();
    final availPublic = config?.publicAvailableSites ?? const <CmsSite>[];
    if (!availPublic.any((s) => s.key == selectedSiteKey)) {
      final fallbackSite = availPublic.isEmpty
          ? null
          : availPublic.firstWhere(
              (s) => !CspBridge.isBannerNoticeSite(s),
              orElse: () => availPublic.first,
            );
      await _prefs.setString(keySelectedSite, fallbackSite?.key ?? '');
    }
    if (!availPublic.any((s) => s.key == (_prefs.getString(keyPreferredSite) ?? ''))) {
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
    try {
      return Map<String, String>.from(
        jsonDecode(_prefs.getString(_siteAliases) ?? '{}') as Map,
      );
    } on Object catch (e) {
      debugPrint('StorageService: _savedAliases parse failed: $e');
      return {};
    }
  }

  Future<void> savePickerEdits(List<CmsSite> ordered, List<CmsSite> removed) => _editSubscriptions(() async {
    _invalidateConfigCache();
    final oldOrder = _prefs.getStringList(_siteOrder) ?? [];
    final ids = ordered.map(_siteIdentity).toList();
    final hidden = {...?_prefs.getStringList(_removedSites), ...removed.map(_siteIdentity)};
    try {
      final orderSaved = await _prefs.setStringList(_siteOrder, [...ids, ...oldOrder.where((id) => !ids.contains(id))]);
      if (!orderSaved) throw StateError('线路顺序未能保存，请重试');
      final removalSaved = await _prefs.setStringList(_removedSites, hidden.toList());
      if (!removalSaved) throw StateError('线路删除未能保存，请重试');
      _invalidateConfigCache();
    } on Object catch (e) {
      debugPrint('StorageService: savePickerEdits failed: $e');
      _invalidateConfigCache();
      await _prefs.reload();
      rethrow;
    }
  });

  Future<void> reorderSites(List<String> order) => _editSubscriptions(() async {
    _invalidateConfigCache();
    await _prefs.setStringList(_siteOrder, order);
  });

  Future<void> hideSite(String siteIdentity) => _editSubscriptions(() async {
    _invalidateConfigCache();
    final hidden = {...?_prefs.getStringList(_removedSites), siteIdentity};
    await _prefs.setStringList(_removedSites, hidden.toList());
  });

  Future<void> removeSite(String siteIdentity) => hideSite(siteIdentity);

  Future<void> restoreSite(String siteIdentity) => _editSubscriptions(() async {
    _invalidateConfigCache();
    final hidden = (_prefs.getStringList(_removedSites) ?? []).where((id) => id != siteIdentity).toList();
    await _prefs.setStringList(_removedSites, hidden);
  });

  Future<void> resetRemovedSites() => _editSubscriptions(() async {
    _invalidateConfigCache();
    await _prefs.remove(_removedSites);
  });

  CmsConfig? loadSavedConfig() {
    if (_cachedConfig != null) return _cachedConfig;
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
    final result = CmsConfig(
      sites: [...sites, ...byId.values],
      lives: config.lives,
      depots: config.depots,
      parses: config.parses,
      spider: config.spider,
    );
    _cachedConfig = result;
    return result;
  }

  CmsConfig? _loadImportedConfig() {
    final subs = getSubscriptions().where((s) => s.enabled).toList();
    final savedDepots = getSavedDepots();
    final aliases = _savedAliases();
    if (_hasAuthoritativeSubscriptions) {
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
        } on Object catch (e) {
          debugPrint('StorageService: skip malformed subscription ${sub.id}: $e');
        }
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
    } on Object catch (e) {
      debugPrint('StorageService: parse legacy rawConfig failed: $e');
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
    _invalidateConfigCache();
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
    final availableVisible =
        isPrivate ? merged.availableSites : merged.publicAvailableSites;
    if (!availableVisible.any((s) => s.key == selectedSiteKey)) {
      if (availableVisible.isNotEmpty) {
        final fallbackSite = availableVisible.firstWhere(
          (s) => !CspBridge.isBannerNoticeSite(s),
          orElse: () => availableVisible.first,
        );
        await _prefs.setString(keySelectedSite, fallbackSite.key);
      } else if (merged.sites.any((s) => s.key == selectedSiteKey)) {
        await _prefs.setString(keySelectedSite, '');
      }
    }
    return merged;
  }
  String get preferredSiteKey {
    final key = _prefs.getString(keyPreferredSite) ?? '';
    return (loadSavedConfig()?.publicAvailableSites ?? const <CmsSite>[])
        .any((s) => s.key == key) ? key : '';
  }
  String get preferredLineName => _prefs.getString(keyPreferredLine) ?? '';
  Future<void> setPreferredSiteKey(String key) async {
    if (key.isNotEmpty && !(loadSavedConfig()?.publicAvailableSites ?? const <CmsSite>[])
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
    await _prefs.setDouble(
      keyPlaySpeed,
      speed.clamp(minPlaySpeed, maxPlaySpeed),
    );
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
    } on Object catch (e) {
      debugPrint('StorageService: _readPublicVideoSkipRecords parse failed: $e');
    }
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
        await _writeSecret(keyQuarkCookie, trimmed);
        break;
      case 'uc':
        await _writeSecret(keyUcCookie, trimmed);
        break;
      case 'baidu':
        await _writeSecret(keyBaiduCookie, trimmed);
        break;
      case 'ali':
        await _writeSecret(keyAliToken, trimmed);
        break;
    }
    unawaited(CatPawHost.instance.syncNetdiskConfig());
  }
  Future<void> setDriveOrder(List<String> order) async {
    await _prefs.setStringList(keyDriveOrder, order);
  }
  Set<String> _privateSiteKeySet() {
    if (_cachedPrivateKeys != null) return _cachedPrivateKeys!;
    final cfg = loadSavedConfig();
    if (cfg == null) {
      _cachedPrivateKeys = const <String>{};
      return _cachedPrivateKeys!;
    }
    final keys = <String>{
      for (final s in cfg.sites)
        if (s.isEffectivelyPrivate) s.key,
    };
    _cachedPrivateKeys = keys;
    return keys;
  }
  void _handleHistoryCorruption(String? rawCorruptString, {List<int>? rawBytes}) {
    final alreadyCorrupted = _historyCorrupted;
    _historyCorrupted = true;
    historyCorruptionNotifier.value = true;
    unawaited(_prefs.setBool(keyHistoryCorrupted, true));
    if (alreadyCorrupted) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    if (rawCorruptString != null && rawCorruptString.isNotEmpty) {
      unawaited(_prefs.setString('watch_history_corrupt_$ts', rawCorruptString));
    }
    try {
      List<int>? bytesToQuarantine = rawBytes;
      if (bytesToQuarantine == null &&
          _fileStore.existsSync(_watchHistoryFileName)) {
        try {
          bytesToQuarantine = _fileStore.readBytesSync(_watchHistoryFileName);
        } on Object catch (e) {
          debugPrint('StorageService: read corrupt watch_history bytes failed: $e');
        }
      }
      if (bytesToQuarantine != null && bytesToQuarantine.isNotEmpty) {
        _fileStore.writeBytesSync(
          'watch_history_corrupt_$ts.json',
          bytesToQuarantine,
        );
      } else if (rawCorruptString != null && rawCorruptString.isNotEmpty) {
        _fileStore.writeBytesSync(
          'watch_history_corrupt_$ts.json',
          utf8.encode(rawCorruptString),
        );
      }
    } on Object catch (e) {
      debugPrint('StorageService: quarantine watch_history failed: $e');
    }
  }

  List<WatchHistoryEntry> _readRawWatchHistory() {
    if (_allHistoryCache != null) return _allHistoryCache!;
    if (_historyCorrupted) {
      _allHistoryCache = const [];
      return const [];
    }
    if (_fileStore.existsSync(_watchHistoryFileName)) {
      List<int>? rawBytes;
      try {
        rawBytes = _fileStore.readBytesSync(_watchHistoryFileName);
        if (rawBytes.isEmpty) {
          _allHistoryCache = const [];
          return const [];
        }
        final content = utf8.decode(rawBytes);
        if (content.trim().isEmpty || content.trim() == '[]') {
          _allHistoryCache = const [];
          return const [];
        }
        final decoded = jsonDecode(content);
        if (decoded is! List) {
          throw const FormatException('watch_history is not a JSON array');
        }
        final entries = decoded
            .whereType<Map>()
            .map((m) => WatchHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
            .where((e) => e.site.isNotEmpty && e.id.isNotEmpty)
            .toList();
        _allHistoryCache = entries;
        return entries;
      } on Object catch (e) {
        debugPrint('StorageService: _readRawWatchHistory file failed: $e');
        String? rawString;
        try {
          rawBytes ??= _fileStore.existsSync(_watchHistoryFileName)
              ? _fileStore.readBytesSync(_watchHistoryFileName)
              : null;
          if (rawBytes != null && rawBytes.isNotEmpty) {
            rawString = utf8.decode(rawBytes, allowMalformed: true);
          }
        } on Object catch (innerError) {
          debugPrint('StorageService: fallback watch_history inspect failed: $innerError');
        }
        _handleHistoryCorruption(rawString, rawBytes: rawBytes);
        _allHistoryCache = const [];
        return const [];
      }
    }
    final raw = _prefs.getString(keyWatchHistory);
    if (raw == null || raw.trim().isEmpty || raw.trim() == '[]') {
      _allHistoryCache = const [];
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('watch_history is not a JSON array');
      }
      final entries = decoded
          .whereType<Map>()
          .map((m) => WatchHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((e) => e.site.isNotEmpty && e.id.isNotEmpty)
          .toList();
      _allHistoryCache = entries;
      return entries;
    } on Object catch (e) {
      debugPrint('StorageService: _readRawWatchHistory prefs failed: $e');
      _handleHistoryCorruption(raw);
      _allHistoryCache = const [];
      return const [];
    }
  }

  List<WatchHistoryEntry> getWatchHistory({bool forPrivate = false}) {
    if (!forPrivate && _historyCache != null) return _historyCache!;
    final rawList = _readRawWatchHistory();
    final privKeys = _privateSiteKeySet();
    final result = rawList
        .where((e) => forPrivate ? true : !privKeys.contains(e.site))
        .toList(growable: false);
    if (!forPrivate) {
      _historyCache = result;
    }
    return result;
  }

  Future<void> _flushHistoryToDisk() async {
    if (_historyCorrupted) return;
    final list = _allHistoryCache ?? _readRawWatchHistory();
    final jsonStr = jsonEncode(list.map((e) => e.toJson()).toList());
    await _atomicWriteFile(_watchHistoryFileName, jsonStr);
    // Keep watch_history mirror in prefs after file write succeeds (M-F3).
    await _prefs.setString(keyWatchHistory, jsonStr);
  }

  Future<void> _handleHistoryPersistence({
    required bool immediate,
    required bool isPrivate,
    bool triggerSync = true,
    bool? syncImmediate,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final effectiveSyncImmediate = syncImmediate ?? immediate;
    if (immediate) {
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      await _flushHistoryToDisk();
      _lastHistoryDiskWriteMs = now;
      _historyDirty = false;
      if (!isPrivate && triggerSync) {
        scheduleAutoWebdavSync(immediate: effectiveSyncImmediate, nowMs: now);
      }
      return;
    }

    if (now - _lastHistoryDiskWriteMs >= 30000) {
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      await _flushHistoryToDisk();
      _lastHistoryDiskWriteMs = now;
      _historyDirty = false;
      if (!isPrivate && triggerSync) {
        scheduleAutoWebdavSync(immediate: effectiveSyncImmediate, nowMs: now);
      }
    } else {
      _historyDirty = true;
      if (_historyFlushTimer == null || !_historyFlushTimer!.isActive) {
        final remainingMs = 30000 - (now - _lastHistoryDiskWriteMs);
        _historyFlushTimer = Timer(Duration(milliseconds: remainingMs), () {
          _runSequentialMutation(() async {
            if (_historyDirty) {
              await _flushHistoryToDisk();
              _lastHistoryDiskWriteMs = DateTime.now().millisecondsSinceEpoch;
              _historyDirty = false;
              if (!isPrivate && triggerSync) {
                scheduleAutoWebdavSync();
              }
            }
          });
        });
      }
    }
  }

  void cancelPendingHistoryFlush() {
    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
  }

  Future<void> flushPendingHistory() {
    _historyFlushTimer?.cancel();
    _historyFlushTimer = null;
    return _runSequentialMutation(() async {
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      if (_historyDirty) {
        await _flushHistoryToDisk();
        _lastHistoryDiskWriteMs = DateTime.now().millisecondsSinceEpoch;
        _historyDirty = false;
      }
    });
  }

  Future<void> upsertWatchHistory(
    WatchHistoryEntry entry, {
    bool immediate = false,
    bool triggerSync = true,
    bool? syncImmediate,
  }) {
    return _runSequentialMutation(() async {
      if (_historyCorrupted) {
        return;
      }
      final privKeys = _privateSiteKeySet();
      final allRaw = _allHistoryCache ?? _readRawWatchHistory();
      final localPrivate =
          allRaw.where((e) => privKeys.contains(e.site)).toList();
      final localPublic =
          allRaw.where((e) => !privKeys.contains(e.site)).toList();

      final bool isPrivateEntry = privKeys.contains(entry.site);
      if (isPrivateEntry) {
        final updatedPrivate = CmsParser.upsertHistory(localPrivate, entry);
        final combined = [...localPublic, ...updatedPrivate]
          ..sort((a, b) => b.updated.compareTo(a.updated));
        if (combined.length > CmsParser.maxHistoryEntries) {
          combined.removeRange(CmsParser.maxHistoryEntries, combined.length);
        }
        _allHistoryCache = combined;
        watchHistoryRevision.value++;
        await _handleHistoryPersistence(
          immediate: immediate,
          isPrivate: true,
          triggerSync: triggerSync,
          syncImmediate: syncImmediate,
        );
        return;
      }

      final updatedPublic = CmsParser.upsertHistory(localPublic, entry);
      final combined = [...updatedPublic, ...localPrivate]
        ..sort((a, b) => b.updated.compareTo(a.updated));
      if (combined.length > CmsParser.maxHistoryEntries) {
        combined.removeRange(CmsParser.maxHistoryEntries, combined.length);
      }
      _allHistoryCache = combined;
      _historyCache = List.unmodifiable(updatedPublic);
      watchHistoryRevision.value++;
      await _handleHistoryPersistence(
        immediate: immediate,
        isPrivate: false,
        triggerSync: triggerSync,
        syncImmediate: syncImmediate,
      );
    });
  }

  Future<void> removeWatchHistoryItem(String siteKey, String videoId) {
    return _runSequentialMutation(() async {
      if (_historyCorrupted) return;
      final targetKey = '$siteKey\n$videoId';
      final allRaw = _allHistoryCache ?? _readRawWatchHistory();
      final updated =
          allRaw.where((e) => e.key != targetKey).toList(growable: false);
      _historyCache = null;
      _allHistoryCache = updated;
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      _historyDirty = false;
      await _flushHistoryToDisk();
      _lastHistoryDiskWriteMs = DateTime.now().millisecondsSinceEpoch;
      watchHistoryRevision.value++;
      await _recordSyncTombstone(
        'hist:$targetKey',
        DateTime.now().millisecondsSinceEpoch,
      );
      if (!_privateSiteKeySet().contains(siteKey)) {
        scheduleAutoWebdavSync(immediate: true);
      }
    });
  }

  Future<void> clearWatchHistory() {
    return _runSequentialMutation(() async {
      final existing = _allHistoryCache ?? _readRawWatchHistory();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (existing.isNotEmpty) {
        final tombs = _readSyncTombstones();
        for (final e in existing) {
          tombs['hist:${e.key}'] = now;
        }
        await _writeSyncTombstones(tombs);
      }
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      _historyDirty = false;
      _historyCache = const [];
      _allHistoryCache = const [];
      _historyCorrupted = false;
      historyCorruptionNotifier.value = false;
      await _prefs.setBool(keyHistoryCorrupted, false);
      await _flushHistoryToDisk();
      _lastHistoryDiskWriteMs = now;
      watchHistoryRevision.value++;
      scheduleAutoWebdavSync(immediate: true);
    });
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
    } on Object catch (e) {
      debugPrint('StorageService: getFavorites parse failed: $e');
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

  Future<bool> toggleFavorite(CmsSite site, CmsVideo video) {
    return _runSequentialMutation(() async {
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
    });
  }
  List<String> getSearchHistory({bool forPrivate = false}) {
    final storageKey = forPrivate ? keyPrivateSearchHistory : keySearchHistory;
    final raw = _prefs.getString(storageKey) ?? '[]';
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    } on Object catch (e) {
      debugPrint('StorageService: getSearchHistory parse failed: $e');
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
    } on Object catch (e) {
      // Inline playlists have no JSON container to filter.
      debugPrint('StorageService: _publicRawConfig non-JSON fallback: $e');
    }
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
    final hasSubs = _hasAuthoritativeSubscriptions;
    return CmsParser.encodeBackupPayload(
      origin: !hasSubs ? configOrigin : primary?.url ?? '',
      rawConfig: !hasSubs ? _publicRawConfig(rawConfig, configOrigin) : primary?.rawContent ?? '',
      settings: <String, dynamic>{
        if (hasSubs) keySubscriptions: public.map((s) => s.toJson()).toList(),
        for (final key in [_siteOrder, _removedSites]) key: (_prefs.getStringList(key) ?? []).map((id) => identityAliases[id] ?? id).where(publicIds.contains).map(exportedIdentity).toList(),
        _siteAliases: aliases,
        keyPreferredSite: preferredSiteKey,
        for (final key in _appearanceStrings) if (_prefs.containsKey(key)) key: _prefs.getString(key),
        for (final key in _appearanceBooleans) if (_prefs.containsKey(key)) key: _prefs.getBool(key),
        keySkipIntroSec: skipIntroSec,
        keySkipOutroSec: skipOutroSec,
        keyRepeatMode: repeatMode,
        keySelectedSite: publicSupportedKey(),
        keyWatchHistory: jsonEncode(getWatchHistory().map((e) => e.toJson()).toList()),
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
  Future<CmsConfig?> importBackupJson(String rawBackup) =>
      _editSubscriptions(() => _importBackupJson(rawBackup));

  Future<CmsConfig?> _importBackupJson(String rawBackup) async {
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
      try {
        return !privateSubIds.contains((jsonDecode(key) as List).first);
      } on Object catch (e) {
        debugPrint('StorageService: prune invalid site alias key: $e');
        return true;
      }
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
      if (parsedConfig != null) {
        final availSites = parsedConfig.publicAvailableSites;
        if (!availSites.any((s) => s.key == selectedSiteKey)) {
          if (availSites.isNotEmpty) {
            final fallbackSite = availSites.firstWhere(
              (s) => !CspBridge.isBannerNoticeSite(s),
              orElse: () => availSites.first,
            );
            await _prefs.setString(keySelectedSite, fallbackSite.key);
          } else {
            await _prefs.setString(keySelectedSite, '');
          }
        }
      }
    }
    _invalidateConfigCache();
    final restoredConfig = loadSavedConfig();
    final restoredPublicAvail =
        restoredConfig?.publicAvailableSites ?? const <CmsSite>[];
    if (settings[keyPreferredSite] is String) {
      final key = (settings[keyPreferredSite] as String).trim();
      final exists =
          key.isNotEmpty && restoredPublicAvail.any((s) => s.key == key);
      await setPreferredSiteKey(exists ? key : '');
    }
    if (settings[keySelectedSite] is String) {
      final candidate = (settings[keySelectedSite] as String).trim();
      if (candidate.isNotEmpty &&
          restoredPublicAvail.any((s) => s.key == candidate)) {
        await setSelectedSiteKey(candidate);
      } else if (!restoredPublicAvail.any((s) => s.key == selectedSiteKey)) {
        if (restoredPublicAvail.isNotEmpty) {
          final fallbackSite = restoredPublicAvail.firstWhere(
            (s) => !CspBridge.isBannerNoticeSite(s),
            orElse: () => restoredPublicAvail.first,
          );
          await setSelectedSiteKey(fallbackSite.key);
        } else {
          await setSelectedSiteKey('');
        }
      }
    }
    if (nextHistory != null) {
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      _historyDirty = false;
      _historyCache = null;
      try {
        final decodedHist = jsonDecode(nextHistory);
        if (decodedHist is List) {
          final entries = decodedHist
              .whereType<Map>()
              .map((m) => WatchHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
              .where((e) => e.site.isNotEmpty && e.id.isNotEmpty)
              .toList();
          _allHistoryCache = entries;
          await _flushHistoryToDisk();
          _lastHistoryDiskWriteMs = DateTime.now().millisecondsSinceEpoch;
        }
      } on Object catch (e) {
        debugPrint('StorageService: importBackupJson history flush fallback: $e');
        await _prefs.setString(keyWatchHistory, nextHistory);
      }
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
      if (speed >= minPlaySpeed && speed <= maxPlaySpeed) {
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
  String get webdavPass =>
      _credentialCache[keyWebdavPass] ?? _prefs.getString(keyWebdavPass) ?? '';
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
    await _writeSecret(keyWebdavPass, pass);
    await _prefs.setString(keyWebdavUrl, url.trim());
    await _prefs.setString(keyWebdavUser, user.trim());
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
    if (_hasAuthoritativeSubscriptions) {
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
        } on Object catch (e) {
          debugPrint('StorageService: _collectPublicSyncSubscriptions legacy parse failed: $e');
        }
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
    } on Object catch (e) {
      debugPrint('StorageService: _readSyncTombstones parse failed: $e');
    }
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
    trimmed = trimmed.replaceAll(' ', '%20');
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
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
    if (isJianguoyun && (path.isEmpty || path == '/')) {
      return trimmed.endsWith('/')
          ? '${trimmed}dav/MarcoMovie/$defaultSyncFileName'
          : '$trimmed/dav/MarcoMovie/$defaultSyncFileName';
    }
    if (isJianguoyun && (path == '/dav' || path == '/dav/')) {
      return trimmed.endsWith('/')
          ? '${trimmed}MarcoMovie/$defaultSyncFileName'
          : '$trimmed/MarcoMovie/$defaultSyncFileName';
    }
    return trimmed.endsWith('/')
        ? '$trimmed$defaultSyncFileName'
        : '$trimmed/$defaultSyncFileName';
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
    if (_historyCorrupted) {
      throw StateError('本地观看历史数据损坏，已停止同步覆盖（已备份至 watch_history_corrupt_*）');
    }
    if (webdavSyncSubs) {
      if (!_subscriptionsCorrupted &&
          _subscriptionsCache == null &&
          _fileStore.existsSync(_subscriptionsFileName)) {
        getSubscriptions();
      }
      if (_subscriptionsCorrupted) {
        throw StateError(
          '本地订阅文件读取或解析异常，已开启写保护（已隔离至 subscriptions_corrupt_*），拒绝同步覆盖',
        );
      }
    }
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
    } on Object catch (e) {
      debugPrint('StorageService: mergeSyncPayload invalid JSON: $e');
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
        final hadRegistry = _hasAuthoritativeSubscriptions;

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
          } on Object catch (e) {
            debugPrint('StorageService: skip unparseable remote subscription: $e');
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
          _invalidateConfigCache();
          final reloaded = loadSavedConfig();
          final pubSites = reloaded?.publicSupportedSites ?? const <CmsSite>[];
          final pubAvailable =
              reloaded?.publicAvailableSites ?? const <CmsSite>[];
          final allAvailable = reloaded?.availableSites ?? const <CmsSite>[];
          final currentSelected = selectedSiteKey;
          if (pubSites.isNotEmpty) {
            if (!allAvailable.any((s) => s.key == currentSelected)) {
              if (pubAvailable.isNotEmpty) {
                final preferredDefault = pubAvailable.firstWhere(
                  (s) => !CspBridge.isBannerNoticeSite(s),
                  orElse: () => pubAvailable.first,
                );
                if (preferredDefault.supported) {
                  await _prefs.setString(keySelectedSite, preferredDefault.key);
                }
              }
              // When target sites are unavailable (pubAvailable.isEmpty),
              // retain the original selectedSiteKey (M-F2).
            }
          } else if (pubSites.isEmpty && currentSelected.isNotEmpty) {
            final allSites = reloaded?.supportedSites ?? const <CmsSite>[];
            if (!allSites.any((s) => s.key == currentSelected)) {
              await _prefs.setString(keySelectedSite, '');
            }
          }
        }
      });
    }

    return _runSequentialMutation(() async {
      if (_historyCorrupted) {
        throw StateError('本地观看历史数据损坏，已停止同步覆盖（已备份至 watch_history_corrupt_*）');
      }

      // 3. Re-read fresh local watch history (including private entries) and favorites
      final allLocalHist = _readRawWatchHistory();
      final privKeys = _privateSiteKeySet();
      final localPrivateHist =
          allLocalHist.where((e) => privKeys.contains(e.site)).toList();
      final localPublicHist =
          allLocalHist.where((e) => !privKeys.contains(e.site)).toList();
      final currentLocalFavs = getFavorites(forPrivate: false);

      final currentLocalTombs = _readSyncTombstones();
      for (final f in currentLocalFavs) {
        if (f.updated > 0) {
          final addKey = 'add:${f.key}';
          final prev = currentLocalTombs[addKey] ?? 0;
          if (f.updated > prev) currentLocalTombs[addKey] = f.updated;
        }
      }
      for (final entry in remoteTombs.entries) {
        final cur = currentLocalTombs[entry.key] ?? 0;
        if (entry.value > cur) currentLocalTombs[entry.key] = entry.value;
      }
      final mergedTombs = currentLocalTombs;

      // Merge watch history (LWW per key + deletion tombstones)
      final histByKey = <String, WatchHistoryEntry>{};
      for (final e in [...localPublicHist, ...remoteHist]) {
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
      final mergedPublicHist = histByKey.values.toList()
        ..sort((a, b) => b.updated.compareTo(a.updated));
      if (mergedPublicHist.length > CmsParser.maxHistoryEntries) {
        mergedPublicHist.removeRange(
          CmsParser.maxHistoryEntries,
          mergedPublicHist.length,
        );
      }

      // Recombine with preserved local private history entries
      final combinedAllHist = [...mergedPublicHist, ...localPrivateHist]
        ..sort((a, b) => b.updated.compareTo(a.updated));
      if (combinedAllHist.length > CmsParser.maxHistoryEntries) {
        combinedAllHist.removeRange(
          CmsParser.maxHistoryEntries,
          combinedAllHist.length,
        );
      }

      // 4. Merge favorites
      final favByKey = <String, FavoriteEntry>{};
      for (final f in [...currentLocalFavs, ...remoteFavs]) {
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

      final nextHistJson =
          jsonEncode(combinedAllHist.map((e) => e.toJson()).toList());
      final nextFavsJson =
          jsonEncode(mergedFavs.map((f) => f.toJson()).toList());
      _historyFlushTimer?.cancel();
      _historyFlushTimer = null;
      _historyDirty = false;
      _historyCache = null;
      _allHistoryCache = combinedAllHist;
      await _flushHistoryToDisk();
      _lastHistoryDiskWriteMs = DateTime.now().millisecondsSinceEpoch;
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
        historyCount: mergedPublicHist.length,
        favoriteCount: mergedFavs.length,
        subscriptionCount: finalSubCount,
        changed: changed,
        subscriptionsChanged: subscriptionsChanged,
        payloadJson: payloadJson,
      );
    });
  }

  void scheduleAutoWebdavSync({bool immediate = false, int? nowMs}) {
    if (!webdavAuto || !isWebdavConfigured) return;
    if (_syncInFlight) {
      _resyncRequested = true;
      if (immediate) {
        _resyncImmediate = true;
      }
      return;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int delayMs;
    if (immediate) {
      delayMs = 2500;
      _autoSyncTimer?.cancel();
    } else {
      const minInterval = 300000; // 5 minutes
      final elapsed = _lastHistoryAutoPushMs > 0
          ? now - _lastHistoryAutoPushMs
          : minInterval;
      if (elapsed < minInterval) {
        if (_autoSyncTimer?.isActive == true) return;
        delayMs = (minInterval - elapsed).clamp(3000, minInterval);
      } else {
        delayMs = 3000;
        _autoSyncTimer?.cancel();
      }
    }
    _autoSyncTimer = Timer(Duration(milliseconds: delayMs), () {
      _lastHistoryAutoPushMs = DateTime.now().millisecondsSinceEpoch;
      if (_syncInFlight) {
        _resyncRequested = true;
        if (immediate) {
          _resyncImmediate = true;
        }
        return;
      }
      syncWithWebdav().ignore();
    });
  }

  Future<void> flushPendingSync({
    Duration timeout = const Duration(seconds: 3),
    http.Client? client,
  }) async {
    cancelPendingAutoSync();
    if (!isWebdavConfigured || !webdavAuto) return;
    if (_syncInFlight) {
      final deadline = DateTime.now().add(timeout);
      while (_syncInFlight && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return;
    }
    try {
      await syncWithWebdav(client: client).timeout(timeout);
    } on Object catch (e) {
      // Best-effort push on exit
      debugPrint('StorageService: flushPendingSync best-effort skipped: $e');
    }
  }

  static bool isWeakEtag(String? etag) {
    if (etag == null) return false;
    final trimmed = etag.trim();
    return trimmed.startsWith('W/') || trimmed.startsWith('w/');
  }

  static String _extractHostKey(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return '';
    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort ? uri.port : (scheme == 'http' ? 80 : 443);
    return '$scheme://$host:$port';
  }

  @visibleForTesting
  static bool isHostMarkedNoConditionalWrite(String rawOrFileUrl) {
    try {
      final resolved = rawOrFileUrl.trim().toLowerCase().endsWith('.json')
          ? rawOrFileUrl.trim()
          : resolveWebdavFileUrl(rawOrFileUrl);
      final key = _extractHostKey(Uri.parse(resolved));
      return key.isNotEmpty && _noConditionalWriteHosts.contains(key);
    } on Object {
      return false;
    }
  }

  @visibleForTesting
  static void clearNoConditionalWriteHostsForTest() {
    _noConditionalWriteHosts.clear();
  }

  static bool _isIfNoneMatchRejectedStatus(int code) {
    return code == 400 ||
        code == 405 ||
        code == 406 ||
        code == 417 ||
        code == 428 ||
        code == 500 ||
        code == 501;
  }

  @visibleForTesting
  static int baseCollectionDepth(String rawBaseUrl, Uri fileUri) {
    final allSegs =
        fileUri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    if (allSegs.length <= 1) return 0;
    final parentSegs = allSegs.sublist(0, allSegs.length - 1);
    final baseSegs = _extractBaseDirSegments(rawBaseUrl);

    final host = fileUri.host.toLowerCase();
    final isJianguoyun =
        host == 'jianguoyun.com' || host.endsWith('.jianguoyun.com');
    if (isJianguoyun && parentSegs.first.toLowerCase() == 'dav') {
      var skip = 1;
      if (baseSegs.isNotEmpty &&
          baseSegs.length < parentSegs.length &&
          _isSegmentPrefix(baseSegs, parentSegs)) {
        if (baseSegs.length > skip) skip = baseSegs.length;
      }
      return skip;
    }
    if (parentSegs.length >= 4 &&
        parentSegs[0].toLowerCase() == 'remote.php' &&
        parentSegs[1].toLowerCase() == 'dav' &&
        parentSegs[2].toLowerCase() == 'files') {
      var skip = 4;
      if (baseSegs.isNotEmpty &&
          baseSegs.length < parentSegs.length &&
          _isSegmentPrefix(baseSegs, parentSegs)) {
        if (baseSegs.length > skip) skip = baseSegs.length;
      }
      return skip;
    }
    if (parentSegs.length >= 2 &&
        parentSegs[0].toLowerCase() == 'remote.php' &&
        parentSegs[1].toLowerCase() == 'webdav') {
      var skip = 2;
      if (baseSegs.isNotEmpty &&
          baseSegs.length < parentSegs.length &&
          _isSegmentPrefix(baseSegs, parentSegs)) {
        if (baseSegs.length > skip) skip = baseSegs.length;
      }
      return skip;
    }

    if (baseSegs.isNotEmpty &&
        baseSegs.length < parentSegs.length &&
        _isSegmentPrefix(baseSegs, parentSegs)) {
      return baseSegs.length;
    }
    return 0;
  }

  static List<String> _extractBaseDirSegments(String rawBaseUrl) {
    var trimmed = rawBaseUrl.trim();
    if (trimmed.isEmpty) return const [];
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      trimmed = 'https://$trimmed';
    }
    trimmed = trimmed.replaceAll(' ', '%20');
    final u = Uri.tryParse(trimmed);
    if (u == null) return const [];
    if (u.path.toLowerCase().endsWith('.json')) return const [];
    return u.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  }

  static bool _isSegmentPrefix(List<String> prefix, List<String> full) {
    if (prefix.length > full.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i].toLowerCase() != full[i].toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  Map<String, String> _webdavHeaders({
    bool jsonContent = false,
    String? ifMatch,
    String? ifNoneMatch,
  }) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
      if (jsonContent) 'Content-Type': 'application/json; charset=utf-8',
      if (ifMatch != null && ifMatch.isNotEmpty) 'If-Match': ifMatch,
      if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
        'If-None-Match': ifNoneMatch,
    };
    if (webdavUser.isNotEmpty || webdavPass.isNotEmpty) {
      final token = base64Encode(utf8.encode('$webdavUser:$webdavPass'));
      headers['Authorization'] = 'Basic $token';
    }
    return headers;
  }

  static String _formatWebdavWriteError(int code) {
    if (code == 412) {
      return 'WebDAV 写入冲突 (HTTP 412)：文件已被其他设备修改，重试后仍冲突';
    }
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

  Future<void> _ensureWebdavCollections(
    http.Client client,
    String rawBaseUrl,
    Uri fileUri,
  ) async {
    final segments =
        fileUri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    if (segments.length <= 1) return;
    final skipSegments = baseCollectionDepth(rawBaseUrl, fileUri);
    for (var i = skipSegments; i < segments.length - 1; i++) {
      final collUri = fileUri.replace(
        pathSegments: <String>[...segments.sublist(0, i + 1), ''],
      );
      final req = http.Request('MKCOL', collUri)
        ..headers.addAll(_webdavHeaders());
      try {
        final streamed =
            await client.send(req).timeout(const Duration(seconds: 10));
        final status = streamed.statusCode;
        await streamed.stream.drain<void>();
        if (status == 401) {
          break;
        }
      } on Object catch (e) {
        debugPrint('StorageService: MKCOL failed for $collUri: $e');
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

  Future<http.Response> _putWebdavWithMkcolRetry(
    http.Client httpClient,
    String rawBaseUrl,
    Uri uri,
    List<int> encodedPayload, {
    String? ifMatch,
    String? ifNoneMatch,
  }) async {
    var putResp = await httpClient
        .put(
          uri,
          headers: _webdavHeaders(
            jsonContent: true,
            ifMatch: ifMatch,
            ifNoneMatch: ifNoneMatch,
          ),
          body: encodedPayload,
        )
        .timeout(const Duration(seconds: 15));
    if (putResp.statusCode == 404 || putResp.statusCode == 409) {
      await _ensureWebdavCollections(httpClient, rawBaseUrl, uri);
      putResp = await httpClient
          .put(
            uri,
            headers: _webdavHeaders(
              jsonContent: true,
              ifMatch: ifMatch,
              ifNoneMatch: ifNoneMatch,
            ),
            body: encodedPayload,
          )
          .timeout(const Duration(seconds: 15));
    }
    return putResp;
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
    final rawBaseUrl = webdavUrl;
    final targetUrl = resolveWebdavFileUrl(rawBaseUrl);
    _syncInFlight = true;
    _lastHistoryAutoPushMs = DateTime.now().millisecondsSinceEpoch;
    final effectiveClient = client ?? _webdavTestClient ?? http.Client();
    final ownsClient = client == null && _webdavTestClient == null;
    try {
      final uri = Uri.parse(targetUrl);
      final hostKey = _extractHostKey(uri);
      const maxRetries = 2;
      var attempt = 0;
      var sawAbsent412 = false;
      final rand = Random();

      while (true) {
        String? remoteBody;
        String? remoteEtag;
        var fileAbsent = false;

        final getResp = await effectiveClient
            .get(uri, headers: _webdavHeaders())
            .timeout(const Duration(seconds: 15));
        if (getResp.statusCode >= 200 && getResp.statusCode < 300) {
          if (getResp.bodyBytes.length > maxSyncPayloadBytes) {
            throw const FormatException('远端同步文件超过 8 MB 大小限制');
          }
          remoteBody = utf8.decode(getResp.bodyBytes);
          final h = getResp.headers['etag']?.trim();
          if (h != null && h.isNotEmpty && !isWeakEtag(h)) {
            remoteEtag = h;
          }
        } else if (getResp.statusCode == 404) {
          remoteBody = null;
          fileAbsent = true;
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

        final skipCond =
            hostKey.isNotEmpty && _noConditionalWriteHosts.contains(hostKey);
        final absent412Fallback = fileAbsent && sawAbsent412;
        String? ifMatch;
        String? ifNoneMatch;
        if (!skipCond) {
          if (fileAbsent) {
            if (!absent412Fallback) {
              ifNoneMatch = '*';
            }
          } else if (remoteEtag != null && remoteEtag.isNotEmpty) {
            ifMatch = remoteEtag;
          }
        }
        final usedConditional = ifMatch != null || ifNoneMatch != null;

        var putResp = await _putWebdavWithMkcolRetry(
          effectiveClient,
          rawBaseUrl,
          uri,
          encodedPayload,
          ifMatch: ifMatch,
          ifNoneMatch: ifNoneMatch,
        );

        if (ifNoneMatch != null &&
            _isIfNoneMatchRejectedStatus(putResp.statusCode)) {
          final retryResp = await _putWebdavWithMkcolRetry(
            effectiveClient,
            rawBaseUrl,
            uri,
            encodedPayload,
          );
          if (retryResp.statusCode >= 200 && retryResp.statusCode < 300) {
            if (hostKey.isNotEmpty) _noConditionalWriteHosts.add(hostKey);
            putResp = retryResp;
          } else {
            putResp = retryResp;
          }
        }

        if (putResp.statusCode == 412) {
          if (attempt < maxRetries && !(fileAbsent && sawAbsent412)) {
            if (ifNoneMatch != null) {
              sawAbsent412 = true;
            }
            attempt++;
            final jitterMs = 50 + rand.nextInt(100);
            await Future<void>.delayed(Duration(milliseconds: jitterMs));
            continue;
          }
          if (usedConditional) {
            final fallbackResp = await _putWebdavWithMkcolRetry(
              effectiveClient,
              rawBaseUrl,
              uri,
              encodedPayload,
            );
            if (fallbackResp.statusCode >= 200 &&
                fallbackResp.statusCode < 300 &&
                hostKey.isNotEmpty) {
              _noConditionalWriteHosts.add(hostKey);
            }
            putResp = fallbackResp;
          }
        }

        if (putResp.statusCode == 401 || putResp.statusCode == 403) {
          throw FormatException('WebDAV 写入被拒绝 (HTTP ${putResp.statusCode})');
        }
        if (putResp.statusCode < 200 || putResp.statusCode >= 300) {
          throw FormatException(_formatWebdavWriteError(putResp.statusCode));
        }

        if (absent412Fallback && hostKey.isNotEmpty) {
          _noConditionalWriteHosts.add(hostKey);
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
      }
    } catch (e) {
      await _prefs.setString(keySyncLastStatus, '上次失败：$e');
      rethrow;
    } finally {
      _syncInFlight = false;
      if (ownsClient) effectiveClient.close();
      if (_resyncRequested) {
        final immediateNext = _resyncImmediate;
        _resyncRequested = false;
        _resyncImmediate = false;
        scheduleAutoWebdavSync(immediate: immediateNext);
      }
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

import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'desktop_horizontal_scroller.dart';
import 'source_choice_sliver.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/cms_client.dart';
import '../core/catpaw_host.dart';
import 'package:url_launcher/url_launcher.dart';
import 'add_resource_library_sheet.dart';
import '../core/cms_parser.dart';
import '../core/config_center_bridge.dart';
import '../core/app_update.dart';
import '../core/csp_bridge.dart';
import '../core/curated_discovery.dart';
import '../core/launch_diagnostics.dart';
import '../core/device_quality_profiler.dart';
import '../core/desktop_webview_js_bridge.dart';
import '../core/download_service.dart';
import '../core/ios_avplayer_controller.dart';
import '../core/live_channel_organizer.dart';
import '../core/local_media_proxy.dart';
import '../core/mdk_platform_player.dart';
import '../core/models.dart';
import '../core/netdisk_service.dart';
import '../core/python_source_host.dart';
import '../core/storage_service.dart';
import '../core/ohos_runtime.dart';
import '../core/spider_plugin_registry.dart';
import '../core/app_log.dart';
import '../core/search_source_notice.dart';
import '../core/windows_tray_service.dart';
import '../core/windows_video_quality.dart';
import '../core/wogg_source.dart';
import 'apple_theme.dart';
import 'cloud_sync_panel.dart';
import 'curated_discovery_section.dart';
import 'detail_screen.dart';
import 'ios_filter_sheet.dart';
import 'ios_glass_popover.dart' show activeIosGlassPopoverCount;
import 'ios_liquid_glass.dart';
import 'ios_press_slide_menu.dart';
import 'ios_search_page.dart';
import 'ios_settings.dart';
import 'ios_update_sheet.dart';
import 'live_station_badge.dart';
import 'macos_official_notice.dart';
import 'macos_update_sheet.dart';
import 'media_folder_browser_page.dart';
import 'motion/aurora_background.dart';
import 'motion/ios27_springs.dart';
import 'motion/player_enter_transition.dart';
import 'netdisk_sheet.dart';
import 'official_channel_notice.dart';
import 'onboarding/onboarding_prefs.dart';
import 'onboarding/onboarding_screen.dart';
import 'player_screen.dart';
import 'poster_expand_route.dart';
import 'poster_image.dart';
import 'release_notes_view.dart';
import 'source_verification_dialog.dart';
import 'spider_extensions_panel.dart';
import 'windows_appearance.dart';
part 'windows_shell.dart';
/// Apple HIG adaptive shell:
/// - macOS / iPadOS / Desktop (`width >= 700`): Translucent sidebar with traffic-light inset & source card
/// - iOS (`width < 700`): Frosted-glass top navigation bar and translucent Cupertino bottom tab bar
class AdaptiveShell extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  @visibleForTesting
  final Future<void> Function(bool value)? onSetPreventCloseForTest;
  @visibleForTesting
  final Future<void> Function()? onDestroyWindowForTest;
  @visibleForTesting
  final Future<void> Function()? onCloseHostForTest;
  @visibleForTesting
  final Future<void> Function()? onCloseScriptsForTest;
  @visibleForTesting
  final Future<void> Function()? onFlushHistoryForTest;
  @visibleForTesting
  final Future<void> Function(Duration timeout)? onFlushSyncForTest;
  @visibleForTesting
  final Duration? windowCloseTotalBudgetForTest;
  @visibleForTesting
  final Future<bool> Function(Uri uri)? onOpenExternalUrlForTest;
  @visibleForTesting
  final Future<void> Function(String text)? onCopyTextForTest;

  const AdaptiveShell({
    super.key,
    required this.storage,
    required this.client,
    this.onSetPreventCloseForTest,
    this.onDestroyWindowForTest,
    this.onCloseHostForTest,
    this.onCloseScriptsForTest,
    this.onFlushHistoryForTest,
    this.onFlushSyncForTest,
    this.windowCloseTotalBudgetForTest,
    this.onOpenExternalUrlForTest,
    this.onCopyTextForTest,
  });

  static const Duration defaultWindowCloseBudget =
      Duration(milliseconds: 1400);

  @visibleForTesting
  static Future<void> runWindowCloseSequence({
    required Future<void> Function(bool prevent) setPreventClose,
    required Future<void> Function() flushHistory,
    required Future<void> Function(Duration timeout) flushSync,
    required Future<void> Function() closeHost,
    required Future<void> Function() closeScripts,
    required Future<void> Function() destroyWindow,
    Future<void> Function()? hideWindow,
    Duration totalBudget = defaultWindowCloseBudget,
  }) async {
    final sw = Stopwatch()..start();

    Duration stepBudget(Duration maxStep) {
      final remMs = totalBudget.inMilliseconds - sw.elapsedMilliseconds;
      if (remMs <= 0) return Duration.zero;
      return remMs < maxStep.inMilliseconds
          ? Duration(milliseconds: remMs)
          : maxStep;
    }

    Future<void> runBounded(
      String stepName,
      Duration maxStep,
      Future<void> Function(Duration budget) fn,
    ) async {
      final b = stepBudget(maxStep);
      if (b <= Duration.zero) return;
      try {
        await fn(b).timeout(b);
      } on Object catch (e) {
        debugPrint('AdaptiveShell: onWindowClose $stepName skipped/timed out: $e');
      }
    }

    try {
      await (() async {
        await runBounded(
          'setPreventClose(true)',
          const Duration(milliseconds: 150),
          (_) => setPreventClose(true),
        );
        if (hideWindow != null) {
          await runBounded(
            'hideWindow',
            const Duration(milliseconds: 120),
            (_) => hideWindow(),
          );
        }
        await runBounded(
          'flushPendingHistory',
          const Duration(milliseconds: 300),
          (_) => flushHistory(),
        );
        await Future.wait([
          runBounded(
            'flushPendingSync',
            const Duration(milliseconds: 550),
            (budget) => flushSync(budget),
          ),
          runBounded(
            'CatPawHost.close',
            const Duration(milliseconds: 350),
            (_) => closeHost(),
          ),
          runBounded(
            'CmsClient.closeScriptSessions',
            const Duration(milliseconds: 350),
            (_) => closeScripts(),
          ),
        ]);
      })().timeout(totalBudget);
    } on Object catch (e) {
      debugPrint('AdaptiveShell: onWindowClose total budget reached: $e');
    } finally {
      try {
        await setPreventClose(false)
            .timeout(const Duration(milliseconds: 150));
      } on Object catch (e) {
        debugPrint('AdaptiveShell: setPreventClose(false) failed: $e');
      }
      try {
        await destroyWindow().timeout(const Duration(milliseconds: 150));
      } on Object catch (e) {
        debugPrint('AdaptiveShell: windowManager.destroy failed: $e');
      }
    }
  }

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}
class _AdaptiveShellState extends State<AdaptiveShell>
    with WindowListener, WidgetsBindingObserver, TickerProviderStateMixin {
  bool _windowListenerAttached = false;
  bool _isClosingWindow = false;
  Future<void>? _closingHistoryFlush;
  int _tabIndex = 0;
  String _windowsPage = 'home';
  LiveChannel? _windowsLiveChannel;
  int _windowsLiveLine = 0;
  int _windowsLiveRevision = 0;
  String _windowsSettings = '背景与外观';
  CmsConfig? _config;
  CmsSite? _activeSite;
  List<CmsCategory> _categories = const [];
  String _selectedCategoryId = '';
  String _primaryTab = 'recommend';
  bool _filterExpanded = false;
  String _filterSubCategoryId = '';
  String _filterGenreLabel = '';
  String _filterArea = '';
  String _filterYear = '';
  List<CmsVideo> _rawCategoryVideos = const [];
  List<CmsVideo> _homeVideos = const [];
  List<CmsVideo> _windowsRecommendedVideos = const [];
  final PageController _iosHeroPageController = PageController();
  int _iosHeroIndex = 0;
  bool _homeRefreshing = false;
  bool _iosHeroPullArmed = false;
  final Map<String, Color> _iosHeroAmbientColors = {};
  final Set<String> _iosHeroAmbientPending = {};
  final Map<int, bool> _rexShelfLightInkCache = {};
  int _currentPage = 1;
  int _pageCount = 1;
  bool _homeLoading = false;
  bool _loadingMore = false;
  String? _homeError;
  String? _loadMoreError;
  Object? _homeErrorCause;
  Future<void> Function()? _retryHomeError;
  int _homeEpoch = 0;
  int _categoryEpoch = 0;
  bool _autoPagingScheduled = false;
  Completer<void>? _homeAbort;
  Completer<void>? _categoryAbort;
  Completer<void>? _liveAbort;

  void _cancelCatalogue() {
    for (final pending in [_homeAbort, _categoryAbort]) {
      if (pending != null && !pending.isCompleted) pending.complete();
    }
  }
  // 5-tap logo privacy state
  int _logoTapCount = 0;
  DateTime? _lastLogoTapAt;
  bool _privateSessionUnlocked = false;
  String _selectedPrivateSiteKey = '';
  bool _privacyPortalAnimating = false;
  int _privacyPortalRunId = 0;
  // Search state
  final TextEditingController _searchController = TextEditingController();
  final List<(CmsSite, CmsVideo)> _searchResults = [];
  final Map<String, String> _searchNotices = {};
  final Map<String, CmsSite> _searchVerificationSites = {};
  String _searchKeyword = '';
  String _searchSiteFilterKey = '';
  bool _searchPerformed = false;
  bool _searching = false;
  int _searchEpoch = 0;
  StreamSubscription<(CmsSite, List<CmsVideo>)>? _searchSubscription;
  final ValueNotifier<int> _searchStateRevision = ValueNotifier<int>(0);
  void _notifySearchUi() {
    if (mounted) _searchStateRevision.value++;
  }
  // Live state
  int _selectedLiveSource = 0;
  int _selectedLiveGroup = 0;
  final TextEditingController _liveSearchController = TextEditingController();
  String _liveSearchQuery = '';
  List<LiveGroup> _liveGroups = const [];
  bool _liveLoading = false;
  String? _liveError;
  int _liveEpoch = 0;
  bool _liveProbing = false;
  LiveProbeProgress? _liveProbeProgress;
  Completer<void>? _liveProbeAbort;
  bool _liveHideUnreachable = false;
  // Favorites / History segmented index
  int _librarySegment = 0;
  bool _dockCollapsed = false;
  bool _dockStableCollapsed = false;
  bool _homeUserDragging = false;
  final ValueNotifier<double> _dockScrollProgress = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> _iosHomeStatusBarDark = ValueNotifier<bool>(false);
  final ValueNotifier<double> _iosHomeTopScrimOpacity =
      ValueNotifier<double>(0.0);
  final ValueNotifier<double> _iosHeroOverscroll = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _rexBackdropScrollOffset =
      ValueNotifier<double>(0.0);
  final ValueNotifier<double> _rexCardInkScrollOffset =
      ValueNotifier<double>(0.0);
  double _lastIosHeroHeight = 460.0;
  OverlayEntry? _undoHistoryOverlayEntry;
  Timer? _undoHistoryTimer;
  bool get _isIosNativeFlow =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !OhosRuntime.isOhos;
  final ValueNotifier<bool> _useRootNativeTabChromeNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> _curatedDockVisibleNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<int> _selectedTabIndexNotifier = ValueNotifier<int>(0);
  late final AnimationController _dockMorphCtrl;
  double _dockMorphFrom = 0.0;
  double _dockMorphTo = 0.0;
  int _dockMorphAnimToken = 0;
  int _dockEpoch = 0;
  IosDockOwner _dockOwner = IosDockOwner.home;
  int _curatedRouteDepth = 0;
  bool _useRootNativeTabChrome = false;
  int _pushedRouteDepth = 0;
  bool _settingsSecondaryRouteActive = false;
  double _lastReportedDockProgress = 0.0;
  bool _lastReportedDockVisible = true;
  bool _sceneActive = true;
  static const List<(IconData, IconData, String)> _iosDockFallbackItems =
      <(IconData, IconData, String)>[
    (CupertinoIcons.house, CupertinoIcons.house_fill, '主页'),
    (CupertinoIcons.tv, CupertinoIcons.tv_fill, '直播'),
    (
      CupertinoIcons.rectangle_stack,
      CupertinoIcons.rectangle_stack_fill,
      '片库',
    ),
    (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, '设置'),
  ];
  List<IosNativeDockItem> _buildIosNativeDockItems() => <IosNativeDockItem>[
        IosNativeDockItem(
          label: '主页',
          symbol: 'house',
          selectedSymbol: 'house.fill',
          kind: 'home',
          menuItems: _buildDockTabNativeMenuItems(0),
        ),
        IosNativeDockItem(
          label: '直播',
          symbol: 'play.tv',
          selectedSymbol: 'play.tv.fill',
          kind: 'live',
          menuItems: _buildDockTabNativeMenuItems(1),
        ),
        IosNativeDockItem(
          label: '片库',
          symbol: 'rectangle.stack',
          selectedSymbol: 'rectangle.stack.fill',
          kind: 'library',
          menuItems: _buildDockTabNativeMenuItems(2),
        ),
        IosNativeDockItem(
          label: '设置',
          symbol: 'gearshape',
          selectedSymbol: 'gearshape.fill',
          kind: 'settings',
          menuItems: _buildDockTabNativeMenuItems(3),
        ),
      ];
  List<IosNativeMenuItem> _buildDockTabNativeMenuItems(int tabIndex) {
    return switch (tabIndex) {
      0 => const <IosNativeMenuItem>[
          IosNativeMenuItem(
            id: 'top',
            title: '回到顶部',
            symbol: 'arrow.up.to.line',
          ),
        ],
      1 => const <IosNativeMenuItem>[
          IosNativeMenuItem(
            id: 'manage_live',
            title: '管理直播源',
            symbol: 'antenna.radiowaves.left.and.right',
          ),
        ],
      2 => <IosNativeMenuItem>[
          const IosNativeMenuItem(
            id: 'favorites',
            title: '收藏',
            symbol: 'heart.fill',
          ),
          if (!_privateSessionUnlocked)
            const IosNativeMenuItem(
              id: 'history',
              title: '观看历史',
              symbol: 'clock.fill',
            ),
        ],
      3 => const <IosNativeMenuItem>[
          IosNativeMenuItem(
            id: 'add_library',
            title: '添加资源库',
            symbol: 'plus.circle',
          ),
          IosNativeMenuItem(
            id: 'netdisk_accounts',
            title: '网盘账号',
            symbol: 'cloud.fill',
          ),
        ],
      _ => const <IosNativeMenuItem>[],
    };
  }

  List<IosSlideMenuAction> _buildDockTabSlideMenuActions(int tabIndex) =>
      iosSlideActionsFromNativeMenu(_buildDockTabNativeMenuItems(tabIndex));

  void _handleDockTabMenuAction(int tabIndex, String actionId) {
    if (!mounted) return;
    if (_curatedRouteDepth > 0 ||
        IosRootTabNavigatorObserver.topRouteIsCurated.value) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    switch (actionId) {
      case 'top':
        _scrollHomeToTop();
        return;
      case 'manage_live':
        setState(() {
          _tabIndex = 1;
          _selectedTabIndexNotifier.value = 1;
        });
        _reconcileDockOwnership(animated: true);
        _showLiveSourceManagerSheet();
        return;
      case 'favorites':
        setState(() {
          _tabIndex = 2;
          _selectedTabIndexNotifier.value = 2;
          _librarySegment = 0;
        });
        _reconcileDockOwnership(animated: true);
        return;
      case 'history':
        if (_privateSessionUnlocked) {
          _showAppleNotice('隐私空间已开启', '隐私空间不记录也不展示普通观看历史。');
          return;
        }
        setState(() {
          _tabIndex = 2;
          _selectedTabIndexNotifier.value = 2;
          _librarySegment = 1;
        });
        _reconcileDockOwnership(animated: true);
        return;
      case 'add_library':
        unawaited(_showImportConfigDialog(iosBackLabel: '设置'));
        return;
      case 'netdisk_accounts':
        _openConfigCenterPage(initialFocus: 'netdisk', iosBackLabel: '设置');
        return;
    }
  }

  void _openConfigCenterPage({
    String initialFocus = 'overview',
    String iosBackLabel = '主页',
  }) {
    final allSites = _config?.publicSupportedSites ?? const <CmsSite>[];
    unawaited(
      _trackSecondaryRoute<void>(
        () => showNetdiskAccountSheet(
          context,
          widget.storage,
          iosBackLabel: iosBackLabel,
          initialFocus: initialFocus,
          sites: allSites,
          activeGroup: _activeSite?.group ?? '',
          onOpenCatPawSettings:
              allSites.any((s) => s.isCatPaw) ? _showCatPawSettings : null,
          onOpenAddLibrary: () => _showImportConfigDialog(iosBackLabel: '配置中心'),
          onOpenSubscriptionManager: () =>
              _showSubscriptionManagerSheet(iosBackLabel: '配置中心'),
          onOpenLibrarySubscription: (sub) {
            final match = _visibleSupportedSites.where(
              (s) =>
                  s.subscriptionId == sub.id ||
                  s.api.trim() == sub.url.trim() ||
                  s.name.trim() == sub.name.trim(),
            );
            if (match.isNotEmpty) {
              _selectSiteDirect(match.first);
            }
          },
          onRemoveLibrarySubscription: (sub) async {
            await widget.storage.removeSubscription(sub.id);
            if (mounted) _reloadSavedConfig();
          },
          onChanged: () {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  List<IosNativeMenuItem> _buildHomeConfigCenterMenuItems() {
    return const <IosNativeMenuItem>[
      IosNativeMenuItem(
        id: 'add_library',
        title: '添加资源库',
        symbol: 'plus.circle',
        section: 0,
      ),
      IosNativeMenuItem(
        id: 'manage_subscriptions',
        title: '管理订阅',
        symbol: 'square.stack.3d.up',
        section: 0,
      ),
      IosNativeMenuItem(
        id: 'netdisk_accounts',
        title: '网盘账号',
        symbol: 'cloud.fill',
        section: 0,
      ),
    ];
  }

  void _onHomeConfigCenterMenuSelected(String id) {
    if (!mounted) return;
    switch (id) {
      case 'add_library':
        unawaited(_showImportConfigDialog(iosBackLabel: '主页'));
        return;
      case 'manage_subscriptions':
        unawaited(_showSubscriptionManagerSheet(iosBackLabel: '主页'));
        return;
      case 'netdisk_accounts':
        _openConfigCenterPage(initialFocus: 'netdisk', iosBackLabel: '主页');
        return;
    }
  }

  IosCuratedDockHost get _curatedDockHost => IosCuratedDockHost(
        progress: _dockScrollProgress,
        useNativeRootChrome: _useRootNativeTabChromeNotifier,
        visibleOnCurated: _curatedDockVisibleNotifier,
        selectedTabIndex: _selectedTabIndexNotifier,
        items: _iosDockFallbackItems,
        onSelectTab: _handleRootNativeTabSelected,
        onSearch: _showGlobalSearchSheet,
        onScrollToTop: _scrollHomeToTop,
        onCuratedEnter: _onCuratedRouteEntered,
        onCuratedExit: _onCuratedRouteExited,
      );
  // Scroll controllers (inline shell views only; sheets own their own)
  final ScrollController _homeScrollController = ScrollController();
  final ScrollController _windowsDiscoverScrollController = ScrollController();
  final ScrollController _continueWatchingScrollController = ScrollController();
  final ScrollController _categoryPillsScrollController = ScrollController();
  final ScrollController _filterCategoryScrollController = ScrollController();
  final ScrollController _filterAreaScrollController = ScrollController();
  final ScrollController _filterYearScrollController = ScrollController();
  final ScrollController _liveSourcesScrollController = ScrollController();
  final ScrollController _liveGroupsScrollController = ScrollController();
  // Expandable drawer keys in Settings tab
  final Set<String> _expandedSettings = <String>{};
  List<WatchHistoryEntry> _cachedWatchHistory = const [];
  bool _onboardingRouteOpen = false;
  bool _officialNoticeOpen = false;
  bool _copyingAuthorSocialName = false;
  int _authorSocialCopyToken = 0;
  BuildContext? _authorSocialOriginContext;
  ModalRoute<dynamic>? _authorSocialOriginRoute;
  int? _authorSocialOriginTabIndex;
  bool _openingOfficialCommunityLink = false;
  int _officialCommunityActionToken = 0;
  BuildContext? _officialCommunityOriginContext;
  ModalRoute<dynamic>? _officialCommunityOriginRoute;
  int? _officialCommunityOriginTabIndex;
  bool _startupOnboardingChecked = false;
  bool _startupOfficialNoticeChecked = false;
  bool _officialNoticeDialogOpen = false;
  bool get _isMacOS =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      !OhosRuntime.isOhos;
  CmsFilter get _currentFilter => CmsFilter(
        primaryTab: _primaryTab,
        categoryId: _filterSubCategoryId,
        genreLabel: _filterGenreLabel,
        area: _filterArea,
        year: _filterYear,
      );
  List<CmsSite> get _visibleSupportedSites {
    final cfg = _config;
    if (cfg == null) return const [];
    return _privateSessionUnlocked
        ? cfg.privateSupportedSites
        : cfg.publicSupportedSites;
  }
  List<LiveSource> get _visibleLives {
    final cfg = _config;
    if (cfg == null) return const [];
    return _privateSessionUnlocked
        ? cfg.privateSupportedLives
        : cfg.publicSupportedLives;
  }
  void _updateWindowsState(VoidCallback change) => setState(change);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dockMorphCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_onDockMorphTick);
    _homeScrollController.addListener(_onHomeScroll);
    PosterLoader.cacheRevision.addListener(_onPosterCacheUpdated);
    _cachedWatchHistory = widget.storage.getWatchHistory();
    _liveHideUnreachable = widget.storage.liveHideUnreachable;
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      windowManager.addListener(this);
      _windowListenerAttached = true;
      unawaited(windowManager.setPreventClose(true));
      if (Platform.isWindows) {
        WindowsTrayService.attach(
          onRestore: () {
            unawaited(windowManager.show());
            unawaited(windowManager.focus());
          },
          onQuit: () {
            unawaited(_executeWindowExit());
          },
        );
      }
    }
    unawaited(_loadInstalledVersion());
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !OhosRuntime.isOhos &&
        !Platform.environment.containsKey('FLUTTER_TEST') &&
        widget.storage.autoHardwareQualityEnabled &&
        widget.storage.lastHardwareProfileSummary.isEmpty) {
      unawaited(DeviceQualityProfiler.detectAndApply(widget.storage));
    }
    GlassworkBackdrop.reduceTransparency.value =
        widget.storage.glassBlurLevel == 'solid' ||
            widget.storage.glassBlurStrength <= 0.02;
    GlassworkBackdrop.intensity.value = widget.storage.glassBlurStrength;
    widget.storage.watchHistoryRevision.addListener(_onWatchHistoryRevision);
    widget.storage.historyCorruptionNotifier.addListener(_onHistoryCorruption);
    widget.storage.subscriptionsCorruptionNotifier.addListener(
      _onSubscriptionsCorruption,
    );
    widget.storage.credentialMigrationFailureNotifier.addListener(
      _onCredentialMigrationFailure,
    );
    if (widget.storage.isHistoryCorrupted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onHistoryCorruption();
      });
    }
    if (widget.storage.isSubscriptionsCorrupted) {
      _onSubscriptionsCorruption();
    }
    if (widget.storage.credentialMigrationFailureNotifier.value) {
      _onCredentialMigrationFailure();
    }
    _reloadSavedConfig();
    IosLiquidGlassBridge.available.addListener(_onRootChromeDependencyChanged);
    IosLiquidGlassBridge.sceneActiveNotifier.addListener(
      _onSceneActivationChanged,
    );
    IosLiquidGlassBridge.activeSheetNotifier.addListener(
      _onRootOverlayVisibilityChanged,
    );
    IosLiquidGlassBridge.rootTabSuppressionCount.addListener(
      _onRootOverlayVisibilityChanged,
    );
    IosRootTabNavigatorObserver.secondaryRouteDepth.addListener(
      _onRootOverlayVisibilityChanged,
    );
    IosRootTabNavigatorObserver.topRouteIsCurated.addListener(
      _onRootOverlayVisibilityChanged,
    );
    activeAppleModalSheetCount.addListener(_onRootOverlayVisibilityChanged);
    activeIosGlassPopoverCount.addListener(_onRootOverlayVisibilityChanged);
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !OhosRuntime.isOhos) {
      unawaited(
        DiskBlockCache.shared.setCapacityMb(
          widget.storage.mediaDiskCacheLimitMb,
        ),
      );
      unawaited(_initRootNativeTabChrome());
    }
    unawaited(_runStartupPrompts());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        MarcoLaunchDiagnostics.record(
          'shell_interactive',
          'subs=${widget.storage.getSubscriptions().length}',
        );
      }
    });
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(_runStartupWebdavSync());
    }
  }

  Future<void> _initRootNativeTabChrome() async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        OhosRuntime.isOhos) {
      return;
    }
    await IosLiquidGlassBridge.ensureInitialized();
    if (!mounted) return;
    if (!IosLiquidGlassBridge.isAvailable) {
      if (_useRootNativeTabChrome) {
        setState(() => _useRootNativeTabChrome = false);
      }
      _useRootNativeTabChromeNotifier.value = false;
      return;
    }
    final items = _buildIosNativeDockItems();
    final safeIdx = _tabIndex.clamp(0, items.length - 1);
    final owner = _computeDockOwner();
    _dockOwner = owner;
    final epoch = ++_dockEpoch;
    final configured = await IosLiquidGlassBridge.configureRootTabChrome(
      items: items,
      selectedIndex: safeIdx,
      showSearch: true,
      visible: owner != IosDockOwner.hidden,
      minimized: owner == IosDockOwner.curated || (_dockCollapsed && safeIdx == 0),
      adaptiveTopOnWide: true,
      epoch: epoch,
      onSelect: _handleRootNativeTabSelected,
      onSearch: _showGlobalSearchSheet,
      onScrollToTop: _scrollHomeToTop,
      onTabMenuAction: _handleDockTabMenuAction,
    );
    if (!mounted) return;
    _useRootNativeTabChromeNotifier.value = configured;
    if (configured != _useRootNativeTabChrome) {
      setState(() => _useRootNativeTabChrome = configured);
    }
    if (configured) {
      _lastReportedDockVisible = owner != IosDockOwner.hidden;
      _reconcileDockOwnership(animated: false);
    }
  }

  void _onRootChromeDependencyChanged() {
    if (!mounted) return;
    if (IosLiquidGlassBridge.isAvailable && !_useRootNativeTabChrome) {
      unawaited(_initRootNativeTabChrome());
    } else if (!IosLiquidGlassBridge.isAvailable && _useRootNativeTabChrome) {
      _useRootNativeTabChromeNotifier.value = false;
      setState(() => _useRootNativeTabChrome = false);
    }
  }

  void _onSceneActivationChanged() {
    if (!mounted) return;
    final next = IosLiquidGlassBridge.isSceneActive;
    if (next != _sceneActive) {
      setState(() => _sceneActive = next);
    }
  }

  void _onRootOverlayVisibilityChanged() {
    if (!mounted) return;
    _reconcileDockOwnership(animated: true);
  }

  void _onCuratedRouteEntered() {
    if (!mounted) return;
    _curatedRouteDepth++;
    _homeUserDragging = false;
    _reconcileDockOwnership(animated: true);
  }

  void _onCuratedRouteExited() {
    if (!mounted) return;
    _curatedRouteDepth = math.max(0, _curatedRouteDepth - 1);
    _reconcileDockOwnership(animated: true);
  }

  void _onDockMorphTick() {
    if (!mounted) return;
    final eased = Curves.easeOutCubic.transform(_dockMorphCtrl.value);
    final nextP = (_dockMorphFrom + (_dockMorphTo - _dockMorphFrom) * eased)
        .clamp(0.0, 1.0);
    _dockScrollProgress.value = nextP;
    _dockCollapsed = nextP >= 0.5;
  }

  void _animateDockProgressTo(
    double target, {
    required bool animated,
    required int epoch,
  }) {
    final clampedTarget = target.clamp(0.0, 1.0);
    final token = ++_dockMorphAnimToken;
    _dockMorphCtrl.stop();
    final current = _dockScrollProgress.value.clamp(0.0, 1.0);
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    _dockCollapsed = clampedTarget >= 0.5;
    if (!animated || reduceMotion || (current - clampedTarget).abs() <= 0.004) {
      _dockScrollProgress.value = clampedTarget;
    } else {
      _dockMorphFrom = current;
      _dockMorphTo = clampedTarget;
      _dockMorphCtrl.value = 0.0;
      unawaited(
        _dockMorphCtrl.forward().whenComplete(() {
          if (!mounted || token != _dockMorphAnimToken) return;
          _dockScrollProgress.value = clampedTarget;
          _dockCollapsed = clampedTarget >= 0.5;
        }),
      );
    }
    if (_useRootNativeTabChrome) {
      _lastReportedDockProgress = clampedTarget;
      unawaited(
        IosLiquidGlassBridge.setRootTabMinimized(
          clampedTarget >= 0.5,
          animated: animated && !reduceMotion,
          epoch: epoch,
        ),
      );
    }
  }

  double _stableHomeDockTargetForOffset(double offset, {bool useHysteresis = false}) {
    if (offset <= 12.0) return 0.0;
    if (offset >= 152.0) return 1.0;
    final progress = ((offset - 12.0) / 140.0).clamp(0.0, 1.0);
    final threshold = useHysteresis
        ? (_dockStableCollapsed ? 0.44 : 0.56)
        : 0.5;
    return progress >= threshold ? 1.0 : 0.0;
  }

  void _settleHomeDockToStableEndpoint({bool animated = true}) {
    if (!mounted || _dockOwner != IosDockOwner.home || _tabIndex != 0) return;
    final offset =
        _homeScrollController.hasClients ? _homeScrollController.offset : 0.0;
    final target = _stableHomeDockTargetForOffset(offset, useHysteresis: true);
    _dockStableCollapsed = target >= 0.5;
    final epoch = ++_dockEpoch;
    _animateDockProgressTo(target, animated: animated, epoch: epoch);
  }

  void _handleRootNativeTabSelected(int index) {
    if (!mounted) return;
    final items = _buildIosNativeDockItems();
    final clamped = index.clamp(0, items.length - 1);
    final wasInCurated = _curatedRouteDepth > 0 ||
        IosRootTabNavigatorObserver.topRouteIsCurated.value ||
        IosRootTabNavigatorObserver.curatedRouteDepth.value > 0;
    if (wasInCurated) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _curatedRouteDepth = 0;
    }
    final homeOffset =
        _homeScrollController.hasClients ? _homeScrollController.offset : 0.0;
    final targetProgress = clamped == 0
        ? _stableHomeDockTargetForOffset(homeOffset)
        : 0.0;
    _dockStableCollapsed = clamped == 0 && targetProgress >= 0.5;
    setState(() {
      _tabIndex = clamped;
      _dockCollapsed = targetProgress >= 0.5;
    });
    _selectedTabIndexNotifier.value = clamped;
    final epoch = ++_dockEpoch;
    if (_useRootNativeTabChrome) {
      unawaited(
        IosLiquidGlassBridge.setRootTabSelectedIndex(clamped, epoch: epoch),
      );
    }
    _dockOwner = _computeDockOwner();
    _curatedDockVisibleNotifier.value = _dockOwner == IosDockOwner.curated;
    _syncRootTabVisibility(animated: true, forceEpoch: epoch);
    if (_dockOwner == IosDockOwner.home || _dockOwner == IosDockOwner.rootTab) {
      _animateDockProgressTo(targetProgress, animated: true, epoch: ++_dockEpoch);
    }
  }

  IosDockOwner _computeDockOwner() {
    if (_privacyPortalAnimating ||
        _settingsSecondaryRouteActive ||
        IosLiquidGlassBridge.rootTabSuppressionCount.value > 0 ||
        activeAppleModalSheetCount.value > 0 ||
        activeIosGlassPopoverCount.value > 0 ||
        IosLiquidGlassBridge.activeSheetNotifier.value) {
      return IosDockOwner.hidden;
    }
    final obsDepth = IosRootTabNavigatorObserver.secondaryRouteDepth.value;
    final obsTopCurated = IosRootTabNavigatorObserver.topRouteIsCurated.value;
    final obsCuratedDepth = IosRootTabNavigatorObserver.curatedRouteDepth.value;
    final nonCuratedPushed =
        _pushedRouteDepth > 0 || (obsDepth > 0 && !obsTopCurated);
    if (nonCuratedPushed) {
      return IosDockOwner.hidden;
    }
    if (_curatedRouteDepth > 0 || obsTopCurated || obsCuratedDepth > 0) {
      return IosDockOwner.curated;
    }
    return _tabIndex == 0 ? IosDockOwner.home : IosDockOwner.rootTab;
  }

  bool _computeRootTabShouldBeVisible() =>
      _computeDockOwner() != IosDockOwner.hidden;

  void _reconcileDockOwnership({bool animated = true}) {
    final prevOwner = _dockOwner;
    final nextOwner = _computeDockOwner();
    _dockOwner = nextOwner;
    _curatedDockVisibleNotifier.value = nextOwner == IosDockOwner.curated;
    final epoch = ++_dockEpoch;
    _syncRootTabVisibility(animated: animated, forceEpoch: epoch);

    if (nextOwner == IosDockOwner.hidden) {
      _homeUserDragging = false;
      _dockMorphAnimToken++;
      _dockMorphCtrl.stop();
      return;
    }
    if (nextOwner == IosDockOwner.curated) {
      _homeUserDragging = false;
      _animateDockProgressTo(1.0, animated: animated, epoch: ++_dockEpoch);
      return;
    }
    if (nextOwner == IosDockOwner.rootTab) {
      _homeUserDragging = false;
      _dockStableCollapsed = false;
      _animateDockProgressTo(0.0, animated: animated, epoch: ++_dockEpoch);
      return;
    }
    // nextOwner == IosDockOwner.home
    if (prevOwner != IosDockOwner.home) {
      final offset =
          _homeScrollController.hasClients ? _homeScrollController.offset : 0.0;
      final target = _stableHomeDockTargetForOffset(offset);
      _dockStableCollapsed = target >= 0.5;
      _animateDockProgressTo(target, animated: animated, epoch: ++_dockEpoch);
    }
  }

  void _syncRootTabVisibility({bool animated = true, int? forceEpoch}) {
    if (!_useRootNativeTabChrome) return;
    final shouldBeVisible = _computeRootTabShouldBeVisible();
    if (shouldBeVisible != _lastReportedDockVisible) {
      _lastReportedDockVisible = shouldBeVisible;
      unawaited(
        IosLiquidGlassBridge.setRootTabVisible(
          shouldBeVisible,
          animated: animated,
          epoch: forceEpoch ?? ++_dockEpoch,
        ),
      );
    }
  }

  Future<T?> _trackSecondaryRoute<T>(Future<T?> Function() pushFn) async {
    _pushedRouteDepth++;
    _reconcileDockOwnership(animated: true);
    try {
      return await pushFn();
    } finally {
      _pushedRouteDepth = math.max(0, _pushedRouteDepth - 1);
      if (mounted) {
        _reconcileDockOwnership(animated: true);
      }
    }
  }

  Future<void> _runStartupPrompts() async {
    if (_isMacOS) {
      await _maybeShowMacosFirstLaunchOfficialNotice();
    }
    if (!mounted) return;
    await _runFirstLaunchPrompts();
  }

  Future<void> _maybeShowMacosFirstLaunchOfficialNotice() async {
    if (_startupOfficialNoticeChecked || !_isMacOS || !mounted) return;
    _startupOfficialNoticeChecked = true;
    final prefs = await MacosOfficialNoticePrefs.load();
    if (!mounted || !prefs.shouldShow(isMacosOverride: _isMacOS)) return;
    final ready = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ready.isCompleted) ready.complete();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    await ready.future;
    if (!mounted || _officialNoticeDialogOpen) return;
    _officialNoticeDialogOpen = true;
    try {
      final confirmed = await showMacosFirstLaunchOfficialNoticeDialog(
        context,
        onOpenUrl: widget.onOpenExternalUrlForTest,
        onCopyText: widget.onCopyTextForTest,
      );
      if (confirmed == true) {
        await prefs.markAcknowledged();
      }
    } finally {
      _officialNoticeDialogOpen = false;
    }
  }

  Future<void> _runFirstLaunchPrompts() async {
    if (_startupOnboardingChecked || !mounted) return;
    _startupOnboardingChecked = true;
    // Only launch first-run prompts on fresh installs without existing configs
    // (never hijack corruption recovery alerts or upgraded installations).
    if (_config != null ||
        widget.storage.getSubscriptions().isNotEmpty ||
        widget.storage.isSubscriptionsCorrupted ||
        widget.storage.isHistoryCorrupted) {
      return;
    }
    final OnboardingPrefs prefs;
    try {
      prefs = await OnboardingPrefs.load().timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('OnboardingPrefs load skipped on cold launch: $e');
      return;
    }
    if (!mounted) return;
    if (_config != null ||
        widget.storage.getSubscriptions().isNotEmpty ||
        widget.storage.isSubscriptionsCorrupted ||
        widget.storage.isHistoryCorrupted) {
      return;
    }
    final isFreshInstall = prefs.doneVersion < OnboardingPrefs.currentVersion;
    if (isFreshInstall &&
        !OhosRuntime.isOhos &&
        !_isMacOS &&
        prefs.shouldShowOfficialChannelNotice() &&
        !_officialNoticeOpen) {
      final frameReady = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!frameReady.isCompleted) frameReady.complete();
      });
      await frameReady.future;
      if (!mounted ||
          _officialNoticeOpen ||
          _config != null ||
          widget.storage.getSubscriptions().isNotEmpty ||
          widget.storage.isSubscriptionsCorrupted ||
          widget.storage.isHistoryCorrupted) {
        return;
      }
      _officialNoticeOpen = true;
      var acknowledged = false;
      var persisted = false;
      try {
        acknowledged = await showOfficialChannelNoticeDialog(
          context,
          urlOpener: widget.onOpenExternalUrlForTest,
          onConfirm: () async {
            persisted = await prefs.markOfficialChannelNoticeSeen();
            return persisted;
          },
        );
      } finally {
        _officialNoticeOpen = false;
      }
      if (acknowledged && !persisted) {
        debugPrint(
          'OfficialChannelNotice: acknowledged for current session; preference write did not persist.',
        );
      }
      if (!mounted || !acknowledged) return;
    }
    if (OhosRuntime.isOhos || !prefs.shouldShowOnboarding()) return;
    if (_config != null ||
        widget.storage.getSubscriptions().isNotEmpty ||
        widget.storage.isSubscriptionsCorrupted ||
        widget.storage.isHistoryCorrupted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _onboardingRouteOpen) return;
      unawaited(_openOnboardingRoute(preloadedPrefs: prefs));
    });
  }

  bool _isSettingsOriginActive(
    BuildContext originContext,
    ModalRoute<dynamic>? originRoute,
    int originTabIndex,
  ) {
    if (!mounted || !originContext.mounted) return false;
    if (_tabIndex != originTabIndex) return false;
    if (originRoute != null && !originRoute.isCurrent) return false;
    return true;
  }

  Future<void> _copyAuthorSocialName({BuildContext? originContext}) async {
    final targetContext = originContext ?? context;
    if (_copyingAuthorSocialName &&
        _authorSocialOriginContext != null &&
        _authorSocialOriginTabIndex != null &&
        _isSettingsOriginActive(
          _authorSocialOriginContext!,
          _authorSocialOriginRoute,
          _authorSocialOriginTabIndex!,
        )) {
      return;
    }
    final token = ++_authorSocialCopyToken;
    final originRoute = ModalRoute.of(targetContext);
    final originTabIndex = _tabIndex;
    _copyingAuthorSocialName = true;
    _authorSocialOriginContext = targetContext;
    _authorSocialOriginRoute = originRoute;
    _authorSocialOriginTabIndex = originTabIndex;
    beginExplicitOfficialClipboardCopy();
    try {
      final copied = await copyOfficialChannelText(
        OfficialChannelInfo.authorSocialName,
      );
      if (token != _authorSocialCopyToken ||
          !_isSettingsOriginActive(
            targetContext,
            originRoute,
            originTabIndex,
          ) ||
          !targetContext.mounted) {
        return;
      }
      if (copied) {
        await showAppleNativeAlert(
          targetContext,
          title: '已复制作者社媒账号名',
          message:
              '账号名：${OfficialChannelInfo.authorSocialName}\n支持平台：${OfficialChannelInfo.socialPlatformsDisplay}。',
          actions: const [
            AppleNativeAlertAction(id: 'ok', title: '好', isDefault: true),
          ],
        );
        return;
      }
      await showOfficialChannelManualCopyDialog(
        targetContext,
        title: '复制失败，请手动选取',
        message:
            '当前无法写入系统剪贴板，请手动选取以下作者社媒账号名（${OfficialChannelInfo.socialPlatformsDisplay}）：',
        selectableValue: OfficialChannelInfo.authorSocialName,
      );
    } finally {
      if (token == _authorSocialCopyToken) {
        _copyingAuthorSocialName = false;
        _authorSocialOriginContext = null;
        _authorSocialOriginRoute = null;
        _authorSocialOriginTabIndex = null;
      }
    }
  }

  Future<void> _openOfficialCommunityLink({BuildContext? originContext}) async {
    final targetContext = originContext ?? context;
    if (_openingOfficialCommunityLink &&
        _officialCommunityOriginContext != null &&
        _officialCommunityOriginTabIndex != null &&
        _isSettingsOriginActive(
          _officialCommunityOriginContext!,
          _officialCommunityOriginRoute,
          _officialCommunityOriginTabIndex!,
        )) {
      return;
    }
    final token = ++_officialCommunityActionToken;
    final originRoute = ModalRoute.of(targetContext);
    final originTabIndex = _tabIndex;
    final startClipboardEpoch = officialExplicitClipboardEpoch;
    _openingOfficialCommunityLink = true;
    _officialCommunityOriginContext = targetContext;
    _officialCommunityOriginRoute = originRoute;
    _officialCommunityOriginTabIndex = originTabIndex;
    try {
      final opened = await launchExternalOfficialUrl(
        OfficialChannelInfo.officialCommunityUri,
        urlOpener: widget.onOpenExternalUrlForTest,
      );
      if (opened) {
        return;
      }
      // Validate origin, action token, and clipboard epoch BEFORE any fallback
      // clipboard write so an abandoned or superseded link request never
      // overwrites a newer explicit copy (staying on page or after re-entry).
      if (token != _officialCommunityActionToken ||
          officialExplicitClipboardEpoch != startClipboardEpoch ||
          !_isSettingsOriginActive(
            targetContext,
            originRoute,
            originTabIndex,
          ) ||
          !targetContext.mounted) {
        return;
      }
      final copied = await copyOfficialChannelText(
        OfficialChannelInfo.officialCommunityUrl,
      );
      if (token != _officialCommunityActionToken ||
          officialExplicitClipboardEpoch != startClipboardEpoch ||
          !_isSettingsOriginActive(
            targetContext,
            originRoute,
            originTabIndex,
          ) ||
          !targetContext.mounted) {
        return;
      }
      if (copied) {
        await showAppleNativeAlert(
          targetContext,
          title: '已复制官网交流群链接',
          message: '请在浏览器中打开：${OfficialChannelInfo.officialCommunityUrl}',
          actions: const [
            AppleNativeAlertAction(id: 'ok', title: '好', isDefault: true),
          ],
        );
        return;
      }
      await showOfficialChannelManualCopyDialog(
        targetContext,
        title: '无法自动打开或复制链接',
        message: '请手动选取以下官网交流群地址，并在浏览器中打开：',
        selectableValue: OfficialChannelInfo.officialCommunityUrl,
      );
    } finally {
      if (token == _officialCommunityActionToken) {
        _openingOfficialCommunityLink = false;
        _officialCommunityOriginContext = null;
        _officialCommunityOriginRoute = null;
        _officialCommunityOriginTabIndex = null;
      }
    }
  }

  Future<void> _openOfficialNoticeDialogFromSettings() async {
    if (!mounted || _officialNoticeOpen) return;
    _officialNoticeOpen = true;
    try {
      await showOfficialChannelNoticeDialog(
        context,
        urlOpener: widget.onOpenExternalUrlForTest,
        barrierDismissible: true,
      );
    } finally {
      _officialNoticeOpen = false;
    }
  }

  Future<void> _openOnboardingRoute({
    bool isReplay = false,
    OnboardingPrefs? preloadedPrefs,
  }) async {
    if (OhosRuntime.isOhos || _onboardingRouteOpen || !mounted) return;
    final prefs = preloadedPrefs ?? await OnboardingPrefs.load();
    if (!mounted || _onboardingRouteOpen) return;
    if (isReplay) {
      await prefs.resetForReplay();
      if (!mounted) return;
    }
    _onboardingRouteOpen = true;
    var routePopped = false;
    void closeRoute() {
      if (routePopped || !mounted) return;
      routePopped = true;
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    }

    final initialBlurLevel = widget.storage.glassBlurLevel;
    final initialBlurStrength = widget.storage.glassBlurStrength;
    final restoredNonSolidLevel =
        initialBlurLevel == 'solid' ? 'standard' : initialBlurLevel;
    final double? restoredNonSolidStrength =
        initialBlurLevel == 'solid' ? null : initialBlurStrength;

    try {
      await _trackSecondaryRoute<void>(
        () => Navigator.of(context).push<void>(
          buildApplePageRoute<void>(
            builder: (routeCtx) => OnboardingScreen(
            prefs: prefs,
            initialReduceTransparency:
                widget.storage.glassBlurLevel == 'solid' ||
                    GlassworkBackdrop.reduceTransparency.value,
            backgroundBuilder: (bgCtx) {
              if (isWindowsDesktopUi &&
                  WindowsAppearanceScope.maybeOf(bgCtx) != null) {
                return const WindowsBackdrop(child: SizedBox.expand());
              }
              return const AuroraBackground();
            },
            onPersonalizationChanged: (
              reduceMotion,
              reduceTransparency,
              textScale,
            ) {
              if (OhosRuntime.isOhos) return;
              GlassworkBackdrop.reduceTransparency.value = reduceTransparency;
              if (reduceTransparency) {
                if (widget.storage.glassBlurLevel != 'solid') {
                  unawaited(widget.storage.setGlassBlurLevel('solid'));
                }
                GlassworkBackdrop.intensity.value = 0.0;
              } else if (widget.storage.glassBlurLevel == 'solid') {
                // Only write when recovering from 'solid'; preserve any
                // existing non-solid preference ('light', 'standard', 'deep')
                // when replaying onboarding to adjust other controls.
                if (restoredNonSolidStrength != null &&
                    restoredNonSolidStrength > 0.05) {
                  unawaited(
                    widget.storage.setGlassBlurStrength(
                      restoredNonSolidStrength,
                    ),
                  );
                  GlassworkBackdrop.intensity.value = restoredNonSolidStrength;
                } else {
                  unawaited(
                    widget.storage.setGlassBlurLevel(restoredNonSolidLevel),
                  );
                  GlassworkBackdrop.intensity.value = switch (
                      restoredNonSolidLevel) {
                    'light' => 0.35,
                    'deep' => 1.0,
                    _ => 0.68,
                  };
                }
              }
            },
            onImportConfig: (initialAddress) {
              unawaited(prefs.markOnboardingCompleted());
              closeRoute();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                unawaited(
                  _showImportConfigDialog(initialInput: initialAddress.trim()),
                );
              });
            },
            onOpenSync: () {
              unawaited(prefs.markOnboardingCompleted());
              closeRoute();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                unawaited(_openCloudSyncCenter());
              });
            },
            onFinished: (_) {
              closeRoute();
            },
          ),
        ),
        ),
      );
    } finally {
      _onboardingRouteOpen = false;
    }
  }
  Future<void> _runStartupWebdavSync() async {
    await widget.storage.waitForCredentialsReady();
    if (!mounted) return;
    if (!widget.storage.isWebdavConfigured || !widget.storage.webdavAuto) {
      return;
    }
    try {
      final res = await widget.storage.syncWithWebdav();
      if (!mounted) return;
      if (res.subscriptionsChanged) {
        _reloadSavedConfig();
      } else if (res.changed) {
        setState(() {});
      }
    } catch (_) {}
  }
  Future<void> _openCloudSyncCenter({String iosBackLabel = '返回'}) async {
    if (_privateSessionUnlocked) {
      _showAppleNotice('隐私空间已隔离', '隐私空间不参与网络同步，请先退出隐私模式再使用多端同步。');
      return;
    }
    await _trackSecondaryRoute<void>(
      () => showCloudSyncSheet(
        context,
        widget.storage,
        iosBackLabel: iosBackLabel,
        onSynced: ({required subscriptionsChanged}) {
          if (!mounted) return;
          if (subscriptionsChanged) {
            _reloadSavedConfig();
          } else {
            setState(() {});
          }
        },
      ),
    );
    if (mounted) setState(() {});
  }
  void _openSyncedMediaEntry({
    required String siteKey,
    required String videoId,
    required String title,
    String poster = '',
    String remarks = '',
    BuildContext? sourceContext,
    double sourceRadius = 14.0,
    String? sourceCardId,
  }) {
    final pool = _visibleSupportedSites;
    CmsSite? matched;
    for (final s in pool) {
      if (s.key == siteKey && s.supported) {
        matched = s;
        break;
      }
    }
    if (matched == null) {
      for (final s in pool) {
        if (s.key == siteKey) {
          matched = s;
          break;
        }
      }
    }
    if (matched != null) {
      if (!matched.supported) {
        _showAppleNotice(matched.name, matched.unsupportedReason);
        return;
      }
      _openVideoDetail(
        matched,
        CmsVideo(
          id: videoId,
          title: title,
          poster: poster,
          remarks: remarks,
        ),
        sourceContext: sourceContext,
        sourceRadius: sourceRadius,
        sourceCardId: sourceCardId,
      );
      return;
    }
    final availablePool = pool.where((s) => s.supported).toList();
    if (availablePool.isEmpty) {
      _showAppleNotice(
        '尚未导入对应片源',
        '本机暂无可用片源，可在「设置 → 多端网络同步」开启订阅源同步或导入订阅后继续观看「$title」。',
      );
      return;
    }
    final kw = title.trim();
    if (kw.isEmpty) return;
    _searchController.text = kw;
    _runGlobalSearch(kw);
    _showGlobalSearchSheet();
  }
  Future<void> _flushPendingHistoryForCloseOrDispose() {
    return _closingHistoryFlush ??= (widget.onFlushHistoryForTest != null
        ? widget.onFlushHistoryForTest!()
        : widget.storage.flushPendingHistory());
  }

  @override
  Future<void> onWindowClose() async {
    if (!kIsWeb &&
        (Platform.isWindows || defaultTargetPlatform == TargetPlatform.windows) &&
        widget.storage.windowsCloseAction == 'tray') {
      unawaited(widget.storage.flushPendingHistory());
      final hidden = await WindowsTrayService.hideToTray(tooltip: 'Marco Movie');
      if (hidden) {
        return;
      }
      try {
        await windowManager.minimize();
        return;
      } catch (_) {}
    }
    await _executeWindowExit();
  }

  Future<void> _executeWindowExit() async {
    if (_isClosingWindow) return;
    _isClosingWindow = true;
    if (!kIsWeb &&
        (Platform.isWindows || defaultTargetPlatform == TargetPlatform.windows)) {
      unawaited(WindowsTrayService.removeTray());
    }
    await AdaptiveShell.runWindowCloseSequence(
      setPreventClose: (prevent) => widget.onSetPreventCloseForTest != null
          ? widget.onSetPreventCloseForTest!(prevent)
          : windowManager.setPreventClose(prevent),
      hideWindow: widget.onDestroyWindowForTest != null
          ? null
          : () => windowManager.hide(),
      flushHistory: _flushPendingHistoryForCloseOrDispose,
      flushSync: (timeout) => widget.onFlushSyncForTest != null
          ? widget.onFlushSyncForTest!(timeout)
          : widget.storage.flushPendingSync(timeout: timeout),
      closeHost: () => widget.onCloseHostForTest != null
          ? widget.onCloseHostForTest!()
          : CatPawHost.instance.close(),
      closeScripts: () => widget.onCloseScriptsForTest != null
          ? widget.onCloseScriptsForTest!()
          : CmsClient.closeScriptSessions(),
      destroyWindow: () => widget.onDestroyWindowForTest != null
          ? widget.onDestroyWindowForTest!()
          : windowManager.destroy(),
      totalBudget: widget.windowCloseTotalBudgetForTest ??
          AdaptiveShell.defaultWindowCloseBudget,
    );
  }

  void _onHistoryCorruption() {
    if (!mounted || !widget.storage.isHistoryCorrupted) return;
    _showAppleNotice(
      '观看历史数据异常',
      '检测到本地历史记录文件损坏，已自动为您备份并暂停同步以防止数据覆盖。可在设置中查看备份或重新同步。',
    );
  }

  void _onSubscriptionsCorruption() {
    if (!mounted || !widget.storage.isSubscriptionsCorrupted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.storage.consumeSubscriptionsCorruptionNotice()) {
        return;
      }
      unawaited(
        showAppleNativeAlert(
          context,
          title: '订阅数据异常',
          message:
              '检测到本地订阅文件读取或解析异常，已自动隔离备份并开启写保护以防止覆盖原数据。修复或替换文件后可点击「重新加载订阅」恢复。',
          actions: const [
            AppleNativeAlertAction(
              key: ValueKey('reload-subscriptions-action'),
              id: 'reload',
              title: '重新加载订阅',
            ),
            AppleNativeAlertAction(
              id: 'ok',
              title: '好',
              isDefault: true,
            ),
          ],
        ).then((choice) async {
          if (choice != 'reload' || !mounted) return;
          final recovered =
              await widget.storage.reloadSubscriptionsFromDisk();
          if (!mounted) return;
          _reloadSavedConfig();
          if (recovered) {
            _showAppleNotice('已重新加载订阅', '订阅文件已恢复正常并解除写保护。');
          }
        }),
      );
    });
  }

  void _onCredentialMigrationFailure() {
    if (!mounted || !widget.storage.credentialMigrationFailureNotifier.value) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.storage.consumeCredentialMigrationFailureNotice()) {
        return;
      }
      _showAppleNotice(
        '凭据迁移提示',
        '旧版加密凭据文件无法解密，原文件已保留为 .bak 备份。请重新输入 WebDAV 密码或云盘登录凭据。',
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(widget.storage.flushPendingHistory());
      widget.storage.scheduleAutoWebdavSync(immediate: true);
    } else if (state == AppLifecycleState.resumed) {
      unawaited(CatPawHost.instance.onAppResumed());
      unawaited(CmsClient.onAppResumed());
    }
  }

  void _onWatchHistoryRevision() {
    if (mounted) {
      setState(() {
        _cachedWatchHistory = widget.storage.getWatchHistory();
    _liveHideUnreachable = widget.storage.liveHideUnreachable;
      });
    }
  }
  @override
  void didUpdateWidget(AdaptiveShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.storage != oldWidget.storage) {
      oldWidget.storage.watchHistoryRevision.removeListener(_onWatchHistoryRevision);
      oldWidget.storage.historyCorruptionNotifier.removeListener(_onHistoryCorruption);
      oldWidget.storage.subscriptionsCorruptionNotifier.removeListener(
        _onSubscriptionsCorruption,
      );
      oldWidget.storage.credentialMigrationFailureNotifier.removeListener(
        _onCredentialMigrationFailure,
      );
      widget.storage.watchHistoryRevision.addListener(_onWatchHistoryRevision);
      widget.storage.historyCorruptionNotifier.addListener(_onHistoryCorruption);
      widget.storage.subscriptionsCorruptionNotifier.addListener(
        _onSubscriptionsCorruption,
      );
      widget.storage.credentialMigrationFailureNotifier.addListener(
        _onCredentialMigrationFailure,
      );
      _cachedWatchHistory = widget.storage.getWatchHistory();
    _liveHideUnreachable = widget.storage.liveHideUnreachable;
      if (widget.storage.isSubscriptionsCorrupted) {
        _onSubscriptionsCorruption();
      }
      if (widget.storage.credentialMigrationFailureNotifier.value) {
        _onCredentialMigrationFailure();
      }
    }
  }
  @override
  void dispose() {
    IosLiquidGlassBridge.available.removeListener(
      _onRootChromeDependencyChanged,
    );
    IosLiquidGlassBridge.sceneActiveNotifier.removeListener(
      _onSceneActivationChanged,
    );
    IosLiquidGlassBridge.activeSheetNotifier.removeListener(
      _onRootOverlayVisibilityChanged,
    );
    IosLiquidGlassBridge.rootTabSuppressionCount.removeListener(
      _onRootOverlayVisibilityChanged,
    );
    IosRootTabNavigatorObserver.secondaryRouteDepth.removeListener(
      _onRootOverlayVisibilityChanged,
    );
    IosRootTabNavigatorObserver.topRouteIsCurated.removeListener(
      _onRootOverlayVisibilityChanged,
    );
    activeAppleModalSheetCount.removeListener(_onRootOverlayVisibilityChanged);
    activeIosGlassPopoverCount.removeListener(_onRootOverlayVisibilityChanged);
    if (_useRootNativeTabChrome) {
      unawaited(IosLiquidGlassBridge.setRootTabVisible(false, animated: false));
    }
    WidgetsBinding.instance.removeObserver(this);
    widget.storage.credentialMigrationFailureNotifier.removeListener(
      _onCredentialMigrationFailure,
    );
    widget.storage.subscriptionsCorruptionNotifier.removeListener(
      _onSubscriptionsCorruption,
    );
    widget.storage.historyCorruptionNotifier.removeListener(_onHistoryCorruption);
    widget.storage.watchHistoryRevision.removeListener(_onWatchHistoryRevision);
    unawaited(_flushPendingHistoryForCloseOrDispose());
    widget.storage.cancelPendingAutoSync();
    if (_windowListenerAttached) {
      windowManager.removeListener(this);
      _windowListenerAttached = false;
      if (!kIsWeb && Platform.isWindows) {
        WindowsTrayService.detach();
        unawaited(WindowsTrayService.removeTray());
      }
    }
    if (!kIsWeb &&
        (Platform.isWindows ||
            Platform.isMacOS ||
            Platform.isLinux ||
            widget.onSetPreventCloseForTest != null)) {
      unawaited(
        (widget.onSetPreventCloseForTest != null
                ? widget.onSetPreventCloseForTest!(false)
                : windowManager.setPreventClose(false))
            .catchError((Object e) {
              debugPrint('AdaptiveShell: setPreventClose(false) on dispose skipped: $e');
            }),
      );
    }
    _installedVersionTimer?.cancel();
    _cancelCatalogue();
    if (_liveAbort != null && !_liveAbort!.isCompleted) _liveAbort!.complete();
    if (_liveProbeAbort != null && !_liveProbeAbort!.isCompleted) {
      _liveProbeAbort!.complete();
    }
    _searchSubscription?.cancel();
    unawaited(CatPawHost.instance.close());
    unawaited(CmsClient.closeScriptSessions());
    _searchController.dispose();
    _searchStateRevision.dispose();
    _liveSearchController.dispose();
    _homeScrollController.removeListener(_onHomeScroll);
    _dockMorphCtrl.removeListener(_onDockMorphTick);
    _dockMorphCtrl.dispose();
    _dockScrollProgress.dispose();
    _iosHomeStatusBarDark.dispose();
    _iosHomeTopScrimOpacity.dispose();
    _iosHeroOverscroll.dispose();
    _rexBackdropScrollOffset.dispose();
    _rexCardInkScrollOffset.dispose();
    _dismissUndoHistoryBanner();
    _useRootNativeTabChromeNotifier.dispose();
    _curatedDockVisibleNotifier.dispose();
    _selectedTabIndexNotifier.dispose();
    PosterLoader.cacheRevision.removeListener(_onPosterCacheUpdated);
    _homeScrollController.dispose();
    _windowsDiscoverScrollController.dispose();
    _iosHeroPageController.dispose();
    _continueWatchingScrollController.dispose();
    _categoryPillsScrollController.dispose();
    _filterCategoryScrollController.dispose();
    _filterAreaScrollController.dispose();
    _filterYearScrollController.dispose();
    _liveSourcesScrollController.dispose();
    _liveGroupsScrollController.dispose();
    super.dispose();
  }
  void _reloadSavedConfig({bool bypassHomeSnapshot = false}) {
    // A deleted source may still have catalogue/live/search requests in flight.
    // Invalidate them before exposing the new registry, including an empty one.
    _cancelCatalogue();
    if (_liveAbort != null && !_liveAbort!.isCompleted) _liveAbort!.complete();
    if (_liveProbeAbort != null && !_liveProbeAbort!.isCompleted) {
      _liveProbeAbort!.complete();
    }
    ++_homeEpoch;
    ++_categoryEpoch;
    ++_liveEpoch;
    ++_searchEpoch;
    _searchSubscription?.cancel();
    _searchSubscription = null;
    _searchResults.clear();
    _searchNotices.clear();
    _searchVerificationSites.clear();
    _searchPerformed = false;
    _searching = false;
    _windowsLiveChannel = null;
    final saved = widget.storage.loadSavedConfig();
    _config = saved;
    if (saved != null && saved.publicSupportedSites.isNotEmpty) {
      unawaited(
        ConfigCenterBridge.syncAll(
          storage: widget.storage,
          sites: saved.publicSupportedSites,
          pullFromExternal: true,
          pushToExternal: true,
        ),
      );
    }
    _cachedWatchHistory = widget.storage.getWatchHistory();
    _liveHideUnreachable = widget.storage.liveHideUnreachable;
    unawaited(CmsClient.retainScriptSessions(
      (saved?.scriptOwners ?? const <CmsSite>[]).where((site) =>
        _privateSessionUnlocked || !site.isEffectivelyPrivate),
    ));
    final availableSites = saved == null
        ? const <CmsSite>[]
        : (_privateSessionUnlocked
            ? saved.privateAvailableSites
            : (saved.publicAvailableSites.isNotEmpty
                ? saved.publicAvailableSites
                : saved.availableSites
                    .where((s) => !s.isEffectivelyPrivate)
                    .toList()));
    if (availableSites.isNotEmpty) {
      final preferredKey = _privateSessionUnlocked
          ? _selectedPrivateSiteKey
          : (widget.storage.preferredSiteKey.isNotEmpty
              ? widget.storage.preferredSiteKey : widget.storage.selectedSiteKey);
      _activeSite = availableSites.firstWhere(
        (s) => s.key == preferredKey,
        orElse: () => availableSites.firstWhere(
          (s) => !CspBridge.isBannerNoticeSite(s),
          orElse: () => availableSites.first,
        ),
      );
      if (_privateSessionUnlocked) {
        _selectedPrivateSiteKey = _activeSite!.key;
      }
      _loadSiteHome(bypassSnapshot: bypassHomeSnapshot);
    } else {
      _activeSite = null;
      _categories = const [];
      _rawCategoryVideos = const [];
      _homeVideos = const [];
      _windowsRecommendedVideos = const [];
      _iosHeroIndex = 0;
      _homeError = null;
      _homeLoading = false;
      _loadingMore = false;
    }
    final lives = _visibleLives;
    if (lives.isNotEmpty) {
      _loadLivePlaylist(0);
    } else {
      _liveGroups = const [];
      _liveLoading = false;
      _liveError = null;
    }
    if (mounted) setState(() {});
  }
  void _onPosterCacheUpdated() {
    if (!mounted) return;
    final candidates = _windowsRecommendedVideos.isNotEmpty
        ? _windowsRecommendedVideos
        : _homeVideos;
    if (candidates.isEmpty) return;
    final idx = _iosHeroIndex.clamp(0, candidates.length - 1);
    final video = candidates[idx];
    final key = '${video.poster}|${video.title}|${video.year}';
    if (_iosHeroAmbientColors.containsKey(key) ||
        _iosHeroAmbientPending.contains(key)) {
      return;
    }
    final bytes = PosterLoader.peekMemory(
      video.poster,
      title: video.title,
      year: video.year,
      preferHd: true,
    );
    if (bytes == null) return;
    _updateHeroAmbientFromBytes(video, bytes);
  }

  void _updateHeroAmbientFromBytes(CmsVideo video, Uint8List bytes) {
    final key = '${video.poster}|${video.title}|${video.year}';
    final cached = PosterLoader.peekVibrantAmbientColor(bytes);
    if (cached != null) {
      if (_iosHeroAmbientColors[key] != cached && mounted) {
        setState(() => _iosHeroAmbientColors[key] = cached);
      } else {
        _iosHeroAmbientColors[key] = cached;
      }
      return;
    }
    if (!_iosHeroAmbientPending.add(key)) return;
    unawaited(
      PosterLoader.extractVibrantAmbientColor(bytes).then((color) {
        _iosHeroAmbientPending.remove(key);
        if (!mounted) return;
        if (_iosHeroAmbientColors[key] != color) {
          setState(() => _iosHeroAmbientColors[key] = color);
        }
      }).catchError((_) {
        _iosHeroAmbientPending.remove(key);
      }),
    );
  }

  void _prefetchIosHeroHdPosters(CmsSite site, List<CmsVideo> videos) {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        OhosRuntime.isOhos ||
        site.isEffectivelyPrivate ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    final candidates = videos
        .where((v) => !v.id.startsWith('netdisk_qr:') && v.title.trim().isNotEmpty)
        .take(6);
    for (final v in candidates) {
      unawaited(
        PosterLoader.loadHdByTitle(
          v.title,
          rawUrl: v.poster,
          year: v.year,
          strictHero: true,
        ).catchError((_) => Uint8List(0)),
      );
    }
  }

  Color _resolveHeroAmbientColor(CmsVideo video, ApplePalette palette) {
    final key = '${video.poster}|${video.title}|${video.year}';
    final existing = _iosHeroAmbientColors[key];
    if (existing != null) return existing;
    final bytes = PosterLoader.peekMemory(
      video.poster,
      title: video.title,
      year: video.year,
      preferHd: true,
    );
    if (bytes != null) {
      final cached = PosterLoader.peekVibrantAmbientColor(bytes);
      if (cached != null) {
        _iosHeroAmbientColors[key] = cached;
        return cached;
      }
      if (_iosHeroAmbientPending.add(key)) {
        unawaited(
          PosterLoader.extractVibrantAmbientColor(bytes).then((color) {
            _iosHeroAmbientPending.remove(key);
            if (!mounted) return;
            if (_iosHeroAmbientColors[key] != color) {
              setState(() => _iosHeroAmbientColors[key] = color);
            }
          }).catchError((_) {
            _iosHeroAmbientPending.remove(key);
          }),
        );
      }
    }
    return palette.isDark ? const Color(0xFF283446) : const Color(0xFF4B6478);
  }

  /// Rex-style poster atmospheric tone derived from the poster's lower band:
  /// - **Dark Mode**: harmonizes into a deep, rich cinema tone (`L in [0.11, 0.20]`)
  ///   so the Hero dissolves effortlessly into pure obsidian `#000000` behind the
  ///   first shelf.
  /// - **Light Mode**: preserves the poster's true natural lightness & warmth
  ///   (`L in [0.24, 0.68]`) — sunlit warm posters stay golden while moody
  ///   posters stay rich cinema slate/bronze, then dissolve smoothly behind the
  ///   first shelf cards into the clean Light canvas with zero seam.
  Color _resolveRexHeroAtmosphere(CmsVideo video, ApplePalette palette) {
    final seed = _resolveHeroAmbientColor(video, palette);
    final hsl = HSLColor.fromColor(seed);
    final hasChroma = hsl.saturation >= 0.06;
    if (palette.isDark) {
      return hsl
          .withSaturation(
            hasChroma ? (hsl.saturation * 1.18).clamp(0.18, 0.56) : 0.06,
          )
          .withLightness((hsl.lightness * 0.62).clamp(0.10, 0.22))
          .toColor();
    }
    return hsl
        .withSaturation(
          hasChroma ? (hsl.saturation * 1.12).clamp(0.16, 0.56) : 0.06,
        )
        .withLightness(hsl.lightness.clamp(0.24, 0.54))
        .toColor();
  }

  static const double _kRexAuraTopExtend = 280.0;
  static const double _kRexAuraSolidPastHero = 42.0;

  /// Smooth scroll-driven transition factor (`0.0` at top = full-screen Hero
  /// atmosphere rendered all the way to the bottom edge like Rex; `1.0` once
  /// scrolled past the Hero = pure Light/Dark page background).
  double _rexHeroScrollFadeForOffset(double rawOffset, double heroHeight) {
    final scrollDown = math.max(0.0, rawOffset);
    final fadeStart = heroHeight * 0.06;
    final fadeSpan = math.max(heroHeight * 0.78, 160.0);
    final linear = ((scrollDown - fadeStart) / fadeSpan).clamp(0.0, 1.0);
    return Curves.easeInOutCubic.transform(linear);
  }

  /// Single source of truth for Layer 0's full-screen tonal gradient, Layer 0's
  /// solid-to-dissolve Hero top aura, and the Hero billboard's bottom dissolve
  /// edge color. Keeping all three derived from the same calculation guarantees
  /// pixel-exact color continuity across the Hero bottom boundary at every
  /// scroll offset, theme mode, poster hue, and viewport height.
  ({
    Color liveEdgeColor,
    Color fullScreenTopTone,
    Color fullScreenMidTone,
    Color fullScreenBotTone,
    double auraTotalHeight,
    double auraSolidEndStop,
  }) _computeRexBackdropMetrics({
    required Color liveAtmo,
    required ApplePalette palette,
    required double heroHeight,
    required double scrollOffset,
  }) {
    final overscroll = math.max(0.0, -scrollOffset);
    final stretchedHeight = heroHeight + overscroll;
    final scrollFade = _rexHeroScrollFadeForOffset(scrollOffset, heroHeight);

    final liveHsl = HSLColor.fromColor(liveAtmo);
    final deepBottomBase = palette.isDark
        ? Color.lerp(liveAtmo, Colors.black, 0.26)!
        : liveHsl
            .withLightness(
              (liveHsl.lightness * 0.88).clamp(0.18, 0.50),
            )
            .toColor();
    final midBase = Color.lerp(liveAtmo, deepBottomBase, 0.38)!;

    final liveEdgeColor = Color.lerp(liveAtmo, palette.background, scrollFade)!;
    final fullScreenMidTone =
        Color.lerp(midBase, palette.background, scrollFade)!;
    final fullScreenBotTone =
        Color.lerp(deepBottomBase, palette.background, scrollFade)!;

    final auraDissolveHeight = palette.isDark ? 260.0 : 200.0;
    final solidHeight =
        _kRexAuraTopExtend + stretchedHeight + _kRexAuraSolidPastHero;
    final auraTotalHeight = solidHeight + auraDissolveHeight;
    final auraSolidEndStop = (solidHeight / auraTotalHeight).clamp(0.45, 0.94);

    return (
      liveEdgeColor: liveEdgeColor,
      fullScreenTopTone: liveEdgeColor,
      fullScreenMidTone: fullScreenMidTone,
      fullScreenBotTone: fullScreenBotTone,
      auraTotalHeight: auraTotalHeight,
      auraSolidEndStop: auraSolidEndStop,
    );
  }

  /// Evaluates the exact composited Layer 0 backdrop color at [viewportY] so
  /// shelf headers, card titles, and translucent secondary labels choose ink
  /// against the true rendered background at every scroll offset.
  Color _sampleRexBackdropColorAtY({
    required double viewportY,
    required double viewportHeight,
    required double heroHeight,
    required double scrollOffset,
    required Color liveAtmo,
    required ApplePalette palette,
  }) {
    final metrics = _computeRexBackdropMetrics(
      liveAtmo: liveAtmo,
      palette: palette,
      heroHeight: heroHeight,
      scrollOffset: scrollOffset,
    );
    final scrollDown = math.max(0.0, scrollOffset);
    final auraTop = -_kRexAuraTopExtend - scrollDown;
    final tAura = (viewportY - auraTop) / metrics.auraTotalHeight;
    if (tAura <= metrics.auraSolidEndStop) {
      return metrics.liveEdgeColor;
    }

    final safeH = math.max(viewportHeight, 1.0);
    final tBg = (viewportY / safeH).clamp(0.0, 1.0);
    final Color baseBg = tBg <= 0.62
        ? Color.lerp(
            metrics.fullScreenTopTone,
            metrics.fullScreenMidTone,
            tBg / 0.62,
          )!
        : Color.lerp(
            metrics.fullScreenMidTone,
            metrics.fullScreenBotTone,
            (tBg - 0.62) / 0.38,
          )!;

    if (tAura >= 1.0) {
      return baseBg;
    }
    final s0 = metrics.auraSolidEndStop;
    final tail = math.max(1.0 - s0, 1e-6);
    final u = ((tAura - s0) / tail).clamp(0.0, 1.0);
    const stopPos = <double>[0.0, 0.18, 0.40, 0.64, 0.84, 1.0];
    const stopAlpha = <double>[1.0, 0.86, 0.58, 0.28, 0.09, 0.0];
    var alpha = 0.0;
    for (var i = 0; i < stopPos.length - 1; i++) {
      if (u <= stopPos[i + 1]) {
        final segT = (u - stopPos[i]) / (stopPos[i + 1] - stopPos[i]);
        alpha = stopAlpha[i] + (stopAlpha[i + 1] - stopAlpha[i]) * segT;
        break;
      }
    }
    return Color.alphaBlend(
      metrics.liveEdgeColor.withValues(alpha: alpha),
      baseBg,
    );
  }

  static double _wcagContrastRatio(Color foreground, Color background) {
    final effectiveFg = foreground.a < 0.999
        ? Color.alphaBlend(foreground, background)
        : foreground;
    final l1 = effectiveFg.computeLuminance();
    final l2 = background.computeLuminance();
    final lighter = math.max(l1, l2);
    final darker = math.min(l1, l2);
    return (lighter + 0.05) / (darker + 0.05);
  }

  static Color _ensureSecondaryContrast(
    Color primaryInk,
    Color background, {
    required double preferredAlpha,
    required double minContrast,
    required bool preferLight,
  }) {
    final baseCandidate = primaryInk.withValues(alpha: preferredAlpha);
    if (_wcagContrastRatio(baseCandidate, background) >= minContrast) {
      return baseCandidate;
    }
    final opaqueBase = primaryInk.withValues(alpha: 1.0);
    if (_wcagContrastRatio(opaqueBase, background) >= minContrast) {
      var lo = preferredAlpha;
      var hi = 1.0;
      for (var i = 0; i < 8; i++) {
        final mid = (lo + hi) * 0.5;
        if (_wcagContrastRatio(primaryInk.withValues(alpha: mid), background) >=
            minContrast) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      return primaryInk.withValues(alpha: hi);
    }
    final extreme = preferLight ? Colors.white : Colors.black;
    var lo = preferredAlpha;
    var hi = 1.0;
    for (var i = 0; i < 8; i++) {
      final mid = (lo + hi) * 0.5;
      if (_wcagContrastRatio(extreme.withValues(alpha: mid), background) >=
          minContrast) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return extreme.withValues(alpha: hi);
  }

  /// Resolves high-contrast primary and secondary inks against a sampled
  /// Layer 0 backdrop pair ([primaryBg] for titles, [secondaryBg] for normal /
  /// secondary copy), using a narrow luminance hysteresis band (`[0.175, 0.177]`)
  /// so continuous scrolling never flickers while keeping normal & translucent
  /// text at >= 4.5:1.
  ({Color primary, Color secondary, bool useLight})
      _resolveRexInksForBackdropBand({
    required int hysteresisSlotKey,
    required Color primaryBg,
    required Color secondaryBg,
    required ApplePalette palette,
  }) {
    if (palette.isDark) {
      final primary = palette.labelPrimary;
      final lightestBg = primaryBg.computeLuminance() >
              secondaryBg.computeLuminance()
          ? primaryBg
          : secondaryBg;
      final secondary = _ensureSecondaryContrast(
        primary,
        lightestBg,
        preferredAlpha: 0.78,
        minContrast: 4.8,
        preferLight: true,
      );
      _rexShelfLightInkCache[hysteresisSlotKey] = true;
      return (primary: primary, secondary: secondary, useLight: true);
    }

    final textLum = secondaryBg.computeLuminance();
    final prevLight = _rexShelfLightInkCache[hysteresisSlotKey];
    final bool useLight;
    if (prevLight == null) {
      useLight = textLum < 0.176;
    } else if (prevLight) {
      useLight = textLum < 0.177;
    } else {
      useLight = textLum <= 0.175;
    }
    _rexShelfLightInkCache[hysteresisSlotKey] = useLight;

    if (useLight) {
      const primary = Colors.white;
      final lightestBg = primaryBg.computeLuminance() >
              secondaryBg.computeLuminance()
          ? primaryBg
          : secondaryBg;
      final secondary = _ensureSecondaryContrast(
        primary,
        lightestBg,
        preferredAlpha: 0.80,
        minContrast: 4.65,
        preferLight: true,
      );
      return (primary: primary, secondary: secondary, useLight: true);
    }

    final darkestBg = secondaryBg.computeLuminance() <
            primaryBg.computeLuminance()
        ? secondaryBg
        : primaryBg;
    final primary = _wcagContrastRatio(palette.labelPrimary, darkestBg) >= 4.60
        ? palette.labelPrimary
        : Colors.black;
    final secondary = _ensureSecondaryContrast(
      primary,
      darkestBg,
      preferredAlpha: 0.78,
      minContrast: 4.65,
      preferLight: false,
    );
    return (primary: primary, secondary: secondary, useLight: false);
  }

  /// Resolves high-contrast primary and secondary shelf inks against the exact
  /// composited Layer 0 backdrop behind [shelfSlotIndex], using a narrow
  /// luminance hysteresis band (`[0.175, 0.177]`) so continuous scrolling never
  /// flickers while guaranteeing >= 4.5:1 contrast for normal & secondary text.
  ({Color primary, Color secondary}) _resolveRexShelfInks({
    required int shelfSlotIndex,
    required Color liveAtmo,
    required ApplePalette palette,
    required double heroHeight,
    required double viewportHeight,
    required double scrollOffset,
  }) {
    final scrollDown = math.max(0.0, scrollOffset);
    final shelfTopY = heroHeight - scrollDown + 14.0 + shelfSlotIndex * 235.0;
    final headerY = (shelfTopY + 14.0).clamp(0.0, viewportHeight);
    final cardTextY = (shelfTopY + 185.0).clamp(0.0, viewportHeight);

    final headerBg = _sampleRexBackdropColorAtY(
      viewportY: headerY,
      viewportHeight: viewportHeight,
      heroHeight: heroHeight,
      scrollOffset: scrollOffset,
      liveAtmo: liveAtmo,
      palette: palette,
    );
    final cardBg = _sampleRexBackdropColorAtY(
      viewportY: cardTextY,
      viewportHeight: viewportHeight,
      heroHeight: heroHeight,
      scrollOffset: scrollOffset,
      liveAtmo: liveAtmo,
      palette: palette,
    );

    final resolved = _resolveRexInksForBackdropBand(
      hysteresisSlotKey: shelfSlotIndex,
      primaryBg: headerBg,
      secondaryBg: cardBg,
      palette: palette,
    );
    return (primary: resolved.primary, secondary: resolved.secondary);
  }

  /// Whether foreground ink over [atmo] (Hero title/dots & upper shelves)
  /// should use crisp white (`true`) or deep charcoal (`false`).
  bool _useLightInkForHeroAtmo(Color atmo, bool isDark) {
    return isDark || atmo.computeLuminance() < 0.185;
  }

  /// Live horizontal-swipe interpolated Rex Hero atmosphere color across
  /// adjacent [heroCandidates] driven by [_iosHeroPageController].
  Color _resolveLiveRexHeroAtmo(
    List<CmsVideo> heroCandidates,
    ApplePalette palette,
  ) {
    if (heroCandidates.isEmpty) {
      return palette.isDark
          ? const Color(0xFF1A2230)
          : const Color(0xFF4B6478);
    }
    final fallbackIdx = _iosHeroIndex.clamp(0, heroCandidates.length - 1);
    if (_iosHeroPageController.positions.length != 1 ||
        !_iosHeroPageController.position.hasViewportDimension ||
        heroCandidates.length == 1) {
      return _resolveRexHeroAtmosphere(heroCandidates[fallbackIdx], palette);
    }
    final page = (_iosHeroPageController.page ?? fallbackIdx.toDouble()).clamp(
      0.0,
      (heroCandidates.length - 1).toDouble(),
    );
    final leftIdx = page.floor().clamp(0, heroCandidates.length - 1);
    final rightIdx = page.ceil().clamp(0, heroCandidates.length - 1);
    final leftColor =
        _resolveRexHeroAtmosphere(heroCandidates[leftIdx], palette);
    if (leftIdx == rightIdx) return leftColor;
    final rightColor =
        _resolveRexHeroAtmosphere(heroCandidates[rightIdx], palette);
    return Color.lerp(leftColor, rightColor, page - leftIdx) ?? leftColor;
  }

  Future<void> _loadSiteHome({
    bool bypassSnapshot = false,
    bool preserveExisting = false,
  }) async {
    final site = _activeSite;
    if (site == null) return;
    _cancelCatalogue();
    final abort = _homeAbort = Completer<void>();
    final epoch = ++_homeEpoch;
    ++_categoryEpoch;
    final cached = bypassSnapshot ? null : widget.storage.getCachedSiteHome(site);
    final hadCached = cached != null && cached.listing.videos.isNotEmpty;
    final keepVisible =
        preserveExisting &&
        (_homeVideos.isNotEmpty || _windowsRecommendedVideos.isNotEmpty);
    setState(() {
      _primaryTab = 'recommend';
      _filterExpanded = false;
      _selectedCategoryId = '';
      _filterSubCategoryId = '';
      _filterGenreLabel = '';
      _filterArea = '';
      _filterYear = '';
      if (keepVisible) {
        _homeRefreshing = true;
        _homeLoading = false;
      } else if (hadCached) {
        _categories = cached.categories;
        _rawCategoryVideos = cached.listing.videos;
        _homeVideos = cached.listing.sourceFiltered
            ? cached.listing.videos
            : CmsParser.filterVideos(cached.listing.videos, const CmsFilter());
        _windowsRecommendedVideos = List.of(_homeVideos);
        _currentPage = cached.listing.page;
        _pageCount = cached.listing.pageCount;
        _homeLoading = false;
        _homeRefreshing = false;
      } else {
        _homeVideos = const [];
        _windowsRecommendedVideos = const [];
        _iosHeroIndex = 0;
        _rawCategoryVideos = const [];
        _categories = const [];
        _homeLoading = true;
        _homeRefreshing = false;
        _currentPage = 1;
      }
      _loadingMore = false;
      _homeError = null;
      _loadMoreError = null;
    });
    if (hadCached && _windowsRecommendedVideos.isNotEmpty) {
      _prefetchIosHeroHdPosters(site, _windowsRecommendedVideos);
    }
    try {
      final homeFuture = widget.client.runSourceOperation(
        () => widget.client.fetchHome(site),
        cancellation: abort,
      );
      final (cats, listing) = !kIsWeb &&
              !Platform.environment.containsKey('FLUTTER_TEST')
          ? await homeFuture.timeout(const Duration(seconds: 15))
          : await homeFuture;
      if (!mounted || epoch != _homeEpoch || _activeSite?.key != site.key) {
        return;
      }
      if (listing.videos.isNotEmpty && !site.isEffectivelyPrivate) {
        unawaited(widget.storage.saveCachedSiteHome(site, cats, listing));
      }
      if ((hadCached || keepVisible) &&
          listing.videos.isEmpty &&
          cats.isEmpty) {
        if (_homeRefreshing) {
          setState(() => _homeRefreshing = false);
        }
        return;
      }
      setState(() {
        if (cats.isNotEmpty || (!hadCached && !keepVisible)) {
          _categories = cats;
        }
        _rawCategoryVideos = listing.videos;
        _homeVideos = listing.sourceFiltered
            ? listing.videos
            : CmsParser.filterVideos(listing.videos, _currentFilter);
        _windowsRecommendedVideos = List.of(_homeVideos);
        _currentPage = listing.page;
        _pageCount = listing.pageCount;
        _homeLoading = false;
        _homeRefreshing = false;
        _loadingMore = false;
      });
      if (_windowsRecommendedVideos.isNotEmpty) {
        _prefetchIosHeroHdPosters(site, _windowsRecommendedVideos);
      }
    } catch (e) {
      if (!mounted || epoch != _homeEpoch || _activeSite?.key != site.key) {
        return;
      }
      if ((hadCached || keepVisible) &&
          !CmsClient.needsSourceVerification(site, e)) {
        setState(() {
          _homeLoading = false;
          _homeRefreshing = false;
          _loadingMore = false;
        });
        return;
      }
      setState(() {
        _homeLoading = false;
        _homeRefreshing = false;
        _loadingMore = false;
        _homeError =
            '读取片源「${site.name}」失败：${CmsClient.cleanErrorMessage(e)}';
        _homeErrorCause = e;
        _retryHomeError = () => _loadSiteHome(bypassSnapshot: true);
      });
    }
  }
  Future<void> _refreshCurrentHomeView() async {
    if (_primaryTab == 'recommend' &&
        _selectedCategoryId.isEmpty &&
        _filterSubCategoryId.isEmpty &&
        _filterGenreLabel.isEmpty &&
        _filterArea.isEmpty &&
        _filterYear.isEmpty) {
      await _loadSiteHome(bypassSnapshot: true, preserveExisting: true);
      return;
    }
    await _reloadFilteredListing(page: 1);
  }
  Future<void> _selectPrimaryTab(String tabKey) async {
    if (tabKey == 'recommend') {
      if (_primaryTab == 'recommend' &&
          _filterSubCategoryId.isEmpty &&
          _filterGenreLabel.isEmpty) {
        if (_filterExpanded) setState(() => _filterExpanded = false);
        return;
      }
      setState(() {
        _primaryTab = 'recommend';
        _filterExpanded = false;
        _filterSubCategoryId = '';
        _filterGenreLabel = '';
      });
      await _reloadFilteredListing(page: 1);
      return;
    }
    if (_primaryTab == tabKey) {
      if (defaultTargetPlatform == TargetPlatform.iOS && !OhosRuntime.isOhos) {
        unawaited(_openNativeFilterSheet());
      } else {
        setState(() => _filterExpanded = !_filterExpanded);
      }
      return;
    }
    final resolved = CmsParser.resolvePrimaryTabCategory(_categories, tabKey);
    setState(() {
      _primaryTab = tabKey;
      _filterExpanded = false;
      _filterSubCategoryId = '';
      _filterGenreLabel = '';
      _selectedCategoryId = resolved.categoryId;
    });
    await _reloadFilteredListing(page: 1);
  }
  Future<void> _reloadFilteredListing({int page = 1}) async {
    final site = _activeSite;
    if (site == null) return;
    if (page > 1 && _loadingMore) return;
    _cancelCatalogue();
    ++_homeEpoch;
    final abort = _categoryAbort = Completer<void>();
    Future<T> read<T>(Future<T> Function() request) => widget.client.runSourceOperation(
      request, cancellation: abort,
    );
    final epoch = ++_categoryEpoch;
    final filter = _currentFilter;
    String targetCategoryId = '';
    List<String> targetChildIds = const [];
    if (_filterSubCategoryId.isNotEmpty) {
      targetCategoryId = _filterSubCategoryId;
      targetChildIds =
          CmsParser.childCategoryIds(_categories, _filterSubCategoryId);
    } else if (_primaryTab != 'recommend') {
      final resolved =
          CmsParser.resolvePrimaryTabCategory(_categories, _primaryTab);
      targetCategoryId = resolved.categoryId;
      targetChildIds = resolved.childIds;
    }
    setState(() {
      if (page == 1) {
        _homeLoading = true;
        _loadingMore = false;
      } else {
        _loadingMore = true;
      }
      _homeError = null;
      _loadMoreError = null;
      _selectedCategoryId = targetCategoryId;
    });
    try {
      CmsListing listing;
      if (targetCategoryId.isEmpty &&
          _primaryTab == 'recommend' &&
          !filter.hasSubFilter &&
          page == 1) {
        final (cats, homeListing) = await read(() => widget.client.fetchHome(site));
        if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) return;
        if (_categories.isEmpty && cats.isNotEmpty) {
          _categories = cats;
        }
        listing = homeListing;
      } else if (targetCategoryId.isEmpty && filter.hasSubFilter) {
        // Filtering from the default "推荐" tab: resolve a real category from
        // the active site so server-side filters (Wogg / CatPaw / DRPY / CMS)
        // actually execute instead of returning an unfiltered home page.
        String fallbackCatId = '';
        List<String> fallbackChildren = const [];
        if (_categories.isNotEmpty) {
          final genre = filter.genreLabel.trim();
          CmsCategory? matchedCat;
          if (genre.isNotEmpty && genre != '全部') {
            for (final c in _categories) {
              if (c.name.contains(genre)) {
                matchedCat = c;
                break;
              }
            }
          }
          final chosen = matchedCat ?? _categories.first;
          fallbackCatId = chosen.id;
          fallbackChildren = CmsParser.childCategoryIds(_categories, chosen.id);
        }
        listing = await read(() => widget.client.fetchCategory(
          site,
          fallbackCatId,
          page,
          childIds: fallbackChildren,
          filter: filter,
        ));
      } else if (targetCategoryId.isEmpty) {
        // Recommend tab pagination (page > 1) or filtered query from "全部":
        // Sites backed by WoGG/MacCMS HTML show pages require a concrete
        // category ID to apply area/year/genre filters.
        if (filter.hasSubFilter &&
            _categories.isNotEmpty &&
            (WoggSource.supports(site) ||
                CspBridge.usesWoggNetdiskAdapter(site))) {
          final firstCat = _categories.first;
          final firstChildren =
              CmsParser.childCategoryIds(_categories, firstCat.id);
          listing = await read(() => widget.client.fetchCategory(
            site,
            firstCat.id,
            page,
            childIds: firstChildren,
            filter: filter,
          ));
        } else {
          listing = await read(() => widget.client.fetchCategory(
            site,
            '',
            page,
            filter: filter,
          ));
          final existingKeys = page > 1
              ? _rawCategoryVideos
                  .map((v) => v.id.isNotEmpty ? v.id : v.title)
                  .toSet()
              : const <String>{};
          final hasUsableItems = page > 1
              ? listing.videos.any(
                  (v) => !existingKeys.contains(v.id.isNotEmpty ? v.id : v.title),
                )
              : listing.videos.isNotEmpty;
          // If the site's root feed does not paginate or filter directly,
          // fallback to the first category with its childIds.
          if (!hasUsableItems && _categories.isNotEmpty) {
            final firstCat = _categories.first;
            final firstChildren =
                CmsParser.childCategoryIds(_categories, firstCat.id);
            final fallbackListing = await read(() => widget.client.fetchCategory(
              site,
              firstCat.id,
              page,
              childIds: firstChildren,
              filter: filter,
            ));
            if (fallbackListing.videos.isNotEmpty) {
              listing = fallbackListing;
            }
          }
        }
      } else {
        listing = await read(() => widget.client.fetchCategory(
          site,
          targetCategoryId,
          page,
          childIds: targetChildIds,
          filter: filter,
        ));
      }
      if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) {
        return;
      }
      List<CmsVideo> combinedRaw;
      int addedCount = 0;
      if (page == 1) {
        combinedRaw = listing.videos;
        addedCount = listing.videos.length;
      } else {
        final seen = <String>{
          for (final v in _rawCategoryVideos)
            v.id.isNotEmpty ? v.id : v.title,
        };
        combinedRaw = [..._rawCategoryVideos];
        for (final v in listing.videos) {
          final key = v.id.isNotEmpty ? v.id : v.title;
          if (seen.add(key)) {
            combinedRaw.add(v);
            addedCount++;
          }
        }
      }
      // Remote rules may filter by opaque values absent from their result cards.
      // Keep the source's result instead of filtering those cards a second time.
      var filteredVideos = listing.sourceFiltered
          ? combinedRaw
          : CmsParser.filterVideos(combinedRaw, filter);
      // If client-side filter on page 1 matched nothing and more pages exist, probe page 2 automatically
      if (filteredVideos.isEmpty &&
          !listing.sourceFiltered &&
          filter.hasSubFilter &&
          page == 1 &&
          listing.pageCount > 1 &&
          targetCategoryId.isNotEmpty) {
        try {
          final page2 = await read(() => widget.client.fetchCategory(
            site,
            targetCategoryId,
            2,
            childIds: targetChildIds,
            filter: filter,
          ));
          final merged2 = [...combinedRaw, ...page2.videos];
          final filtered2 = page2.sourceFiltered
              ? merged2
              : CmsParser.filterVideos(merged2, filter);
          if (filtered2.isNotEmpty) {
            filteredVideos = filtered2;
          }
        } catch (_) {}
      }
      // The optional second-page probe may outlive a changed filter or route.
      if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) return;
      setState(() {
        _rawCategoryVideos = combinedRaw;
        _homeVideos = filteredVideos;
        _currentPage = page;
        if (page == 1) {
          _pageCount = listing.pageCount;
        } else if (listing.videos.isEmpty ||
            (addedCount == 0 && !filter.hasSubFilter)) {
          // Reached the end of available pages (or source repeats duplicate pages)
          _pageCount = page;
        } else {
          _pageCount = math.max(_pageCount, listing.pageCount);
        }
        _homeLoading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || epoch != _categoryEpoch || _activeSite?.key != site.key) {
        return;
      }
      setState(() {
        _homeLoading = false;
        _loadingMore = false;
        if (page == 1 || CmsClient.needsSourceVerification(site, e)) {
          _homeError = '加载分类失败：${CmsClient.cleanErrorMessage(e)}';
          _homeErrorCause = e;
          _retryHomeError = () => _reloadFilteredListing(page: page);
        } else {
          _loadMoreError = CmsClient.cleanErrorMessage(e);
        }
      });
    }
  }
  Future<void> _runGlobalSearch(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty || _config == null) return;
    final epoch = ++_searchEpoch;
    await _searchSubscription?.cancel();
    _searchSubscription = null;
    await widget.storage.addSearchKeyword(
      trimmed,
      forPrivate: _privateSessionUnlocked,
    );
    if (!mounted || epoch != _searchEpoch) return;
    final allSites = _visibleSupportedSites;
    final hasSelectedSite = _searchSiteFilterKey.isNotEmpty &&
        allSites.any((s) => '${s.subscriptionId}:${s.key}' == _searchSiteFilterKey);
    final orderedSites = hasSelectedSite
        ? <CmsSite>[
            ...allSites.where((s) => '${s.subscriptionId}:${s.key}' == _searchSiteFilterKey),
            ...allSites.where((s) => '${s.subscriptionId}:${s.key}' != _searchSiteFilterKey),
          ]
        : allSites;
    setState(() {
      _searching = true;
      _searchResults.clear();
      _searchNotices.clear();
      _searchVerificationSites.clear();
      if (!hasSelectedSite) _searchSiteFilterKey = '';
      _searchKeyword = trimmed;
      _searchPerformed = true;
    });
    _notifySearchUi();
    _searchSubscription = widget.client
        .searchAcrossSites(
          orderedSites,
          trimmed,
          onSourceError: (site, error) {
            if (!mounted || epoch != _searchEpoch) return;
            setState(() {
              _searchNotices['${site.subscriptionId}:${site.key}'] =
                  '${_searchSourceLabel(site)}：${searchSourceNotice(error)}';
              if (CmsClient.needsSourceVerification(site, error)) {
                _searchVerificationSites['${site.subscriptionId}:${site.key}'] = site;
              }
            });
            _notifySearchUi();
          },
        )
        .listen(
          (batch) {
            if (!mounted || epoch != _searchEpoch) return;
            final (site, videos) = batch;
            setState(() {
              final key = '${site.subscriptionId}:${site.key}';
              _searchNotices.remove(key);
              _searchVerificationSites.remove(key);
              for (final v in videos) {
                _searchResults.add((site, v));
              }
            });
            _notifySearchUi();
          },
          onError: (_) {
            if (mounted && epoch == _searchEpoch) {
              setState(() => _searching = false);
              _notifySearchUi();
            }
          },
          onDone: () {
            if (mounted && epoch == _searchEpoch) {
              _searchSubscription = null;
              setState(() => _searching = false);
              _notifySearchUi();
            }
          },
        );
  }
  void _resetGlobalSearch() {
    _searchEpoch++;
    final activeSub = _searchSubscription;
    _searchSubscription = null;
    if (activeSub != null) {
      unawaited(activeSub.cancel());
    }
    setState(() {
      _searching = false;
      _searchPerformed = false;
      _searchKeyword = '';
      _searchSiteFilterKey = '';
      _searchResults.clear();
      _searchNotices.clear();
      _searchVerificationSites.clear();
    });
    _notifySearchUi();
  }
  Future<void> _retryVerifiedSearch(CmsSite site) async {
    final epoch = _searchEpoch;
    final key = '${site.subscriptionId}:${site.key}';
    try {
      final listing = await widget.client.fetchSearch(site, _searchKeyword);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _searchResults.removeWhere((v) => v.$1.key == site.key && v.$1.subscriptionId == site.subscriptionId);
        _searchResults.addAll(listing.videos.map((v) => (site, v)));
        _searchNotices.remove(key);
        _searchVerificationSites.remove(key);
      });
    } catch (error) {
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _searchNotices[key] = '${_searchSourceLabel(site)}：${searchSourceNotice(error)}';
        if (!CmsClient.needsSourceVerification(site, error)) _searchVerificationSites.remove(key);
      });
    }
    _notifySearchUi();
  }

  String _searchSourceLabel(CmsSite site) => searchSourceLabel(
      site, _visibleSupportedSites, widget.storage.getSubscriptions());

  static String _formatLiveError(String sourceName, Object error) {
    if (error is FormatException) {
      final msg = error.message.trim();
      if (msg.isNotEmpty &&
          !msg.contains('://') &&
          RegExp(r'[\u4e00-\u9fff]').hasMatch(msg)) {
        return '读取「$sourceName」失败：$msg';
      }
    }
    if (error is TimeoutException) {
      return '读取直播源「$sourceName」超时，请检查网络或切换其他直播源';
    }
    if (error is HttpException) {
      final code = RegExp(r'HTTP\s+\d+').firstMatch(error.message)?.group(0);
      return code != null
          ? '直播源「$sourceName」响应异常（$code），请稍后重试或切换其他来源'
          : '直播源「$sourceName」响应异常，请稍后重试或切换其他来源';
    }
    final raw = error.toString();
    if (error is SocketException ||
        raw.contains('SocketException') ||
        raw.contains('ClientException')) {
      return '无法连接直播源「$sourceName」，请检查网络后重试或切换其他直播源';
    }
    return '读取直播源「$sourceName」失败，请稍后重试或切换其他直播源';
  }

  void _cancelLiveProbe() {
    if (_liveProbeAbort != null && !_liveProbeAbort!.isCompleted) {
      _liveProbeAbort!.complete();
    }
    if (_liveProbing && mounted) {
      setState(() {
        _liveProbing = false;
        _liveProbeProgress = null;
      });
    }
  }

  List<LiveGroup> get _displayLiveGroups {
    if (!_liveHideUnreachable) return _liveGroups;
    return _liveGroups
        .where((g) => g.name != LiveChannelOrganizer.failedGroupName)
        .toList(growable: false);
  }

  Future<void> _loadLivePlaylist(
    int sourceIndex, {
    bool forceRefresh = false,
    bool autoProbeAfterLoad = false,
  }) async {
    final lives = _visibleLives;
    if (sourceIndex < 0 || sourceIndex >= lives.length) return;
    if (_liveAbort != null && !_liveAbort!.isCompleted) _liveAbort!.complete();
    _cancelLiveProbe();
    final abort = _liveAbort = Completer<void>();
    final epoch = ++_liveEpoch;
    final source = lives[sourceIndex];
    final standalone = widget.storage.findStandaloneLiveSourceForLive(source);
    final autoCat = standalone?.autoCategorize ?? widget.storage.liveAutoCategorize;
    final logoTemplate = standalone?.logoTemplate ?? '';

    final cached = !forceRefresh ? widget.storage.loadLiveSnapshot(source) : null;
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _selectedLiveSource = sourceIndex;
        _windowsLiveChannel = null;
        _selectedLiveGroup = 0;
        _liveGroups = cached;
        _liveLoading = false;
        _liveError = null;
      });
      if (autoProbeAfterLoad) {
        unawaited(_probeCurrentLiveGroups());
      }
      return;
    }

    setState(() {
      _selectedLiveSource = sourceIndex;
      _windowsLiveChannel = null;
      _selectedLiveGroup = 0;
      _liveGroups = const [];
      _liveLoading = true;
      _liveError = null;
    });
    try {
      final rawGroups = await widget.client.runSourceOperation(
        () => widget.client.fetchLiveGroups(source),
        cancellation: abort,
      );
      if (!mounted ||
          epoch != _liveEpoch ||
          _selectedLiveSource != sourceIndex) {
        return;
      }
      final organized = LiveChannelOrganizer.organize(
        rawGroups,
        autoCategorize: autoCat,
        logoTemplate: logoTemplate,
      );
      unawaited(widget.storage.saveLiveSnapshot(source, organized));
      setState(() {
        _liveGroups = organized;
        _liveLoading = false;
      });
      if (autoProbeAfterLoad) {
        unawaited(_probeCurrentLiveGroups());
      }
    } catch (e) {
      if (!mounted ||
          abort.isCompleted ||
          epoch != _liveEpoch ||
          _selectedLiveSource != sourceIndex) {
        return;
      }
      setState(() {
        _liveGroups = const [];
        _liveLoading = false;
        _liveError = _formatLiveError(source.name, e);
      });
    }
  }

  Future<void> _probeCurrentLiveGroups() async {
    final lives = _visibleLives;
    if (_liveGroups.isEmpty ||
        _selectedLiveSource < 0 ||
        _selectedLiveSource >= lives.length) {
      return;
    }
    if (_liveProbing) {
      _cancelLiveProbe();
      return;
    }
    final source = lives[_selectedLiveSource];
    final standalone = widget.storage.findStandaloneLiveSourceForLive(source);
    final autoCat = standalone?.autoCategorize ?? widget.storage.liveAutoCategorize;
    final logoTemplate = standalone?.logoTemplate ?? '';
    final epoch = _liveEpoch;
    final probeAbort = _liveProbeAbort = Completer<void>();
    final total = _liveGroups.fold<int>(0, (s, g) => s + g.channels.length);
    setState(() {
      _liveProbing = true;
      _liveProbeProgress = LiveProbeProgress(
        completedChannels: 0,
        totalChannels: total,
        reachableChannels: 0,
        unreachableChannels: 0,
      );
    });
    var lastUiUpdateMs = 0;
    try {
      final probed = await LiveStreamProber.probeAndOrganize(
        _liveGroups,
        autoCategorize: autoCat,
        logoTemplate: logoTemplate,
        cancellation: probeAbort,
        onProgress: (p) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (!mounted || epoch != _liveEpoch) return;
          if (now - lastUiUpdateMs >= 180 ||
              p.completedChannels >= p.totalChannels) {
            lastUiUpdateMs = now;
            setState(() => _liveProbeProgress = p);
          }
        },
      );
      if (!mounted || epoch != _liveEpoch) return;
      unawaited(widget.storage.saveLiveSnapshot(source, probed));
      setState(() {
        _liveGroups = probed;
        _liveProbing = false;
        _liveProbeProgress = null;
        if (_selectedLiveGroup >= _displayLiveGroups.length) {
          _selectedLiveGroup = 0;
        }
      });
    } catch (_) {
      if (!mounted || epoch != _liveEpoch) return;
      setState(() {
        _liveProbing = false;
        _liveProbeProgress = null;
      });
    }
  }
  void _openVideoDetail(
    CmsSite site,
    CmsVideo video, {
    BuildContext? sourceContext,
    double sourceRadius = 14.0,
    String? sourceCardId,
    String? sourcePosterUrl,
    bool isFullBleedHero = false,
    Color? ambientColor,
  }) {
    if (!CuratedDiscoveryService.isCuratedSite(site) && !site.supported) {
      _showAppleNotice(site.name, site.unsupportedReason);
      return;
    }
    if (video.tag == 'media-folder' || video.id.startsWith('mmfolder://')) {
      unawaited(
        _trackSecondaryRoute<void>(
          () => Navigator.of(context).push<void>(
            buildApplePageRoute<void>(
              builder: (_) => MediaFolderBrowserPage(
                site: site,
                client: widget.client,
                storage: widget.storage,
                folderId: video.id,
                folderTitle: video.title,
                backLabel: site.name,
                onOpenVideo: (s, v) => _openVideoDetail(s, v),
              ),
            ),
          ),
        ),
      );
      return;
    }
    if (video.id.startsWith('netdisk_qr:')) {
      final driveKey = video.id.substring('netdisk_qr:'.length).trim();
      unawaited(
        _trackSecondaryRoute<void>(
          () => showNetdiskAccountSheet(
            context,
            widget.storage,
            initialDriveKey: driveKey.isEmpty ? null : driveKey,
            sites: _config?.publicSupportedSites ?? const <CmsSite>[],
            activeGroup: _activeSite?.group ?? '',
            onOpenCatPawSettings:
                (_config?.publicSupportedSites.any((s) => s.isCatPaw) ?? false)
                    ? _showCatPawSettings
                    : null,
            onChanged: () {
              if (mounted) setState(() {});
            },
          ),
        ),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (_searchSubscription != null) {
      _searchEpoch++;
      final activeSub = _searchSubscription;
      _searchSubscription = null;
      unawaited(activeSub!.cancel());
      if (_searching) {
        setState(() => _searching = false);
        _notifySearchUi();
      }
    }
    if (_loadingMore &&
        _categoryAbort != null &&
        !_categoryAbort!.isCompleted) {
      _categoryEpoch++;
      _categoryAbort!.complete();
      setState(() => _loadingMore = false);
    }
    Widget detailBuilder(BuildContext _) => DetailScreen(
          site: site,
          initialVideo: video,
          client: widget.client,
          storage: widget.storage,
        );
    final usePosterExpand =
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS) &&
        !OhosRuntime.isOhos &&
        sourceContext != null;
    final initialRect =
        usePosterExpand ? PosterExpandRoute.captureRect(sourceContext) : null;
    final isLandscapeCuratedCard = initialRect != null &&
        CuratedDiscoveryService.isCuratedSite(site) &&
        initialRect.width > initialRect.height * 1.15;
    final effectivePosterUrl = (sourcePosterUrl != null &&
            sourcePosterUrl.trim().isNotEmpty)
        ? sourcePosterUrl.trim()
        : (isLandscapeCuratedCard
            ? CuratedDiscoveryService.backdropFor(video)
            : video.poster);
    final Route<void> route = initialRect != null
        ? PosterExpandRoute<void>(
            initialSourceRect: initialRect,
            sourceRectResolver: () =>
                PosterExpandRoute.captureRect(sourceContext),
            sourceBorderRadius: isFullBleedHero ? 0.0 : sourceRadius,
            sourceCardId: sourceCardId,
            posterUrl: effectivePosterUrl,
            title: site.isEffectivelyPrivate ? '' : video.title,
            year: site.isEffectivelyPrivate ? '' : video.year,
            isFullBleedHero: isFullBleedHero,
            strictHighResPoster: isFullBleedHero,
            forBackdrop: isLandscapeCuratedCard,
            posterAlignment: isFullBleedHero
                ? const Alignment(0.0, -0.22)
                : Alignment.center,
            ambientColor: ambientColor ?? const Color(0xFF0E1016),
            builder: detailBuilder,
          )
        : buildApplePageRoute<void>(builder: detailBuilder);
    _trackSecondaryRoute<void>(() => Navigator.of(context).push(route)).then((_) {
      if (mounted) setState(() {});
    });
  }
  void _showAppleNotice(String title, String message) {
    if (!mounted) return;
    unawaited(
      showAppleNativeAlert(
        context,
        title: title,
        message: message,
        actions: const [
          AppleNativeAlertAction(id: 'ok', title: '好', isDefault: true),
        ],
      ),
    );
  }

  Future<bool> _confirmIosDestructiveAction(
    BuildContext dialogContext, {
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    if (!dialogContext.mounted) return false;
    final choice = await showAppleNativeAlert(
      dialogContext,
      title: title,
      message: message,
      actions: [
        const AppleNativeAlertAction(
          id: 'cancel',
          title: '取消',
          isCancel: true,
        ),
        AppleNativeAlertAction(
          id: 'confirm',
          title: confirmLabel,
          isDestructive: true,
        ),
      ],
    );
    return choice == 'confirm';
  }

  void _dismissUndoHistoryBanner() {
    _undoHistoryTimer?.cancel();
    _undoHistoryTimer = null;
    try {
      _undoHistoryOverlayEntry?.remove();
    } catch (_) {}
    _undoHistoryOverlayEntry = null;
  }

  void _showIosUndoHistoryBanner(
    BuildContext hostContext,
    WatchHistoryEntry entry, {
    VoidCallback? onRestored,
  }) {
    if (!_isIosNativeFlow || !mounted) return;
    _dismissUndoHistoryBanner();
    final overlay = Overlay.maybeOf(hostContext, rootOverlay: true) ??
        Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final isDark = ApplePalette.isDarkOf(context);
    late OverlayEntry bannerEntry;
    bannerEntry = OverlayEntry(
      builder: (overlayCtx) => Positioned(
        left: 16,
        right: 16,
        bottom: bottomInset + 92,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: const ValueKey('ios-undo-history-banner'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xF022242C)
                      : const Color(0xF21C1D22),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                    width: 0.6,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已删除「${entry.title}」',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CupertinoButton(
                      key: const ValueKey('ios-undo-history-action'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: const Size(32, 32),
                      onPressed: () async {
                        _dismissUndoHistoryBanner();
                        await widget.storage.restoreWatchHistoryEntry(entry);
                        if (!mounted) return;
                        onRestored?.call();
                        setState(() {});
                      },
                      child: const Text(
                        '撤销',
                        style: TextStyle(
                          color: AppleColors.systemBlue,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _undoHistoryOverlayEntry = bannerEntry;
    overlay.insert(bannerEntry);
    _undoHistoryTimer = Timer(const Duration(seconds: 3), () {
      if (_undoHistoryOverlayEntry == bannerEntry) {
        _dismissUndoHistoryBanner();
      }
    });
  }

  void _updateHomeScrollVisualNotifiers(double offset) {
    final heroH = _lastIosHeroHeight > 0 ? _lastIosHeroHeight : 460.0;
    final nextDarkStatus = offset >= heroH * 0.42;
    if (_iosHomeStatusBarDark.value != nextDarkStatus) {
      _iosHomeStatusBarDark.value = nextDarkStatus;
    }
    final nextScrim = ((offset - 18.0) / 150.0).clamp(0.0, 1.0);
    if ((nextScrim - _iosHomeTopScrimOpacity.value).abs() >= 0.015 ||
        (nextScrim == 0.0 && _iosHomeTopScrimOpacity.value != 0.0) ||
        (nextScrim == 1.0 && _iosHomeTopScrimOpacity.value != 1.0)) {
      _iosHomeTopScrimOpacity.value = nextScrim;
    }
    final nextOverscroll = math.max(0.0, -offset);
    if ((nextOverscroll - _iosHeroOverscroll.value).abs() >= 0.25 ||
        (nextOverscroll == 0.0 && _iosHeroOverscroll.value != 0.0)) {
      _iosHeroOverscroll.value = nextOverscroll;
    }
    final maxBackdropOffset = heroH + 380.0;
    final nextBackdrop = offset.clamp(-400.0, maxBackdropOffset).toDouble();
    if (_rexBackdropScrollOffset.value != nextBackdrop) {
      _rexBackdropScrollOffset.value = nextBackdrop;
    }
    final cardFade = _rexHeroScrollFadeForOffset(offset, heroH);
    final settledSentinel = heroH + 100.0;
    final nextCardOffset = cardFade >= 0.999 ? settledSentinel : offset;
    if (_rexCardInkScrollOffset.value != nextCardOffset) {
      _rexCardInkScrollOffset.value = nextCardOffset;
    }
  }
  Future<void> _quickImportFromClipboard() async {
    if (defaultTargetPlatform == TargetPlatform.iOS && !OhosRuntime.isOhos) {
      await _showImportConfigDialog();
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      _showImportConfigDialog();
      return;
    }
    try {
      if (CmsParser.isBackupPayload(text)) {
        if (OhosRuntime.isOhos) {
          await widget.storage.importValidatedLocalBackupJson(text);
        } else {
          await widget.storage.importBackupJson(text);
        }
        _reloadSavedConfig();
        _showAppleNotice('已从剪贴板恢复备份', '备份中的配置、收藏与观看历史已同步生效。');
        return;
      }
      final entries = await widget.client.resolveBatchSubscriptions(
        rawTextInput: text,
      );
      final merged = await widget.storage.upsertSubscriptions(entries);
      _reloadSavedConfig();
      final totalSiteCount = merged?.publicSupportedSites.length ?? 0;
      final availSiteCount = merged?.publicAvailableSiteCount ?? 0;
      final liveCount = merged?.publicLives.length ?? 0;
      _showAppleNotice(
        '订阅导入成功',
        '本次成功导入 ${entries.length} 个订阅源，当前 可用 $availSiteCount / 共 $totalSiteCount 个片源'
        '${liveCount > 0 ? "、$liveCount 个直播源" : ""}。',
      );
    } catch (e) {
      _showImportConfigDialog(initialInput: text, initialError: '剪贴板内容未能直接导入：$e');
    }
  }
  void _onHomeScroll() {
    if (_homeScrollController.positions.length == 1) {
      _updateHomeScrollVisualNotifiers(_homeScrollController.offset);
    }
    if (!_homeScrollController.hasClients ||
        _tabIndex != 0 ||
        _dockOwner != IosDockOwner.home) {
      return;
    }
    final offset = _homeScrollController.offset;
    // If the user is not dragging and a settle animation is in progress, let
    // the settle animation finish unless the scroll has already crossed an
    // outer boundary (top <= 12 or fully scrolled >= 152).
    if (!_homeUserDragging && _dockMorphCtrl.isAnimating) {
      if (offset > 12.0 && offset < 152.0) {
        return;
      }
      _dockMorphAnimToken++;
      _dockMorphCtrl.stop();
    }
    // Strictly linear progress in [0.0, 1.0] across 140pt of downward scroll.
    // Driven without calling setState() on the full shell tree so scrolling
    // stays locked at 60/120fps with zero frame drops or snap jumps.
    final progress = ((offset - 12.0) / 140.0).clamp(0.0, 1.0);
    _dockCollapsed = progress >= 0.5;
    if (progress <= 0.001) {
      _dockStableCollapsed = false;
    } else if (progress >= 0.999) {
      _dockStableCollapsed = true;
    }
    if ((_dockScrollProgress.value - progress).abs() >= 0.002 ||
        (progress == 0.0 && _dockScrollProgress.value != 0.0) ||
        (progress == 1.0 && _dockScrollProgress.value != 1.0)) {
      _dockScrollProgress.value = progress;
    }
    if (_useRootNativeTabChrome) {
      final crossedBoundary = (progress == 0.0 && _lastReportedDockProgress != 0.0) ||
          (progress == 1.0 && _lastReportedDockProgress != 1.0);
      if (crossedBoundary || (progress - _lastReportedDockProgress).abs() >= 0.004) {
        _lastReportedDockProgress = progress;
        unawaited(
          IosLiquidGlassBridge.setRootTabMinimized(
            _dockCollapsed,
            animated: false,
            progress: progress,
            epoch: ++_dockEpoch,
          ),
        );
      }
    }
  }

  void _scrollHomeToTop() {
    if (!mounted) return;
    final wasInCurated = _curatedRouteDepth > 0 ||
        IosRootTabNavigatorObserver.topRouteIsCurated.value ||
        IosRootTabNavigatorObserver.curatedRouteDepth.value > 0;
    if (wasInCurated) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _curatedRouteDepth = 0;
    }
    if (_tabIndex != 0) {
      setState(() => _tabIndex = 0);
      _selectedTabIndexNotifier.value = 0;
      if (_useRootNativeTabChrome) {
        unawaited(
          IosLiquidGlassBridge.setRootTabSelectedIndex(0, epoch: ++_dockEpoch),
        );
      }
    }
    _dockOwner = _computeDockOwner();
    _curatedDockVisibleNotifier.value = _dockOwner == IosDockOwner.curated;
    _dockStableCollapsed = false;
    _homeUserDragging = false;
    _syncRootTabVisibility(animated: true, forceEpoch: ++_dockEpoch);
    if (_homeScrollController.hasClients) {
      final useSpring = !isWindowsDesktopUi && !OhosRuntime.isOhos;
      unawaited(
        _homeScrollController.animateTo(
          0,
          duration: useSpring
              ? const Duration(milliseconds: 360)
              : const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic,
        ),
      );
      _animateDockProgressTo(0.0, animated: true, epoch: ++_dockEpoch);
    } else {
      _animateDockProgressTo(0.0, animated: true, epoch: ++_dockEpoch);
    }
  }

  void _selectSiteDirect(CmsSite s) {
    if (s.isCatPaw && Uri.parse(s.api).path == '/api/baseset') {
      _showCatPawSettings(s);
      return;
    }
    if (_privateSessionUnlocked) {
      setState(() {
        _privateSessionUnlocked = true;
        _selectedPrivateSiteKey = s.key;
        _activeSite = s;
      });
    } else {
      widget.storage.setSelectedSiteKey(s.key);
      unawaited(
        CmsClient.retainScriptSessions(
          (_config?.scriptOwners ?? const <CmsSite>[])
              .where((site) => !site.isEffectivelyPrivate),
        ),
      );
      setState(() {
        _privateSessionUnlocked = false;
        _activeSite = s;
      });
    }
    _loadSiteHome();
  }

  Future<void> _switchToDepotDirect(CmsDepot d) async {
    final depots = _config?.depots ?? const <CmsDepot>[];
    final owners = widget.storage
        .getSubscriptions()
        .where((sub) => sub.id == d.subscriptionId);
    final owner = owners.isEmpty ? null : owners.first;
    try {
      if (owner != null) {
        final withDirectory = owner.copyWith(
          depots: depots
              .where((entry) => entry.subscriptionId == owner.id)
              .toList(),
        );
        final updated = await widget.client.switchSubscriptionDepot(
          withDirectory,
          d,
        );
        if (!mounted) return;
        await widget.storage.upsertSubscriptions([updated]);
      } else {
        final resolved = await widget.client.resolveConfigInput(
          urlInput: d.url,
        );
        if (!mounted) return;
        await widget.storage.saveConfig(
          resolved.rawConfig,
          origin: resolved.origin,
          depots: [...depots, ...resolved.depots],
          activeDepotName: resolved.activeDepotName.isEmpty
              ? d.name
              : resolved.activeDepotName,
        );
      }
      if (mounted) _reloadSavedConfig();
    } catch (e) {
      if (mounted) _showAppleNotice('切换仓库失败', '$e');
    }
  }

  List<IosNativeMenuItem> _buildHomeSourceMenuItems({
    bool currentGroupOnly = true,
  }) {
    final inPrivacyMode = _privateSessionUnlocked;
    final rawSupported = inPrivacyMode
        ? (_config?.privateSupportedSites ?? const <CmsSite>[])
        : (_config?.publicSupportedSites ?? const <CmsSite>[]);
    final hasRealSupported = rawSupported.any(
      (s) => !CspBridge.isPickerHiddenUtilitySite(s),
    );
    final filtered = hasRealSupported
        ? rawSupported
            .where(
              (s) =>
                  !CspBridge.isPickerHiddenUtilitySite(s) ||
                  s.key == _activeSite?.key,
            )
            .toList()
        : List<CmsSite>.from(rawSupported);
    // Quick-switch UIMenu only lists actually supported routes on this device
    // (excluding Android .so-only / incompatible spiders), falling back to all
    // only when zero routes are supported.
    final availableOnly = filtered.where((s) => s.supported).toList();
    final menuPool = availableOnly.isNotEmpty ? availableOnly : filtered;
    final prioritized = widget.storage.prioritizeSites(menuPool);
    final prefKey = widget.storage.preferredSiteKey;
    final activeKey = _activeSite?.key ?? '';
    final defaultGroupName = inPrivacyMode ? '隐私分组' : '默认分组';

    final orderedSites = <CmsSite>[];
    final seenKeys = <String>{};
    if (_activeSite != null &&
        prioritized.any((s) => s.key == _activeSite!.key)) {
      orderedSites.add(_activeSite!);
      seenKeys.add(_activeSite!.key);
    }
    for (final s in prioritized) {
      if (seenKeys.add(s.key)) {
        orderedSites.add(s);
      }
    }

    final groupBuckets = <String, List<CmsSite>>{};
    for (final s in orderedSites) {
      final g = s.group.trim().isEmpty ? defaultGroupName : s.group.trim();
      groupBuckets.putIfAbsent(g, () => <CmsSite>[]).add(s);
    }

    final activeGroupName = (_activeSite?.group.trim().isNotEmpty ?? false)
        ? _activeSite!.group.trim()
        : (groupBuckets.isNotEmpty ? groupBuckets.keys.first : defaultGroupName);
    final scopedSites = currentGroupOnly && groupBuckets.length > 1
        ? (groupBuckets[activeGroupName] ?? orderedSites)
        : orderedSites;

    final items = <IosNativeMenuItem>[
      IosNativeMenuItem(
        id: '__all__',
        title: inPrivacyMode ? '管理隐私片源' : '管理片源',
        subtitle: '查看全部 ${orderedSites.length} 条线路',
        symbol: 'slider.horizontal.3',
        section: 0,
      ),
    ];

    final groupTitle =
        '$activeGroupName (${scopedSites.length})';
    for (final s in scopedSites) {
      items.add(
        IosNativeMenuItem(
          id: 'site:${s.key}',
          title: s.name,
          symbol: (!inPrivacyMode && s.key == prefKey)
              ? 'star.fill'
              : (inPrivacyMode ? 'lock.shield' : 'play.tv'),
          checked: s.key == activeKey,
          section: 1,
          sectionTitle: groupBuckets.length > 1 ? groupTitle : null,
        ),
      );
    }
    return items;
  }

  void _onHomeSourceMenuSelected(String id) {
    if (id == '__all__') {
      _showSitePickerDialog();
      return;
    }
    if (id.startsWith('site:')) {
      final key = id.substring(5);
      final pool = _privateSessionUnlocked
          ? (_config?.privateSupportedSites ?? const <CmsSite>[])
          : (_config?.publicSupportedSites ?? const <CmsSite>[]);
      for (final s in pool) {
        if (s.key == key) {
          _selectSiteDirect(s);
          return;
        }
      }
    }
  }

  List<IosNativeMenuItem> _buildHomeDepotMenuItems(List<CmsDepot> depots) {
    final subs = widget.storage.getSubscriptions();
    return [
      IosNativeMenuItem(
        id: '__manage__',
        title: '查看与管理全部仓库…',
        subtitle: '共 ${depots.length} 个子仓库',
        symbol: 'archivebox',
        section: 0,
      ),
      for (var i = 0; i < depots.length; i++) ...[
        () {
          final d = depots[i];
          final owners = subs.where((sub) => sub.id == d.subscriptionId);
          final owner = owners.isEmpty ? null : owners.first;
          final isCurrent =
              d.url == (owner?.url ?? widget.storage.configOrigin);
          return IosNativeMenuItem(
            id: 'depot:$i',
            title: d.name,
            symbol: 'shippingbox',
            checked: isCurrent,
            section: 1,
          );
        }(),
      ],
    ];
  }

  Future<void> _openNativeFilterSheet() async {
    final subCats = CmsParser.subCategoriesForPrimaryTab(
      _categories,
      _primaryTab,
    );
    final existingNames = subCats.map((c) => c.name.trim()).toSet();
    final extraGenres = [
      for (final g in CmsParser.fallbackGenreTags)
        if (!existingNames.any((n) => n.contains(g))) g,
    ];
    final cats = <IosNativeFilterCategory>[
      const IosNativeFilterCategory(id: '', label: '全部', kind: 'all'),
      for (final c in subCats)
        IosNativeFilterCategory(id: c.id, label: c.name, kind: 'cat'),
      for (final g in extraGenres)
        IosNativeFilterCategory(id: g, label: g, kind: 'genre'),
    ];
    final picked = IosLiquidGlassBridge.isAvailable
        ? await showAppleNativeFilterSheet(
            title: '片库筛选',
            categories: cats,
            selectedCategoryId: _filterSubCategoryId,
            selectedGenreLabel: _filterGenreLabel,
            areas: CmsParser.filterAreas,
            selectedArea: _filterArea,
            years: CmsParser.filterYears,
            selectedYear: _filterYear,
          )
        : await showIosCatalogFilterSheet(
            context: context,
            title: '片库筛选',
            categories: cats,
            selectedCategoryId: _filterSubCategoryId,
            selectedGenreLabel: _filterGenreLabel,
            areas: CmsParser.filterAreas,
            selectedArea: _filterArea,
            years: CmsParser.filterYears,
            selectedYear: _filterYear,
          );
    if (picked == null || !mounted) return;
    final changed = picked.categoryId != _filterSubCategoryId ||
        picked.genreLabel != _filterGenreLabel ||
        picked.area != _filterArea ||
        picked.year != _filterYear;
    if (!changed) return;
    setState(() {
      _filterSubCategoryId = picked.categoryId;
      _filterGenreLabel = picked.genreLabel;
      _filterArea = picked.area;
      _filterYear = picked.year;
      _filterExpanded = false;
    });
    _reloadFilteredListing(page: 1);
  }

  bool get _isDesktop {
    if (kIsWeb) return false;
    if (OhosRuntime.isOhos &&
        OhosRuntime.deviceProfile.deviceType.toLowerCase() == '2in1') {
      return true;
    }
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  @override
  Widget build(BuildContext context) {
    if (isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null) {
      return _buildWindowsShell(context);
    }
    final size = MediaQuery.sizeOf(context);
    final useSidebar =
        _isDesktop ? (size.width >= 700) : (size.width > size.height);
    const dockItems = _iosDockFallbackItems;
    final nativeDockItems = _buildIosNativeDockItems();
    final safeTabIndex = _tabIndex.clamp(0, dockItems.length - 1);
    final Widget activePage = switch (safeTabIndex) {
      1 => _buildLiveTab(context, useSidebar: useSidebar),
      2 => _buildFavoritesHistoryTab(context, useSidebar: useSidebar),
      3 => _buildSettingsTab(context, useSidebar: useSidebar),
      _ => _buildHomeTab(context, useSidebar: useSidebar),
    };
    final ambientPoster = safeTabIndex == 0 && _homeVideos.isNotEmpty
        ? _homeVideos.first.poster
        : '';
    final ambientTitle = safeTabIndex == 0 &&
            _homeVideos.isNotEmpty &&
            !_privateSessionUnlocked &&
            !(_activeSite?.isEffectivelyPrivate ?? false)
        ? _homeVideos.first.title
        : '';
    final ambientYear = safeTabIndex == 0 && _homeVideos.isNotEmpty
        ? _homeVideos.first.year
        : '';
    final customWallUrl = widget.storage.customWallpaperUrl;
    final blurSigma = switch (widget.storage.glassBlurLevel) {
      'light' => 36.0,
      'deep' => 84.0,
      _ => 60.0,
    };
    Widget? customWallWidget;
    if (customWallUrl.isNotEmpty) {
      if (customWallUrl.startsWith('http://') ||
          customWallUrl.startsWith('https://')) {
        customWallWidget = PosterImage(
          url: customWallUrl,
          highRes: true,
          placeholder: const SizedBox.shrink(),
        );
      } else if (!kIsWeb) {
        final file = File(customWallUrl);
        if (file.existsSync()) {
          customWallWidget = Image.file(
            file,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          );
        }
      }
    }
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _showGlobalSearchSheet,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _showGlobalSearchSheet,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: ApplePalette.of(context).background,
      extendBody: true,
      bottomNavigationBar: (useSidebar || _useRootNativeTabChrome)
          ? null
          : Center(
              heightFactor: 1,
              child: AppleLiquidGlassDock(
                selectedIndex: safeTabIndex,
                onSelect: _handleRootNativeTabSelected,
                isLandscape: false,
                items: dockItems,
                nativeItems: nativeDockItems,
                onSearch: _showGlobalSearchSheet,
                onScrollToTop: _scrollHomeToTop,
                tabMenuItemsBuilder: _buildDockTabSlideMenuActions,
                onTabMenuAction: _handleDockTabMenuAction,
                hidden: _privacyPortalAnimating,
                collapsed: _dockCollapsed && safeTabIndex == 0,
                scrollProgress: safeTabIndex == 0 ? _dockScrollProgress : null,
              ),
            ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Minimal Apple background: true black, faint top lift, and a softly
          // blurred ambient artwork of the featured title on the home tab.
          RepaintBoundary(
            child: AnimatedSwitcher(
              duration: (isWindowsDesktopUi ||
                      Ios27ConcentricGeometry.isReduceMotion(context))
                  ? Duration.zero
                  : const Duration(milliseconds: 600),
              child: AppleAmbientBackground(
                key: ValueKey<String>(
                  '$ambientPoster|${widget.storage.wallpaperPreset}|$customWallUrl|${widget.storage.ambientGlowEnabled}|$blurSigma',
                ),
                preset: widget.storage.wallpaperPreset,
                customWallpaper: customWallWidget,
                showAmbientArtwork: widget.storage.ambientGlowEnabled,
                blurSigma: blurSigma,
                artwork: ambientPoster.isEmpty && ambientTitle.isEmpty
                    ? null
                    : Opacity(
                        opacity: 0.55,
                        child: PosterImage(
                          url: ambientPoster,
                          title: ambientTitle,
                          year: ambientYear,
                          highRes: !isWindowsDesktopUi,
                          forBackdrop: true,
                          placeholder: const SizedBox.shrink(),
                        ),
                      ),
              ),
            ),
          ),
          // Active page content (with right clearance in landscape for the right-side Dock,
          // or top clearance when root-hosted iOS 27 native chrome switches to top bar in wide mode)
          Padding(
            padding: EdgeInsets.only(
              top: (useSidebar && _useRootNativeTabChrome) ? 62.0 : 0.0,
              right: (useSidebar && !_useRootNativeTabChrome)
                  ? AppleLiquidGlassDock.landscapeFootprint(context)
                  : 0,
            ),
            child: RepaintBoundary(child: activePage),
          ),
          // iPhone / iPad style Dock:
          // - Portrait: bottom floating rounded-rectangle dock
          // - Landscape: right-side vertical dock
          if (useSidebar && !_useRootNativeTabChrome)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: Center(
                child: AppleLiquidGlassDock(
                  selectedIndex: safeTabIndex,
                  onSelect: _handleRootNativeTabSelected,
                  isLandscape: true,
                  items: dockItems,
                  nativeItems: nativeDockItems,
                  onSearch: _showGlobalSearchSheet,
                  onScrollToTop: _scrollHomeToTop,
                  tabMenuItemsBuilder: _buildDockTabSlideMenuActions,
                  onTabMenuAction: _handleDockTabMenuAction,
                  hidden: _privacyPortalAnimating,
                ),
              ),
            ),
          if (_privacyPortalAnimating)
            Positioned.fill(
              child: _PrivacyModePortalAnimation(
                key: ValueKey('privacy_portal_$_privacyPortalRunId'),
                onFinished: () {
                  if (mounted) {
                    setState(() => _privacyPortalAnimating = false);
                    _syncRootTabVisibility(animated: true);
                  }
                },
              ),
            ),
        ],
      ),
        ),
      ),
    );
  }
  Widget _buildHomeTab(BuildContext context, {required bool useSidebar}) {
    if (_config == null && !_privateSessionUnlocked) {
      return _buildWelcomeOnboarding(context);
    }
    final depots =
        _privateSessionUnlocked ? const <CmsDepot>[] : (_config?.depots ?? const []);
    final history = _privateSessionUnlocked
        ? const <WatchHistoryEntry>[]
        : _cachedWatchHistory;
    final topSafePad = MediaQuery.paddingOf(context).top;
    final activeFilterCount = _currentFilter.activeDimensionCount;
    return SafeArea(
      top: false,
      bottom: false,
      right: !useSidebar,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH =
              constraints.maxHeight > 0 ? constraints.maxHeight : 800.0;
          final viewport = AppleViewportLayout(
            Size(constraints.maxWidth, maxH),
          );
          final horizontalPad =
              viewport.horizontalPadding(useSidebar: useSidebar);
          final isIosMobileHome =
              !useSidebar &&
              defaultTargetPlatform == TargetPlatform.iOS &&
              !OhosRuntime.isOhos;
          final heroCandidates = (_windowsRecommendedVideos.isNotEmpty
                  ? _windowsRecommendedVideos
                  : _homeVideos)
              .where((v) => !v.id.startsWith('netdisk_qr:'))
              .take(6)
              .toList(growable: false);
          final showIosImmersiveHero =
              isIosMobileHome &&
              _activeSite != null &&
              widget.storage.showHeroBanner &&
              !CspBridge.isMyDriveSite(_activeSite!) &&
              heroCandidates.isNotEmpty;
          final compactHeader = constraints.maxWidth < 600;
          final depotLabel = compactHeader
              ? ''
              : (widget.storage.activeDepotName.isEmpty
                  ? '切换仓库'
                  : widget.storage.activeDepotName);
          final sourceLabel = (_activeSite?.name ??
                  (_privateSessionUnlocked ? '选择隐私源' : '选择片源'))
              .replaceAll(RegExp(r'[\r\n\s]+'), ' ')
              .trim();
          final double sourceMaxW = viewport.isCompactSplit
              ? (depots.isEmpty ? 156.0 : 126.0)
              : (compactHeader ? (depots.isEmpty ? 204.0 : 168.0) : 228.0);
          final isIosPlatform =
              defaultTargetPlatform == TargetPlatform.iOS &&
                  !OhosRuntime.isOhos;
          final depotMenuItems =
              depots.isNotEmpty ? _buildHomeDepotMenuItems(depots) : const <IosNativeMenuItem>[];
          final sourceMenuItems = _buildHomeSourceMenuItems(currentGroupOnly: true);
          void handleDepotMenuSelection(String id) {
            if (id == '__manage__') {
              _showDepotPickerDialog();
              return;
            }
            if (id.startsWith('depot:')) {
              final idx = int.tryParse(id.substring(6));
              if (idx != null && idx >= 0 && idx < depots.length) {
                unawaited(_switchToDepotDirect(depots[idx]));
              }
            }
          }
          final Widget depotFallbackButton = isIosPlatform
              ? IosPressSlideMenuAnchor(
                  key: const ValueKey('home-depot-button'),
                  openOnTap: false,
                  onTap: _showDepotPickerDialog,
                  itemsBuilder: () =>
                      iosSlideActionsFromNativeMenu(depotMenuItems),
                  onSelected: handleDepotMenuSelection,
                  accessibilityLabel:
                      depotLabel.isEmpty ? '切换仓库' : '切换仓库 $depotLabel',
                  menuKey: const ValueKey('home-depot-longpress-menu'),
                  minTouchWidth: 44,
                  minTouchHeight: 44,
                  child: _buildHeaderCapsule(
                    compact: compactHeader,
                    icon: CupertinoIcons.archivebox_fill,
                    label: depotLabel,
                    onTap: () {},
                    absorbTap: false,
                  ),
                )
              : _buildHeaderCapsule(
                  compact: compactHeader,
                  icon: CupertinoIcons.archivebox_fill,
                  label: depotLabel,
                  onTap: _showDepotPickerDialog,
                );
          final Widget sourceFallbackButton = isIosPlatform
              ? IosPressSlideMenuAnchor(
                  key: const ValueKey('home-source-button'),
                  openOnTap: false,
                  onTap: _showSitePickerDialog,
                  itemsBuilder: () =>
                      iosSlideActionsFromNativeMenu(sourceMenuItems),
                  onSelected: _onHomeSourceMenuSelected,
                  accessibilityLabel: '切换片源 $sourceLabel',
                  menuKey: const ValueKey('home-source-longpress-menu'),
                  minTouchWidth: 44,
                  minTouchHeight: 44,
                  child: _buildHeaderCapsule(
                    compact: compactHeader,
                    icon: _privateSessionUnlocked
                        ? CupertinoIcons.lock_shield_fill
                        : CupertinoIcons.layers_alt_fill,
                    label: sourceLabel,
                    onTap: () {},
                    absorbTap: false,
                  ),
                )
              : _buildHeaderCapsule(
                  compact: compactHeader,
                  icon: _privateSessionUnlocked
                      ? CupertinoIcons.lock_shield_fill
                      : CupertinoIcons.layers_alt_fill,
                  label: sourceLabel,
                  onTap: _showSitePickerDialog,
                );
          final sourceControls = Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (depots.isNotEmpty) ...[
                Flexible(
                  child: IosNativeGlassButton(
                    style: compactHeader ? 'circle' : 'capsule',
                    symbol: 'archivebox.fill',
                    trailingSymbol: compactHeader ? null : 'chevron.down',
                    label: depotLabel,
                    symbolSize: 13.5,
                    forceDark: showIosImmersiveHero,
                    height: 36,
                    width: compactHeader ? 36 : null,
                    maxWidth: 148,
                    accessibilityLabel:
                        depotLabel.isEmpty ? '切换仓库' : '切换仓库 $depotLabel',
                    menuTitle: '切换多仓子仓库',
                    menuItems: depotMenuItems,
                    menuAsPrimaryAction: false,
                    onMenuSelected: handleDepotMenuSelection,
                    onTap: _showDepotPickerDialog,
                    fallback: depotFallbackButton,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: IosNativeGlassButton(
                  style: 'capsule',
                  symbol: _privateSessionUnlocked
                      ? 'lock.shield.fill'
                      : 'square.3.layers.3d',
                  trailingSymbol: 'chevron.down',
                  label: sourceLabel,
                  symbolSize: 13.5,
                  forceDark: showIosImmersiveHero,
                  height: 36,
                  maxWidth: sourceMaxW,
                  accessibilityLabel: '切换片源 $sourceLabel',
                  menuTitle: _privateSessionUnlocked ? '隐私片源' : '切换片源',
                  menuItems: sourceMenuItems,
                  menuAsPrimaryAction: false,
                  onMenuSelected: _onHomeSourceMenuSelected,
                  onTap: _showSitePickerDialog,
                  fallback: sourceFallbackButton,
                ),
              ),
            ],
          );
          final s1 = ((topSafePad * 0.35) / maxH).clamp(0.008, 0.045);
          final s2 = ((topSafePad * 0.78) / maxH).clamp(0.020, 0.085);
          final s3 = ((topSafePad + 16.0) / maxH).clamp(0.038, 0.13);
          final showCuratedDiscovery =
              _activeSite != null &&
              !_privateSessionUnlocked &&
              widget.storage.showCuratedDiscovery &&
              (isIosMobileHome ||
                  (_primaryTab == 'recommend' &&
                      !_currentFilter.hasSubFilter &&
                      _filterSubCategoryId.isEmpty &&
                      _homeError == null));
          final topHeaderRow = _buildHomeTopHeaderRow(
            context,
            constraints: constraints,
            compactHeader: compactHeader,
            sourceControls: sourceControls,
            overImmersiveHero: showIosImmersiveHero,
          );
          final iosHeroHeight = viewport.iosHomeHeroHeight(maxH);
          final heroHeightChanged =
              (_lastIosHeroHeight - iosHeroHeight).abs() >= 0.5;
          _lastIosHeroHeight = iosHeroHeight;
          if (_homeScrollController.positions.length == 1) {
            final currentOffset = _homeScrollController.offset;
            final desiredDarkStatus = currentOffset >= iosHeroHeight * 0.42;
            if (heroHeightChanged ||
                desiredDarkStatus != _iosHomeStatusBarDark.value) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _homeScrollController.positions.length != 1) {
                  return;
                }
                _updateHomeScrollVisualNotifiers(_homeScrollController.offset);
              });
            }
          }

          List<Widget> buildSourceCatalogSlivers({int? rexSectionSlotIndex}) {
            final useRexCardInk =
                showIosImmersiveHero && rexSectionSlotIndex != null;
            final gridExtent = viewport.posterGridExtent(
              useSidebar: useSidebar,
              density: widget.storage.gridDensity,
            );
            final gridWidth =
                math.max(1.0, constraints.maxWidth - horizontalPad * 2);
            final crossAxisCount =
                ((gridWidth + 12.0) / (gridExtent + 12.0)).ceil().clamp(1, 12);
            final tileWidth =
                (gridWidth - 12.0 * (crossAxisCount - 1)) / crossAxisCount;
            final tileHeight = tileWidth / 0.56;

            return [
              if (_homeError != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.exclamationmark_triangle_fill,
                            color: AppleColors.systemOrange,
                            size: 38,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _homeError!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: ApplePalette.of(context).labelSecondary,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            children: [
                              AppleCapsuleButton(
                                label: '重试',
                                icon: CupertinoIcons.refresh,
                                primary: true,
                                compact: true,
                                onPressed: _retryHomeError ?? _loadSiteHome,
                              ),
                              if (CmsClient.needsSourceVerification(
                                  _activeSite!, _homeErrorCause))
                                SourceVerificationButton(
                                  client: widget.client,
                                  site: _activeSite!,
                                  onVerified: _retryHomeError ?? _loadSiteHome,
                                ),
                              AppleCapsuleButton(
                                label: '切换其他片源',
                                icon: CupertinoIcons.layers_alt,
                                compact: true,
                                onPressed: _showSitePickerDialog,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPad,
                    vertical: 8,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: gridExtent,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.56,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final video = _homeVideos[index];
                        if (!useRexCardInk) {
                          return _buildVideoCard(_activeSite!, video);
                        }
                        final site = _activeSite!;
                        final cardKey =
                            'vcard_${site.key}_${video.id.isNotEmpty ? video.id : video.title}_';
                        final row = index ~/ crossAxisCount;
                        return RepaintBoundary(
                          key: ValueKey(cardKey),
                          child: AnimatedBuilder(
                            animation: Listenable.merge([
                              _iosHeroPageController,
                              _rexCardInkScrollOffset,
                            ]),
                            builder: (cardCtx, _) {
                              final rawOffset = _rexCardInkScrollOffset.value;
                              final scrollFade = _rexHeroScrollFadeForOffset(
                                rawOffset,
                                iosHeroHeight,
                              );
                              if (scrollFade >= 0.999) {
                                return _buildVideoCard(
                                  site,
                                  video,
                                  includeOuterKey: false,
                                );
                              }
                              final palette = ApplePalette.of(cardCtx);
                              final liveAtmo = _resolveLiveRexHeroAtmo(
                                heroCandidates,
                                palette,
                              );
                              final scrollDown = math.max(0.0, rawOffset);
                              final titleContentY = iosHeroHeight +
                                  rexSectionSlotIndex * 235.0 +
                                  104.0 +
                                  row * (tileHeight + 16.0) +
                                  tileHeight -
                                  28.0;
                              final subContentY = titleContentY + 16.0;
                              final titleY =
                                  (titleContentY - scrollDown).clamp(0.0, maxH);
                              final subY =
                                  (subContentY - scrollDown).clamp(0.0, maxH);
                              final titleBg = _sampleRexBackdropColorAtY(
                                viewportY: titleY,
                                viewportHeight: maxH,
                                heroHeight: iosHeroHeight,
                                scrollOffset: rawOffset,
                                liveAtmo: liveAtmo,
                                palette: palette,
                              );
                              final subBg = _sampleRexBackdropColorAtY(
                                viewportY: subY,
                                viewportHeight: maxH,
                                heroHeight: iosHeroHeight,
                                scrollOffset: rawOffset,
                                liveAtmo: liveAtmo,
                                palette: palette,
                              );
                              final inks = _resolveRexInksForBackdropBand(
                                hysteresisSlotKey:
                                    1000 + rexSectionSlotIndex * 100 + row,
                                primaryBg: titleBg,
                                secondaryBg: subBg,
                                palette: palette,
                              );
                              return _buildVideoCard(
                                site,
                                video,
                                includeOuterKey: false,
                                titleColorOverride: inks.primary,
                                subtitleColorOverride: inks.secondary,
                              );
                            },
                          ),
                        );
                      },
                      childCount: _homeVideos.length,
                      findChildIndexCallback: (Key key) {
                        if (key is! ValueKey<String>) return null;
                        final siteKey = _activeSite?.key ?? '';
                        final target = key.value;
                        for (int i = 0; i < _homeVideos.length; i++) {
                          final v = _homeVideos[i];
                          final expected =
                              'vcard_${siteKey}_${v.id.isNotEmpty ? v.id : v.title}_';
                          if (expected == target) return i;
                        }
                        return null;
                      },
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: 18,
                    bottom: useSidebar ? 32 : 24,
                  ),
                  child: Center(
                    child: (_homeLoading || _loadingMore)
                        ? const CupertinoActivityIndicator(radius: 13)
                        : (_homeVideos.isEmpty && _homeError == null)
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 40,
                                  horizontal: 20,
                                ),
                                child: (_activeSite != null &&
                                        CspBridge.isSearchOnlySite(_activeSite!))
                                    ? Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '「${_activeSite!.name}」为网盘搜索专用源，不提供首页推荐片单，请直接搜索影片',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: ApplePalette.of(context)
                                                  .labelSecondary,
                                              fontSize: 14,
                                            ),
                                          ),
                                          const SizedBox(height: 14),
                                          AppleCapsuleButton(
                                            label: '立即搜索影片',
                                            icon: CupertinoIcons.search,
                                            compact: true,
                                            onPressed: _showGlobalSearchSheet,
                                          ),
                                        ],
                                      )
                                    : Text(
                                        '当前筛选条件下暂无影片，试试调整筛选或切换分类',
                                        style: TextStyle(
                                          color: ApplePalette.of(context)
                                              .labelSecondary,
                                          fontSize: 14,
                                        ),
                                      ),
                              )
                            : (_loadMoreError != null &&
                                    _currentPage < _pageCount
                                ? AppleCapsuleButton(
                                    label: '重试加载更多',
                                    icon: CupertinoIcons.refresh,
                                    compact: true,
                                    onPressed: () => _reloadFilteredListing(
                                      page: _currentPage + 1,
                                    ),
                                  )
                                : const SizedBox.shrink()),
                  ),
                ),
              ),
            ];
          }

          List<Widget> buildIosConfigurableBodySlivers() {
            final slivers = <Widget>[];
            if (_activeSite != null && CspBridge.isMyDriveSite(_activeSite!)) {
              slivers.add(
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPad,
                      16,
                      horizontalPad,
                      0,
                    ),
                    child: _buildMyDriveNetdiskBanner(_activeSite!),
                  ),
                ),
              );
            }
            final hasSearchable = (_config?.publicAvailableSites ?? const [])
                .any((s) => s.searchable);
            final orderedIds = widget.storage.homeSectionOrder;
            var emittedCount = 0;

            Widget wrapFirstHeroShelfHeader(
              Widget Function(Color? headerInk, Color? secondaryInk) builder,
            ) {
              if (!showIosImmersiveHero) {
                return builder(null, null);
              }
              final slotIndex = emittedCount;
              return AnimatedBuilder(
                animation: Listenable.merge([
                  _iosHeroPageController,
                  _rexCardInkScrollOffset,
                ]),
                builder: (context, _) {
                  final palette = ApplePalette.of(context);
                  final rawOffset = _rexCardInkScrollOffset.value;
                  final scrollFade =
                      _rexHeroScrollFadeForOffset(rawOffset, iosHeroHeight);
                  if (scrollFade >= 0.999) {
                    return builder(null, null);
                  }
                  final liveAtmo = _resolveLiveRexHeroAtmo(
                    heroCandidates,
                    palette,
                  );
                  final inks = _resolveRexShelfInks(
                    shelfSlotIndex: slotIndex,
                    liveAtmo: liveAtmo,
                    palette: palette,
                    heroHeight: iosHeroHeight,
                    viewportHeight: maxH,
                    scrollOffset: rawOffset,
                  );
                  return builder(inks.primary, inks.secondary);
                },
              );
            }

            for (final sectionId in orderedIds) {
              if (!widget.storage.isHomeSectionEnabled(sectionId)) continue;

              if (sectionId == StorageService.homeSectionHistory) {
                if (!_privateSessionUnlocked && history.isNotEmpty) {
                  final isFirstUnderHero =
                      emittedCount == 0 && showIosImmersiveHero;
                  slivers.add(
                    SliverToBoxAdapter(
                      key: const ValueKey('home-section-watch_history'),
                      child: wrapFirstHeroShelfHeader(
                        (headerInk, secondaryInk) => _buildHomeHistoryShelf(
                          context,
                          history: history,
                          horizontalPad: horizontalPad,
                          topSpacing: isFirstUnderHero ? 14 : 16,
                          headerInkOverride: headerInk,
                          secondaryInkOverride: secondaryInk,
                        ),
                      ),
                    ),
                  );
                  emittedCount++;
                }
                continue;
              }

              if (sectionId.startsWith('disc_')) {
                if (!_privateSessionUnlocked &&
                    widget.storage.showCuratedDiscovery) {
                  final isFirstUnderHero =
                      emittedCount == 0 && showIosImmersiveHero;
                  slivers.add(
                    SliverToBoxAdapter(
                      key: ValueKey('home-section-$sectionId'),
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: isFirstUnderHero ? 14 : 22,
                        ),
                        child: wrapFirstHeroShelfHeader(
                          (headerInk, secondaryInk) => CuratedDiscoverySection(
                            visibleSectionIds: [sectionId],
                            hasUserSources: hasSearchable,
                            loadLive:
                                !Platform.environment.containsKey('FLUTTER_TEST'),
                            headerInkOverride: headerInk,
                            secondaryInkOverride: secondaryInk,
                            dockHost: defaultTargetPlatform == TargetPlatform.iOS &&
                                    !OhosRuntime.isOhos
                                ? _curatedDockHost
                                : null,
                            onOpenVideo: (video) => _openVideoDetail(
                              CuratedDiscoveryService.curatedSiteSentinel,
                              video,
                            ),
                            onOpenVideoFromCard:
                                (video, cardCtx, radius, cardId) =>
                                    _openVideoDetail(
                              CuratedDiscoveryService.curatedSiteSentinel,
                              video,
                              sourceContext: cardCtx,
                              sourceRadius: radius,
                              sourceCardId: cardId,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  emittedCount++;
                }
                continue;
              }

              if (sectionId == StorageService.homeSectionSourceUpdates &&
                  _activeSite != null) {
                final isFirstUnderHero =
                    emittedCount == 0 && showIosImmersiveHero;
                final topPad = isFirstUnderHero
                    ? 14.0
                    : (emittedCount == 0 ? 12.0 : 22.0);
                slivers.add(
                  SliverToBoxAdapter(
                    key: const ValueKey('home-section-source_updates'),
                    child: wrapFirstHeroShelfHeader(
                      (headerInk, secondaryInk) =>
                          _buildHomeSourceUpdatesHeader(
                        context,
                        horizontalPad: horizontalPad,
                        topPadding: topPad,
                        bottomPadding: 10,
                        headerInkOverride: headerInk,
                        secondaryInkOverride: secondaryInk,
                      ),
                    ),
                  ),
                );
                slivers.add(
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildHomeCategoryFilterSection(
                        context,
                        horizontalPad: horizontalPad,
                        activeFilterCount: activeFilterCount,
                        topSpacing: 0,
                      ),
                    ),
                  ),
                );
                slivers.addAll(
                  buildSourceCatalogSlivers(
                    rexSectionSlotIndex: emittedCount,
                  ),
                );
                emittedCount++;
              }
            }

            // Generous safe bottom clearance for the floating Liquid Glass Dock.
            slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 112)));
            return slivers;
          }

          final homeScrollView = CustomScrollView(
              controller: _homeScrollController,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                if (isIosMobileHome) ...[
                  if (showIosImmersiveHero)
                    SliverToBoxAdapter(
                      child: _buildIosImmersiveHeroBillboard(
                        context,
                        site: _activeSite!,
                        featuredList: heroCandidates,
                        topSafePad: topSafePad,
                        heroHeight: iosHeroHeight,
                        horizontalPad: horizontalPad,
                        headerOverlay: topHeaderRow,
                      ),
                    )
                  else ...[
                    SliverPadding(
                      padding: EdgeInsets.only(top: topSafePad),
                      sliver: CupertinoSliverRefreshControl(
                        onRefresh: _refreshCurrentHomeView,
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
                      sliver: SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: horizontalPad,
                          ),
                          child: topHeaderRow,
                        ),
                      ),
                    ),
                  ],
                  if (_activeSite == null)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        24,
                        horizontalPad,
                        12,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _privateSessionUnlocked
                            ? _buildEmptyPrivacySpaceNotice(context)
                            : _buildPluginOnlyConfigNotice(context),
                      ),
                    ),
                  ...buildIosConfigurableBodySlivers(),
                ] else ...[
                  SliverPadding(
                    padding: EdgeInsets.only(top: topSafePad),
                    sliver: CupertinoSliverRefreshControl(
                      onRefresh: _refreshCurrentHomeView,
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      0,
                      _isMacOS ? 38 : 12,
                      0,
                      12,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: horizontalPad,
                            ),
                            child: topHeaderRow,
                          ),
                          if (_activeSite == null) ...[
                            const SizedBox(height: 24),
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: horizontalPad,
                              ),
                              child: _privateSessionUnlocked
                                  ? _buildEmptyPrivacySpaceNotice(context)
                                  : _buildPluginOnlyConfigNotice(context),
                            ),
                          ] else if (_isMacOS &&
                              !CspBridge.isMyDriveSite(_activeSite!) &&
                              _primaryTab == 'recommend' &&
                              !_currentFilter.hasSubFilter &&
                              _currentPage == 1) ...[
                            _buildMacWideHomeHeroSection(
                              context,
                              site: _activeSite!,
                              history: (!_privateSessionUnlocked &&
                                      widget.storage.showContinueWatching)
                                  ? history
                                  : const <WatchHistoryEntry>[],
                              contentWidth: math.max(
                                320.0,
                                constraints.maxWidth - horizontalPad * 2,
                              ),
                              horizontalPad: horizontalPad,
                            ),
                            _buildHomeCategoryFilterSection(
                              context,
                              horizontalPad: horizontalPad,
                              activeFilterCount: activeFilterCount,
                              topSpacing: 18,
                            ),
                          ] else ...[
                            if (!_privateSessionUnlocked &&
                                widget.storage.showContinueWatching &&
                                history.isNotEmpty)
                              _buildHomeHistoryShelf(
                                context,
                                history: history,
                                horizontalPad: horizontalPad,
                                topSpacing: 20,
                              ),
                            if (widget.storage.showHeroBanner &&
                                !CspBridge.isMyDriveSite(_activeSite!) &&
                                _homeVideos.isNotEmpty &&
                                !_homeVideos.first.id.startsWith('netdisk_qr:') &&
                                _primaryTab == 'recommend' &&
                                !_currentFilter.hasSubFilter &&
                                _currentPage == 1) ...[
                              const SizedBox(height: 18),
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPad,
                                ),
                                child: _buildHeroShowcaseCard(
                                  _activeSite!,
                                  _homeVideos.first,
                                  wide: useSidebar,
                                ),
                              ),
                            ],
                            if (CspBridge.isMyDriveSite(_activeSite!)) ...[
                              const SizedBox(height: 16),
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPad,
                                ),
                                child: _buildMyDriveNetdiskBanner(_activeSite!),
                              ),
                            ],
                            _buildHomeCategoryFilterSection(
                              context,
                              horizontalPad: horizontalPad,
                              activeFilterCount: activeFilterCount,
                              topSpacing: 18,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_activeSite != null) ...[
                    if (showCuratedDiscovery) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: CuratedDiscoverySection(
                            hasUserSources:
                                (_config?.publicAvailableSites ?? const [])
                                    .any((s) => s.searchable),
                            loadLive:
                                !Platform.environment.containsKey('FLUTTER_TEST'),
                            dockHost: defaultTargetPlatform == TargetPlatform.iOS &&
                                    !OhosRuntime.isOhos
                                ? _curatedDockHost
                                : null,
                            onOpenVideo: (video) => _openVideoDetail(
                              CuratedDiscoveryService.curatedSiteSentinel,
                              video,
                            ),
                            onOpenVideoFromCard:
                                (video, cardCtx, radius, cardId) =>
                                    _openVideoDetail(
                              CuratedDiscoveryService.curatedSiteSentinel,
                              video,
                              sourceContext: cardCtx,
                              sourceRadius: radius,
                              sourceCardId: cardId,
                            ),
                          ),
                        ),
                      ),
                      if (_homeVideos.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildHomeSourceUpdatesHeader(
                            context,
                            horizontalPad: horizontalPad,
                            topPadding: 4,
                            bottomPadding: 8,
                          ),
                        ),
                    ],
                    ...buildSourceCatalogSlivers(),
                    SliverToBoxAdapter(
                      child: SizedBox(height: useSidebar ? 12 : 96),
                    ),
                  ] else if (!_privateSessionUnlocked &&
                      widget.storage.showCuratedDiscovery) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: 20,
                          bottom: useSidebar ? 32 : 128,
                        ),
                        child: CuratedDiscoverySection(
                          hasUserSources:
                              (_config?.publicAvailableSites ?? const [])
                                  .any((s) => s.searchable),
                          loadLive:
                              !Platform.environment.containsKey('FLUTTER_TEST'),
                          dockHost: defaultTargetPlatform == TargetPlatform.iOS &&
                                  !OhosRuntime.isOhos
                              ? _curatedDockHost
                              : null,
                          onOpenVideo: (video) => _openVideoDetail(
                            CuratedDiscoveryService.curatedSiteSentinel,
                            video,
                          ),
                          onOpenVideoFromCard:
                              (video, cardCtx, radius, cardId) =>
                                  _openVideoDetail(
                            CuratedDiscoveryService.curatedSiteSentinel,
                            video,
                            sourceContext: cardCtx,
                            sourceRadius: radius,
                            sourceCardId: cardId,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            );
          final autoPagingScrollView = NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth == 0 &&
                  notification.metrics.axis == Axis.vertical &&
                  _dockOwner == IosDockOwner.home &&
                  _tabIndex == 0 &&
                  defaultTargetPlatform == TargetPlatform.iOS &&
                  !OhosRuntime.isOhos) {
                if (notification is ScrollStartNotification) {
                  if (notification.dragDetails != null) {
                    _homeUserDragging = true;
                    _dockMorphAnimToken++;
                    _dockMorphCtrl.stop();
                  }
                } else if (notification is ScrollUpdateNotification) {
                  if (notification.dragDetails != null) {
                    _homeUserDragging = true;
                  }
                } else if (notification is ScrollEndNotification) {
                  _homeUserDragging = false;
                  _settleHomeDockToStableEndpoint(animated: true);
                }
              }
              if (showIosImmersiveHero &&
                  notification.metrics.axis == Axis.vertical) {
                final overscroll = -notification.metrics.pixels;
                if (notification is ScrollUpdateNotification) {
                  if (notification.dragDetails != null) {
                    if (overscroll >= 84.0 &&
                        !_iosHeroPullArmed &&
                        !_homeRefreshing) {
                      _iosHeroPullArmed = true;
                      HapticFeedback.mediumImpact();
                    } else if (overscroll < 56.0 && _iosHeroPullArmed) {
                      _iosHeroPullArmed = false;
                    }
                  } else if (_iosHeroPullArmed && !_homeRefreshing) {
                    _iosHeroPullArmed = false;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !_homeRefreshing) {
                        unawaited(_refreshCurrentHomeView());
                      }
                    });
                  }
                } else if (notification is ScrollEndNotification &&
                    _iosHeroPullArmed &&
                    !_homeRefreshing) {
                  _iosHeroPullArmed = false;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_homeRefreshing) {
                      unawaited(_refreshCurrentHomeView());
                    }
                  });
                }
              }
              if (notification.metrics.axis == Axis.vertical &&
                  (notification.metrics.maxScrollExtent > 0 ||
                      notification.metrics.pixels > 16) &&
                  notification.metrics.extentAfter < 420 &&
                  !_homeLoading &&
                  !_loadingMore &&
                  !_autoPagingScheduled &&
                  _homeError == null &&
                  _loadMoreError == null &&
                  _currentPage < _pageCount) {
                _autoPagingScheduled = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _autoPagingScheduled = false;
                  if (!mounted ||
                      _homeLoading ||
                      _loadingMore ||
                      _homeError != null ||
                      _loadMoreError != null ||
                      _currentPage >= _pageCount) {
                    return;
                  }
                  _reloadFilteredListing(page: _currentPage + 1);
                });
              }
              return false;
            },
            child: homeScrollView,
          );
          if (isWindowsDesktopUi) {
            return autoPagingScrollView;
          }
          final bgColor = ApplePalette.of(context).background;
          final maskedScroll = ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => showIosImmersiveHero
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0x00FFFFFF),
                    ],
                    stops: [0.0, 0.968, 1.0],
                  ).createShader(rect)
                : LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [
                      Color(0x00FFFFFF),
                      Color(0x1EFFFFFF),
                      Color(0x88FFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0x00FFFFFF),
                    ],
                    stops: [0.0, s1, s2, s3, 0.968, 1.0],
                  ).createShader(rect),
            child: autoPagingScrollView,
          );
          final homeStack = Stack(
            fit: StackFit.expand,
            children: [
              // Layer 0 (STRICTLY BEHIND CustomScrollView): Rex-style full-bleed
              // Hero atmosphere backdrop. Tracks vertical scroll & pull-down
              // stretch 1:1 and live-morphs color across horizontal carousel
              // swipes. Stays 100% solid across the Hero & right behind the
              // first shelf header ("光影风向标"), then dissolves smoothly behind
              // the opaque first-row cards into the pure Light/Dark page canvas
              // — zero Sliver 0 paint-order fog, zero seam, zero white flash!
              if (showIosImmersiveHero)
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: Listenable.merge([
                          _rexBackdropScrollOffset,
                          _iosHeroPageController,
                        ]),
                        builder: (context, _) {
                          final palette = ApplePalette.of(context);
                          final liveAtmo = _resolveLiveRexHeroAtmo(
                            heroCandidates,
                            palette,
                          );
                          final rawOffset = _rexBackdropScrollOffset.value;
                        final scrollDown = math.max(0.0, rawOffset);
                        final metrics = _computeRexBackdropMetrics(
                          liveAtmo: liveAtmo,
                          palette: palette,
                          heroHeight: iosHeroHeight,
                          scrollOffset: rawOffset,
                        );
                        final edge = metrics.liveEdgeColor;
                        final solidEndStop = metrics.auraSolidEndStop;
                        final tail = 1.0 - solidEndStop;

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fill(
                              child: DecoratedBox(
                                key: const ValueKey(
                                  'ios-hero-rex-full-tonal-bg',
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      metrics.fullScreenTopTone,
                                      metrics.fullScreenMidTone,
                                      metrics.fullScreenBotTone,
                                    ],
                                    stops: const [0.0, 0.62, 1.0],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: -_kRexAuraTopExtend - scrollDown,
                              left: 0,
                              right: 0,
                              height: metrics.auraTotalHeight,
                              child: DecoratedBox(
                                key: const ValueKey(
                                  'ios-hero-top-ambient-aura',
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      edge,
                                      edge,
                                      edge.withValues(alpha: 0.86),
                                      edge.withValues(alpha: 0.58),
                                      edge.withValues(alpha: 0.28),
                                      edge.withValues(alpha: 0.09),
                                      edge.withValues(alpha: 0.0),
                                    ],
                                    stops: [
                                      0.0,
                                      solidEndStop,
                                      solidEndStop + tail * 0.18,
                                      solidEndStop + tail * 0.40,
                                      solidEndStop + tail * 0.64,
                                      solidEndStop + tail * 0.84,
                                      1.0,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    ),
                  ),
                ),
              maskedScroll,
              if (showIosImmersiveHero)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topSafePad + 54,
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _iosHomeTopScrimOpacity,
                      builder: (context, scrimOpacity, child) {
                        if (scrimOpacity <= 0.01) {
                          return const SizedBox.shrink();
                        }
                        return Opacity(opacity: scrimOpacity, child: child);
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              bgColor.withValues(alpha: 0.94),
                              bgColor.withValues(alpha: 0.78),
                              bgColor.withValues(alpha: 0.44),
                              bgColor.withValues(alpha: 0.14),
                              bgColor.withValues(alpha: 0.0),
                            ],
                            stops: const [0.0, 0.28, 0.56, 0.80, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
          if (!showIosImmersiveHero) {
            return homeStack;
          }
          final isDarkHome = ApplePalette.isDarkOf(context);
          return ValueListenableBuilder<bool>(
            valueListenable: _iosHomeStatusBarDark,
            child: homeStack,
            builder: (context, pastHeroThreshold, child) {
              // Keep iOS status bar light over the dark immersive Hero poster,
              // flipping to dark in Light Mode once scrolled into light shelves.
              final overlayStyle = (isDarkHome || !pastHeroThreshold)
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: overlayStyle,
                child: child!,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildHomeTopHeaderRow(
    BuildContext context, {
    required BoxConstraints constraints,
    required bool compactHeader,
    required Widget sourceControls,
    bool overImmersiveHero = false,
  }) {
    return Row(
      children: [
        Flexible(
          flex: 0,
          child: GestureDetector(
            key: const ValueKey('home-brand-logo'),
            behavior: HitTestBehavior.opaque,
            onTap: _handleHomeLogoTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: 44,
                maxWidth: defaultTargetPlatform == TargetPlatform.iOS
                    ? (compactHeader ? constraints.maxWidth * .4 : 210)
                    : double.infinity,
              ),
              child: MarcoBrandLogo(
                iconSize: defaultTargetPlatform == TargetPlatform.iOS
                    ? (compactHeader ? 36 : 40)
                    : (compactHeader ? 24 : 28),
                fontSize: defaultTargetPlatform == TargetPlatform.iOS
                    ? (constraints.maxWidth < 360 ? 16 : 18)
                    : (compactHeader ? 14 : 16.5),
                showWordmark:
                    (!_privateSessionUnlocked || !compactHeader) &&
                    (defaultTargetPlatform != TargetPlatform.iOS ||
                        constraints.maxWidth >= 360),
                forceLightInk: overImmersiveHero,
              ),
            ),
          ),
        ),
        if (_privateSessionUnlocked) ...[
          const SizedBox(width: 8),
          GestureDetector(
            key: const ValueKey('home-exit-privacy-pill'),
            onTap: _exitPrivacySpace,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                ),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0x88C4B5FD),
                  width: 0.6,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.eye_slash_fill,
                    color: Colors.white,
                    size: 11.5,
                  ),
                  SizedBox(width: 4),
                  Text(
                    '隐私 · 退出',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Expanded(child: sourceControls),
        const SizedBox(width: 6),
        Builder(
          builder: (context) {
            final isIosPlatform =
                defaultTargetPlatform == TargetPlatform.iOS &&
                    !OhosRuntime.isOhos;
            final loggedCount = NetdiskService.drives
                .where((d) => widget.storage.isNetdiskLoggedIn(d.key))
                .length;
            void openNetdisk() {
              _openConfigCenterPage(iosBackLabel: '主页');
            }
            final configMenuItems = _buildHomeConfigCenterMenuItems();
            final netdiskLabel = compactHeader
                ? ''
                : (loggedCount > 0 ? '配置 · $loggedCount' : '配置中心');
            final netdiskGlass = LiquidGlass(
              borderRadius: 999,
              elevated: false,
              rimStrength: 0.9,
              tint: loggedCount > 0
                  ? const Color(0x33165B33)
                  : const Color(0x281E1E24),
              padding: EdgeInsets.symmetric(
                horizontal: compactHeader ? 8.5 : 11,
                vertical: 8.5,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    loggedCount > 0
                        ? CupertinoIcons.cloud_fill
                        : CupertinoIcons.qrcode_viewfinder,
                    color: loggedCount > 0
                        ? AppleColors.systemGreen
                        : const Color(0xFF5AC8FA),
                    size: 13.5,
                  ),
                  if (!compactHeader) ...[
                    const SizedBox(width: 4),
                    Text(
                      netdiskLabel,
                      style: TextStyle(
                        color: ApplePalette.of(context).labelPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            );
            final fallback = (isWindowsDesktopUi || OhosRuntime.isOhos)
                ? ApplePressableScale(
                    key: const ValueKey('home-netdisk-button'),
                    pressedScale: 0.93,
                    pressedOpacity: 0.86,
                    onTap: openNetdisk,
                    child: netdiskGlass,
                  )
                : isIosPlatform
                    ? IosPressSlideMenuAnchor(
                        key: const ValueKey('home-netdisk-button'),
                        openOnTap: false,
                        onTap: openNetdisk,
                        itemsBuilder: () =>
                            iosSlideActionsFromNativeMenu(configMenuItems),
                        onSelected: _onHomeConfigCenterMenuSelected,
                        accessibilityLabel: '配置中心',
                        menuKey: const ValueKey(
                          'home-config-center-longpress-menu',
                        ),
                        minTouchWidth: 44,
                        minTouchHeight: 44,
                        child: netdiskGlass,
                      )
                    : Ios27Pressable(
                        key: const ValueKey('home-netdisk-button'),
                        pressedScale: Ios27Spring.pressSwellScale,
                        borderRadius: 999,
                        onTap: openNetdisk,
                        child: netdiskGlass,
                      );
            return IosNativeGlassButton(
              style: compactHeader ? 'circle' : 'capsule',
              symbol: loggedCount > 0 ? 'cloud.fill' : 'qrcode.viewfinder',
              label: netdiskLabel,
              symbolSize: 15,
              foregroundColor: loggedCount > 0
                  ? AppleColors.systemGreen
                  : ((overImmersiveHero || ApplePalette.isDarkOf(context))
                      ? const Color(0xFF5AC8FA)
                      : AppleColors.systemBlue),
              forceDark: overImmersiveHero,
              width: compactHeader ? 36 : null,
              height: 36,
              maxWidth: 124,
              accessibilityLabel: '配置中心',
              menuTitle: '配置中心',
              menuItems: configMenuItems,
              menuAsPrimaryAction: false,
              onMenuSelected: _onHomeConfigCenterMenuSelected,
              onTap: openNetdisk,
              fallback: fallback,
            );
          },
        ),
      ],
    );
  }

  Widget _buildHomeHistoryShelf(
    BuildContext context, {
    required List<WatchHistoryEntry> history,
    required double horizontalPad,
    required double topSpacing,
    Color? headerInkOverride,
    Color? secondaryInkOverride,
  }) {
    final titleColor =
        headerInkOverride ?? ApplePalette.of(context).labelPrimary;
    final actionColor = secondaryInkOverride ??
        (headerInkOverride != null &&
                headerInkOverride.computeLuminance() > 0.48
            ? headerInkOverride.withValues(alpha: 0.86)
            : AppleColors.systemBlue);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: topSpacing),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPad),
          child: Row(
            children: [
              Text(
                '历史记录',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const Spacer(),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 24,
                onPressed: _showWatchHistorySheet,
                child: Text(
                  '查看全部',
                  style: TextStyle(
                    color: actionColor,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 108,
          child: DesktopHorizontalScroller(
            controller: _continueWatchingScrollController,
            child: ListView.separated(
              controller: _continueWatchingScrollController,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPad,
                vertical: 8,
              ),
              itemCount: history.length.clamp(0, 8),
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (ctx, i) => _buildContinueWatchingCard(history[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHomeSourceUpdatesHeader(
    BuildContext context, {
    required double horizontalPad,
    required double topPadding,
    required double bottomPadding,
    Color? headerInkOverride,
    Color? secondaryInkOverride,
  }) {
    final palette = ApplePalette.of(context);
    final titleColor = headerInkOverride ?? palette.labelPrimary;
    final subColor = secondaryInkOverride ??
        (headerInkOverride != null
            ? headerInkOverride.withValues(alpha: 0.84)
            : palette.labelSecondary);
    return Padding(
      key: const ValueKey('home-source-updates-header'),
      padding: EdgeInsets.fromLTRB(
        horizontalPad,
        topPadding,
        horizontalPad,
        bottomPadding,
      ),
      child: Row(
        children: [
          Text(
            '片源最新更新',
            style: TextStyle(
              color: titleColor,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.35,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _activeSite?.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeCategoryFilterSection(
    BuildContext context, {
    required double horizontalPad,
    required int activeFilterCount,
    required double topSpacing,
  }) {
    return Column(
      key: const ValueKey('home-category-filter-bar'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (topSpacing > 0) SizedBox(height: topSpacing),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPad),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: IosNativeSegmentedControl(
                    segments: [
                      for (final (_, tabLabel) in CmsParser.primaryHomeTabs)
                        tabLabel,
                    ],
                    selectedIndex: CmsParser.primaryHomeTabs
                        .indexWhere((t) => t.$1 == _primaryTab)
                        .clamp(0, CmsParser.primaryHomeTabs.length - 1),
                    height: 36,
                    onChanged: (idx) {
                      if (idx >= 0 && idx < CmsParser.primaryHomeTabs.length) {
                        _selectPrimaryTab(CmsParser.primaryHomeTabs[idx].$1);
                      }
                    },
                    fallback: DesktopHorizontalScroller(
                      controller: _categoryPillsScrollController,
                      child: ListView.separated(
                        controller: _categoryPillsScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: CmsParser.primaryHomeTabs.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (ctx, idx) {
                          final (tabKey, tabLabel) =
                              CmsParser.primaryHomeTabs[idx];
                          return _buildCategoryPill(
                            label: tabLabel,
                            selected: _primaryTab == tabKey,
                            onTap: () => _selectPrimaryTab(tabKey),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IosNativeGlassButton(
                style: 'capsule',
                symbol: 'line.3.horizontal.decrease',
                label: activeFilterCount > 0
                    ? '筛选 · $activeFilterCount'
                    : '筛选',
                symbolSize: 13.5,
                tintColor:
                    activeFilterCount > 0 ? AppleColors.systemBlue : null,
                height: 36,
                maxWidth: 108,
                accessibilityLabel: '片库筛选',
                onTap: () => unawaited(_openNativeFilterSheet()),
                fallback: Semantics(
                  button: true,
                  label: '片库筛选',
                  child: GestureDetector(
                    key: const ValueKey('home-filter-button'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (defaultTargetPlatform == TargetPlatform.iOS &&
                          !OhosRuntime.isOhos) {
                        unawaited(_openNativeFilterSheet());
                      } else {
                        setState(() => _filterExpanded = !_filterExpanded);
                      }
                    },
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: defaultTargetPlatform == TargetPlatform.iOS
                            ? 44
                            : 36,
                        minWidth: defaultTargetPlatform == TargetPlatform.iOS
                            ? 44
                            : 0,
                      ),
                      child: Align(
                        alignment: Alignment.center,
                        widthFactor: 1.0,
                        child: LiquidGlass(
                          height: 36,
                          borderRadius: 999,
                          elevated: false,
                          rimStrength:
                              (_filterExpanded || activeFilterCount > 0)
                                  ? 1.05
                                  : 0.88,
                          tint: (_filterExpanded || activeFilterCount > 0)
                              ? const Color(0xCC0A84FF)
                              : const Color(0x241E1E24),
                          padding: const EdgeInsets.symmetric(horizontal: 13),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.slider_horizontal_3,
                                size: 14,
                                color:
                                    (_filterExpanded || activeFilterCount > 0)
                                        ? Colors.white
                                        : ApplePalette.of(context).labelPrimary,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                activeFilterCount > 0
                                    ? '筛选 · $activeFilterCount'
                                    : '筛选',
                                style: TextStyle(
                                  color:
                                      (_filterExpanded || activeFilterCount > 0)
                                          ? Colors.white
                                          : ApplePalette.of(context)
                                              .labelPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (activeFilterCount > 0 && !_filterExpanded)
          Padding(
            padding: EdgeInsets.fromLTRB(horizontalPad, 10, horizontalPad, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_filterSubCategoryId.isNotEmpty)
                  _buildActiveFilterBadge(
                    _categories
                            .where((c) => c.id == _filterSubCategoryId)
                            .map((c) => c.name)
                            .firstOrNull ??
                        _filterSubCategoryId,
                    onClear: () {
                      setState(() => _filterSubCategoryId = '');
                      _reloadFilteredListing(page: 1);
                    },
                  ),
                if (_filterGenreLabel.isNotEmpty)
                  _buildActiveFilterBadge(
                    _filterGenreLabel,
                    onClear: () {
                      setState(() => _filterGenreLabel = '');
                      _reloadFilteredListing(page: 1);
                    },
                  ),
                if (_filterArea.isNotEmpty)
                  _buildActiveFilterBadge(
                    _filterArea,
                    onClear: () {
                      setState(() => _filterArea = '');
                      _reloadFilteredListing(page: 1);
                    },
                  ),
                if (_filterYear.isNotEmpty)
                  _buildActiveFilterBadge(
                    _filterYear,
                    onClear: () {
                      setState(() => _filterYear = '');
                      _reloadFilteredListing(page: 1);
                    },
                  ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _filterSubCategoryId = '';
                      _filterGenreLabel = '';
                      _filterArea = '';
                      _filterYear = '';
                    });
                    _reloadFilteredListing(page: 1);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Text(
                      '清除全部',
                      style: TextStyle(
                        color: ApplePalette.of(context).systemBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        AnimatedSize(
          duration: (isWindowsDesktopUi || OhosRuntime.isOhos)
              ? const Duration(milliseconds: 260)
              : Ios27Spring.smooth.nominalDuration,
          curve: (isWindowsDesktopUi || OhosRuntime.isOhos)
              ? Curves.easeOutCubic
              : Ios27Spring.smooth.curve,
          child: _filterExpanded
              ? Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPad,
                    12,
                    horizontalPad,
                    2,
                  ),
                  child: _buildHomeFilterDrawer(),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Full-bleed elastic-stretch HD cinema Hero Billboard for iOS Home.
  ///
  /// - Aggressively resolves true Retina vertical HD artwork (`strictHighRes: true`)
  ///   and syncs edge ambient tinting smoothly as HD artwork lands.
  /// - Preserves full-bleed unobstructed artwork with NO white top/bottom wash;
  ///   from the title (`剧名`) zone downward, transitions smoothly using the
  ///   poster's extracted ambient color and melts softly into the page canvas
  ///   below for zero seam and zero white flash on open/return.
  /// - Opens & returns via full-bleed linear [PosterExpandRoute] (`sourceRadius: 0`,
  ///   `isFullBleedHero: true`) with 1:1 lockstep chrome cross-fade via
  ///   [PosterExpandRegistry.activeProgress] — zero middle split or pop.
  Widget _buildIosImmersiveHeroBillboard(
    BuildContext context, {
    required CmsSite site,
    required List<CmsVideo> featuredList,
    required double topSafePad,
    required double heroHeight,
    required double horizontalPad,
    required Widget headerOverlay,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final activeIdx = _iosHeroIndex.clamp(0, featuredList.length - 1);
    final activeFeatured = featuredList[activeIdx];
    final bool isShortHero = heroHeight < 460;

    final activeAtmo = _resolveRexHeroAtmosphere(activeFeatured, palette);

    Widget buildHeroChromeFade({required Widget child}) {
      return ValueListenableBuilder<double>(
        valueListenable: PosterExpandRegistry.activeProgress,
        child: child,
        builder: (context, progress, inner) {
          final activeId = PosterExpandRegistry.activeCardId.value;
          final isHeroTransition =
              activeId != null && activeId.startsWith('ios_hero_');
          if (!isHeroTransition || progress <= 0.001) {
            return inner!;
          }
          final chromeOpacity = (1.0 - (progress / 0.35)).clamp(0.0, 1.0);
          return Opacity(opacity: chromeOpacity, child: inner);
        },
      );
    }

    return SizedBox(
      key: const ValueKey('ios-home-immersive-hero'),
      height: heroHeight,
      width: double.infinity,
      child: ValueListenableBuilder<double>(
        valueListenable: _iosHeroOverscroll,
        builder: (context, overscroll, _) {
          final stretchedHeight = heroHeight + overscroll;
          final stretchScale =
              (1.0 + (overscroll / math.max(heroHeight, 1.0)) * 0.68)
                  .clamp(1.0, 1.44);
          final pullProgress = ((overscroll - 12.0) / 72.0).clamp(0.0, 1.0);
          final showRefreshPill = _homeRefreshing || pullProgress > 0.06;
          final refreshPillOpacity =
              _homeRefreshing ? 1.0 : pullProgress.clamp(0.0, 1.0);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // 1. Full-bleed swipeable HD Posters anchored to screen y = 0 on
              //    overscroll and scrolling smoothly away as one intact block.
              //    (The continuous Rex atmosphere aura lives in Layer 0 BEHIND
              //    CustomScrollView so Sliver 0 never paints over shelf headers!)
              Positioned(
                top: -overscroll,
                left: 0,
                right: 0,
                height: stretchedHeight,
                child: PageView.builder(
                  controller: _iosHeroPageController,
                  physics: const BouncingScrollPhysics(),
                  itemCount: featuredList.length,
                  onPageChanged: (index) {
                    if (mounted && _iosHeroIndex != index) {
                      setState(() => _iosHeroIndex = index);
                      _onPosterCacheUpdated();
                    }
                  },
                  itemBuilder: (context, index) {
                    final featured = featuredList[index];
                    final itemAtmo =
                        _resolveRexHeroAtmosphere(featured, palette);
                    final posterLookupKey =
                        '${featured.poster}|${featured.title}|${featured.year}';
                    final heroCardId =
                        'ios_hero_${site.key}_${featured.id.isNotEmpty ? featured.id : featured.title}_$index';
                    final metaParts = <String>[
                      if (featured.year.trim().isNotEmpty) featured.year.trim(),
                      if (featured.area.trim().isNotEmpty) featured.area.trim(),
                      if (featured.remarks.trim().isNotEmpty)
                        featured.remarks.trim(),
                    ];
                    final infoLine = featured.description.trim().isNotEmpty
                        ? featured.description.trim()
                        : (featured.actor.trim().isNotEmpty
                            ? '主演：${featured.actor.trim()}'
                            : '');
                    return Builder(
                      builder: (heroTapCtx) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _openVideoDetail(
                          site,
                          featured,
                          sourceContext: heroTapCtx,
                          sourceRadius: 0.0,
                          sourceCardId: heroCardId,
                          isFullBleedHero: true,
                          ambientColor: itemAtmo,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Full-bleed crisp HD artwork backed by Layer 0's live
                            // interpolated atmosphere (never per-slide opaque backing
                            // that splits at the bottom edge during swipes).
                            Positioned.fill(
                              child: PosterExpandSourceCard(
                                cardId: heroCardId,
                                child: ClipRect(
                                  child: Transform.scale(
                                    key: const ValueKey(
                                      'ios-hero-stretch-zoom',
                                    ),
                                    scale: stretchScale,
                                    alignment: const Alignment(0.0, -0.08),
                                    child: PosterImage(
                                      url: featured.poster,
                                      title: site.isEffectivelyPrivate
                                          ? ''
                                          : featured.title,
                                      year: site.isEffectivelyPrivate
                                          ? ''
                                          : featured.year,
                                      highRes: true,
                                      strictHighRes: true,
                                      fit: BoxFit.cover,
                                      alignment: const Alignment(0.0, -0.22),
                                      onBytesLoaded: (bytes) =>
                                          _updateHeroAmbientFromBytes(
                                        featured,
                                        bytes,
                                      ),
                                      placeholder: const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Subtle top cinema vignette strictly behind status
                            // bar & floating header controls (never white wash).
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              height: topSafePad + 58,
                              child: IgnorePointer(
                                child: buildHeroChromeFade(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.black.withValues(alpha: 0.42),
                                          Colors.black.withValues(alpha: 0.16),
                                          Colors.transparent,
                                        ],
                                        stops: const [0.0, 0.56, 1.0],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Rex-style live-interpolated 8-stop atmospheric dissolve
                            // strictly below the faces: uses liveAtmo (matching Layer 0
                            // pixel-for-pixel AT EVERY FRAME OF EVERY HORIZONTAL SWIPE!)
                            // so there is ZERO horizontal bottom cut line mid-swipe
                            // AND zero seam at rest in BOTH Light Mode and Dark Mode.
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: stretchedHeight * 0.58,
                              child: IgnorePointer(
                                child: buildHeroChromeFade(
                                  child: AnimatedBuilder(
                                    animation: Listenable.merge([
                                      _iosHeroPageController,
                                      _rexBackdropScrollOffset,
                                    ]),
                                    builder: (context, _) {
                                      final liveAtmo = _resolveLiveRexHeroAtmo(
                                        featuredList,
                                        palette,
                                      );
                                      final liveEdgeColor =
                                          _computeRexBackdropMetrics(
                                        liveAtmo: liveAtmo,
                                        palette: palette,
                                        heroHeight: heroHeight,
                                        scrollOffset:
                                            _rexBackdropScrollOffset.value,
                                      ).liveEdgeColor;
                                      return DecoratedBox(
                                        key: const ValueKey(
                                          'ios-hero-bottom-ambient-gradient',
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              liveEdgeColor.withValues(
                                                alpha: 0.0,
                                              ),
                                              liveEdgeColor.withValues(
                                                alpha: 0.05,
                                              ),
                                              liveEdgeColor.withValues(
                                                alpha: 0.18,
                                              ),
                                              liveEdgeColor.withValues(
                                                alpha: 0.44,
                                              ),
                                              liveEdgeColor.withValues(
                                                alpha: 0.72,
                                              ),
                                              liveEdgeColor.withValues(
                                                alpha: 0.90,
                                              ),
                                              liveEdgeColor.withValues(
                                                alpha: 0.98,
                                              ),
                                              liveEdgeColor,
                                            ],
                                            stops: const [
                                              0.0,
                                              0.14,
                                              0.30,
                                              0.48,
                                              0.66,
                                              0.82,
                                              0.93,
                                              1.0,
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),

                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: stretchedHeight * 0.62,
                              child: buildHeroChromeFade(
                                child: AnimatedBuilder(
                                  animation: Listenable.merge([
                                    _iosHeroPageController,
                                    _rexBackdropScrollOffset,
                                  ]),
                                  builder: (context, _) {
                                    final liveAtmo = _resolveLiveRexHeroAtmo(
                                      featuredList,
                                      palette,
                                    );
                                    final liveEdgeColor =
                                        _computeRexBackdropMetrics(
                                      liveAtmo: liveAtmo,
                                      palette: palette,
                                      heroHeight: heroHeight,
                                      scrollOffset:
                                          _rexBackdropScrollOffset.value,
                                    ).liveEdgeColor;
                                    final hasLoadedPoster =
                                        _iosHeroAmbientColors
                                                .containsKey(posterLookupKey) ||
                                            PosterLoader.peekMemory(
                                                  featured.poster,
                                                  title: site
                                                          .isEffectivelyPrivate
                                                      ? ''
                                                      : featured.title,
                                                  year: site
                                                          .isEffectivelyPrivate
                                                      ? ''
                                                      : featured.year,
                                                  preferHd: true,
                                                ) !=
                                                null;
                                    // At the title's position inside the bottom
                                    // 58% dissolve, the gradient covers ~60% of
                                    // a loaded poster and 100% liveEdgeColor
                                    // when the poster image is missing.
                                    final effectiveHeroBg = hasLoadedPoster
                                        ? Color.alphaBlend(
                                            liveEdgeColor.withValues(
                                              alpha: 0.60,
                                            ),
                                            itemAtmo,
                                          )
                                        : liveEdgeColor;
                                    final heroInks =
                                        _resolveRexInksForBackdropBand(
                                      hysteresisSlotKey: -100 - index,
                                      primaryBg: effectiveHeroBg,
                                      secondaryBg: effectiveHeroBg,
                                      palette: palette,
                                    );
                                    final useLightInk = heroInks.useLight;
                                    final primaryInk = heroInks.primary;
                                    final secondaryInk = heroInks.secondary;
                                    final bodyInk = heroInks.secondary;
                                    final titleShadows = useLightInk
                                        ? const [
                                            Shadow(
                                              color: Color(0x99000000),
                                              blurRadius: 14,
                                              offset: Offset(0, 2),
                                            ),
                                          ]
                                        : const [
                                            Shadow(
                                              color: Color(0x45FFFFFF),
                                              blurRadius: 10,
                                            ),
                                          ];
                                    final subShadows = useLightInk
                                        ? const [
                                            Shadow(
                                              color: Color(0x88000000),
                                              blurRadius: 8,
                                            ),
                                          ]
                                        : const [
                                            Shadow(
                                              color: Color(0x38FFFFFF),
                                              blurRadius: 6,
                                            ),
                                          ];
                                    final scrimTint = useLightInk
                                        ? Colors.black
                                        : liveEdgeColor;
                                    final scrimHeight = math.min(
                                      math.max(0.0, stretchedHeight * 0.60 - 22),
                                      (stretchedHeight * 0.50).clamp(180.0, 275.0),
                                    );
                                    return Stack(
                                      fit: StackFit.expand,
                                      clipBehavior: Clip.none,
                                      children: [
                                        // Localized title-band legibility scrim
                                        // over loaded posters: shields 2-line
                                        // Hero typography from bright/dark local
                                        // poster highlights while tapering to
                                        // 0.0 at bottom: 22 so the Hero bottom
                                        // seam at bottom: 0 remains untouched.
                                        if (hasLoadedPoster && scrimHeight > 0)
                                          Positioned(
                                            left: 0,
                                            right: 0,
                                            bottom: 22,
                                            height: scrimHeight,
                                            child: IgnorePointer(
                                              child: DecoratedBox(
                                                key: const ValueKey(
                                                  'ios-hero-title-contrast-scrim',
                                                ),
                                                decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                    begin: Alignment.topCenter,
                                                    end: Alignment.bottomCenter,
                                                    colors: [
                                                      scrimTint.withValues(
                                                        alpha: 0.0,
                                                      ),
                                                      scrimTint.withValues(
                                                        alpha: 0.24,
                                                      ),
                                                      scrimTint.withValues(
                                                        alpha: 0.54,
                                                      ),
                                                      scrimTint.withValues(
                                                        alpha: 0.56,
                                                      ),
                                                      scrimTint.withValues(
                                                        alpha: 0.42,
                                                      ),
                                                      scrimTint.withValues(
                                                        alpha: 0.14,
                                                      ),
                                                      scrimTint.withValues(
                                                        alpha: 0.0,
                                                      ),
                                                    ],
                                                    stops: const [
                                                      0.0,
                                                      0.14,
                                                      0.32,
                                                      0.58,
                                                      0.78,
                                                      0.92,
                                                      1.0,
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        Positioned(
                                          left: horizontalPad + 6,
                                          right: horizontalPad + 6,
                                          bottom: featuredList.length > 1
                                              ? (isShortHero ? 26 : 30)
                                              : (isShortHero ? 14 : 16),
                                          child: Center(
                                            child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: 520,
                                              ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.center,
                                                children: [
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                      horizontal: 9.5,
                                                      vertical: 4,
                                                    ),
                                                    decoration: BoxDecoration(
                                                      color: useLightInk
                                                          ? Colors.white.withValues(
                                                              alpha: 0.16,
                                                            )
                                                          : Colors.black.withValues(
                                                              alpha: 0.08,
                                                            ),
                                                      borderRadius:
                                                          BorderRadius.circular(999),
                                                      border: Border.all(
                                                        color: useLightInk
                                                            ? Colors.white.withValues(
                                                                alpha: 0.24,
                                                              )
                                                            : Colors.black.withValues(
                                                                alpha: 0.14,
                                                              ),
                                                        width: 0.6,
                                                      ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          CupertinoIcons.sparkles,
                                                          color: useLightInk
                                                              ? const Color(
                                                                  0xFF5AC8FA,
                                                                )
                                                              : AppleColors
                                                                  .systemBlue,
                                                          size: 11.5,
                                                        ),
                                                        const SizedBox(width: 4),
                                                        Flexible(
                                                          child: Text(
                                                            '今日首推 · ${site.name}',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow.ellipsis,
                                                            style: TextStyle(
                                                              color: primaryInk,
                                                              fontSize: 11,
                                                              fontWeight:
                                                                  FontWeight.w600,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    featured.title,
                                                    maxLines: 2,
                                                    textAlign: TextAlign.center,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: primaryInk,
                                                      fontSize:
                                                          heroHeight < 460 ? 22 : 25,
                                                      fontWeight: FontWeight.w800,
                                                      letterSpacing: -0.5,
                                                      height: 1.15,
                                                      shadows: titleShadows,
                                                    ),
                                                  ),
                                                  if (metaParts.isNotEmpty) ...[
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      metaParts.join(' · '),
                                                      maxLines: 1,
                                                      textAlign: TextAlign.center,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: secondaryInk,
                                                        fontSize: 12.5,
                                                        fontWeight: FontWeight.w600,
                                                        letterSpacing: 0.1,
                                                        shadows: subShadows,
                                                      ),
                                                    ),
                                                  ],
                                                  if (infoLine.isNotEmpty) ...[
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      infoLine,
                                                      maxLines: 1,
                                                      textAlign: TextAlign.center,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: bodyInk,
                                                        fontSize: 12,
                                                        height: 1.32,
                                                        shadows: subShadows,
                                                      ),
                                                    ),
                                                  ],
                                                  const SizedBox(height: 10),
                                                  ApplePressableScale(
                                                    pressedScale: 0.94,
                                                    onTap: () => _openVideoDetail(
                                                      site,
                                                      featured,
                                                      sourceContext: heroTapCtx,
                                                      sourceRadius: 0.0,
                                                      sourceCardId: heroCardId,
                                                      isFullBleedHero: true,
                                                      ambientColor: itemAtmo,
                                                    ),
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                        horizontal: 20,
                                                        vertical: 8.5,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: AppleColors.systemBlue,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                          999,
                                                        ),
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color: Color(0x4D0A84FF),
                                                            blurRadius: 14,
                                                            offset: Offset(0, 4),
                                                          ),
                                                        ],
                                                      ),
                                                      child: const Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Icon(
                                                            CupertinoIcons.play_fill,
                                                            color: Colors.white,
                                                            size: 13,
                                                          ),
                                                          SizedBox(width: 5),
                                                          Text(
                                                            '立即观看',
                                                            style: TextStyle(
                                                              color: Colors.white,
                                                              fontSize: 13.5,
                                                              fontWeight:
                                                                  FontWeight.w700,
                                                              letterSpacing: -0.1,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

              // 2. Floating Header Row nestled in the top ambient aura: gently
              //    tracks pull-down overscroll and scrolls upward cleanly as one
              //    intact piece when scrolling down (never crushed or sliced!).
              Positioned(
                key: const ValueKey('ios-hero-floating-header'),
                top: topSafePad + 6 - overscroll * 0.82,
                left: horizontalPad,
                right: horizontalPad,
                child: buildHeroChromeFade(child: headerOverlay),
              ),

              // 3. Translucent pull-to-refresh pill while pulling/refreshing
              if (showRefreshPill)
                Positioned(
                  top: topSafePad + 54 - overscroll * 0.52,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Opacity(
                        opacity: refreshPillOpacity,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.20),
                              width: 0.6,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CupertinoActivityIndicator(
                                radius: 7.5,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _homeRefreshing
                                    ? '正在刷新片单'
                                    : (pullProgress >= 0.95
                                        ? '松手立即刷新'
                                        : '下拉放大刷新'),
                                textScaler: TextScaler.noScaling,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // 4. Centered carousel pagination dots right above the seamless
              //    Rex atmosphere continuation into the first shelf below.
              if (featuredList.length > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: isShortHero ? 10 : 12,
                  child: IgnorePointer(
                    child: buildHeroChromeFade(
                      child: ValueListenableBuilder<double>(
                        valueListenable: _rexCardInkScrollOffset,
                        builder: (context, cardOffset, _) {
                          final activeLiveEdgeColor =
                              _computeRexBackdropMetrics(
                            liveAtmo: activeAtmo,
                            palette: palette,
                            heroHeight: heroHeight,
                            scrollOffset: cardOffset,
                          ).liveEdgeColor;
                          final activeUseLight = _useLightInkForHeroAtmo(
                            activeLiveEdgeColor,
                            isDark,
                          );
                          final activeDotInk = activeUseLight
                              ? Colors.white
                              : const Color(0xFF141821);
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (int i = 0; i < featuredList.length; i++)
                                AnimatedContainer(
                                  duration: (isWindowsDesktopUi ||
                                          OhosRuntime.isOhos)
                                      ? const Duration(milliseconds: 220)
                                      : Ios27Spring.snappy.nominalDuration,
                                  curve: (isWindowsDesktopUi ||
                                          OhosRuntime.isOhos)
                                      ? Curves.easeOutCubic
                                      : Ios27Spring.snappy.curve,
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 3),
                                  width: i == activeIdx ? 18 : 5.5,
                                  height: 5.5,
                                  decoration: BoxDecoration(
                                    color: i == activeIdx
                                        ? activeDotInk
                                        : activeDotInk.withValues(alpha: 0.36),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
  Widget _buildWelcomeOnboarding(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: AppleGlassSurface(
              padding: const EdgeInsets.all(28),
              borderRadius: BorderRadius.circular(26),
              color: const Color(0xCC16171D),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MarcoBrandLogo(
                    iconSize: 78,
                    fontSize: 24,
                    stacked: true,
                  ),
                  SizedBox(height: 16),
                  Text(
                    '把今晚，留给好故事。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '适用于手机、平板与桌面的播放器。导入自己的订阅或本地配置后开始使用。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: AppleCapsuleButton(
                      label: '导入配置地址或 JSON',
                      icon: CupertinoIcons.add_circled_solid,
                      primary: true,
                      onPressed: () => _showImportConfigDialog(),
                    ),
                  ),
                  if (defaultTargetPlatform != TargetPlatform.iOS ||
                      OhosRuntime.isOhos) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: AppleCapsuleButton(
                        label: '一键粘贴剪贴板并导入',
                        icon: CupertinoIcons.doc_on_clipboard_fill,
                        onPressed: _quickImportFromClipboard,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: AppleCapsuleButton(
                      label: '从跨平台备份恢复',
                      icon: CupertinoIcons.arrow_2_circlepath,
                      onPressed: _showBackupRestoreDialog,
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                    '本产品仅为播放工具，不内置、不提供、不托管任何影视资源或配置地址。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelTertiary,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildEmptyPrivacySpaceNotice(BuildContext context) {
    return AppleGlassSurface(
      padding: const EdgeInsets.all(24),
      borderRadius: BorderRadius.circular(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.eye_slash_fill,
                color: Color(0xFFA78BFA),
                size: 22,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '隐私分组模式 · 独立无痕空间',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            '当前尚未添加任何隐私分组订阅。隐私空间与正常模式完全隔离：不保留观看历史记录，搜索、收藏与片源数据互不共通。',
            style: TextStyle(
              color: ApplePalette.of(context).labelSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              AppleCapsuleButton(
                label: '导入隐私订阅 (VOD/M3U/JSON)',
                icon: CupertinoIcons.lock_fill,
                primary: true,
                compact: true,
                onPressed: () => _showImportConfigDialog(
                  initialIsPrivate: true,
                  initialGroup: '隐私分组',
                ),
              ),
              AppleCapsuleButton(
                label: '管理隐私订阅与密码',
                icon: CupertinoIcons.slider_horizontal_3,
                compact: true,
                onPressed: _showPrivateResourcesSheet,
              ),
              AppleCapsuleButton(
                label: '退出隐私模式',
                icon: CupertinoIcons.lock_open_fill,
                compact: true,
                onPressed: _exitPrivacySpace,
              ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildPluginOnlyConfigNotice(BuildContext context) {
    final pluginCount = _config?.pluginOnlySites.length ?? 0;
    final depotCount = _config?.depots.length ?? 0;
    final liveCount = _config?.supportedLives.length ?? 0;
    final String titleText;
    final String bodyText;
    if (pluginCount > 0) {
      titleText = '已成功加载配置（共 $pluginCount 个安卓专用插件站点）';
      bodyText =
          '当前仓库中的片源全部为安卓 JAR 爬虫插件（csp_*）。由于苹果 iOS / macOS 系统安全机制限制，无法直接运行安卓 DEX 字节码插件；Apple 端支持所有标准 HTTP/HTTPS CMS 站点（type 0 / 1 / 4）、已移植 Guard/DRPY/JS/Py 规则源与 M3U/TXT 电视直播源。';
    } else if (liveCount > 0) {
      titleText = '已成功加载直播配置（共 $liveCount 个直播源）';
      bodyText = '当前订阅仅包含电视直播频道，可直接前往直播页观看，或导入点播订阅源。';
    } else {
      titleText = '当前订阅暂未加载到可用片源';
      bodyText = '请尝试在设置中刷新订阅源、切换其他子仓库，或导入新的影视/直播配置地址。';
    }
    return AppleGlassSurface(
      padding: const EdgeInsets.all(22),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.info_circle_fill,
                color: AppleColors.systemBlue,
                size: 22,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  titleText,
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            bodyText,
            style: TextStyle(
              color: ApplePalette.of(context).labelSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (depotCount > 1)
                AppleCapsuleButton(
                  label: '切换其他子仓库 ($depotCount)',
                  icon: CupertinoIcons.archivebox_fill,
                  primary: true,
                  compact: true,
                  onPressed: _showDepotPickerDialog,
                ),
              if (liveCount > 0)
                AppleCapsuleButton(
                  label: '观看电视直播 ($liveCount)',
                  icon: CupertinoIcons.dot_radiowaves_left_right,
                  primary: depotCount <= 1,
                  compact: true,
                  onPressed: () => setState(() => _tabIndex = 1),
                ),
              AppleCapsuleButton(
                label: '查看全部站点列表',
                icon: CupertinoIcons.list_bullet,
                compact: true,
                onPressed: _showSitePickerDialog,
              ),
              AppleCapsuleButton(
                label: '导入其他配置',
                icon: CupertinoIcons.add,
                compact: true,
                onPressed: _showImportConfigDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildHeaderCapsule({
    required IconData icon,
    bool compact = false,
    required String label,
    required VoidCallback onTap,
    bool absorbTap = true,
  }) {
    final palette = ApplePalette.of(context);
    final pill = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 176),
      child: LiquidGlass(
        borderRadius: 999,
        elevated: false,
        rimStrength: 0.9,
        tint: palette.isDark
            ? const Color(0x281E1E24)
            : const Color(0xCCFFFFFF),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: 8.5,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact || label.isEmpty)
              Icon(icon, color: palette.labelSecondary, size: 13.5),
            if (!compact) const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (!compact) const SizedBox(width: 4),
            if (!compact)
              Icon(
                CupertinoIcons.chevron_down,
                color: palette.labelSecondary,
                size: 11.5,
              ),
          ],
        ),
      ),
    );
    if (!absorbTap) return pill;
    return ApplePressableScale(
      pressedScale: 0.93,
      pressedOpacity: 0.86,
      onTap: onTap,
      child: pill,
    );
  }
  /// macOS widescreen home hero + optional docked right-hand Continue Watching
  /// panel (inspired by Windows 0.6.0 wide home while preserving Apple Glass
  /// aesthetics, Light/Dark contrast, Reduce Motion, and iOS poster expand).
  Widget _buildMacWideHomeHeroSection(
    BuildContext context, {
    required CmsSite site,
    required List<WatchHistoryEntry> history,
    required double contentWidth,
    required double horizontalPad,
  }) {
    final showHero = widget.storage.showHeroBanner;
    final candidates = _homeVideos
        .where((v) => !v.id.startsWith('netdisk_qr:'))
        .toList(growable: false);
    final sideHistory =
        showHero && candidates.isNotEmpty && history.isNotEmpty && contentWidth >= 960;
    final historyWidth = contentWidth >= 1480 ? 336.0 : 304.0;
    final heroHeight = contentWidth >= 1480
        ? 284.0
        : (contentWidth >= 1060 ? 256.0 : 228.0);
    final heroAreaWidth =
        sideHistory ? math.max(320.0, contentWidth - historyWidth - 18.0) : contentWidth;
    final maxHeroSlots = (heroAreaWidth / 340.0).floor().clamp(1, 4);
    final heroVideos = showHero
        ? candidates.take(math.min(candidates.length, maxHeroSlots)).toList(growable: false)
        : const <CmsVideo>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (history.isNotEmpty && !sideHistory)
          _buildHomeHistoryShelf(
            context,
            history: history,
            horizontalPad: horizontalPad,
            topSpacing: 18,
          ),
        if (heroVideos.isNotEmpty) ...[
          const SizedBox(height: 18),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPad),
            child: SizedBox(
              key: const ValueKey('mac-home-hero-row'),
              height: heroHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < heroVideos.length; i++) ...[
                          if (i > 0) const SizedBox(width: 14),
                          Expanded(
                            child: _buildMacWideHeroCard(
                              context,
                              site,
                              heroVideos[i],
                              index: i,
                              compact: heroVideos.length >= 3 ||
                                  (heroAreaWidth / heroVideos.length) < 420,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (sideHistory) ...[
                    const SizedBox(width: 16),
                    SizedBox(
                      key: const ValueKey('mac-home-side-history'),
                      width: historyWidth,
                      child: _buildMacSideHistoryPanel(context, history),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMacWideHeroCard(
    BuildContext context,
    CmsSite site,
    CmsVideo featured, {
    required int index,
    required bool compact,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final cardId =
        'mac_hero_${site.key}_${featured.id.isNotEmpty ? featured.id : featured.title}_$index';
    final tags = <String>[
      if (featured.year.trim().isNotEmpty) featured.year.trim(),
      if (featured.area.trim().isNotEmpty) featured.area.trim(),
      if (featured.remarks.trim().isNotEmpty) featured.remarks.trim(),
    ];
    final infoLine = featured.description.trim().isNotEmpty
        ? featured.description.trim()
        : (featured.actor.trim().isNotEmpty ? '主演：${featured.actor.trim()}' : '');
    BuildContext? cardCtx;
    void openFeatured() => _openVideoDetail(
          site,
          featured,
          sourceContext: cardCtx ?? context,
          sourceRadius: 22.0,
          sourceCardId: cardId,
        );

    final inner = PosterExpandSourceCard(
      cardId: cardId,
      child: Builder(
        builder: (ctx) {
          cardCtx = ctx;
          return AppleSmoothClipCard(
            key: ValueKey('mac-home-hero-card-$index'),
            borderRadius: 24,
            backgroundColor:
                isDark ? const Color(0xFF111319) : const Color(0xFF1A202C),
            rimStrength: isDark ? 1.0 : 0.65,
            boxShadow: isDark
                ? const [
                    BoxShadow(
                      color: Color(0x52000000),
                      blurRadius: 24,
                      offset: Offset(0, 10),
                    ),
                  ]
                : const [
                    BoxShadow(
                      color: Color(0x240F172A),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
            child: Stack(
              fit: StackFit.expand,
              children: [
                LandscapePosterImage(
                  url: featured.poster,
                  title: site.isEffectivelyPrivate ? '' : featured.title,
                  year: site.isEffectivelyPrivate ? '' : featured.year,
                  allowExternalLookup: !site.isEffectivelyPrivate,
                  blurPortraitFallback: true,
                  showRightFramedPortraitFallback: !compact,
                  placeholder: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1D2434), Color(0xFF0E1118)],
                      ),
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xD90A0D14),
                        Color(0x8C0A0D14),
                        Color(0x1A0A0D14),
                      ],
                      stops: [0.0, 0.56, 1.0],
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x14000000),
                        Color(0x28000000),
                        Color(0xCF080A10),
                      ],
                      stops: [0.0, 0.48, 1.0],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 16 : 20,
                    compact ? 14 : 18,
                    compact ? 16 : 124,
                    compact ? 14 : 18,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (index == 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x40FFFFFF),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0x4DFFFFFF),
                              width: 0.6,
                            ),
                          ),
                          child: const Text(
                            '精选推荐',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      const Spacer(),
                      Text(
                        featured.title,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 18 : 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          height: 1.18,
                        ),
                      ),
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final tag in tags.take(compact ? 2 : 3))
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2.5,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x33FFFFFF),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  tag,
                                  style: const TextStyle(
                                    color: Color(0xF2FFFFFF),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (!compact && infoLine.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          infoLine,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xCCFFFFFF),
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (reduceMotion) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: openFeatured,
        child: inner,
      );
    }
    return ApplePressableScale(
      pressedScale: 0.975,
      pressedOpacity: 0.94,
      onTap: openFeatured,
      child: inner,
    );
  }

  Widget _buildMacSideHistoryPanel(
    BuildContext context,
    List<WatchHistoryEntry> history,
  ) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final items = history.take(3).toList(growable: false);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xA6161820) : const Color(0xE8FFFFFF),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : const Color(0x1F0F172A),
          width: 0.85,
        ),
        boxShadow: isDark
            ? const [
                BoxShadow(
                  color: Color(0x3D000000),
                  blurRadius: 20,
                  offset: Offset(0, 8),
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x140F172A),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '继续观看',
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 22,
                onPressed: _showWatchHistorySheet,
                child: const Text(
                  '全部',
                  style: TextStyle(
                    color: AppleColors.systemBlue,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final entry in items)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Builder(
                        builder: (ctx) {
                          final resolvedPoster = _resolveHistoryPoster(entry);
                          final cwCardId = 'mac_side_cw_${entry.site}_${entry.id}';
                          final hasKnownDuration = entry.duration > 0;
                          final realProgress = hasKnownDuration
                              ? entry.progressFraction.clamp(0.0, 1.0)
                              : null;
                          return Semantics(
                            button: true,
                            label: entry.episode.isNotEmpty
                                ? '继续观看 ${entry.title} ${entry.episode}'
                                : '继续观看 ${entry.title}',
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                key: ValueKey(
                                  'mac-side-history-item-${entry.site}-${entry.id}',
                                ),
                                borderRadius: BorderRadius.circular(12),
                                focusColor:
                                    AppleColors.systemBlue.withValues(alpha: 0.24),
                                hoverColor: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : const Color(0x140F172A),
                                onTap: () => _openSyncedMediaEntry(
                                  siteKey: entry.site,
                                  videoId: entry.id,
                                  title: entry.title,
                                  poster: resolvedPoster,
                                  sourceContext: ctx,
                                  sourceRadius: 10.0,
                                  sourceCardId: cwCardId,
                                ),
                                child: Ink(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.05)
                                        : const Color(0x0A0F172A),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      PosterExpandSourceCard(
                                        cardId: cwCardId,
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          child: SizedBox(
                                            width: 36,
                                            height: 50,
                                            child: PosterImage(
                                              url: resolvedPoster,
                                              title: entry.title,
                                              placeholder:
                                                  _buildPosterPlaceholder(),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              entry.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: palette.labelPrimary,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              entry.episode.isNotEmpty
                                                  ? entry.episode
                                                  : '继续观看',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: palette.labelSecondary,
                                                fontSize: 11,
                                              ),
                                            ),
                                            if (realProgress != null) ...[
                                              const SizedBox(height: 4),
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                child: LinearProgressIndicator(
                                                  key: ValueKey(
                                                    'mac-side-history-progress-${entry.site}-${entry.id}',
                                                  ),
                                                  value: realProgress,
                                                  minHeight: 3,
                                                  backgroundColor:
                                                      palette.groupedTertiary,
                                                  valueColor:
                                                      const AlwaysStoppedAnimation<
                                                          Color>(
                                                    AppleColors.systemBlue,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroShowcaseCard(
    CmsSite site,
    CmsVideo featured, {
    required bool wide,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final tagChips = <String>[
      if (featured.year.trim().isNotEmpty) featured.year.trim(),
      if (featured.area.trim().isNotEmpty) featured.area.trim(),
      if (featured.remarks.trim().isNotEmpty) featured.remarks.trim(),
    ];
    final infoLine = featured.description.trim().isNotEmpty
        ? featured.description.trim()
        : (featured.actor.trim().isNotEmpty ? '主演：${featured.actor.trim()}' : '');
    final cardId =
        'hero_showcase_${site.key}_${featured.id.isNotEmpty ? featured.id : featured.title}';
    BuildContext? posterCtx;
    void openShowcase() => _openVideoDetail(
          site,
          featured,
          sourceContext: posterCtx ?? context,
          sourceRadius: 18.0,
          sourceCardId: cardId,
        );
    return ApplePressableScale(
      pressedScale: 0.965,
      pressedOpacity: 0.92,
      onTap: openShowcase,
      child: SizedBox(
        height: wide ? 256 : 212,
        child: AppleSmoothClipCard(
          borderRadius: 28,
          backgroundColor: isDark ? const Color(0xFF111114) : const Color(0xFFF3F5FA),
          rimStrength: isDark ? 1.05 : 0.45,
          boxShadow: isDark
              ? const [
                  BoxShadow(
                    color: Color(0x59000000),
                    blurRadius: 26,
                    offset: Offset(0, 12),
                  ),
                ]
              : const [
                  BoxShadow(
                    color: Color(0x180F172A),
                    blurRadius: 22,
                    offset: Offset(0, 8),
                  ),
                ],
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Opacity(
                      opacity: isDark ? 1.0 : 0.52,
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: isWindowsDesktopUi ? 22 : 36,
                          sigmaY: isWindowsDesktopUi ? 22 : 36,
                          tileMode: isWindowsDesktopUi
                              ? TileMode.decal
                              : TileMode.mirror,
                        ),
                        child: PosterImage(
                          url: featured.poster,
                          title: featured.title,
                          year: featured.year,
                          highRes: !isWindowsDesktopUi,
                          forBackdrop: true,
                          placeholder: const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isDark
                              ? const [
                                  Color(0x55000000),
                                  Color(0xAD07080C),
                                  Color(0xEB050508),
                                ]
                              : const [
                                  Color(0xA6EEF1F8),
                                  Color(0xD4F1F4FA),
                                  Color(0xECF7F8FC),
                                ],
                          stops: const [0.0, 0.52, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.all(wide ? 22 : 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 2 / 3,
                      child: PosterExpandSourceCard(
                        cardId: cardId,
                        child: Builder(
                          builder: (ctx) {
                            posterCtx = ctx;
                            return AppleSmoothClipCard(
                              borderRadius: 18,
                              backgroundColor: isDark
                                  ? const Color(0xFF1A1A20)
                                  : const Color(0xFFE3E7F0),
                              rimStrength: isDark ? 0.88 : 0.35,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.28 : 0.16,
                                  ),
                                  blurRadius: 14,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                              child: PosterImage(
                                url: featured.poster,
                                title: site.isEffectivelyPrivate
                                    ? ''
                                    : featured.title,
                                year: site.isEffectivelyPrivate
                                    ? ''
                                    : featured.year,
                                highRes: true,
                                strictHighRes: true,
                                placeholder: _buildPosterPlaceholder(),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    SizedBox(width: wide ? 20 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.5,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0x38FFFFFF)
                                  : Colors.white.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0x30FFFFFF)
                                    : Colors.black.withValues(alpha: 0.06),
                                width: 0.6,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  CupertinoIcons.sparkles,
                                  color: isDark
                                      ? const Color(0xFF5AC8FA)
                                      : palette.accent,
                                  size: 11,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '今日首推 · ${site.name}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isDark
                                          ? AppleColors.labelPrimary
                                          : palette.labelPrimary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Title
                          Text(
                            featured.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isDark
                                  ? AppleColors.labelPrimary
                                  : palette.labelPrimary,
                              fontSize: wide ? 23 : 18.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                              height: 1.2,
                            ),
                          ),
                          if (tagChips.isNotEmpty) ...[
                            const SizedBox(height: 7),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final chip in tagChips)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? const Color(0x29FFFFFF)
                                          : Colors.black.withValues(alpha: 0.065),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      chip,
                                      style: TextStyle(
                                        color: isDark
                                            ? AppleColors.labelSecondary
                                            : palette.labelSecondary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          if (infoLine.isNotEmpty) ...[
                            const SizedBox(height: 7),
                            Text(
                              infoLine,
                              maxLines: wide ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isDark
                                    ? AppleColors.labelSecondary
                                    : palette.labelSecondary,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ],
                          const Spacer(),
                          // Bottom row: Watch Now button anchored at bottom-right corner
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              AppleCapsuleButton(
                                key: const ValueKey('hero-watch-now-button'),
                                label: '立即观看',
                                icon: CupertinoIcons.play_fill,
                                primary: true,
                                compact: true,
                                onPressed: openShowcase,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildActiveFilterBadge(String label, {required VoidCallback onClear}) {
    final palette = ApplePalette.of(context);
    return GestureDetector(
      onTap: onClear,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
        decoration: BoxDecoration(
          color: palette.systemBlue.withValues(alpha: palette.isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: palette.systemBlue.withValues(alpha: 0.45),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: palette.systemBlue,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.xmark_circle_fill,
              size: 13,
              color: palette.systemBlue.withValues(alpha: 0.8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeFilterDrawer() {
    final subCats = CmsParser.subCategoriesForPrimaryTab(
      _categories,
      _primaryTab,
    );
    final existingNames = subCats.map((c) => c.name.trim()).toSet();
    final extraGenres = [
      for (final g in CmsParser.fallbackGenreTags)
        if (!existingNames.any((n) => n.contains(g))) g,
    ];
    final hasAnyFilter = _currentFilter.hasSubFilter;

    return LiquidGlass(
      key: const ValueKey('home-filter-drawer'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: 22,
      elevated: false,
      rimStrength: 0.95,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.slider_horizontal_3,
                color: AppleColors.systemBlue,
                size: 14,
              ),
              SizedBox(width: 6),
              Text(
                '多维片库筛选',
                style: TextStyle(
                  color: ApplePalette.of(context).labelPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (hasAnyFilter)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _filterSubCategoryId = '';
                      _filterGenreLabel = '';
                      _filterArea = '';
                      _filterYear = '';
                    });
                    _reloadFilteredListing(page: 1);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x280A84FF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0x555AC8FA),
                        width: 0.6,
                      ),
                    ),
                    child: const Text(
                      '重置筛选',
                      style: TextStyle(
                        color: AppleColors.systemBlue,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 1. 类别 (Sub-categories from site + Genre tags)
          _buildFilterDimensionRow(
            title: '类别',
            controller: _filterCategoryScrollController,
            children: [
              _buildMiniFilterChip(
                label: '全部',
                selected:
                    _filterSubCategoryId.isEmpty && _filterGenreLabel.isEmpty,
                onTap: () {
                  setState(() {
                    _filterSubCategoryId = '';
                    _filterGenreLabel = '';
                  });
                  _reloadFilteredListing(page: 1);
                },
              ),
              for (final cat in subCats)
                _buildMiniFilterChip(
                  label: cat.name,
                  selected: _filterSubCategoryId == cat.id,
                  onTap: () {
                    setState(() {
                      _filterSubCategoryId = cat.id;
                      _filterGenreLabel = '';
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
              for (final genre in extraGenres)
                _buildMiniFilterChip(
                  label: genre,
                  selected: _filterSubCategoryId.isEmpty &&
                      _filterGenreLabel == genre,
                  onTap: () {
                    setState(() {
                      _filterSubCategoryId = '';
                      _filterGenreLabel =
                          _filterGenreLabel == genre ? '' : genre;
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 2. 地区 (Area / Country)
          _buildFilterDimensionRow(
            title: '地区',
            controller: _filterAreaScrollController,
            children: [
              for (final area in CmsParser.filterAreas)
                _buildMiniFilterChip(
                  label: area,
                  selected: (_filterArea.isEmpty && area == '全部') ||
                      _filterArea == area,
                  onTap: () {
                    setState(() {
                      _filterArea = area == '全部' ? '' : area;
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 3. 年份 (Year)
          _buildFilterDimensionRow(
            title: '年份',
            controller: _filterYearScrollController,
            children: [
              for (final yr in CmsParser.filterYears)
                _buildMiniFilterChip(
                  label: yr,
                  selected: (_filterYear.isEmpty && yr == '全部') ||
                      _filterYear == yr,
                  onTap: () {
                    setState(() {
                      _filterYear = yr == '全部' ? '' : yr;
                    });
                    _reloadFilteredListing(page: 1);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildFilterDimensionRow({
    required String title,
    required List<Widget> children,
    required ScrollController controller,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(
            title,
            style: TextStyle(
              color: ApplePalette.of(context).labelSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: DesktopHorizontalScroller(
            controller: controller,
            child: SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  for (int i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(width: 7),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
  Widget _buildMiniFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return ApplePressableScale(
      pressedScale: 0.92,
      pressedOpacity: 0.86,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12.5, vertical: 6.5),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF2894FF), Color(0xFF0A84FF)],
                )
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? const [Color(0x26FFFFFF), Color(0x14FFFFFF)]
                      : const [Color(0xFFFFFFFF), Color(0xFFF3F4F8)],
                ),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? const Color(0xAA80D4FF)
                : (isDark
                    ? const Color(0x2EFFFFFF)
                    : Colors.black.withValues(alpha: 0.10)),
            width: 0.7,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          strutStyle: const StrutStyle(
            forceStrutHeight: true,
            height: 1.1,
            fontSize: 12,
          ),
          style: TextStyle(
            color: selected ? Colors.white : palette.labelPrimary,
            fontSize: 12,
            height: 1.1,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
  String _resolveHistoryPoster(WatchHistoryEntry entry) {
    final direct = entry.poster.trim();
    if (direct.isNotEmpty) return direct;
    for (final v in _homeVideos) {
      if ((v.id == entry.id || v.title == entry.title) &&
          v.poster.trim().isNotEmpty) {
        return v.poster.trim();
      }
    }
    for (final f in widget.storage.getFavorites()) {
      if ((f.id == entry.id || f.title == entry.title) &&
          f.poster.trim().isNotEmpty) {
        return f.poster.trim();
      }
    }
    return '';
  }

  Widget _buildContinueWatchingCard(WatchHistoryEntry entry) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final resolvedPoster = _resolveHistoryPoster(entry);
    final pct = (entry.progressFraction * 100).round();
    final cwCardId = 'cw_${entry.site}_${entry.id}';
    BuildContext? posterCtx;
    final innerRow = SizedBox(
      width: 228,
      child: Row(
        children: [
          PosterExpandSourceCard(
            cardId: cwCardId,
            child: Builder(
              builder: (ctx) {
                posterCtx = ctx;
                return SizedBox(
                  width: 52,
                  height: 72,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PosterImage(
                          url: resolvedPoster,
                          title: entry.title,
                          placeholder: _buildPosterPlaceholder(),
                        ),
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: const Color(0xB8000000),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0x66FFFFFF),
                                width: 0.6,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              CupertinoIcons.play_fill,
                              color: Colors.white,
                              size: 9.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  entry.episode.isEmpty
                      ? (pct > 0 ? '已看 $pct%' : '继续观看')
                      : entry.episode,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 12,
                  ),
                ),
                if (entry.duration > 0) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      key: ValueKey('cw-progress-${entry.site}-${entry.id}'),
                      value: entry.progressFraction.clamp(0.0, 1.0),
                      minHeight: 3.5,
                      backgroundColor: palette.groupedTertiary,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppleColors.systemBlue,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return ApplePressableScale(
      key: ValueKey('cw_${entry.site}_${entry.id}'),
      pressedScale: 0.96,
      pressedOpacity: 0.92,
      onTap: () => _openSyncedMediaEntry(
        siteKey: entry.site,
        videoId: entry.id,
        title: entry.title,
        poster: resolvedPoster,
        sourceContext: posterCtx ?? context,
        sourceRadius: 11.0,
        sourceCardId: cwCardId,
      ),
      child: isDark
          ? AppleGlassSurface(
              borderRadius: BorderRadius.circular(18),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              blurSigma: 28,
              child: innerRow,
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: palette.groupedPrimary,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.065),
                  width: 0.75,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x120F172A),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: innerRow,
            ),
    );
  }
  Widget _buildCategoryPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final palette = ApplePalette.of(context);
    return ApplePressableScale(
      pressedScale: 0.92,
      pressedOpacity: 0.86,
      onTap: onTap,
      child: selected
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: palette.isDark
                      ? const [Color(0xFFFFFFFF), Color(0xFFE7E9EE)]
                      : const [Color(0xFF1C1C20), Color(0xFF111114)],
                ),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: palette.isDark
                      ? const Color(0xB3FFFFFF)
                      : const Color(0x26000000),
                  width: 0.75,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  color: palette.isDark
                      ? const Color(0xFF0A0A0E)
                      : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : LiquidGlass(
              borderRadius: 999,
              elevated: false,
              rimStrength: 0.88,
              tint: palette.isDark
                  ? const Color(0x241E1E24)
                  : const Color(0xCCFFFFFF),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
    );
  }
  Widget _buildMyDriveNetdiskBanner(CmsSite site) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return Container(
      key: const ValueKey('mydrive-netdisk-banner'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF12233B), Color(0xFF14161E)]
              : const [Color(0xFFEAF3FF), Color(0xFFFFFFFF)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: AppleColors.systemBlue.withValues(alpha: isDark ? 0.45 : 0.28),
          width: 0.8,
        ),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x100F172A),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.qrcode_viewfinder,
                color: isDark ? const Color(0xFF5AC8FA) : AppleColors.systemBlue,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${site.name} · 电视端网盘扫码与账号管理',
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AppleCapsuleButton(
                label: '打开网盘中心',
                icon: CupertinoIcons.qrcode,
                primary: true,
                compact: true,
                onPressed: () => unawaited(
                  _trackSecondaryRoute<void>(
                    () => showNetdiskAccountSheet(
                      context,
                      widget.storage,
                      onChanged: () {
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            '点击下方网盘即可弹出官方扫码窗口，支持夸克（我的夸父）、UC（我的优汐）、百度（我的嘟嘟）、阿里云盘（我的阿狸）4K 原画线路：',
            style: TextStyle(
              color: ApplePalette.of(context).labelSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final drive in NetdiskService.drives)
                AppleCapsuleButton(
                  label:
                      '${drive.tvAlias} · ${widget.storage.isNetdiskLoggedIn(drive.key) ? "已启用" : "扫码登录"}',
                  icon: widget.storage.isNetdiskLoggedIn(drive.key)
                      ? CupertinoIcons.checkmark_seal_fill
                      : CupertinoIcons.qrcode_viewfinder,
                  primary: widget.storage.isNetdiskLoggedIn(drive.key),
                  compact: true,
                  onPressed: () => unawaited(
                    _trackSecondaryRoute<void>(
                      () => showNetdiskAccountSheet(
                        context,
                        widget.storage,
                        initialDriveKey: drive.key,
                        onChanged: () {
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
  Widget _buildPosterPlaceholder() {
    final palette = ApplePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: palette.isDark
              ? const [Color(0xFF242428), Color(0xFF161618)]
              : const [Color(0xFFE5E8F0), Color(0xFFD8DDE8)],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.film,
        color: palette.labelTertiary,
        size: 26,
      ),
    );
  }
  Widget _buildNetdiskCardPoster(String driveKey, String title) {
    final loggedIn = widget.storage.isNetdiskLoggedIn(driveKey);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: loggedIn
              ? const [Color(0xFF143527), Color(0xFF0E1D17)]
              : const [Color(0xFF152946), Color(0xFF101724)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            loggedIn ? CupertinoIcons.cloud_fill : CupertinoIcons.qrcode_viewfinder,
            color: loggedIn ? const Color(0xFF30D158) : const Color(0xFF5AC8FA),
            size: 38,
          ),
          const SizedBox(height: 8),
          Text(
            title.split('·').first.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              loggedIn ? '已登录+启用中' : '点击扫码登录',
              style: TextStyle(
                color: loggedIn ? const Color(0xFF30D158) : const Color(0xFF5AC8FA),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildVideoCard(
    CmsSite site,
    CmsVideo video, {
    String? badge,
    VoidCallback? onTap,
    String cardIdPrefix = 'vcard',
    void Function(BuildContext posterContext, double radius, String cardId)?
        onTapWithSource,
    bool includeOuterKey = true,
    Color? titleColorOverride,
    Color? subtitleColorOverride,
  }) {
    final cardKey =
        '${cardIdPrefix}_${site.key}_${video.id.isNotEmpty ? video.id : video.title}_${badge ?? ""}';
    BuildContext? posterCtx;
    return RepaintBoundary(
      key: includeOuterKey ? ValueKey(cardKey) : null,
      child: ApplePressableScale(
        pressedScale: 0.945,
        pressedOpacity: 0.90,
        onTap: onTapWithSource != null
            ? () => onTapWithSource(posterCtx ?? context, 20.0, cardKey)
            : (onTap ??
                () => _openVideoDetail(
                      site,
                      video,
                      sourceContext: posterCtx ?? context,
                      sourceRadius: 20.0,
                      sourceCardId: cardKey,
                    )),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PosterExpandSourceCard(
                cardId: cardKey,
                child: Builder(
                  builder: (ctx) {
                    posterCtx = ctx;
                    return AppleSmoothClipCard(
                      borderRadius: 20,
                      backgroundColor: const Color(0xFF1C1C20),
                      rimStrength: 0.86,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x36000000),
                          blurRadius: 12,
                          offset: Offset(0, 5),
                        ),
                      ],
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          video.id.startsWith('netdisk_qr:')
                              ? _buildNetdiskCardPoster(
                                  video.id
                                      .substring('netdisk_qr:'.length)
                                      .trim(),
                                  video.title,
                                )
                              : PosterImage(
                                  url: video.poster,
                                  title: site.isEffectivelyPrivate
                                      ? ''
                                      : video.title,
                                  year: site.isEffectivelyPrivate
                                      ? ''
                                      : video.year,
                                  placeholder: _buildPosterPlaceholder(),
                                ),
                          if (badge != null && badge.isNotEmpty)
                            Positioned(
                              top: 7,
                              left: 7,
                              right: 7,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: GlassworkBackdrop(
                                    radius: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7.5,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0x701E1E22),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0x3DFFFFFF),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        badge,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppleColors.labelPrimary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (video.remarks.isNotEmpty)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding:
                                    const EdgeInsets.fromLTRB(8, 16, 8, 6),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x00000000),
                                      Color(0xBD000000),
                                    ],
                                  ),
                                ),
                                child: Text(
                                  video.remarks,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: AppleColors.labelPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: titleColorOverride ??
                    ApplePalette.of(context).labelPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            if (widget.storage.cardSubtitleMode != 'none') ...[
              const SizedBox(height: 2),
              Text(
                switch (widget.storage.cardSubtitleMode) {
                  'site' => site.name,
                  'year_area' => [
                      video.year.trim(),
                      video.area.trim(),
                      video.tag.trim(),
                    ].where((s) => s.isNotEmpty).join(' · ').isNotEmpty
                        ? [
                            video.year.trim(),
                            video.area.trim(),
                            video.tag.trim(),
                          ].where((s) => s.isNotEmpty).join(' · ')
                        : (video.remarks.isNotEmpty
                            ? video.remarks
                            : site.name),
                  _ => video.remarks.isNotEmpty ? video.remarks : site.name,
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: subtitleColorOverride ??
                      ApplePalette.of(context).labelSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
  void _showGlobalSearchSheet() {
    if (isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null) {
      _windowsNavigate('search');
      return;
    }
    unawaited(
      _trackSecondaryRoute<void>(
        () => Navigator.of(context).push(
          buildIosSearchOverlayRoute<void>(
            builder: (_) => IosGlobalSearchPage(
          controller: _searchController,
          storage: widget.storage,
          client: widget.client,
          stateRevision: _searchStateRevision,
          readSnapshot: () => GlobalSearchSnapshot(
            isPrivate: _privateSessionUnlocked,
            searching: _searching,
            searchPerformed: _searchPerformed,
            searchKeyword: _searchKeyword,
            siteFilterKey: _searchSiteFilterKey,
            searchEpoch: _searchEpoch,
            results: _searchResults,
            notices: _searchNotices,
            verificationSites: _searchVerificationSites,
            visibleSupportedSites: _visibleSupportedSites,
            activeSite: _activeSite,
            homeHotVideos: _homeVideos,
          ),
          sourceLabelOf: _searchSourceLabel,
          onSearch: (kw) => unawaited(_runGlobalSearch(kw)),
          onResetSearch: _resetGlobalSearch,
          onSiteFilterChanged: (nextKey) {
            setState(() => _searchSiteFilterKey = nextKey);
            _notifySearchUi();
          },
          onRetryVerifiedSearch: _retryVerifiedSearch,
          onOpenVideoDetail: _openVideoDetail,
          onOpenVideoDetailFromCard: (
            site,
            video, {
            sourceContext,
            sourceRadius = 14.0,
            sourceCardId,
          }) =>
              _openVideoDetail(
            site,
            video,
            sourceContext: sourceContext,
            sourceRadius: sourceRadius,
            sourceCardId: sourceCardId,
          ),
          buildVideoCard: _buildVideoCard,
          buildVideoCardWithSource: (
            site,
            video, {
            badge,
            cardIdPrefix = 'search_card',
            onTapWithSource,
          }) =>
              _buildVideoCard(
            site,
            video,
            badge: badge,
            cardIdPrefix: cardIdPrefix,
            onTapWithSource: onTapWithSource,
          ),
          ),
        ),
        ),
      ),
    );
  }

  void _handleHomeLogoTap() {
    final now = DateTime.now();
    if (_lastLogoTapAt == null ||
        now.difference(_lastLogoTapAt!) > const Duration(milliseconds: 2500)) {
      _logoTapCount = 1;
    } else {
      _logoTapCount++;
    }
    _lastLogoTapAt = now;
    if (_logoTapCount >= 5) {
      _logoTapCount = 0;
      _lastLogoTapAt = null;
      _openPrivateSpaceWithAuth();
    }
  }

  void _enterPrivacySpaceDirectly() {
    HapticFeedback.heavyImpact();
    _searchSubscription?.cancel();
    _searchResults.clear();
    _searchController.clear();
    setState(() {
      _privateSessionUnlocked = true;
      _privacyPortalAnimating = true;
      _privacyPortalRunId++;
      _tabIndex = 0;
      _windowsPage = 'home';
    });
    _syncRootTabVisibility(animated: true);
    _reloadSavedConfig();
  }

  void _exitPrivacySpace() {
    HapticFeedback.lightImpact();
    widget.storage.clearPrivateVideoSkipRecords();
    _searchSubscription?.cancel();
    _searchResults.clear();
    _searchController.clear();
    setState(() {
      _privateSessionUnlocked = false;
    });
    _reloadSavedConfig(bypassHomeSnapshot: true);
  }

  void _openPrivateSpaceWithAuth() {
    if (_privateSessionUnlocked) {
      _exitPrivacySpace();
      return;
    }
    if (!widget.storage.hasPrivacyPassword) {
      _showSetPrivacyPasswordDialog(
        title: '设置隐私数字密码',
        subtitle: '请使用下方号码盘设置 4 位数字密码（后续连点 Logo 5 次输入密码即可直接进入隐私分组模式）',
        onSuccess: _enterPrivacySpaceDirectly,
      );
      return;
    }
    _showVerifyPrivacyPasswordDialog(
      onSuccess: _enterPrivacySpaceDirectly,
    );
  }

  void _showSetPrivacyPasswordDialog({
    String title = '设置隐私数字密码',
    String subtitle = '请输入 4 位数字作为隐私分组访问密码',
    VoidCallback? onSuccess,
  }) {
    if (IosLiquidGlassBridge.isAvailable) {
      unawaited(() async {
        final nativeResult = await showAppleNativePrivacyPin(
          mode: 'set',
          title: title,
          subtitle: subtitle,
          confirmTitle: '再次输入确认密码',
          confirmSubtitle: '请再次输入刚才设置的 4 位数字密码',
          pinLength: 4,
          loadingText: '正在加密保存密码…',
          mismatchError: '两次输入的密码不一致，请重新设置',
          onSubmit: (pin) async {
            await widget.storage.setPrivacyPassword(pin);
            return (ok: true, error: null);
          },
        );
        if (!mounted) return;
        if (nativeResult == true) {
          onSuccess?.call();
          return;
        }
        if (nativeResult == false) {
          return;
        }
        _showSetPrivacyPasswordFallbackDialog(
          title: title,
          subtitle: subtitle,
          onSuccess: onSuccess,
        );
      }());
      return;
    }
    _showSetPrivacyPasswordFallbackDialog(
      title: title,
      subtitle: subtitle,
      onSuccess: onSuccess,
    );
  }

  void _showSetPrivacyPasswordFallbackDialog({
    String title = '设置隐私数字密码',
    String subtitle = '请输入 4 位数字作为隐私分组访问密码',
    VoidCallback? onSuccess,
  }) {
    String firstPin = '';
    String currentPin = '';
    bool confirming = false;
    bool isBusy = false;
    String? err;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'SetPrivacyPin',
      barrierColor: const Color(0xB3000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim1, anim2) {
        return Center(
          child: StatefulBuilder(
            builder: (ctx, setPadState) {
              void handleDigit(String digit) async {
                if (isBusy || currentPin.length >= 4) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin += digit;
                });
                if (currentPin.length == 4) {
                  await Future<void>.delayed(const Duration(milliseconds: 120));
                  if (!ctx.mounted) return;
                  if (!confirming) {
                    setPadState(() {
                      firstPin = currentPin;
                      currentPin = '';
                      confirming = true;
                    });
                  } else {
                    if (currentPin == firstPin) {
                      setPadState(() {
                        isBusy = true;
                        err = null;
                      });
                      try {
                        await widget.storage.setPrivacyPassword(currentPin);
                      } finally {
                        if (ctx.mounted) {
                          setPadState(() => isBusy = false);
                        }
                      }
                      if (!ctx.mounted || !mounted ||
                          ModalRoute.of(ctx)?.isCurrent != true) {
                        return;
                      }
                      Navigator.of(ctx).pop();
                      onSuccess?.call();
                    } else {
                      HapticFeedback.heavyImpact();
                      setPadState(() {
                        err = '两次输入的密码不一致，请重新设置';
                        firstPin = '';
                        currentPin = '';
                        confirming = false;
                      });
                    }
                  }
                }
              }

              void handleBackspace() {
                if (isBusy || currentPin.isEmpty) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin = currentPin.substring(0, currentPin.length - 1);
                });
              }

              return _buildGlassPinPadCard(
                context: ctx,
                title: confirming ? '再次输入确认密码' : title,
                subtitle: confirming ? '请再次输入刚才设置的 4 位数字密码' : subtitle,
                pinLength: 4,
                enteredCount: currentPin.length,
                errorText: err,
                isLoading: isBusy,
                loadingText: '正在加密保存密码…',
                onDigit: handleDigit,
                onBackspace: handleBackspace,
                onCancel: () => Navigator.of(ctx).pop(),
              );
            },
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final useSpring = !isWindowsDesktopUi && !OhosRuntime.isOhos;
        final curved = CurvedAnimation(
          parent: anim,
          curve: useSpring ? Ios27Spring.bouncy.curve : Curves.easeOutBack,
        );
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.90, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  void _showVerifyPrivacyPasswordDialog({required VoidCallback onSuccess}) {
    final targetLen = widget.storage.privacyPasswordLength;
    if (IosLiquidGlassBridge.isAvailable) {
      unawaited(() async {
        final nativeResult = await showAppleNativePrivacyPin(
          mode: 'verify',
          title: '解锁隐私空间',
          subtitle: '输入设置的密码即可直接进入隐私分组模式',
          pinLength: targetLen,
          loadingText: '正在验证密码…',
          onSubmit: (pin) async {
            final verified = await widget.storage.verifyPrivacyPassword(pin);
            return (
              ok: verified,
              error: verified ? null : '密码错误，请重新输入',
            );
          },
        );
        if (!mounted) return;
        if (nativeResult == true) {
          onSuccess();
          return;
        }
        if (nativeResult == false) {
          return;
        }
        _showVerifyPrivacyPasswordFallbackDialog(onSuccess: onSuccess);
      }());
      return;
    }
    _showVerifyPrivacyPasswordFallbackDialog(onSuccess: onSuccess);
  }

  void _showVerifyPrivacyPasswordFallbackDialog({
    required VoidCallback onSuccess,
  }) {
    final targetLen = widget.storage.privacyPasswordLength;
    String currentPin = '';
    bool isBusy = false;
    String? err;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'VerifyPrivacyPin',
      barrierColor: const Color(0xB8000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, anim1, anim2) {
        return Center(
          child: StatefulBuilder(
            builder: (ctx, setPadState) {
              void handleDigit(String digit) async {
                if (isBusy || currentPin.length >= targetLen) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin += digit;
                });
                if (currentPin.length < targetLen) {
                  return;
                }
                setPadState(() {
                  isBusy = true;
                  err = null;
                });
                bool verified = false;
                try {
                  verified = await widget.storage.verifyPrivacyPassword(
                    currentPin,
                  );
                } finally {
                  if (ctx.mounted && !verified) {
                    setPadState(() => isBusy = false);
                  }
                }
                if (!ctx.mounted) return;
                if (verified) {
                  await Future<void>.delayed(const Duration(milliseconds: 90));
                  if (!ctx.mounted || !mounted ||
                      ModalRoute.of(ctx)?.isCurrent != true) {
                    return;
                  }
                  Navigator.of(ctx).pop();
                  onSuccess();
                  return;
                }
                HapticFeedback.heavyImpact();
                setPadState(() {
                  err = '密码错误，请重新输入';
                });
                await Future<void>.delayed(const Duration(milliseconds: 340));
                if (ctx.mounted) {
                  setPadState(() {
                    currentPin = '';
                  });
                }
              }

              void handleBackspace() {
                if (isBusy || currentPin.isEmpty) return;
                HapticFeedback.selectionClick();
                setPadState(() {
                  err = null;
                  currentPin = currentPin.substring(0, currentPin.length - 1);
                });
              }

              return _buildGlassPinPadCard(
                context: ctx,
                title: '解锁隐私空间',
                subtitle: '输入设置的密码即可直接进入隐私分组模式',
                pinLength: targetLen,
                enteredCount: currentPin.length,
                errorText: err,
                isLoading: isBusy,
                loadingText: '正在验证密码…',
                onDigit: handleDigit,
                onBackspace: handleBackspace,
                onCancel: () => Navigator.of(ctx).pop(),
              );
            },
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) {
        final useSpring = !isWindowsDesktopUi && !OhosRuntime.isOhos;
        final curved = CurvedAnimation(
          parent: anim,
          curve: useSpring ? Ios27Spring.bouncy.curve : Curves.easeOutBack,
        );
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.90, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildGlassPinPadCard({
    required BuildContext context,
    required String title,
    required String subtitle,
    required int pinLength,
    required int enteredCount,
    required String? errorText,
    bool isLoading = false,
    String? loadingText,
    required ValueChanged<String> onDigit,
    required VoidCallback onBackspace,
    required VoidCallback onCancel,
  }) {
    final hasError = errorText != null && errorText.isNotEmpty;
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    final card = Material(
      color: Colors.transparent,
      child: AppleGlassSurface(
        key: const ValueKey('privacy-pin-glass'),
        width: 326,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        borderRadius: BorderRadius.circular(32),
        elevated: true,
        child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF8B5CF6), Color(0xFF4F46E5)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF8B5CF6).withValues(alpha: 0.45),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: isLoading
                      ? const CupertinoActivityIndicator(
                          key: ValueKey('privacy-pin-loading'),
                          color: Colors.white,
                          radius: 11,
                        )
                      : const Icon(
                          CupertinoIcons.lock_shield_fill,
                          color: Colors.white,
                          size: 24,
                        ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  isLoading
                      ? (loadingText ?? '正在安全校验…')
                      : (hasError ? errorText : subtitle),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isLoading
                        ? ApplePalette.of(context).labelPrimary
                        : (hasError
                            ? AppleColors.systemRed
                            : ApplePalette.of(context).labelSecondary),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                // PIN indicator dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (int i = 0; i < pinLength; i++) ...[
                      if (i > 0) const SizedBox(width: 14),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < enteredCount
                              ? (hasError
                                  ? AppleColors.systemRed
                                  : (ApplePalette.isDarkOf(context)
                                      ? const Color(0xFFC4B5FD)
                                      : const Color(0xFF7C3AED)))
                              : (ApplePalette.isDarkOf(context)
                                  ? const Color(0x1FFFFFFF)
                                  : Colors.black.withValues(alpha: 0.06)),
                          border: Border.all(
                            color: i < enteredCount
                                ? (hasError
                                    ? AppleColors.systemRed
                                    : (ApplePalette.isDarkOf(context)
                                        ? const Color(0xFFA78BFA)
                                        : const Color(0xFF6D28D9)))
                                : (ApplePalette.isDarkOf(context)
                                    ? const Color(0x4DFFFFFF)
                                    : Colors.black.withValues(alpha: 0.24)),
                            width: 1.2,
                          ),
                          boxShadow: i < enteredCount
                              ? [
                                  BoxShadow(
                                    color: (hasError
                                            ? AppleColors.systemRed
                                            : const Color(0xFF8B5CF6))
                                        .withValues(alpha: 0.65),
                                    blurRadius: 10,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 22),
                // 3x4 Tactile Liquid Glass Number Pad
                for (final row in rows) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final digit in row)
                        _buildPinPadDigitButton(
                          label: digit,
                          onTap: () => onDigit(digit),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildPinPadActionButton(
                      label: '取消',
                      onTap: onCancel,
                    ),
                    _buildPinPadDigitButton(
                      label: '0',
                      onTap: () => onDigit('0'),
                    ),
                    _buildPinPadActionButton(
                      icon: CupertinoIcons.delete_left_fill,
                      onTap: onBackspace,
                    ),
                  ],
                ),
              ],
        ),
      ),
    );
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final String? digit = switch (key) {
          LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => '0',
          LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => '1',
          LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => '2',
          LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => '3',
          LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => '4',
          LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => '5',
          LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => '6',
          LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => '7',
          LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => '8',
          LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => '9',
          _ => null,
        };
        if (digit != null) {
          onDigit(digit);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.backspace ||
            key == LogicalKeyboardKey.delete) {
          onBackspace();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape) {
          onCancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          key: const ValueKey('privacy-pin-scroll'),
          child: card,
        ),
      ),
    );
  }

  Widget _buildPinPadDigitButton({
    required String label,
    required VoidCallback onTap,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0x38FFFFFF), Color(0x1AFFFFFF)]
                : const [Color(0xFFFFFFFF), Color(0xFFF0F2F7)],
          ),
          border: Border.all(
            color: isDark
                ? const Color(0x36FFFFFF)
                : Colors.black.withValues(alpha: 0.12),
            width: 0.75,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: palette.labelPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildPinPadActionButton({
    String? label,
    IconData? icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 68,
        height: 68,
        child: Center(
          child: icon != null
              ? Icon(icon, color: ApplePalette.of(context).labelSecondary, size: 22)
              : Text(
                  label ?? '',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }

  void _showPrivateResourcesSheet() {
    showAppleModalSheet<void>(
      context: context,
      title: '隐私资源 · 隐藏列表',
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minSize: 28,
        onPressed: () {
          Navigator.of(context).pop();
          setState(() {
            _privateSessionUnlocked = false;
          });
          _reloadSavedConfig();
        },
        child: const Text(
          '锁定退出',
          style: TextStyle(color: AppleColors.systemOrange, fontSize: 13),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final allSubs = widget.storage.getSubscriptions();
          final privateSubs =
              allSubs.where((s) => s.isEffectivelyPrivate).toList();
          final privateSites = _config?.privateSupportedSites ?? const [];
          final privateLives = _config?.privateSupportedLives ?? const [];
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  AppleCapsuleButton(
                    label: '导入隐私订阅 (VOD/M3U/JSON)',
                    icon: CupertinoIcons.lock_fill,
                    primary: true,
                    compact: true,
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _showImportConfigDialog(
                        initialIsPrivate: true,
                        initialGroup: '隐私专区',
                      );
                    },
                  ),
                  AppleCapsuleButton(
                    label: '修改隐私密码',
                    icon: CupertinoIcons.lock_shield_fill,
                    compact: true,
                    onPressed: () {
                      _showSetPrivacyPasswordDialog(
                        title: '修改隐私访问密码',
                        subtitle: '请输入新的隐私空间密码：',
                      );
                    },
                  ),
                ],
              ),
              SizedBox(height: 16),
              if (privateSites.isEmpty &&
                  privateSubs.isEmpty &&
                  privateLives.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: ApplePalette.of(context).groupedSecondary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        CupertinoIcons.eye_slash_fill,
                        color: ApplePalette.of(context).labelTertiary,
                        size: 38,
                      ),
                      SizedBox(height: 10),
                      Text(
                        '隐藏列表暂无隐私资源',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '点击上方「导入隐私订阅」，或将下方现有订阅设为「隐私」，即可在此安全访问；日常浏览时完全隐藏。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: ApplePalette.of(context).labelSecondary,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              if (privateSites.isNotEmpty) ...[
                AppleGroupedSection(
                  header: '隐藏影视片源 (${privateSites.length})',
                  footer: '点击任意隐私片源即可在主页立即加载浏览；点击右上角「锁定退出」后自动恢复隐藏。',
                  children: privateSites.map((s) {
                    final selected = s.key == _activeSite?.key;
                    final tile = AppleGroupedTile(
                      icon: CupertinoIcons.lock_shield_fill,
                      iconBgColor: selected
                          ? AppleColors.systemBlue
                          : AppleColors.systemPurple,
                      title: s.name,
                      subtitle: s.supported
                          ? '${s.group} · ${s.api}'
                          : '${s.group} · ${s.unsupportedReason}',
                      trailing: selected
                          ? Icon(
                              CupertinoIcons.checkmark_alt,
                              color: AppleColors.systemBlue,
                              size: 18,
                            )
                          : Text(
                              s.supported ? '立即访问' : '未适配',
                              style: TextStyle(
                                color: s.supported
                                    ? AppleColors.systemBlue
                                    : ApplePalette.of(context).labelTertiary,
                                fontSize: 12,
                              ),
                            ),
                      onTap: () {
                        if (!s.supported) {
                          unawaited(
                            showAppleNativeAlert(
                              ctx,
                              title: s.name,
                              message: s.unsupportedReason,
                              actions: const [
                                AppleNativeAlertAction(
                                  id: 'ok',
                                  title: '我知道了',
                                  isDefault: true,
                                ),
                              ],
                            ),
                          );
                          return;
                        }
                        Navigator.of(ctx).pop();
                        if (s.isCatPaw && Uri.parse(s.api).path == '/api/baseset') {
                          _showCatPawSettings(s);
                          return;
                        }
                        setState(() {
                          _privateSessionUnlocked = true;
                          _activeSite = s;
                        });
                        _loadSiteHome();
                      },
                    );
                    return s.supported
                        ? tile
                        : Opacity(opacity: 0.52, child: tile);
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              if (privateLives.isNotEmpty) ...[
                AppleGroupedSection(
                  header: '隐藏直播源 (${privateLives.length})',
                  children: [
                    for (int i = 0; i < privateLives.length; i++)
                      AppleGroupedTile(
                        icon: CupertinoIcons.dot_radiowaves_left_right,
                        iconBgColor: AppleColors.systemIndigo,
                        title: privateLives[i].name,
                        subtitle: '${privateLives[i].group} · M3U/TXT 直播',
                        trailingText: '去观看',
                        onTap: () {
                          Navigator.of(ctx).pop();
                          setState(() {
                            _privateSessionUnlocked = true;
                            _tabIndex = 1;
                            _windowsPage = 'live';
                          });
                          final idx = _visibleLives.indexWhere(
                            (l) => l.url == privateLives[i].url,
                          );
                          if (idx >= 0) _loadLivePlaylist(idx);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (allSubs.isNotEmpty)
                AppleGroupedSection(
                  header: '管理订阅隐私开关 (${allSubs.length})',
                  footer: '开启开关可将对应订阅移入隐私隐藏列表。',
                  children: allSubs.map((sub) {
                    final priv = sub.isEffectivelyPrivate;
                    return AppleGroupedTile(
                      icon: priv
                          ? CupertinoIcons.eye_slash_fill
                          : CupertinoIcons.globe,
                      iconBgColor: priv
                          ? AppleColors.systemPurple
                          : AppleColors.systemBlue,
                      title: '${sub.name} [${sub.format}]',
                      subtitle:
                          '分组：${sub.group} · ${sub.siteCount} 片源 / ${sub.liveCount} 直播',
                      trailing: CupertinoSwitch(
                        value: priv,
                        activeTrackColor: AppleColors.systemPurple,
                        onChanged: (val) async {
                          await widget.storage.toggleSubscriptionPrivacy(
                            sub.id,
                            val,
                          );
                          if (!val &&
                              (sub.group.contains('隐私') ||
                                  sub.group.contains('私密'))) {
                            await widget.storage.updateSubscriptionGroup(
                              sub.id,
                              '默认分组',
                            );
                          }
                          _reloadSavedConfig();
                          setSheetState(() {});
                        },
                      ),
                    );
                  }).toList(),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLiveTab(BuildContext context, {required bool useSidebar}) {
    final lives = _visibleLives;
    if (lives.isEmpty) {
      final rawLives = _privateSessionUnlocked
          ? (_config?.privateLives ?? const [])
          : (_config?.publicLives ?? const []);
      final hasPluginOnlyLives = rawLives.isNotEmpty;
      return SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.dot_radiowaves_left_right,
                  color: ApplePalette.of(context).labelTertiary,
                  size: 48,
                ),
                SizedBox(height: 12),
                Text(
                  hasPluginOnlyLives
                      ? '当前订阅的直播源需要专用插件'
                      : '当前配置未包含 M3U / TXT 直播源',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  hasPluginOnlyLives
                      ? '所选订阅中的直播线路依赖 Android 本地代理插件，当前设备暂不支持；可导入 M3U / TXT 直播地址观看。'
                      : '可直接导入 M3U / TXT 直播订阅地址或包含 lives 节点的 JSON 配置。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    AppleCapsuleButton(
                      label: '独立导入直播源',
                      icon: CupertinoIcons.add,
                      primary: true,
                      compact: true,
                      onPressed: () => _showStandaloneLiveImportSheet(),
                    ),
                    AppleCapsuleButton(
                      label: '从订阅配置导入',
                      icon: CupertinoIcons.cloud_download,
                      compact: true,
                      onPressed: () =>
                          _showImportConfigDialog(initialGroup: '电视直播'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final displayGroups = _displayLiveGroups;
    final hasFailedGroup = _liveGroups.any(
      (g) => g.name == LiveChannelOrganizer.failedGroupName,
    );
    final totalChannelCount = displayGroups.fold<int>(
      0,
      (sum, g) => sum + g.channels.length,
    );
    final safeGroupIdx = displayGroups.isEmpty
        ? -1
        : (_selectedLiveGroup >= displayGroups.length ? 0 : _selectedLiveGroup);
    final queryLower = _liveSearchQuery.trim().toLowerCase();

    final visibleChannels = <LiveChannel>[];
    if (queryLower.isNotEmpty) {
      for (final g in displayGroups) {
        for (final ch in g.channels) {
          if (ch.name.toLowerCase().contains(queryLower) ||
              ch.group.toLowerCase().contains(queryLower)) {
            visibleChannels.add(ch);
          }
        }
      }
    } else if (safeGroupIdx == -1) {
      for (final g in displayGroups) {
        visibleChannels.addAll(g.channels);
      }
    } else if (safeGroupIdx >= 0 && safeGroupIdx < displayGroups.length) {
      visibleChannels.addAll(displayGroups[safeGroupIdx].channels);
    }

    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final viewport = AppleViewportLayout.of(context);
    final livePad = viewport.horizontalPadding(useSidebar: useSidebar);
    final compactLiveHeader = viewport.width < 380;
    final hasStandaloneLives =
        widget.storage.getStandaloneLiveSources().isNotEmpty;

    return SafeArea(
      bottom: useSidebar,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          livePad,
          _isMacOS ? 38 : 14,
          livePad,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row 1: Page Title + Channel Count + Spacious Primary Actions
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          '电视直播',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.labelPrimary,
                            fontSize: compactLiveHeader ? 22 : 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                          ),
                        ),
                      ),
                      if (totalChannelCount > 0 && !compactLiveHeader) ...[
                        const SizedBox(width: 9),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3.5,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0x22FFFFFF)
                                : Colors.black.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$totalChannelCount 频道',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildLiveToolbarAction(
                  icon: CupertinoIcons.add,
                  label: '导入',
                  accentFill: true,
                  onTap: () => _showStandaloneLiveImportSheet(),
                ),
                if (!_liveLoading && _liveGroups.isNotEmpty) ...[
                  SizedBox(width: compactLiveHeader ? 6 : 8),
                  _buildLiveToolbarAction(
                    icon: _liveProbing
                        ? CupertinoIcons.stop_circle
                        : CupertinoIcons.speedometer,
                    label: _liveProbing ? '停止' : '测速',
                    highlighted: _liveProbing,
                    onTap: _probeCurrentLiveGroups,
                  ),
                ],
                if (hasStandaloneLives) ...[
                  SizedBox(width: compactLiveHeader ? 6 : 8),
                  _buildLiveToolbarAction(
                    icon: CupertinoIcons.slider_horizontal_3,
                    label: '',
                    tooltip: '管理独立直播源',
                    onTap: _showLiveSourceManagerSheet,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),

            // Row 2: Dedicated Full-Width Channel Search Field
            SizedBox(
              height: 40,
              child: AppleSearchField(
                controller: _liveSearchController,
                placeholder: '搜索频道、台名或分组…',
                onChanged: (v) => setState(() => _liveSearchQuery = v),
                onSuffixTap: () {
                  _liveSearchController.clear();
                  setState(() => _liveSearchQuery = '');
                },
              ),
            ),
            const SizedBox(height: 12),

            // Row 3: Dedicated Uncluttered Live Source Switcher Strip
            SizedBox(
              height: 36,
              child: DesktopHorizontalScroller(
                controller: _liveSourcesScrollController,
                child: ListView.separated(
                  controller: _liveSourcesScrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: lives.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) => _buildCategoryPill(
                    label: lives[i].name,
                    selected: i == _selectedLiveSource,
                    onTap: () => _loadLivePlaylist(i),
                  ),
                ),
              ),
            ),

            if (_liveProbing && _liveProbeProgress != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0x260A84FF)
                      : const Color(0x16007AFF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: palette.systemBlue.withValues(alpha: 0.35),
                    width: 0.7,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const CupertinoActivityIndicator(radius: 7.5),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '正在检测通畅度 ${_liveProbeProgress!.completedChannels}/${_liveProbeProgress!.totalChannels} · 通畅 ${_liveProbeProgress!.reachableChannels} · 失效 ${_liveProbeProgress!.unreachableChannels}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.labelPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _liveProbeProgress!.fraction,
                        minHeight: 3.5,
                        backgroundColor: isDark
                            ? const Color(0x28FFFFFF)
                            : Colors.black.withValues(alpha: 0.08),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF30D158),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Row 4: Dedicated Category Filter Strip + Inline Hide-Failed Pill
            if (!_liveLoading &&
                _liveError == null &&
                displayGroups.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: DesktopHorizontalScroller(
                  controller: _liveGroupsScrollController,
                  child: ListView.separated(
                    controller: _liveGroupsScrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount:
                        displayGroups.length + 1 + (hasFailedGroup ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, idx) {
                      if (idx == 0) {
                        final isAllSelected =
                            queryLower.isEmpty && safeGroupIdx == -1;
                        return _buildCategoryPill(
                          label: '全部 ($totalChannelCount)',
                          selected: isAllSelected,
                          onTap: () => setState(() {
                            _selectedLiveGroup = -1;
                            if (_liveSearchQuery.isNotEmpty) {
                              _liveSearchController.clear();
                              _liveSearchQuery = '';
                            }
                          }),
                        );
                      }
                      if (hasFailedGroup && idx == displayGroups.length + 1) {
                        return _buildLiveToolbarAction(
                          icon: _liveHideUnreachable
                              ? CupertinoIcons.eye_slash_fill
                              : CupertinoIcons.eye,
                          label: _liveHideUnreachable ? '已隐失效' : '隐失效',
                          highlighted: _liveHideUnreachable,
                          onTap: () {
                            final next = !_liveHideUnreachable;
                            unawaited(
                              widget.storage.setLiveHideUnreachable(next),
                            );
                            setState(() {
                              _liveHideUnreachable = next;
                              if (_selectedLiveGroup >=
                                  _displayLiveGroups.length) {
                                _selectedLiveGroup = 0;
                              }
                            });
                          },
                        );
                      }
                      final gIdx = idx - 1;
                      final g = displayGroups[gIdx];
                      final isSelected =
                          queryLower.isEmpty && safeGroupIdx == gIdx;
                      return _buildCategoryPill(
                        label: '${g.name} (${g.channels.length})',
                        selected: isSelected,
                        onTap: () => setState(() {
                          _selectedLiveGroup = gIdx;
                          if (_liveSearchQuery.isNotEmpty) {
                            _liveSearchController.clear();
                            _liveSearchQuery = '';
                          }
                        }),
                      );
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),

            // Main Multi-Column Channel Card Grid
            if (_liveLoading)
              const Expanded(
                child: Center(child: CupertinoActivityIndicator(radius: 14)),
              )
            else if (_liveError != null)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.wifi_exclamationmark,
                          color: ApplePalette.of(context).labelTertiary,
                          size: 38,
                        ),
                        SizedBox(height: 12),
                        Text(
                          _liveError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: ApplePalette.of(context).labelSecondary,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                        AppleCapsuleButton(
                          label: '重新加载',
                          icon: CupertinoIcons.refresh,
                          compact: true,
                          onPressed: () => _loadLivePlaylist(
                            _selectedLiveSource.clamp(0, lives.length - 1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (visibleChannels.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    '未找到匹配的直播频道',
                    style: TextStyle(
                      color: ApplePalette.of(context).labelSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final availW = constraints.maxWidth;
                    final int cols = availW >= 1240
                        ? 5
                        : availW >= 920
                            ? 4
                            : availW >= 580
                                ? 3
                                : availW >= 340
                                    ? 2
                                    : 1;
                    final double aspect = cols == 1
                        ? 4.1
                        : (cols == 2 ? 2.28 : 2.42);
                    return ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00FFFFFF),
                          Color(0xD9FFFFFF),
                          Color(0xFFFFFFFF),
                        ],
                        stops: [0.0, 0.025, 0.055],
                      ).createShader(rect),
                      child: GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.only(
                          top: 4,
                          bottom: useSidebar ? 28 : 124,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: 11,
                          crossAxisSpacing: 11,
                          childAspectRatio: aspect,
                        ),
                        itemCount: visibleChannels.length,
                        itemBuilder: (ctx, cIdx) {
                          final ch = visibleChannels[cIdx];
                          return _buildLiveChannelCard(
                            context,
                            channel: ch,
                            lives: lives,
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openLiveChannelStream(
    List<LiveSource> lives,
    LiveChannel ch,
    int lineIdx,
  ) {
    if (lives.isEmpty || ch.urls.isEmpty) return;
    final safeIdx = _selectedLiveSource.clamp(0, lives.length - 1);
    final liveSite = lives[safeIdx].playbackSite;
    final liveVideo = CmsVideo(
      id: ch.name,
      title: ch.name,
      lines: [
        CmsLine(
          name: ch.group,
          episodes: ch.episodes,
        ),
      ],
    );
    final catalogGroups = _displayLiveGroups;
    if (OhosRuntime.isOhos) {
      unawaited(
        _trackSecondaryRoute<void>(
          () => Navigator.of(context).push(
            buildApplePageRoute<void>(
              builder: (_) => PlayerScreen(
                site: liveSite,
                video: liveVideo,
                initialLineIndex: 0,
                initialEpisodeIndex: lineIdx.clamp(0, ch.urls.length - 1),
                storage: widget.storage,
                isLive: true,
                liveGroups: catalogGroups,
                initialLiveChannel: ch,
              ),
            ),
          ),
        ),
      );
    } else {
      unawaited(
        _trackSecondaryRoute<void>(
          () => pushPlayerRoute<void>(
            context: context,
            useFastWindowsMode: isWindowsDesktopUi,
            builder: (_) => PlayerScreen(
              site: liveSite,
              video: liveVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: lineIdx.clamp(0, ch.urls.length - 1),
              storage: widget.storage,
              isLive: true,
              liveGroups: catalogGroups,
              initialLiveChannel: ch,
            ),
          ),
        ),
      );
    }
  }

  void _showLiveChannelLinesSheet(
    List<LiveSource> lives,
    LiveChannel ch,
  ) {
    showAppleModalSheet<void>(
      context: context,
      title: '${ch.name} · 选择直播线路',
      maxWidth: 460,
      builder: (ctx) => ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
        itemCount: ch.urls.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (ctx, idx) {
          final palette = ApplePalette.of(ctx);
          final isDark = palette.isDark;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Navigator.of(ctx).pop();
              _openLiveChannelStream(lives, ch, idx);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: ShapeDecoration(
                color: isDark ? const Color(0xFF242429) : Colors.white,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: isDark
                        ? const Color(0x28FFFFFF)
                        : Colors.black.withValues(alpha: 0.08),
                    width: 0.65,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppleColors.systemGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      idx < ch.episodes.length && ch.episodes[idx].name.isNotEmpty
                          ? ch.episodes[idx].name
                          : '线路 ${idx + 1}',
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.play_fill,
                    color: palette.accent,
                    size: 15,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLiveChannelCard(
    BuildContext context, {
    required LiveChannel channel,
    required List<LiveSource> lives,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final upper = channel.name.toUpperCase();
    final String? qualityTag = upper.contains('8K')
        ? '8K'
        : upper.contains('4K') || upper.contains('UHD')
            ? '4K'
            : upper.contains('50FPS') || upper.contains('60FPS')
                ? '高帧'
                : upper.contains('FHD') || upper.contains('高清')
                    ? 'HD'
                    : null;

    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openLiveChannelStream(lives, channel, 0),
        onLongPress: channel.urls.length > 1
            ? () => _showLiveChannelLinesSheet(lives, channel)
            : null,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            gradient: isDark
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xF020222D),
                      Color(0xF0151720),
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFF7F9FC),
                    ],
                  ),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isDark
                    ? const Color(0x28FFFFFF)
                    : Colors.black.withValues(alpha: 0.065),
                width: 0.7,
              ),
            ),
            shadows: [
              BoxShadow(
                color: isDark
                    ? const Color(0x36000000)
                    : const Color(0x100F172A),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            child: Row(
              children: [
                _buildLiveChannelBadge(channel),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.labelPrimary,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          if (qualityTag != null) ...[
                            const SizedBox(width: 5),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: qualityTag == '4K' || qualityTag == '8K'
                                    ? const Color(0x2EF59E0B)
                                    : (isDark
                                        ? const Color(0x26FFFFFF)
                                        : Colors.black.withValues(alpha: 0.06)),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: qualityTag == '4K' || qualityTag == '8K'
                                      ? const Color(0x80F59E0B)
                                      : palette.separator,
                                  width: 0.5,
                                ),
                              ),
                              child: Text(
                                qualityTag,
                                style: TextStyle(
                                  color: qualityTag == '4K' || qualityTag == '8K'
                                      ? (isDark
                                          ? const Color(0xFFFBBF24)
                                          : const Color(0xFFB45309))
                                      : palette.labelSecondary,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            width: 6.5,
                            height: 6.5,
                            decoration: BoxDecoration(
                              color: LiveHealthVisual.dotColor(channel.health),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              channel.group,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.labelSecondary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (LiveHealthVisual.badgeText(channel)
                              case final String speedLabel) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5.5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: LiveHealthVisual.dotColor(channel.health)
                                    .withValues(alpha: isDark ? 0.22 : 0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                speedLabel,
                                style: TextStyle(
                                  color:
                                      LiveHealthVisual.dotColor(channel.health),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                          ],
                          if (channel.urls.length > 1)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () =>
                                  _showLiveChannelLinesSheet(lives, channel),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6.5,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0x26FFFFFF)
                                      : Colors.black.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${channel.urls.length}源 ▾',
                                  style: TextStyle(
                                    color: palette.labelSecondary,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            )
                          else
                            Text(
                              '直连',
                              style: TextStyle(
                                color: palette.labelTertiary,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveToolbarAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlighted = false,
    bool accentFill = false,
    String? tooltip,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final hasLabel = label.isNotEmpty;
    final bgColor = accentFill
        ? palette.systemBlue
        : (highlighted
            ? palette.systemBlue.withValues(alpha: isDark ? 0.30 : 0.15)
            : (isDark
                ? const Color(0x24FFFFFF)
                : Colors.white.withValues(alpha: 0.92)));
    final borderColor = accentFill
        ? palette.systemBlue
        : (highlighted
            ? palette.systemBlue.withValues(alpha: 0.55)
            : (isDark
                ? const Color(0x2CFFFFFF)
                : Colors.black.withValues(alpha: 0.08)));
    final fgColor = accentFill
        ? Colors.white
        : (highlighted ? palette.systemBlue : palette.labelPrimary);
    final child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 34,
        padding: EdgeInsets.symmetric(horizontal: hasLabel ? 12 : 9.5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor, width: 0.7),
          boxShadow: !isDark && !highlighted && !accentFill
              ? const [
                  BoxShadow(
                    color: Color(0x0C0F172A),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: fgColor),
            if (hasLabel) ...[
              const SizedBox(width: 4.5),
              Text(
                label,
                style: TextStyle(
                  color: fgColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (tooltip != null && tooltip.isNotEmpty) {
      return Semantics(button: true, label: tooltip, child: child);
    }
    return child;
  }

  Future<void> _showStandaloneLiveImportSheet({
    StandaloneLiveSource? editing,
  }) async {
    var mode = (editing != null &&
            editing.url.isEmpty &&
            editing.inlineContent.isNotEmpty)
        ? 2
        : 0; // 0: URL, 1: Local File, 2: Paste Text
    final nameCtrl = TextEditingController(text: editing?.name ?? '');
    final urlCtrl = TextEditingController(text: editing?.url ?? '');
    final textCtrl = TextEditingController(text: editing?.inlineContent ?? '');
    final uaCtrl = TextEditingController(text: editing?.userAgent ?? '');
    final logoCtrl = TextEditingController(text: editing?.logoTemplate ?? '');
    var autoCategorize =
        editing?.autoCategorize ?? widget.storage.liveAutoCategorize;
    var autoProbe = true;
    var showAdvanced =
        (editing?.userAgent.trim().isNotEmpty ?? false) ||
        (editing?.logoTemplate.trim().isNotEmpty ?? false);
    var pickedFileName = '';
    var pickedFileContent = editing?.inlineContent ?? '';
    String? errorMsg;

    await showAppleModalSheet<void>(
      context: context,
      title: editing == null ? '独立导入直播源' : '编辑直播源',
      maxWidth: 520,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final palette = ApplePalette.of(ctx);
          final isDark = palette.isDark;
          final fieldBg = isDark ? const Color(0xFF2C2C2E) : Colors.white;
          final cardBg = isDark ? const Color(0xFF242428) : Colors.white;
          final fieldBorder = isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.09);

          Widget fieldCaption(String text) => Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 7),
                child: Text(
                  text,
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );

          Widget styledInput({
            Key? fieldKey,
            required TextEditingController controller,
            required String placeholder,
            TextInputType? keyboardType,
            int maxLines = 1,
            int? minLines,
          }) =>
              TextSelectionMouseGuard(
                child: CupertinoTextField(
                  key: fieldKey,
                  controller: controller,
                  placeholder: placeholder,
                  keyboardType: keyboardType,
                  maxLines: maxLines,
                  minLines: minLines,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 15,
                  ),
                  placeholderStyle: TextStyle(
                    color: palette.labelTertiary,
                    fontSize: 14.5,
                  ),
                  decoration: BoxDecoration(
                    color: fieldBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: fieldBorder, width: 0.7),
                  ),
                ),
              );

          Future<void> pickLocalFile() async {
            try {
              String rawText = '';
              String fileName = '';
              if (OhosRuntime.isOhos) {
                final picked = await OhosRuntime.pickDocumentFile(
                  purpose: OhosDocumentPurpose.live,
                  maxBytes: CmsClient.maxResponseBytes,
                );
                if (picked == null) return;
                fileName = picked.name;
                rawText = CmsParser.decodeConfigDocument(picked.bytes);
              } else {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.any,
                  withData: true,
                );
                if (result == null || result.files.isEmpty) return;
                final file = result.files.first;
                fileName = file.name;
                if (file.bytes != null) {
                  if (file.bytes!.length > CmsClient.maxResponseBytes) {
                    setSheetState(() => errorMsg = '直播源文件超过 6 MB 限制');
                    return;
                  }
                  rawText = utf8.decode(file.bytes!, allowMalformed: true);
                } else if (file.path != null && file.path!.isNotEmpty) {
                  final ioFile = File(file.path!);
                  if (await ioFile.length() > CmsClient.maxResponseBytes) {
                    setSheetState(() => errorMsg = '直播源文件超过 6 MB 限制');
                    return;
                  }
                  rawText = await ioFile.readAsString();
                }
              }
              if (rawText.trim().isEmpty) {
                setSheetState(() => errorMsg = '所选直播文件内容为空');
                return;
              }
              setSheetState(() {
                pickedFileName = fileName;
                pickedFileContent = rawText;
                errorMsg = null;
                if (nameCtrl.text.trim().isEmpty) {
                  nameCtrl.text = fileName.replaceAll(
                    RegExp(r'\.(?:m3u8?|txt|json)$', caseSensitive: false),
                    '',
                  );
                }
              });
            } on FormatException catch (e) {
              setSheetState(() => errorMsg = '读取文件失败：${e.message}');
            } catch (e) {
              setSheetState(() => errorMsg = '读取文件失败：$e');
            }
          }

          Future<void> submit() async {
            final url = mode == 0 ? urlCtrl.text.trim() : '';
            final inline = mode == 1
                ? pickedFileContent.trim()
                : (mode == 2 ? textCtrl.text.trim() : '');
            if (mode == 0) {
              final parsed = Uri.tryParse(url);
              if (parsed == null ||
                  !const {'http', 'https'}.contains(parsed.scheme.toLowerCase()) ||
                  parsed.host.isEmpty) {
                setSheetState(() => errorMsg = '请输入有效的 HTTP / HTTPS 直播源地址');
                return;
              }
            } else if (inline.isEmpty) {
              setSheetState(
                () => errorMsg =
                    mode == 1 ? '请先选择一个 M3U / TXT 直播文件' : '请粘贴 M3U 或 TXT 直播列表内容',
              );
              return;
            }
            if (inline.isNotEmpty) {
              try {
                final preview = CmsParser.parseLivePlaylist(inline);
                if (preview.isEmpty) {
                  setSheetState(() => errorMsg = '未在内容中解析出有效直播频道');
                  return;
                }
              } catch (e) {
                setSheetState(() => errorMsg = '解析直播内容失败：$e');
                return;
              }
            }
            var finalName = nameCtrl.text.trim();
            if (finalName.isEmpty) {
              if (url.isNotEmpty) {
                final uri = Uri.tryParse(url);
                final seg = uri != null && uri.pathSegments.isNotEmpty
                    ? uri.pathSegments.last
                    : (uri?.host ?? '自建直播源');
                finalName = seg.replaceAll(
                  RegExp(r'\.(?:m3u8?|txt|json)$', caseSensitive: false),
                  '',
                );
                if (finalName.isEmpty) finalName = uri?.host ?? '自建直播源';
              } else {
                finalName = pickedFileName.isNotEmpty ? pickedFileName : '自建直播源';
              }
            }
            final saved = await widget.storage.upsertStandaloneLiveSource(
              StandaloneLiveSource(
                id: editing?.id ?? '',
                name: finalName,
                url: url,
                inlineContent: inline,
                userAgent: uaCtrl.text.trim(),
                logoTemplate: logoCtrl.text.trim(),
                autoCategorize: autoCategorize,
                enabled: true,
              ),
            );
            await widget.storage.clearLiveSnapshot(saved.toLiveSource());
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (!mounted) return;
            _reloadSavedConfig(bypassHomeSnapshot: true);
            final lives = _visibleLives;
            final targetIdx = lives.indexWhere(
              (l) => l.subscriptionId == 'standalone_live:${saved.id}',
            );
            if (targetIdx >= 0) {
              unawaited(
                _loadLivePlaylist(
                  targetIdx,
                  forceRefresh: true,
                  autoProbeAfterLoad: autoProbe,
                ),
              );
            }
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CupertinoSlidingSegmentedControl<int>(
                  groupValue: mode,
                  backgroundColor: isDark
                      ? const Color(0xFF1C1C1F)
                      : const Color(0x16787880),
                  thumbColor: isDark ? const Color(0xFF3A3A3F) : Colors.white,
                  children: {
                    0: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Text(
                        '网络地址',
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 13.5,
                          fontWeight:
                              mode == 0 ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                    1: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Text(
                        '本地文件',
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 13.5,
                          fontWeight:
                              mode == 1 ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                    2: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Text(
                        '粘贴内容',
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 13.5,
                          fontWeight:
                              mode == 2 ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                  },
                  onValueChanged: (v) {
                    if (v != null) {
                      setSheetState(() {
                        mode = v;
                        errorMsg = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 18),
                fieldCaption('直播源名称'),
                styledInput(
                  fieldKey: const ValueKey('live-import-name-field'),
                  controller: nameCtrl,
                  placeholder: '可选，留空自动按文件名或域名命名',
                ),
                const SizedBox(height: 16),
                fieldCaption(
                  mode == 0
                      ? '直播源地址'
                      : (mode == 1 ? '选择本地直播文件' : '直播列表文本'),
                ),
                if (mode == 0)
                  styledInput(
                    fieldKey: const ValueKey('live-import-url-field'),
                    controller: urlCtrl,
                    placeholder: 'https://…（支持 M3U / M3U8 / TXT）',
                    keyboardType: TextInputType.url,
                  )
                else if (mode == 1)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: fieldBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: fieldBorder, width: 0.7),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            pickedFileName.isNotEmpty
                                ? '已选择：$pickedFileName'
                                : '支持 .m3u / .m3u8 / .txt / .json 直播文件',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: pickedFileName.isNotEmpty
                                  ? palette.labelPrimary
                                  : palette.labelSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        AppleCapsuleButton(
                          label: '选择文件',
                          icon: CupertinoIcons.doc_text,
                          compact: true,
                          onPressed: pickLocalFile,
                        ),
                      ],
                    ),
                  )
                else
                  styledInput(
                    fieldKey: const ValueKey('live-import-text-field'),
                    controller: textCtrl,
                    placeholder: '粘贴 #EXTM3U 或 频道名,播放地址 格式内容…',
                    maxLines: 5,
                    minLines: 4,
                  ),
                const SizedBox(height: 16),
                // Collapsible advanced header/logo fields keep the modal airy
                // and scannable while keeping full customization 1 tap away.
                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: fieldBorder, width: 0.65),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setSheetState(
                          () => showAdvanced = !showAdvanced,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                CupertinoIcons.slider_horizontal_3,
                                size: 16,
                                color: palette.labelSecondary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '高级选项（User-Agent / 台标模板）',
                                  style: TextStyle(
                                    color: palette.labelPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              Icon(
                                showAdvanced
                                    ? CupertinoIcons.chevron_up
                                    : CupertinoIcons.chevron_down,
                                size: 15,
                                color: palette.labelTertiary,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (showAdvanced) ...[
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          color: palette.separator,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              fieldCaption('自定义 User-Agent'),
                              styledInput(
                                controller: uaCtrl,
                                placeholder: '可选，默认 okhttp/4.12.0',
                              ),
                              const SizedBox(height: 12),
                              fieldCaption('自定义台标模板'),
                              styledInput(
                                controller: logoCtrl,
                                placeholder: '可选，用 {name} 占位频道名',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: fieldBorder, width: 0.65),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '自动智能归类 & 匹配台标',
                                    style: TextStyle(
                                      color: palette.labelPrimary,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '按央视 / 卫视 / 4K / 港澳台 / 体育等分组并补全品牌台标',
                                    style: TextStyle(
                                      color: palette.labelSecondary,
                                      fontSize: 12.5,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            CupertinoSwitch(
                              value: autoCategorize,
                              activeTrackColor: AppleColors.systemGreen,
                              onChanged: (v) =>
                                  setSheetState(() => autoCategorize = v),
                            ),
                          ],
                        ),
                      ),
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        indent: 14,
                        color: palette.separator,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '导入后自动检测通畅度',
                                    style: TextStyle(
                                      color: palette.labelPrimary,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '多路信号按延迟排序，不可用频道归入「失效频道」',
                                    style: TextStyle(
                                      color: palette.labelSecondary,
                                      fontSize: 12.5,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            CupertinoSwitch(
                              value: autoProbe,
                              activeTrackColor: AppleColors.systemGreen,
                              onChanged: (v) =>
                                  setSheetState(() => autoProbe = v),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      errorMsg!,
                      style: const TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 204,
                      maxWidth: 248,
                    ),
                    child: AppleCapsuleButton(
                      key: const ValueKey('live-import-save-btn'),
                      label: editing == null ? '保存并导入' : '保存修改',
                      icon: CupertinoIcons.checkmark_alt,
                      primary: true,
                      onPressed: submit,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    nameCtrl.dispose();
    urlCtrl.dispose();
    textCtrl.dispose();
    uaCtrl.dispose();
    logoCtrl.dispose();
  }

  void _showLiveSourceManagerSheet() {
    showAppleModalSheet<void>(
      context: context,
      title: '独立直播源管理',
      maxWidth: 520,
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minSize: 28,
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(_showStandaloneLiveImportSheet());
        },
        child: const Text(
          '新增',
          style: TextStyle(color: AppleColors.systemBlue, fontSize: 13.5),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final items = widget.storage.getStandaloneLiveSources();
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  '暂无独立导入的直播源',
                  style: TextStyle(
                    color: ApplePalette.of(ctx).labelSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            );
          }
          return ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, idx) {
              final item = items[idx];
              final sheetPalette = ApplePalette.of(ctx);
              final sheetDark = sheetPalette.isDark;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: sheetDark ? const Color(0xFF242429) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: sheetDark
                        ? const Color(0x28FFFFFF)
                        : Colors.black.withValues(alpha: 0.08),
                    width: 0.65,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: sheetPalette.labelPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.url.isNotEmpty ? item.url : '本地/粘贴直播列表',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: sheetPalette.labelSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minSize: 28,
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        unawaited(_showStandaloneLiveImportSheet(editing: item));
                      },
                      child: Icon(
                        CupertinoIcons.pencil,
                        size: 18,
                        color: sheetPalette.accent,
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minSize: 28,
                      onPressed: () async {
                        await widget.storage.clearLiveSnapshot(item.toLiveSource());
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        final lives = _visibleLives;
                        final i = lives.indexWhere(
                          (l) => l.subscriptionId == 'standalone_live:${item.id}',
                        );
                        if (i >= 0) {
                          unawaited(_loadLivePlaylist(i, forceRefresh: true));
                        }
                      },
                      child: Icon(
                        CupertinoIcons.refresh,
                        size: 18,
                        color: sheetPalette.labelSecondary,
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minSize: 28,
                      onPressed: () async {
                        await widget.storage.deleteStandaloneLiveSource(item.id);
                        if (mounted) _reloadSavedConfig(bypassHomeSnapshot: true);
                        setSheetState(() {});
                      },
                      child: const Icon(
                        CupertinoIcons.trash,
                        color: AppleColors.systemRed,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildLiveChannelBadge(LiveChannel channel) =>
      LiveStationBadge(channel: channel);
  void _showWatchHistorySheet() {
    if (_privateSessionUnlocked) return;
    showAppleModalSheet<void>(
      context: context,
      title: '观看历史记录',
      maxWidth: 620,
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minSize: 28,
        onPressed: () async {
          if (widget.storage.getWatchHistory().isEmpty) {
            if (context.mounted) Navigator.of(context).pop();
            return;
          }
          if (_isIosNativeFlow) {
            final ok = await _confirmIosDestructiveAction(
              context,
              title: '清空全部观看历史？',
              message: '清空后将移除所有观看进度，收藏片单与订阅配置会保留。',
              confirmLabel: '清空全部',
            );
            if (!ok || !mounted) return;
          }
          await widget.storage.clearWatchHistory();
          if (mounted) setState(() {});
          if (context.mounted) Navigator.of(context).pop();
        },
        child: const Text(
          '清空全部',
          style: TextStyle(color: AppleColors.systemRed, fontSize: 13),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final history = widget.storage.getWatchHistory();
          if (history.isEmpty) {
            return Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text(
                  '暂无观看历史记录',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            );
          }
          final maxListHeight =
              (MediaQuery.sizeOf(ctx).height * 0.70).clamp(300.0, 580.0);
          final estimatedHeight = 46.0 + history.length * 102.0 + 36.0;
          final viewportHeight =
              estimatedHeight.clamp(160.0, maxListHeight).toDouble();
          return SizedBox(
            height: viewportHeight,
            child: AppleEdgeFade(
              axis: Axis.vertical,
              fadeWidth: 24,
              fadeStart: true,
              fadeEnd: true,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                cacheExtent: 420,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 26),
                itemCount: history.length + 1,
                separatorBuilder: (_, idx) =>
                    SizedBox(height: idx == 0 ? 8 : 10),
                itemBuilder: (ctx, idx) {
                  if (idx == 0) {
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        '提示：向左滑动单条记录可显示「删除」按钮',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelTertiary,
                          fontSize: 12,
                        ),
                      ),
                    );
                  }
                  final h = history[idx - 1];
                  final resolvedPoster = _resolveHistoryPoster(h);
                  return _SwipeToDeleteHistoryTile(
                    key: ValueKey('sheet_hist_${h.site}_${h.id}'),
                    entry: h,
                    posterUrl: resolvedPoster,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _openSyncedMediaEntry(
                        siteKey: h.site,
                        videoId: h.id,
                        title: h.title,
                        poster: resolvedPoster,
                      );
                    },
                    onDelete: () async {
                      await widget.storage.removeWatchHistoryItem(
                        h.site,
                        h.id,
                      );
                      setSheetState(() {});
                      if (mounted) setState(() {});
                      _showIosUndoHistoryBanner(
                        ctx,
                        h,
                        onRestored: () {
                          if (ctx.mounted) setSheetState(() {});
                        },
                      );
                    },
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFavoritesHistoryTab(
    BuildContext context, {
    required bool useSidebar,
  }) {
    final favorites =
        widget.storage.getFavorites(forPrivate: _privateSessionUnlocked);
    final history = _privateSessionUnlocked
        ? const <WatchHistoryEntry>[]
        : _cachedWatchHistory;
    final viewport = AppleViewportLayout.of(context);
    final pad = viewport.horizontalPadding(useSidebar: useSidebar);
    return SafeArea(
      bottom: useSidebar,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          pad,
          _isMacOS ? 38 : 14,
          pad,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _privateSessionUnlocked ? '隐私片库' : '我的片库',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: viewport.isCompactSplit ? 23 : 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (!_privateSessionUnlocked && _librarySegment != 2)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: CupertinoButton(
                      key: const ValueKey('library-open-cloud-sync'),
                      padding: EdgeInsets.zero,
                      minSize: 28,
                      onPressed: () =>
                          _openCloudSyncCenter(iosBackLabel: '片库'),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.cloud,
                            color: AppleColors.systemBlue,
                            size: 16,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '多端同步',
                            style: TextStyle(
                              color: AppleColors.systemBlue,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_librarySegment == 2 &&
                    DownloadService.instance.canOpenFolder &&
                    DownloadService.instance.rootPath.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 28,
                    onPressed: DownloadService.instance.openFolder,
                    child: const Text(
                      '打开文件夹',
                      style: TextStyle(
                        color: AppleColors.systemBlue,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (_librarySegment == 1 &&
                    !_privateSessionUnlocked &&
                    history.isNotEmpty)
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 28,
                    onPressed: () async {
                      if (_isIosNativeFlow) {
                        final ok = await _confirmIosDestructiveAction(
                          context,
                          title: '清空全部观看历史？',
                          message: '清空后将移除所有观看进度，收藏片单与订阅配置会保留。',
                          confirmLabel: '清空记录',
                        );
                        if (!ok || !mounted) return;
                      }
                      await widget.storage.clearWatchHistory();
                      if (mounted) setState(() {});
                    },
                    child: const Text(
                      '清空记录',
                      style: TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: IosNativeSegmentedControl(
                segments: const ['收藏片单', '观看历史', '离线下载'],
                selectedIndex: _librarySegment,
                onChanged: (v) => setState(() => _librarySegment = v),
                fallback: CupertinoSlidingSegmentedControl<int>(
                  backgroundColor: ApplePalette.of(context).fill,
                  thumbColor: ApplePalette.of(context).isDark
                      ? const Color(0xFF636366)
                      : Colors.white,
                  groupValue: _librarySegment,
                  children: {
                    0: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Text(
                        '收藏片单',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    1: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Text(
                        '观看历史',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    2: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Text(
                        '离线下载',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  },
                  onValueChanged: (v) {
                    if (v != null) setState(() => _librarySegment = v);
                  },
                ),
              ),
            ),
            SizedBox(height: 16),
            if (_librarySegment == 2)
              Expanded(child: _buildDownloadsList(useSidebar: useSidebar))
            else
            Expanded(
              child: _librarySegment == 0
                  ? (favorites.isEmpty
                      ? Center(
                          child: Text(
                            _privateSessionUnlocked
                                ? '隐私片库还没有收藏任何影片'
                                : '还没有收藏任何影片',
                            style: TextStyle(
                              color: ApplePalette.of(context).labelSecondary,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: EdgeInsets.only(
                            bottom: useSidebar ? 24 : 124,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: viewport.posterGridExtent(
                              useSidebar: useSidebar,
                            ),
                            mainAxisSpacing: 16,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.56,
                          ),
                          itemCount: favorites.length,
                          itemBuilder: (ctx, i) {
                            final fav = favorites[i];
                            final sitePool = _visibleSupportedSites;
                            CmsSite? matched;
                            for (final s in sitePool) {
                              if (s.key == fav.site) {
                                matched = s;
                                break;
                              }
                            }
                            final displaySite = matched ??
                                CmsSite(
                                  key: fav.site,
                                  name: fav.site,
                                  type: 1,
                                  api: '',
                                  isPrivate: _privateSessionUnlocked,
                                );
                            final card = _buildVideoCard(
                              displaySite,
                              CmsVideo(
                                id: fav.id,
                                title: fav.title,
                                poster: fav.poster,
                                remarks: fav.remarks,
                              ),
                              cardIdPrefix: 'fav_$i',
                              onTapWithSource: (posterCtx, radius, cardId) =>
                                  _openSyncedMediaEntry(
                                siteKey: fav.site,
                                videoId: fav.id,
                                title: fav.title,
                                poster: fav.poster,
                                remarks: fav.remarks,
                                sourceContext: posterCtx,
                                sourceRadius: radius,
                                sourceCardId: cardId,
                              ),
                            );
                            return (matched != null && !matched.supported)
                                ? Opacity(opacity: 0.55, child: card)
                                : card;
                          },
                        ))
                  : (_privateSessionUnlocked
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.eye_slash_fill,
                                color: Color(0xFFA78BFA),
                                size: 42,
                              ),
                              SizedBox(height: 12),
                              Text(
                                '隐私模式不保留任何观看历史记录',
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 6),
                              Text(
                                '隐私分组中的播放进度、搜索与收藏均与正常模式完全隔离',
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        )
                      : (history.isEmpty
                          ? Center(
                              child: Text(
                                '暂无观看历史',
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelSecondary,
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: EdgeInsets.only(
                                bottom: useSidebar ? 24 : 124,
                              ),
                              itemCount: history.length + 1,
                              separatorBuilder: (_, __) =>
                                  SizedBox(height: 8),
                              itemBuilder: (ctx, idx) {
                                if (idx == 0) {
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      left: 4,
                                      bottom: 2,
                                    ),
                                    child: Text(
                                      '提示：向左滑动单条记录可显示「删除」按钮',
                                      style: TextStyle(
                                        color: ApplePalette.of(context).labelTertiary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  );
                                }
                                final h = history[idx - 1];
                                final resolvedPoster = _resolveHistoryPoster(h);
                                final histCardId =
                                    'lib_hist_${h.site}_${h.id}_$idx';
                                return _SwipeToDeleteHistoryTile(
                                  key: ValueKey('lib_hist_${h.site}_${h.id}'),
                                  entry: h,
                                  posterUrl: resolvedPoster,
                                  sourceCardId: histCardId,
                                  onTap: () => _openSyncedMediaEntry(
                                    siteKey: h.site,
                                    videoId: h.id,
                                    title: h.title,
                                    poster: resolvedPoster,
                                  ),
                                  onTapWithSource: (posterCtx, radius, cardId) =>
                                      _openSyncedMediaEntry(
                                    siteKey: h.site,
                                    videoId: h.id,
                                    title: h.title,
                                    poster: resolvedPoster,
                                    sourceContext: posterCtx,
                                    sourceRadius: radius,
                                    sourceCardId: cardId,
                                  ),
                                  onDelete: () async {
                                    await widget.storage.removeWatchHistoryItem(
                                      h.site,
                                      h.id,
                                    );
                                    if (mounted) setState(() {});
                                    if (ctx.mounted) {
                                      _showIosUndoHistoryBanner(ctx, h);
                                    }
                                  },
                                );
                              },
                            ))),
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildDownloadsList({required bool useSidebar}) {
    final service = DownloadService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        if (!service.isReady) {
          return Center(
            child: Text(
              '当前设备暂不支持离线下载',
              style: TextStyle(color: ApplePalette.of(context).labelSecondary, fontSize: 14),
            ),
          );
        }
        final tasks = service.tasks;
        if (tasks.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.arrow_down_circle,
                  color: ApplePalette.of(context).labelTertiary,
                  size: 46,
                ),
                SizedBox(height: 12),
                Text(
                  '还没有下载任何影片',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '在影片详情页点击「下载」，即可在没有网络时观看',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          );
        }
        final active = service.activeCount;
        final hasPaused = tasks.any((t) => t.status == DownloadStatus.paused);
        return ListView(
          padding: EdgeInsets.only(bottom: useSidebar ? 24 : 124),
          children: [
            if (active > 0 || hasPaused)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Row(
                  children: [
                    Text(
                      active > 0 ? '$active 个任务进行中' : '下载已暂停',
                      style: TextStyle(
                        color: ApplePalette.of(context).labelSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 26,
                      onPressed:
                          active > 0 ? service.pauseAll : service.resumeAll,
                      child: Text(
                        active > 0 ? '全部暂停' : '全部继续',
                        style: const TextStyle(
                          color: AppleColors.systemBlue,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            AppleGroupedSection(
              children: [for (final t in tasks) _buildDownloadRow(t)],
            ),
            if (service.rootPath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  '保存位置：${service.rootPath}',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
  Widget _buildDownloadRow(DownloadTask t) {
    final service = DownloadService.instance;
    final done = t.status == DownloadStatus.completed;
    final failed = t.status == DownloadStatus.failed;
    final statusColor = failed
        ? AppleColors.systemRed
        : (done ? AppleColors.systemGreen : ApplePalette.of(context).labelSecondary);
    IconData actionIcon;
    VoidCallback action;
    if (done) {
      actionIcon = CupertinoIcons.play_circle_fill;
      action = () => _playDownloaded(t);
    } else if (t.status == DownloadStatus.paused || failed) {
      actionIcon = CupertinoIcons.arrow_clockwise_circle;
      action = () => service.resume(t.id);
    } else {
      actionIcon = CupertinoIcons.pause_circle;
      action = () => service.pause(t.id);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: done ? () => _playDownloaded(t) : null,
        highlightColor: Colors.white10,
        splashColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  width: 40,
                  height: 56,
                  child: PosterImage(
                    url: t.poster,
                    title: t.title,
                    placeholder: _buildPosterPlaceholder(),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ApplePalette.of(context).labelPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '${t.episodeName} · ${t.lineName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ApplePalette.of(context).labelSecondary,
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(height: 6),
                    if (!done) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: t.status == DownloadStatus.queued &&
                                  t.progress <= 0
                              ? null
                              : t.progress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: ApplePalette.of(context).fill,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            failed
                                ? AppleColors.systemRed
                                : AppleColors.systemBlue,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      DownloadService.statusLabel(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: statusColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 6),
              CupertinoButton(
                padding: const EdgeInsets.all(4),
                minSize: 34,
                onPressed: action,
                child: Icon(
                  actionIcon,
                  size: 27,
                  color: done
                      ? ApplePalette.of(context).labelPrimary
                      : AppleColors.systemBlue,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.all(4),
                minSize: 34,
                onPressed: () => _confirmDeleteDownload(t),
                child: Icon(
                  CupertinoIcons.trash,
                  size: 19,
                  color: ApplePalette.of(context).labelTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  void _confirmDeleteDownload(DownloadTask t) {
    unawaited(
      showAppleNativeAlert(
        context,
        title: '删除下载？',
        message: '「${t.title} · ${t.episodeName}」及已下载的文件将被删除。',
        actions: const [
          AppleNativeAlertAction(id: 'cancel', title: '取消', isCancel: true),
          AppleNativeAlertAction(
            id: 'delete',
            title: '删除',
            isDestructive: true,
          ),
        ],
      ).then((choice) {
        if (choice == 'delete') {
          DownloadService.instance.remove(t.id);
        }
      }),
    );
  }
  void _playDownloaded(DownloadTask t) {
    final completed = DownloadService.instance
        .completedFor(t.siteKey, t.videoId)
        .where((x) => x.lineName == t.lineName && x.filePath.isNotEmpty)
        .toList();
    if (completed.isEmpty) return;
    final start = completed.indexWhere((x) => x.id == t.id);
    final site = CmsSite(
      key: t.siteKey,
      name: t.siteName,
      type: t.siteType,
      api: t.siteApi,
    );
    final video = CmsVideo(
      id: t.videoId,
      title: t.title,
      poster: t.poster,
      lines: [
        CmsLine(
          name: t.lineName,
          episodes: [
            for (final x in completed)
              CmsEpisode(name: x.episodeName, url: x.filePath),
          ],
        ),
      ],
    );
    if (OhosRuntime.isOhos) {
      unawaited(
        _trackSecondaryRoute<void>(
          () => Navigator.of(context).push(
            buildApplePageRoute<void>(
              builder: (_) => PlayerScreen(
                site: site,
                video: video,
                initialLineIndex: 0,
                initialEpisodeIndex: start < 0 ? 0 : start,
                storage: widget.storage,
              ),
            ),
          ),
        ),
      );
    } else {
      unawaited(
        _trackSecondaryRoute<void>(
          () => pushPlayerRoute<void>(
            context: context,
            useFastWindowsMode: isWindowsDesktopUi,
            builder: (_) => PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: start < 0 ? 0 : start,
              storage: widget.storage,
            ),
          ),
        ),
      );
    }
  }
  String get _wallpaperPresetLabel => switch (widget.storage.wallpaperPreset) {
        'midnight' => '午夜深蓝',
        'aurora' => '极光紫韵',
        'amber' => '流金琥珀',
        'emerald' => '翡翠幽林',
        'custom' => '自定义壁纸',
        _ => '曜石纯黑',
      };

  String get _glassBlurLabel => switch (widget.storage.glassBlurLevel) {
        'light' => '轻盈通透',
        'deep' => '深邃毛玻璃',
        'solid' => '减少透明度',
        _ => '标准液态',
      };

  String get _gridDensityLabel => switch (widget.storage.gridDensity) {
        'comfortable' => '舒展大卡',
        'compact' => '紧凑多列',
        _ => '标准均衡',
      };

  String get _cardSubtitleModeLabel => switch (widget.storage.cardSubtitleMode) {
        'year_area' => '年份与地区',
        'site' => '所属片源名称',
        'none' => '极简隐藏',
        _ => '更新集数与备注',
      };

  String get _preferredQualityLabel => switch (widget.storage.preferredQuality) {
        '4k_netdisk' => '4K 超清原画优先',
        '1080p_direct' => '1080P 高清直连优先',
        'fast_hls' => '极速 M3U8 流媒体优先',
        _ => '站点默认顺序',
      };

  String get _defaultAspectLabel => switch (widget.storage.defaultAspectMode) {
        'cover' => '铺满裁剪',
        'fill' => '拉伸全屏',
        _ => '适应屏幕',
      };

  String get _skipIntroOutroSummary {
    final count = widget.storage.countVideoSkipRecords(
      forPrivate: _privateSessionUnlocked,
    );
    return count <= 0 ? '按影片独立记录' : '已记录 $count 部';
  }

  Widget _buildSettingsQuickActionRow({
    Key? key,
    required IconData icon,
    required Color iconBgColor,
    required String title,
    String? subtitle,
    String? trailingText,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final rowContent = ConstrainedBox(
      key: onTap == null ? key : null,
      constraints: const BoxConstraints(minHeight: 58),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                color: iconBgColor,
                shape: ContinuousRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                shadows: [
                  BoxShadow(
                    color: iconBgColor.withValues(alpha: 0.28),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Icon(icon, size: 17, color: Colors.white),
              ),
            ),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                      height: 1.28,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ApplePalette.of(context).labelSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.1,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (trailing != null)
              trailing
            else ...[
              if (trailingText != null && trailingText.isNotEmpty)
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 168),
                    child: Text(
                      trailingText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: ApplePalette.of(context).labelSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                Icon(
                  CupertinoIcons.chevron_forward,
                  size: 15,
                  color: Colors.white.withValues(alpha: 0.30),
                ),
              ],
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return rowContent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        onTap: onTap,
        highlightColor: Colors.white.withValues(alpha: 0.08),
        splashColor: Colors.white.withValues(alpha: 0.04),
        child: rowContent,
      ),
    );
  }

  /// Main Settings Tab (Level 1): Authentic iOS System Settings inset-grouped layout
  /// with vivid squircle badges, inline linear Liquid Glass refraction slider, and
  /// clean category navigation rows.
  Widget _buildSettingsTab(BuildContext context, {required bool useSidebar}) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return IosSettingsPage(
        pages: _iosSettingsPages,
        version: _currentAppVersion,
        onSecondaryRouteActive: (active) {
          _settingsSecondaryRouteActive = active;
          _syncRootTabVisibility(animated: true);
        },
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
    }
    final pad = useSidebar ? 28.0 : 16.0;
    final publicSites = _config?.publicSupportedSites ?? const [];
    return SafeArea(
      bottom: useSidebar,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              pad,
              _isMacOS ? 38 : 16,
              pad,
              useSidebar ? 36 : MediaQuery.paddingOf(context).bottom + 28,
            ),
            children: [
              Padding(
                padding: EdgeInsets.only(left: 4, bottom: 16),
                child: Text(
                  '设置',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              AppleGroupedSection(
                header: '核心偏好设置',
                children: [
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.paintbrush_fill,
                    iconBgColor: AppleColors.systemPurple,
                    title: '外观与视觉风格',
                    subtitle: '自定义影院主题配色、高清壁纸与毛玻璃档位',
                    trailingText: _wallpaperPresetLabel,
                    onTap: () => _openSettingsSubPage(
                      title: '外观与视觉风格',
                      subtitle: '自定义影院主题配色、动态流光背景与毛玻璃通透效果',
                      sectionBuilder: _buildAppearanceSettingsSection,
                    ),
                  ),
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.square_grid_2x2_fill,
                    iconBgColor: AppleColors.systemBlue,
                    title: '首页与排版布局',
                    subtitle: '设置海报列数密度、卡片副标题与首页推荐模块',
                    trailingText: _gridDensityLabel,
                    onTap: () => _openSettingsSubPage(
                      title: '首页与排版布局',
                      subtitle: '调整首页展示模块开关、海报列数密度与卡片副标题样式',
                      sectionBuilder: _buildLayoutSettingsSection,
                    ),
                  ),
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.play_rectangle_fill,
                    iconBgColor: AppleColors.systemOrange,
                    title: '播放与画质偏好',
                    subtitle: '设置默认优选画质、起播倍速与片头片尾自动跳过',
                    trailingText: _preferredQualityLabel,
                    onTap: () => _openSettingsSubPage(
                      title: '播放与画质偏好',
                      subtitle: '进入影视详情页与播放器时自动按首选画质、倍速与片头片尾规则起播',
                      sectionBuilder: _buildPlaybackSettingsSection,
                    ),
                  ),
                  AppleGroupedTile(
                    minHeight: 88,
                    icon: CupertinoIcons.folder_fill,
                    iconBgColor: AppleColors.systemGreen,
                    title: '订阅与数据维护',
                    subtitle: '网盘扫码登录、点播直播订阅源管理与缓存清理',
                    trailingText: '可用 ${publicSites.where((s) => s.supported).length} / 共 ${publicSites.length}',
                    onTap: () => _openSettingsSubPage(
                      title: '订阅与数据维护',
                      subtitle: '集中管理云盘扫码授权、点播与直播订阅源、多仓切换及跨端数据备份',
                      sectionBuilder: _buildCloudAndDataSettingsSection,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              AppleGroupedSection(
                header: '云盘与快捷工具',
                footer: isWindowsDesktopUi
                    ? '拖动滑块可实时调节全局界面面板通透度。'
                    : null,
                children: [
                  Builder(
                    builder: (context) {
                      final loggedCount = NetdiskService.drives
                          .where((d) => widget.storage.isNetdiskLoggedIn(d.key))
                          .length;
                      return _buildSettingsQuickActionRow(
                        icon: CupertinoIcons.qrcode_viewfinder,
                        iconBgColor: const Color(0xFF0A84FF),
                        title: '配置中心 · 多源网盘扫码与账号',
                        subtitle: '一次扫码多源通用，支持夸克 / UC / 百度 / 阿里与源配置中心直读',
                        trailingText:
                            loggedCount > 0 ? '已登录 $loggedCount 个' : '去扫码',
                        onTap: () {
                          final allSites =
                              _config?.publicSupportedSites ?? const <CmsSite>[];
                          showNetdiskAccountSheet(
                            context,
                            widget.storage,
                            sites: allSites,
                            activeGroup: _activeSite?.group ?? '',
                            onOpenCatPawSettings: allSites.any((s) => s.isCatPaw)
                                ? _showCatPawSettings
                                : null,
                            onChanged: () {
                              if (mounted) setState(() {});
                            },
                          );
                        },
                      );
                    },
                  ),
                  if (!isWindowsDesktopUi) _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.sparkles,
                    iconBgColor: AppleColors.systemIndigo,
                    title: '动态流光背景',
                    subtitle: '开启柔和极光背景与海报环境光晕',
                    trailing: CupertinoSwitch(
                      value: widget.storage.ambientGlowEnabled,
                      activeTrackColor: AppleColors.systemGreen,
                      onChanged: (v) async {
                        await widget.storage.setAmbientGlowEnabled(v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                  if (isWindowsDesktopUi)
                    _buildLiquidGlassSliderRow(() {
                      if (mounted) setState(() {});
                    }),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.cloud_fill,
                    iconBgColor: AppleColors.systemBlue,
                    title: '多端网络同步 (WebDAV / 局域网)',
                    subtitle: widget.storage.syncStatusSummary,
                    trailingText:
                        widget.storage.isWebdavConfigured ? '已配置' : '去设置',
                    onTap: () => _openCloudSyncCenter(),
                  ),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.cloud_upload_fill,
                    iconBgColor: AppleColors.systemTeal,
                    title: '跨平台备份与恢复',
                    subtitle: '导出或恢复全平台通用 JSON 备份配置',
                    trailingText: 'JSON 互通',
                    onTap: _showBackupRestoreDialog,
                  ),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.arrow_down_circle_fill,
                    iconBgColor: AppleColors.systemBlue,
                    title: '软件更新与版本',
                    subtitle: '检查最新版本更新与发行说明',
                    trailingText: 'v$_currentAppVersion',
                    onTap: _showUpdateCheckSheet,
                  ),
                  _buildSettingsQuickActionRow(
                    icon: CupertinoIcons.doc_plaintext,
                    iconBgColor: AppleColors.systemOrange,
                    title: '导出诊断日志包',
                    subtitle: '导出脱敏系统环境信息与最近 1MB 异常运行日志',
                    trailingText: '导出',
                    onTap: () => _exportDiagnosticsBundle(context),
                  ),
                  if (!OhosRuntime.isOhos)
                    _buildSettingsQuickActionRow(
                      icon: CupertinoIcons.sparkles,
                      iconBgColor: AppleColors.systemBlue,
                      title: '重新查看新手引导',
                      subtitle: '回顾自有配置导入、多端同步与播放手势指南',
                      trailingText: '重看',
                      onTap: () => _openOnboardingRoute(isReplay: true),
                    ),
                ],
              ),
              if (_isMacOS) ...[
                const SizedBox(height: 22),
                AppleGroupedSection(
                  key: const ValueKey('macos-settings-contact-section'),
                  header: '联系与反馈作者',
                  footer: MacosOfficialInfo.securityWarning,
                  children: [
                    _buildSettingsQuickActionRow(
                      key: const ValueKey('macos-settings-contact-author'),
                      icon: CupertinoIcons.bubble_left_bubble_right_fill,
                      iconBgColor: AppleColors.systemPink,
                      title: '联系反馈作者 · ${MacosOfficialInfo.authorSocialName}',
                      subtitle:
                          '${MacosOfficialInfo.socialPlatformsSummary}（全平台同名）',
                      trailingText: '查看 / 复制',
                      onTap: _showMacosAuthorContactSheet,
                    ),
                    _buildSettingsQuickActionRow(
                      key: const ValueKey('macos-settings-official-group'),
                      icon: CupertinoIcons.globe,
                      iconBgColor: AppleColors.systemBlue,
                      title: '官网交流群链接',
                      subtitle:
                          'Marco 官网：${MacosOfficialInfo.officialWebsiteDisplay}',
                      trailingText: '打开官网',
                      onTap: _openMacosOfficialWebsiteFromSettings,
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 22),
                AppleGroupedSection(
                  header: '联系反馈与官方交流',
                  footer: OfficialChannelInfo.antiTamperWarning,
                  children: [
                    Builder(
                      builder: (rowCtx) => _buildSettingsQuickActionRow(
                        key: const ValueKey('settings-author-socials'),
                        icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                        iconBgColor: AppleColors.systemPink,
                        title: '联系反馈作者（各社媒账号名）',
                        subtitle: OfficialChannelInfo.authorSocialSummary,
                        trailingText: '复制',
                        onTap: () =>
                            _copyAuthorSocialName(originContext: rowCtx),
                      ),
                    ),
                    Builder(
                      builder: (rowCtx) => _buildSettingsQuickActionRow(
                        key: const ValueKey('settings-official-community'),
                        icon: CupertinoIcons.chat_bubble_2_fill,
                        iconBgColor: AppleColors.systemGreen,
                        title: '官网交流群',
                        subtitle: OfficialChannelInfo.officialCommunityUrl,
                        trailingText: '打开官网',
                        onTap: () =>
                            _openOfficialCommunityLink(originContext: rowCtx),
                      ),
                    ),
                    _buildSettingsQuickActionRow(
                      key: const ValueKey('settings-official-notice'),
                      icon: CupertinoIcons.shield_lefthalf_fill,
                      iconBgColor: AppleColors.systemOrange,
                      title: '官方渠道安全声明',
                      subtitle:
                          '认准 Marco 官网 ${OfficialChannelInfo.officialWebsiteDisplay}',
                      trailingText: '查看',
                      onTap: _openOfficialNoticeDialogFromSettings,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showMacosAuthorContactSheet() {
    showAppleModalSheet<void>(
      context: context,
      title: '联系与反馈作者',
      builder: (_) => MacosAuthorContactSheet(
        onOpenUrl: widget.onOpenExternalUrlForTest,
        onCopyText: widget.onCopyTextForTest,
      ),
    );
  }

  Future<void> _openMacosOfficialWebsiteFromSettings() async {
    final opened = await openMacosOfficialUrl(
      MacosOfficialInfo.officialWebsiteUrl,
      onOpenUrl: widget.onOpenExternalUrlForTest,
    );
    if (opened || !mounted) return;
    if (widget.onCopyTextForTest != null) {
      await widget.onCopyTextForTest!(MacosOfficialInfo.officialWebsiteUrl);
    } else {
      await Clipboard.setData(
        const ClipboardData(text: MacosOfficialInfo.officialWebsiteUrl),
      );
    }
    if (!mounted) return;
    _showAppleNotice(
      '已复制官网地址',
      '请在浏览器中打开：${MacosOfficialInfo.officialWebsiteUrl}',
    );
  }

  Widget _buildLiquidGlassSliderRow(VoidCallback refreshBoth) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: GlassworkBackdrop.intensity,
        builder: (context, rawStrength, _) {
          final strength = rawStrength.clamp(0.0, 1.0);
          final pct = (strength * 100).round();
          if (usesWindowsAppearance(context)) {
            return Column(children: [
              WinSettingsRow(title: '面板通透度', subtitle: '调整界面面板，背景模糊可在背景与外观中单独设置',
                  value: '$pct%', icon: CupertinoIcons.drop),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Slider(
                key: const ValueKey('settings-liquid-glass-slider'), value: strength,
                onChanged: (v) { GlassworkBackdrop.intensity.value = v; GlassworkBackdrop.reduceTransparency.value = v <= .02; },
                onChangeEnd: (v) async { await widget.storage.setGlassBlurStrength(v); refreshBoth(); })),
            ]);
          }
          final levelLabel = strength < 0.05
              ? '关闭'
              : strength < 0.48
                  ? '轻柔'
                  : strength < 0.80
                      ? '标准'
                      : '深邃';
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color.alphaBlend(
                              const Color(0x28FFFFFF),
                              AppleColors.systemTeal,
                            ),
                            AppleColors.systemTeal,
                          ],
                        ),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(7.5),
                          side: const BorderSide(
                            color: Color(0x33FFFFFF),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: const SizedBox(
                        width: 30,
                        height: 30,
                        child: Icon(
                          CupertinoIcons.drop_fill,
                          color: Colors.white,
                          size: 17,
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '毛玻璃通透度',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                    Text(
                      '$pct% · $levelLabel',
                      style: TextStyle(
                        color: ApplePalette.of(context).labelSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      CupertinoIcons.drop,
                      size: 15,
                      color: ApplePalette.of(context).labelSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CupertinoSlider(
                        key: const ValueKey('settings-liquid-glass-slider'),
                        value: strength,
                        min: 0.0,
                        max: 1.0,
                        activeColor: AppleColors.systemBlue,
                        onChanged: (v) {
                          GlassworkBackdrop.intensity.value = v;
                          GlassworkBackdrop.reduceTransparency.value =
                              v <= 0.02;
                        },
                        onChangeEnd: (v) async {
                          await widget.storage.setGlassBlurStrength(v);
                          refreshBoth();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      CupertinoIcons.drop_fill,
                      size: 18,
                      color: AppleColors.systemBlue,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openSettingsSubPage({
    required String title,
    required String subtitle,
    required Widget Function(BuildContext context, VoidCallback refreshSubPage)
        sectionBuilder,
  }) {
    unawaited(
      _trackSecondaryRoute<void>(
        () => Navigator.of(context).push(
          buildApplePageRoute<void>(
            builder: (routeCtx) => StatefulBuilder(
              builder: (subCtx, setSubState) {
                void refreshBoth() {
                  if (subCtx.mounted) setSubState(() {});
                }

                if (usesWindowsAppearance(subCtx)) {
                  return WinSettingsScaffold(title: title, subtitle: subtitle,
                      child: sectionBuilder(subCtx, refreshBoth));
                }
                final topPad = MediaQuery.paddingOf(subCtx).top;
                final width = MediaQuery.sizeOf(subCtx).width;
                final hPad = width >= 720 ? 32.0 : 16.0;
                return Scaffold(
                  backgroundColor: ApplePalette.of(context).background,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      AppleAmbientBackground(
                        preset: widget.storage.wallpaperPreset,
                        showAmbientArtwork: widget.storage.ambientGlowEnabled,
                        blurSigma: 60,
                        animate: false,
                      ),
                      SafeArea(
                        child: RepaintBoundary(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 860),
                              child: ListView(
                                physics: const BouncingScrollPhysics(),
                                padding: EdgeInsets.fromLTRB(hPad, 58, hPad, 48),
                                children: [
                                  Text(
                                    title,
                                    style: TextStyle(
                                      color: ApplePalette.of(context).labelPrimary,
                                      fontSize: 25,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  SizedBox(height: 6),
                                  Text(
                                    subtitle,
                                    style: TextStyle(
                                      color: ApplePalette.of(context).labelSecondary,
                                      fontSize: 13,
                                      height: 1.45,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  sectionBuilder(subCtx, refreshBoth),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: topPad + 8,
                        left: hPad,
                        child: GestureDetector(
                          onTap: () => Navigator.of(subCtx).maybePop(),
                          child: AppleSettingsGlassCard(
                            borderRadius: BorderRadius.circular(999),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 8,
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  CupertinoIcons.chevron_back,
                                  color: AppleColors.systemBlue,
                                  size: 17,
                                ),
                                SizedBox(width: 3),
                                Text(
                                  '设置',
                                  style: TextStyle(
                                    color: AppleColors.systemBlue,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ).then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  Widget _buildAppearanceSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null)
          AppleGroupedSection(
            header: 'Windows 背景与外观',
            children: [AppleGroupedTile(
              icon: CupertinoIcons.photo,
              iconBgColor: AppleColors.systemPurple,
              title: '背景与外观',
              subtitle: '选择柔光预设、导入照片或调整界面明暗',
              onTap: () {
                if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                _updateWindowsState(() {
                  _windowsSettings = '背景与外观';
                  _windowsPage = 'settings';
                });
              },
            )],
          )
        else AppleGroupedSection(
          header: '壁纸与动态流光氛围',
          footer: '开启呼吸式动态流光后，背景极光色块将以约 8 秒周期柔和呼吸律动，并透过液态玻璃产生实时折射。',
          children: [
            _buildSettingDrawerContainer(
              settingKey: 'wallpaper_preset',
              icon: CupertinoIcons.photo_fill_on_rectangle_fill,
              iconBgColor: AppleColors.systemPurple,
              title: '背景壁纸与主题风格',
              subtitle: widget.storage.customWallpaperUrl.isNotEmpty
                  ? '已启用自定义高清壁纸'
                  : '选择暗黑影院主题底色或自定义壁纸',
              trailingText: _wallpaperPresetLabel,
              onStateChanged: refreshBoth,
              drawerChild: _buildWallpaperDrawerBody(onStateChanged: refreshBoth),
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.sparkles,
              iconBgColor: AppleColors.systemIndigo,
              title: '呼吸式流光氛围背景',
              subtitle: '渲染动态呼吸流光与海报主色调光晕',
              trailing: CupertinoSwitch(
                value: widget.storage.ambientGlowEnabled,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setAmbientGlowEnabled(v);
                  refreshBoth();
                },
              ),
            ),
          ],
        ),
        if (isWindowsDesktopUi) ...[
          const SizedBox(height: 22),
          AppleGroupedSection(
            header: '面板通透度',
            footer: '支持 0%–100% 连续调节，也可点击下方预设档位快速切换。',
            children: [
              _buildLiquidGlassSliderRow(refreshBoth),
              _buildExpandableChoiceDrawerTile<String>(
                settingKey: 'glass_blur',
                icon: CupertinoIcons.drop_fill,
                iconBgColor: AppleColors.systemBlue,
                title: '通透效果档位',
                subtitle: '快速切换四档磨砂与通透配置',
                trailingText: _glassBlurLabel,
                currentValue: widget.storage.glassBlurLevel,
                onStateChanged: refreshBoth,
                options: const [
                  ('light', '轻盈通透 (35%)', '轻量高斯模糊，保留更多背景色彩细节'),
                  ('standard', '标准液态 (68%)', '细腻边缘高光与背景折射'),
                  ('deep', '深邃毛玻璃 (100%)', '高浓度深邃磨砂，强化前景文字对比'),
                  ('solid', '减少透明度 (0%)', '使用实色面板，提升阅读清晰度'),
                ],
                onSelected: (val) async {
                  await widget.storage.setGlassBlurLevel(val);
                  GlassworkBackdrop.reduceTransparency.value = val == 'solid';
                  GlassworkBackdrop.intensity.value =
                      widget.storage.glassBlurStrength;
                  refreshBoth();
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<SettingsPane> _iosSettingsPages(VoidCallback refresh) {
    final storage = widget.storage;
    Widget choices<T>(
      String title,
      T value,
      List<(T, String)> values,
      Future<void> Function(T) save, {
      String? footer,
    }) =>
        SettingsChoices<T>(
          title: title,
          footer: footer,
          value: value,
          choices: values,
          onSelected: (v) async {
            await save(v);
            refresh();
          },
        );
    Widget toggleRow(
      String title,
      IconData icon,
      Color color,
      bool value,
      Future<void> Function(bool) save, {
      String? subtitle,
    }) =>
        IosSettingsSwitchRow(
          key: ValueKey('switch-$title'),
          icon: icon,
          iconColor: color,
          title: title,
          subtitle: subtitle,
          value: value,
          onChanged: (v) async {
            await save(v);
            refresh();
          },
        );
    Widget stack(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
    final sites = _config?.publicSupportedSites ?? const [];
    final publicSubs = storage
        .getSubscriptions()
        .where((s) => !s.isEffectivelyPrivate)
        .toList();
    final loggedDriveCount = NetdiskService.drives
        .where((d) => storage.isNetdiskLoggedIn(d.key))
        .length;
    final speedLabel = storage.playSpeed == storage.playSpeed.roundToDouble()
        ? '${storage.playSpeed.toInt()}×'
        : '${storage.playSpeed}×';
    return [
      SettingsPane(
        'appearance',
        '外观',
        '浅色白底与深色夜间，自动跟随系统切换',
        CupertinoIcons.circle_lefthalf_fill,
        AppleColors.systemPurple,
        sectionGroup: 'core',
        trailingText: AppleTheme.labelFor(storage.appThemeMode),
        content: stack([
          Builder(
            builder: (ctx) {
              final currentMode = storage.appThemeMode;
              return IosSettingsGroup(
                header: '主题模式',
                footer: '默认自动跟随手机系统的浅色 / 深色外观切换，也可手动固定为简约白底或深色夜间模式。',
                children: [
                  for (final opt in const [
                    (
                      'system',
                      '跟随系统',
                      '随手机日间 / 夜间模式自动切换',
                      CupertinoIcons.device_phone_portrait,
                      AppleColors.systemBlue,
                    ),
                    (
                      'light',
                      '简约白底',
                      '纯净浅色留白界面，日间阅读更通透',
                      CupertinoIcons.sun_max_fill,
                      AppleColors.systemOrange,
                    ),
                    (
                      'dark',
                      '深色夜间',
                      '低眩光暗色影院界面，夜间观影更护眼',
                      CupertinoIcons.moon_stars_fill,
                      AppleColors.systemIndigo,
                    ),
                  ])
                    IosSettingsChoiceTile(
                      key: ValueKey('choice-主题模式-${opt.$1}'),
                      label: opt.$2,
                      selected: currentMode == opt.$1,
                      onTap: () async {
                        await storage.setAppThemeMode(opt.$1);
                        AppleTheme.mode.value = AppleTheme.fromPref(opt.$1);
                        await IosLiquidGlassBridge.setAppearanceMode(opt.$1);
                        refresh();
                      },
                    ),
                ],
              );
            },
          ),
        ]),
      ),
      SettingsPane(
        'browsing',
        '浏览',
        '海报网格密度、副标题与主页模块',
        CupertinoIcons.square_grid_2x2_fill,
        AppleColors.systemBlue,
        sectionGroup: 'core',
        trailingText: _gridDensityLabel,
        children: [
          SettingsPane(
            'cards',
            '海报与卡片',
            '设置单行海报尺寸密度与副标题信息',
            CupertinoIcons.rectangle_grid_2x2_fill,
            AppleColors.systemBlue,
            trailingText: _gridDensityLabel,
            content: stack([
              choices(
                '海报密度',
                storage.gridDensity,
                const [
                  ('comfortable', '舒展'),
                  ('standard', '标准'),
                  ('compact', '紧凑'),
                ],
                storage.setGridDensity,
              ),
              choices(
                '卡片副标题',
                storage.cardSubtitleMode,
                const [
                  ('remarks', '更新与备注'),
                  ('year_area', '年份与地区'),
                  ('site', '所属片源'),
                  ('none', '隐藏'),
                ],
                storage.setCardSubtitleMode,
              ),
            ]),
          ),
          SettingsPane(
            'home',
            '首页板块与排序',
            '单独开关首页各板块并自定义展示顺序',
            CupertinoIcons.house_fill,
            AppleColors.systemOrange,
            content: _buildIosHomeSectionsSettingsBody(refresh),
          ),
        ],
      ),
      SettingsPane(
        'playback',
        '播放',
        '默认优选画质、倍速与片头片尾跳过',
        CupertinoIcons.play_circle_fill,
        AppleColors.systemOrange,
        sectionGroup: 'core',
        trailingText: speedLabel,
        children: [
          SettingsPane(
            'picture',
            '画质与画面',
            '播放内核（AVPlayer/MPV）、HDR 色调映射、人声响度与超分',
            CupertinoIcons.tv_fill,
            AppleColors.systemPurple,
            trailingText:
                '${IosPlaybackEngineMode.fromId(storage.iosPlaybackEngineMode).shortLabel} · $_defaultAspectLabel',
            content: stack([
              IosPlaybackEngineSettingsSection(
                storage: storage,
                onChanged: refresh,
              ),
              const SizedBox(height: 20),
              choices(
                '画质与线路',
                storage.preferredQuality,
                const [
                  ('4k_netdisk', '4K 原画优先'),
                  ('1080p_direct', '1080P 直连'),
                  ('fast_hls', '极速流媒体'),
                  ('default', '站点默认'),
                ],
                (v) async {
                  await storage.setAutoHardwareQualityEnabled(false);
                  await storage.setPreferredQuality(v);
                },
              ),
              choices(
                '画面比例',
                storage.defaultAspectMode,
                const [
                  ('contain', '适应屏幕'),
                  ('cover', '铺满裁剪'),
                  ('fill', '拉伸全屏'),
                ],
                storage.setDefaultAspectMode,
              ),
              choices(
                '解码偏好',
                storage.playerKernel,
                const [
                  ('ijk', '自动解码'),
                  ('exo', 'Apple 硬件优先'),
                ],
                (v) async {
                  await storage.setAutoHardwareQualityEnabled(false);
                  await storage.setPlayerKernel(v);
                },
              ),
            ]),
          ),
          SettingsPane(
            'episodes',
            '倍速与选集',
            (!kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.iOS &&
                    !OhosRuntime.isOhos)
                ? '起播倍速、连播与时钟显示'
                : '起播倍速、剧集排序、连播与时钟显示',
            CupertinoIcons.speedometer,
            AppleColors.systemOrange,
            trailingText: speedLabel,
            content: stack([
              choices(
                '起播倍速',
                storage.playSpeed,
                const [
                  (0.75, '0.75×'),
                  (1.0, '1×'),
                  (1.25, '1.25×'),
                  (1.5, '1.5×'),
                  (2.0, '2×'),
                ],
                storage.setPlaySpeed,
              ),
              if (kIsWeb ||
                  defaultTargetPlatform != TargetPlatform.iOS ||
                  OhosRuntime.isOhos)
                choices(
                  '剧集排序',
                  storage.episodesDescending,
                  const [(false, '正序'), (true, '倒序')],
                  storage.setEpisodesDescending,
                ),
              IosSettingsGroup(
                header: '连续播放与时钟',
                children: [
                  toggleRow(
                    '自动播放下一集',
                    CupertinoIcons.forward_end_fill,
                    AppleColors.systemGreen,
                    storage.autoNext,
                    storage.setAutoNext,
                  ),
                  toggleRow(
                    '播放页常显时间',
                    CupertinoIcons.clock_fill,
                    AppleColors.systemTeal,
                    storage.playerAlwaysShowClock,
                    storage.setPlayerAlwaysShowClock,
                  ),
                ],
              ),
            ]),
          ),
          SettingsPane(
            'skip',
            '片头与片尾',
            '设置点播剧集自动跳过片头片尾秒数',
            CupertinoIcons.forward_fill,
            AppleColors.systemIndigo,
            trailingText: _skipIntroOutroSummary,
            content: IosSettingsGroup(
              header: '自动跳过时长',
              footer: '仅对点播剧集生效，电视直播频道将自动保持实时播放。',
              dividerIndent: 18,
              children: [
                _buildSkipIntroOutroDrawerBody(onStateChanged: refresh),
              ],
            ),
          ),
          if (!OhosRuntime.isOhos)
            SettingsPane(
              'danmu',
              '弹幕设置',
              '分片弹幕开关、显示类型、兼容服务源与屏蔽词',
              CupertinoIcons.chat_bubble_text_fill,
              AppleColors.systemTeal,
              content: IosDanmuSettingsSection(onChanged: refresh),
            ),
          if (!OhosRuntime.isOhos)
            SettingsPane(
              'hud',
              '播放界面与手势',
              '起播规格提示、细进度条、跳过倒计时与双击手势',
              CupertinoIcons.hand_draw_fill,
              AppleColors.systemBlue,
              content: IosPlayerHudSettingsSection(onChanged: refresh),
            ),
        ],
      ),
      SettingsPane(
        'sources',
        '订阅与账号',
        '点播直播源管理与 4K 网盘扫码授权',
        CupertinoIcons.layers_alt_fill,
        AppleColors.systemGreen,
        sectionGroup: 'account',
        trailingText: '${publicSubs.length} 订阅',
        content: stack([
          IosSettingsGroup(
            header: '片源与订阅管理',
            footer: '支持 JSON 单仓/多仓、MacCMS 接口以及 M3U/TXT 直播源批量导入与分组。',
            children: [
              IosSettingsRow(
                key: const ValueKey('ios-open-subscriptions'),
                icon: CupertinoIcons.folder_fill,
                iconColor: AppleColors.systemBlue,
                title: '订阅源与分组管理',
                trailingText: '${publicSubs.length} 个',
                showChevron: true,
                onTap: () async {
                  await _showSubscriptionManagerSheet(
                    iosBackLabel: '订阅与账号',
                  );
                  refresh();
                },
              ),
              IosSettingsRow(
                key: const ValueKey('ios-open-import-subscription'),
                icon: CupertinoIcons.plus_app_fill,
                iconColor: AppleColors.systemGreen,
                title: '添加资源库',
                showChevron: true,
                onTap: () async {
                  await _showImportConfigDialog(iosBackLabel: '订阅与账号');
                  refresh();
                },
              ),
              IosSettingsRow(
                key: const ValueKey('ios-open-cloud-sync-shortcut'),
                icon: CupertinoIcons.cloud_fill,
                iconColor: AppleColors.systemTeal,
                title: '多端网络同步（含订阅源同步）',
                trailingText: storage.isWebdavConfigured ? '已配置' : '设置',
                showChevron: true,
                onTap: () async {
                  await _openCloudSyncCenter(iosBackLabel: '订阅与账号');
                  refresh();
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          IosSettingsGroup(
            header: '云盘账号与扩展',
            footer: '绑定夸克、UC、百度或阿里云盘后，自动解锁对应 4K 原画直连线路。',
            children: [
              IosSettingsRow(
                key: const ValueKey('ios-open-netdisk'),
                icon: CupertinoIcons.qrcode,
                iconColor: AppleColors.systemIndigo,
                title: '配置中心',
                trailingText:
                    loggedDriveCount > 0 ? '已登录 $loggedDriveCount 个' : '未登录',
                showChevron: true,
                onTap: () => showNetdiskAccountSheet(
                  context,
                  storage,
                  iosBackLabel: '订阅与账号',
                  sites: sites,
                  activeGroup: _activeSite?.group ?? '',
                  onOpenCatPawSettings: sites.any((site) => site.isCatPaw)
                      ? _showCatPawSettings
                      : null,
                  onChanged: refresh,
                ),
              ),
              if (sites.any((site) => site.isCatPaw))
                IosSettingsRow(
                  icon: CupertinoIcons.slider_horizontal_3,
                  iconColor: AppleColors.systemOrange,
                  title: 'CatPaw 本机配置',
                  showChevron: true,
                  onTap: _showCatPawSettings,
                ),
            ],
          ),
        ]),
      ),
      SettingsPane(
        'extensions',
        '蜘蛛扩展与网关',
        '热插拔脚本扩展包与自建局域网网关兜底（适配 .so 线路）',
        CupertinoIcons.cube_box_fill,
        AppleColors.systemIndigo,
        sectionGroup: 'account',
        trailingText: SpiderPluginRegistry.instance.gatewayConfig.isActive
            ? '网关已开启'
            : (SpiderPluginRegistry.instance.enabledPackCount > 0
                ? '${SpiderPluginRegistry.instance.enabledPackCount} 扩展包'
                : '本机模式'),
        content: SpiderExtensionsPanel(
          storage: storage,
          client: widget.client,
          sites: sites,
          onChanged: () {
            _reloadSavedConfig();
            refresh();
          },
          onNotice: _showAppleNotice,
        ),
      ),
      SettingsPane(
        'data',
        '数据',
        'WebDAV 云同步、备份恢复与缓存清理',
        CupertinoIcons.tray_fill,
        AppleColors.systemTeal,
        sectionGroup: 'account',
        trailingText: storage.isWebdavConfigured ? '云同步已开启' : null,
        children: [
          SettingsPane(
            'sync',
            '多端网络同步',
            storage.syncStatusSummary,
            CupertinoIcons.cloud_fill,
            AppleColors.systemBlue,
            trailingText: storage.isWebdavConfigured ? '已配置' : '设置',
            content: CloudSyncSettingsPanel(
              storage: storage,
              embeddedInList: true,
              onSynced: ({required subscriptionsChanged}) {
                if (subscriptionsChanged) {
                  _reloadSavedConfig();
                }
                refresh();
              },
              onNotice: _showAppleNotice,
            ),
          ),
          SettingsPane(
            'backup',
            '备份与恢复',
            '导入或导出跨平台 JSON 备份文件',
            CupertinoIcons.arrow_2_circlepath,
            AppleColors.systemGreen,
            content: _IosBackupRestorePanel(
              storage: storage,
              onRestored: () {
                _reloadSavedConfig();
                refresh();
              },
              onNotice: _showAppleNotice,
            ),
          ),
          SettingsPane(
            'cache',
            '缓存与搜索记录',
            '媒体分块落盘缓存、HLS 点播去广告与海报搜索清理',
            CupertinoIcons.trash_fill,
            AppleColors.systemRed,
            trailingText: PosterLoader.memoryCacheSizeLabel,
            content: stack([
              if (!OhosRuntime.isOhos) ...[
                IosMediaCacheAndAdSection(
                  storage: storage,
                  onChanged: refresh,
                ),
                const SizedBox(height: 24),
              ],
              IosSettingsGroup(
                header: '存储概览',
                footer: '清理海报缓存和当前空间的搜索历史，不会删除收藏和观看记录。',
                children: [
                  IosSettingsRow(
                    icon: CupertinoIcons.photo_on_rectangle,
                    iconColor: AppleColors.systemBlue,
                    title: '海报内存缓存',
                    trailingText: PosterLoader.memoryCacheSizeLabel,
                  ),
                  IosSettingsRow(
                    icon: CupertinoIcons.search,
                    iconColor: AppleColors.systemTeal,
                    title: '搜索记录',
                    trailingText:
                        '${storage.getSearchHistory(forPrivate: _privateSessionUnlocked).length} 条',
                  ),
                ],
              ),
              const SizedBox(height: 24),
              IosSettingsGroup(
                dividerIndent: 18,
                children: [
                  IosSettingsRow(
                    key: const ValueKey('ios-clear-cache-row'),
                    title: '清理缓存与搜索记录',
                    titleColor: AppleColors.systemRed,
                    onTap: () async {
                      await PosterLoader.clearCache();
                      await storage.clearSearchHistory(
                        forPrivate: _privateSessionUnlocked,
                      );
                      refresh();
                      if (!mounted) return;
                      await showAppleNativeAlert(
                        context,
                        title: '缓存已清理',
                        message: '已清空海报缓存与搜索记录。',
                        actions: const [
                          AppleNativeAlertAction(
                            id: 'ok',
                            title: '好的',
                            isDefault: true,
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ]),
          ),
        ],
      ),
      SettingsPane(
        'about',
        '关于与更新',
        '版本信息、联系反馈（${OfficialChannelInfo.authorSocialName}）、官网交流群与更新检查',
        CupertinoIcons.info_circle_fill,
        AppleColors.systemIndigo,
        sectionGroup: 'about',
        content: stack([
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 24),
            child: Center(
              child: MarcoBrandLogo(iconSize: 52, fontSize: 22),
            ),
          ),
          IosSettingsGroup(
            header: '关于本机应用',
            dividerIndent: 18,
            children: [
              const IosSettingsRow(
                title: '应用名称',
                trailingText: 'Marco Movie',
              ),
              IosSettingsRow(
                key: const ValueKey('ios-about-version'),
                title: '版本',
                trailingText: _currentAppVersion,
              ),
              IosSettingsRow(
                title: '导出诊断日志包',
                onTap: () => _exportDiagnosticsBundle(context),
              ),
              if (!OhosRuntime.isOhos)
                IosSettingsRow(
                  key: const ValueKey('ios-replay-onboarding'),
                  icon: CupertinoIcons.sparkles,
                  iconColor: AppleColors.systemBlue,
                  title: '重新查看新手引导',
                  showChevron: true,
                  onTap: () => _openOnboardingRoute(isReplay: true),
                ),
            ],
          ),
          const SizedBox(height: 24),
          IosSettingsGroup(
            header: '联系反馈与官方交流',
            footer: OfficialChannelInfo.antiTamperWarning,
            dividerIndent: 18,
            children: [
              Builder(
                builder: (rowCtx) => IosSettingsRow(
                  key: const ValueKey('ios-settings-author-socials'),
                  icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                  iconColor: AppleColors.systemPink,
                  title: '联系反馈作者（各社媒账号名）',
                  subtitle: OfficialChannelInfo.authorSocialSummary,
                  subtitleMaxLines: 2,
                  trailingText: '复制',
                  onTap: () => _copyAuthorSocialName(originContext: rowCtx),
                ),
              ),
              Builder(
                builder: (rowCtx) => IosSettingsRow(
                  key: const ValueKey('ios-settings-official-community'),
                  icon: CupertinoIcons.chat_bubble_2_fill,
                  iconColor: AppleColors.systemGreen,
                  title: '官网交流群',
                  subtitle: OfficialChannelInfo.officialCommunityUrl,
                  showChevron: true,
                  onTap: () =>
                      _openOfficialCommunityLink(originContext: rowCtx),
                ),
              ),
              IosSettingsRow(
                key: const ValueKey('ios-settings-official-notice'),
                icon: CupertinoIcons.shield_lefthalf_fill,
                iconColor: AppleColors.systemOrange,
                title: '官方渠道安全声明',
                subtitle:
                    '认准官网 ${OfficialChannelInfo.officialWebsiteDisplay}',
                showChevron: true,
                onTap: _openOfficialNoticeDialogFromSettings,
              ),
            ],
          ),
          const SizedBox(height: 24),
          IosUpdateSheet(
            installedVersion: _currentAppVersion,
            embedded: true,
            autoCheck: false,
          ),
        ]),
      ),
    ];
  }

  Widget _buildLayoutSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '海报网格与卡片信息',
          children: [
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'grid_density',
              icon: CupertinoIcons.square_grid_3x2_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '海报网格排版密度',
              subtitle: '选择舒展大卡、标准均衡或紧凑多列',
              trailingText: _gridDensityLabel,
              currentValue: widget.storage.gridDensity,
              onStateChanged: refreshBoth,
              options: const [
                ('comfortable', '舒展大卡', '减少单行卡片列数，放大海报尺寸与视觉呼吸感'),
                ('standard', '标准均衡', '默认黄金比例网格密度，兼顾浏览视野与效率'),
                ('compact', '紧凑多列', '同屏展示更多海报卡片，适合快速浏览检索'),
              ],
              onSelected: (val) async {
                await widget.storage.setGridDensity(val);
                refreshBoth();
              },
            ),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'card_subtitle',
              icon: CupertinoIcons.text_badge_checkmark,
              iconBgColor: AppleColors.systemIndigo,
              title: '影视卡片副标题展示',
              subtitle: '选择海报下方展示的辅助信息类型',
              trailingText: _cardSubtitleModeLabel,
              currentValue: widget.storage.cardSubtitleMode,
              onStateChanged: refreshBoth,
              options: const [
                ('remarks', '更新集数与备注', '展示「更新至第X集 / 4K / HD中字」等状态信息'),
                ('year_area', '年份与地区', '展示「2026 · 中国大陆」等发行年份与地区'),
                ('site', '所属片源名称', '展示当前影片所属的订阅源站点名称'),
                ('none', '极简隐藏', '仅展示影片标题，隐藏下方副标题行'),
              ],
              onSelected: (val) async {
                await widget.storage.setCardSubtitleMode(val);
                refreshBoth();
              },
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '首页板块与排序',
          children: [
            AppleGroupedTile(
              icon: CupertinoIcons.rectangle_on_rectangle_angled,
              iconBgColor: AppleColors.systemOrange,
              title: '沉浸首推海报',
              subtitle: '在首页顶部展示全幅高清推荐海报横幅',
              trailing: CupertinoSwitch(
                value: widget.storage.showHeroBanner,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setShowHeroBanner(v);
                  refreshBoth();
                },
              ),
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.play_rectangle_fill,
              iconBgColor: AppleColors.systemGreen,
              title: '历史记录（默认关闭）',
              subtitle: '在首页展示最近观看进度以便一键续播',
              trailing: CupertinoSwitch(
                value: widget.storage.showContinueWatching,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setShowContinueWatching(v);
                  refreshBoth();
                },
              ),
            ),
            for (final meta in _homeSectionMetas)
              if (meta.id != StorageService.homeSectionHistory)
                AppleGroupedTile(
                  icon: meta.icon,
                  iconBgColor: meta.color,
                  title: meta.title,
                  subtitle: meta.subtitle,
                  trailing: CupertinoSwitch(
                    value: widget.storage.isHomeSectionEnabled(meta.id),
                    activeTrackColor: AppleColors.systemGreen,
                    onChanged: (v) async {
                      await widget.storage.setHomeSectionEnabled(meta.id, v);
                      refreshBoth();
                    },
                  ),
                ),
          ],
        ),
      ],
    );
  }

  static const List<({String id, String title, String subtitle, IconData icon, Color color})>
      _homeSectionMetas = [
    (
      id: StorageService.homeSectionHistory,
      title: '历史记录',
      subtitle: '最近观看进度与续播卡片（默认关闭）',
      icon: CupertinoIcons.clock_fill,
      color: AppleColors.systemBlue,
    ),
    (
      id: StorageService.homeSectionWidescreenRadar,
      title: '光影风向标',
      subtitle: '16:9 横版宽银幕热点剧影推荐',
      icon: CupertinoIcons.film_fill,
      color: AppleColors.systemIndigo,
    ),
    (
      id: StorageService.homeSectionEditorialPicks,
      title: '月度策划',
      subtitle: '藤蔓装饰主题合集大卡（剧集 / 综艺 / 口碑）',
      icon: CupertinoIcons.sparkles,
      color: AppleColors.systemTeal,
    ),
    (
      id: StorageService.homeSectionHotStream,
      title: '热播剧影榜',
      subtitle: '2:3 竖版精排热播榜单',
      icon: CupertinoIcons.flame_fill,
      color: AppleColors.systemOrange,
    ),
    (
      id: StorageService.homeSectionMoodCapsules,
      title: '灵感片单',
      subtitle: '斜叠迷你影票情绪与题材分组',
      icon: CupertinoIcons.collections_solid,
      color: AppleColors.systemPink,
    ),
    (
      id: StorageService.homeSectionStudioGalleries,
      title: '影业档案室',
      subtitle: 'Disney+ / MARVEL / DC 品牌折扇卡',
      icon: CupertinoIcons.rectangle_stack_fill,
      color: AppleColors.systemPurple,
    ),
    (
      id: StorageService.homeSectionPosterMosaics,
      title: '口碑典藏馆',
      subtitle: '三排交错海报墙马赛克专题',
      icon: CupertinoIcons.square_grid_3x2_fill,
      color: AppleColors.systemGreen,
    ),
    (
      id: StorageService.homeSectionSourceUpdates,
      title: '片源最新更新',
      subtitle: '当前已选片源的最新片库与分类筛选栏',
      icon: CupertinoIcons.layers_alt_fill,
      color: AppleColors.systemRed,
    ),
  ];

  Widget _buildIosHomeSectionsSettingsBody(VoidCallback refresh) {
    final storage = widget.storage;
    final orderedIds = storage.homeSectionOrder;
    final metaById = {for (final m in _homeSectionMetas) m.id: m};
    final palette = ApplePalette.of(context);

    Future<void> moveSection(int index, int delta) async {
      final target = index + delta;
      if (target < 0 || target >= orderedIds.length) return;
      final next = List<String>.of(orderedIds);
      final moved = next.removeAt(index);
      next.insert(target, moved);
      await storage.setHomeSectionOrder(next);
      HapticFeedback.selectionClick();
      refresh();
    }

    return Column(
      key: const ValueKey('ios-home-sections-settings-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSettingsGroup(
          header: '顶部沉浸首推',
          footer: '控制首页顶部全幅高清海报横幅的展示状态。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('switch-home-hero'),
              icon: CupertinoIcons.star_fill,
              iconColor: AppleColors.systemOrange,
              title: '沉浸首推海报',
              subtitle: '顶部高清海报横幅与下拉放大刷新',
              value: storage.showHeroBanner,
              onChanged: (v) async {
                await storage.setShowHeroBanner(v);
                refresh();
              },
            ),
          ],
        ),
        const SizedBox(height: 18),
        IosSettingsGroup(
          header: '首页板块开关与顺序（拖动或点箭头排序）',
          footer: '可单独开关每个板块并自由调整上下顺序，历史记录默认关闭。',
          children: [
            ReorderableListView.builder(
              key: const ValueKey('ios-home-sections-reorder-list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: orderedIds.length,
              onReorder: (oldIndex, newIndex) async {
                var target = newIndex;
                if (target > oldIndex) target -= 1;
                final next = List<String>.of(orderedIds);
                final moved = next.removeAt(oldIndex);
                next.insert(target, moved);
                await storage.setHomeSectionOrder(next);
                HapticFeedback.selectionClick();
                refresh();
              },
              itemBuilder: (ctx, index) {
                final id = orderedIds[index];
                final meta = metaById[id];
                if (meta == null) {
                  return SizedBox.shrink(key: ValueKey('missing-$id'));
                }
                final enabled = storage.isHomeSectionEnabled(id);
                return Container(
                  key: ValueKey('home-section-row-$id'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: palette.groupedPrimary,
                    border: index < orderedIds.length - 1
                        ? Border(
                            bottom: BorderSide(
                              color: palette.separator,
                              width: 0.5,
                            ),
                          )
                        : null,
                  ),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Icon(
                            CupertinoIcons.line_horizontal_3,
                            size: 16,
                            color: palette.labelTertiary,
                          ),
                        ),
                      ),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: meta.color,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(
                          meta.icon,
                          size: 15,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              meta.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.labelPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              meta.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.labelTertiary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (index > 0)
                        CupertinoButton(
                          key: ValueKey('home-section-up-$id'),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(26, 28),
                          onPressed: () => moveSection(index, -1),
                          child: Icon(
                            CupertinoIcons.chevron_up,
                            size: 14,
                            color: palette.labelSecondary,
                          ),
                        ),
                      if (index < orderedIds.length - 1)
                        CupertinoButton(
                          key: ValueKey('home-section-down-$id'),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(26, 28),
                          onPressed: () => moveSection(index, 1),
                          child: Icon(
                            CupertinoIcons.chevron_down,
                            size: 14,
                            color: palette.labelSecondary,
                          ),
                        ),
                      const SizedBox(width: 4),
                      if (isWindowsDesktopUi || OhosRuntime.isOhos)
                        CupertinoSwitch(
                          key: ValueKey('switch-home-section-$id'),
                          value: enabled,
                          activeTrackColor: AppleColors.systemGreen,
                          onChanged: (v) async {
                            await storage.setHomeSectionEnabled(id, v);
                            refresh();
                          },
                        )
                      else
                        IosNativeSwitch(
                          key: ValueKey('switch-home-section-$id'),
                          value: enabled,
                          activeColor: AppleColors.systemGreen,
                          accessibilityLabel: meta.title,
                          onChanged: (v) async {
                            await storage.setHomeSectionEnabled(id, v);
                            refresh();
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 18),
        IosSettingsGroup(
          children: [
            IosSettingsRow(
              key: const ValueKey('home-sections-reset-btn'),
              icon: CupertinoIcons.arrow_counterclockwise,
              iconColor: AppleColors.systemRed,
              title: '恢复默认板块与排序',
              showChevron: false,
              onTap: () async {
                await storage.resetHomeSectionPreferences();
                HapticFeedback.mediumImpact();
                refresh();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlaybackSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '画质与画面比例',
          children: [
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'preferred_quality',
              icon: CupertinoIcons.tv_music_note_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '默认画质与线路推荐',
              subtitle: '进入详情页时自动优选匹配的画质与线路',
              trailingText: _preferredQualityLabel,
              currentValue: widget.storage.preferredQuality,
              onStateChanged: refreshBoth,
              options: const [
                ('4k_netdisk', '4K 超清原画优先', '优先匹配 4K HDR / 杜比视界超清线路'),
                ('1080p_direct', '1080P 高清直连优先', '优先选择高码率 1080P 直连点播线路'),
                ('fast_hls', '极速 M3U8 流媒体优先', '优先选择秒开 M3U8 切片流媒体线路'),
                ('default', '站点默认顺序', '保持采集站原始线路排序'),
              ],
              onSelected: (val) async {
                await widget.storage.setPreferredQuality(val);
                refreshBoth();
              },
            ),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'player_kernel',
              icon: CupertinoIcons.slider_horizontal_3,
              iconBgColor: AppleColors.systemTeal,
              title: '默认播放策略',
              subtitle: '调整同一播放器的硬件解码偏好与缓冲大小',
              trailingText: switch (widget.storage.playerKernel) {
                'ijk' => '兼容缓冲',
                'mpv' => '大容量缓冲',
                _ => '均衡播放',
              },
              currentValue: widget.storage.playerKernel,
              onStateChanged: refreshBoth,
              options: const [
                ('exo', '均衡播放（默认）', '自动选择解码方式，使用 64 MB 前向缓冲'),
                ('ijk', '兼容缓冲', '硬件解码拷贝输出，增加媒体探测时间'),
                ('mpv', '大容量缓冲', '使用 128 MB 前向缓冲，占用更多内存'),
              ],
              onSelected: (val) async {
                await widget.storage.setPlayerKernel(val);
                refreshBoth();
              },
            ),
            _buildExpandableChoiceDrawerTile<String>(
              settingKey: 'aspect_mode',
              icon: CupertinoIcons.viewfinder,
              iconBgColor: AppleColors.systemPurple,
              title: '默认画面比例',
              subtitle: '播放器启动时的默认画面缩放模式',
              trailingText: _defaultAspectLabel,
              currentValue: widget.storage.defaultAspectMode,
              onStateChanged: refreshBoth,
              options: const [
                ('contain', '适应屏幕', '保持原始视频宽高比完整显示画面'),
                ('cover', '铺满裁剪', '等比放大铺满全屏区域，自动裁切黑边'),
                ('fill', '拉伸全屏', '拉伸画面填满整个屏幕显示区域'),
              ],
              onSelected: (val) async {
                await widget.storage.setDefaultAspectMode(val);
                refreshBoth();
              },
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '起播规则与选集',
          children: [
            _buildExpandableChoiceDrawerTile<double>(
              settingKey: 'play_speed',
              icon: CupertinoIcons.speedometer,
              iconBgColor: AppleColors.systemOrange,
              title: '默认起播倍速',
              subtitle: '选择播放器起播时的默认倍速',
              trailingText: '${widget.storage.playSpeed}x',
              currentValue: widget.storage.playSpeed,
              onStateChanged: refreshBoth,
              options: const [
                (0.75, '0.75x 慢速', '放慢语速与动作细节'),
                (1.0, '1.0x 正常原速', '标准原片播放速度'),
                (1.25, '1.25x 轻快倍速', '轻微提速，不损台词听感'),
                (1.5, '1.5x 高效倍速', '适合快速浏览剧情推进'),
                (2.0, '2.0x 二倍速播放', '高速刷剧模式'),
              ],
              onSelected: (val) async {
                await widget.storage.setPlaySpeed(val);
                refreshBoth();
              },
            ),
            _buildSettingDrawerContainer(
              settingKey: 'skip_intro_outro',
              icon: CupertinoIcons.forward_fill,
              iconBgColor: AppleColors.systemIndigo,
              title: '片头 / 片尾独立记录',
              subtitle: '每部影片独立记录片头片尾跳过时间，不全局同步',
              trailingText: _skipIntroOutroSummary,
              onStateChanged: refreshBoth,
              drawerChild:
                  _buildSkipIntroOutroDrawerBody(onStateChanged: refreshBoth),
            ),
            _buildExpandableChoiceDrawerTile<bool>(
              settingKey: 'episodes_order',
              icon: CupertinoIcons.sort_down,
              iconBgColor: AppleColors.systemGreen,
              title: '默认剧集排序方式',
              subtitle: '详情页与选集列表的默认排列顺序',
              trailingText:
                  widget.storage.episodesDescending ? '倒序（最新集）' : '正序（第 1 集起）',
              currentValue: widget.storage.episodesDescending,
              onStateChanged: refreshBoth,
              options: const [
                (false, '正序（第 1 集起）', '从第 1 集开始依次排列，适合从头追剧'),
                (true, '倒序（最新集起）', '最新更新的集数排在最前，适合追更连载剧集'),
              ],
              onSelected: (val) async {
                await widget.storage.setEpisodesDescending(val);
                refreshBoth();
              },
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.forward_end_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '自动连播下一集',
              subtitle: '当前剧集播放完毕后无缝切换下一集',
              trailing: CupertinoSwitch(
                value: widget.storage.autoNext,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setAutoNext(v);
                  refreshBoth();
                },
              ),
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.clock_fill,
              iconBgColor: AppleColors.systemTeal,
              title: '播放页常显时间',
              subtitle: '在播放页面右上角独立常显当前系统时间',
              trailing: CupertinoSwitch(
                value: widget.storage.playerAlwaysShowClock,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await widget.storage.setPlayerAlwaysShowClock(v);
                  refreshBoth();
                },
              ),
            ),
          ],
        ),
        if (!OhosRuntime.isOhos) ...[
          const SizedBox(height: 22),
          IosDanmuSettingsSection(onChanged: refreshBoth),
          const SizedBox(height: 22),
          IosPlayerHudSettingsSection(onChanged: refreshBoth),
        ],
      ],
    );
  }

  Widget _buildCloudAndDataSettingsSection(
    BuildContext context,
    VoidCallback refreshBoth,
  ) {
    final depots = _config?.depots ?? const [];
    final subs = widget.storage.getSubscriptions();
    final publicSubs = subs.where((s) => !s.isEffectivelyPrivate).toList();
    final publicSites = _config?.publicSupportedSites ?? const [];
    final loggedDriveCount = NetdiskService.drives
        .where((d) => widget.storage.isNetdiskLoggedIn(d.key))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppleGroupedSection(
          header: '云盘扫码与 4K 原画账号',
          footer: '扫码或粘贴 Cookie / Token 绑定后，玩偶哥哥、聚剧四盘、盘搜等 4K 原画线路将自动启用。',
          children: [
            AppleGroupedTile(
              icon: CupertinoIcons.qrcode_viewfinder,
              iconBgColor: const Color(0xFF0A84FF),
              title: '配置中心 · 多源网盘扫码与账号',
              subtitle: '兼容多源配置中心直读，一次扫码全源通用',
              trailingText:
                  loggedDriveCount > 0 ? '已登录 $loggedDriveCount 个' : '去扫码',
              onTap: () => showNetdiskAccountSheet(
                context,
                widget.storage,
                sites: publicSites,
                activeGroup: _activeSite?.group ?? '',
                onOpenCatPawSettings: publicSites.any((s) => s.isCatPaw)
                    ? _showCatPawSettings
                    : null,
                onChanged: () {
                  refreshBoth();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '片源仓库与备份',
          children: [
            if (publicSites.any((s) => s.isCatPaw))
              AppleGroupedTile(
                icon: CupertinoIcons.slider_horizontal_3,
                iconBgColor: AppleColors.systemBlue,
                title: 'CatPaw 本机配置',
                subtitle: '管理该订阅的启用线路与来源设置',
                onTap: _showCatPawSettings,
              ),
            AppleGroupedTile(
              icon: CupertinoIcons.folder_fill,
              iconBgColor: AppleColors.systemPurple,
              title: '订阅源与分组管理中心',
              subtitle: publicSubs.isEmpty
                  ? '批量导入、多仓切换与自定义分组（当前 可用 ${publicSites.where((s) => s.supported).length} / 共 ${publicSites.length} 片源）'
                  : '已导入 ${publicSubs.length} 个订阅 · 可用 ${publicSites.where((s) => s.supported).length} / 共 ${publicSites.length} 个片源${depots.isNotEmpty ? " · ${depots.length} 个子仓库" : ""}',
              trailingText: '${publicSubs.length} 订阅',
              onTap: () async {
                await _showSubscriptionManagerSheet();
                if (context.mounted) refreshBoth();
              },
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.cloud_fill,
              iconBgColor: AppleColors.systemBlue,
              title: '多端网络同步 (WebDAV / 局域网)',
              subtitle: widget.storage.syncStatusSummary,
              trailingText: widget.storage.isWebdavConfigured ? '已配置' : '去配置',
              onTap: () async {
                await _openCloudSyncCenter();
                if (context.mounted) refreshBoth();
              },
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.arrow_2_circlepath,
              iconBgColor: AppleColors.systemGreen,
              title: '跨平台备份导出 / 恢复',
              subtitle: '与 Android、Windows、Mac、iPad 双向互通备份',
              onTap: _showBackupRestoreDialog,
            ),
          ],
        ),
        const SizedBox(height: 22),
        AppleGroupedSection(
          header: '系统更新与缓存存储',
          children: [
            AppleGroupedTile(
              icon: CupertinoIcons.arrow_down_circle_fill,
              iconBgColor: AppleColors.systemOrange,
              title: '检查版本更新',
              subtitle: '当前正式版 $_currentAppVersion · 按当前设备检查更新',
              trailingText: '检测更新',
              onTap: _showUpdateCheckSheet,
            ),
            AppleGroupedTile(
              icon: CupertinoIcons.trash_fill,
              iconBgColor: AppleColors.systemRed,
              title: '清理海报与搜索缓存',
              subtitle:
                  '海报内存缓存：${PosterLoader.memoryCacheSizeLabel} · 搜索历史 ${widget.storage.getSearchHistory(forPrivate: _privateSessionUnlocked).length} 条',
              trailingText: '一键清理',
              onTap: () async {
                await PosterLoader.clearCache();
                await widget.storage.clearSearchHistory(
                  forPrivate: _privateSessionUnlocked,
                );
                refreshBoth();
                if (!context.mounted) return;
                unawaited(
                  showAppleNativeAlert(
                    context,
                    title: '缓存已清理',
                    message: '已清空内存与磁盘海报缓存及搜索历史记录。',
                    actions: const [
                      AppleNativeAlertAction(
                        id: 'ok',
                        title: '好的',
                        isDefault: true,
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showCatPawSettings([CmsSite? requested]) async {
    final bundles = <String,CmsSite>{};
    for (final site in _config?.publicSupportedSites ?? <CmsSite>[]) {
      if (site.isCatPaw) bundles.putIfAbsent(Uri.parse(site.api).host, () => site);
    }
    if (bundles.isEmpty && requested == null) return;
    CmsSite? selected = requested ?? bundles.values.first;
    if (requested == null && bundles.length > 1) {
      selected = await showAppleNativeActionSheet<CmsSite>(
        context,
        title: '选择 CatPaw 订阅',
        options: [
          for (final site in bundles.values)
            AppleNativeSheetOption<CmsSite>(value: site, title: site.name),
        ],
        cancelLabel: '取消',
      );
    }
    if (selected == null || !mounted) return;
    try {
      final url = await CatPawHost.instance.settings(selected.api);
      if (!mounted) return;
      final opened = await launchUrl(url,mode:Platform.isIOS ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication);
      if (!opened) throw StateError('无法打开本机配置页');
    } catch (_) {
      if (!mounted) return;
      await showAppleNativeAlert(
        context,
        title: '无法打开 CatPaw 配置',
        message: '请确认订阅已成功导入，并使用包含本机运行组件的完整版本。',
        actions: const [
          AppleNativeAlertAction(id: 'ok', title: '好的', isDefault: true),
        ],
      );
    }
  }

  Widget _buildSettingDrawerContainer({
    required String settingKey,
    required IconData icon,
    required Color iconBgColor,
    required String title,
    required String subtitle,
    required String trailingText,
    required Widget drawerChild,
    VoidCallback? onStateChanged,
  }) {
    final expanded = _expandedSettings.contains(settingKey);
    if (usesWindowsAppearance(context)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WinSettingsRow(title: title, subtitle: subtitle, icon: icon, value: trailingText,
            trailing: Icon(expanded ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                size: 14, color: winMuted(context)), onTap: () {
          if (expanded) { _expandedSettings.remove(settingKey); }
          else { _expandedSettings.add(settingKey); }
          if (onStateChanged != null) { onStateChanged(); } else { setState(() {}); }
        }),
        if (expanded) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: drawerChild),
      ]);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (expanded) {
              _expandedSettings.remove(settingKey);
            } else {
              _expandedSettings.add(settingKey);
            }
            if (onStateChanged != null) {
              onStateChanged();
            } else {
              setState(() {});
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(const Color(0x28FFFFFF), iconBgColor),
                        iconBgColor,
                      ],
                    ),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(7.5),
                      side: const BorderSide(
                        color: Color(0x33FFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(icon, size: 17, color: Colors.white),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: ApplePalette.of(context).labelPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                          height: 1.28,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ApplePalette.of(context).labelSecondary,
                          fontSize: 12.5,
                          height: 1.35,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      trailingText,
                      style: TextStyle(
                        color: expanded
                            ? AppleColors.systemBlue
                            : ApplePalette.of(context).labelSecondary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    SizedBox(width: 5),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0.0,
                      duration: (isWindowsDesktopUi || OhosRuntime.isOhos)
                          ? const Duration(milliseconds: 220)
                          : Ios27Spring.snappy.nominalDuration,
                      curve: (isWindowsDesktopUi || OhosRuntime.isOhos)
                          ? Curves.easeOutCubic
                          : Ios27Spring.snappy.curve,
                      child: Icon(
                        CupertinoIcons.chevron_down,
                        size: 13.5,
                        color: expanded
                            ? AppleColors.systemBlue
                            : ApplePalette.of(context).labelTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Builder(
              builder: (dCtx) {
                final dp = ApplePalette.of(dCtx);
                return Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: dp.isDark
                        ? const Color(0x3D000000)
                        : dp.groupedSecondary,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: dp.isDark
                          ? const Color(0x24FFFFFF)
                          : dp.separator,
                      width: 0.7,
                    ),
                  ),
                  child: drawerChild,
                );
              },
            ),
          ),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: (isWindowsDesktopUi || OhosRuntime.isOhos)
              ? const Duration(milliseconds: 220)
              : Ios27Spring.smooth.nominalDuration,
          sizeCurve: (isWindowsDesktopUi || OhosRuntime.isOhos)
              ? Curves.easeOutCubic
              : Ios27Spring.smooth.curve,
        ),
      ],
    );
  }

  Widget _buildExpandableChoiceDrawerTile<T>({
    required String settingKey,
    required IconData icon,
    required Color iconBgColor,
    required String title,
    required String subtitle,
    required String trailingText,
    required T currentValue,
    required List<(T, String, String)> options,
    required Future<void> Function(T) onSelected,
    VoidCallback? onStateChanged,
  }) {
    return _buildSettingDrawerContainer(
      settingKey: settingKey,
      icon: icon,
      iconBgColor: iconBgColor,
      title: title,
      subtitle: subtitle,
      trailingText: trailingText,
      onStateChanged: onStateChanged,
      drawerChild: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Builder(
              builder: (context) {
                final opt = options[i];
                final selected = opt.$1 == currentValue;
                if (usesWindowsAppearance(context)) {
                  return WinSettingsRow(title: opt.$2, subtitle: opt.$3,
                      onTap: () => onSelected(opt.$1),
                      trailing: Icon(selected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                          color: selected ? const Color(0xFF426B91) : winMuted(context), size: 20));
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(opt.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppleColors.systemBlue.withValues(
                              alpha: ApplePalette.isDarkOf(context) ? 0.22 : 0.12,
                            )
                          : (ApplePalette.isDarkOf(context)
                              ? const Color(0x12FFFFFF)
                              : Colors.white),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? AppleColors.systemBlue.withValues(alpha: 0.55)
                            : (ApplePalette.isDarkOf(context)
                                ? const Color(0x16FFFFFF)
                                : ApplePalette.of(context).separator),
                        width: 0.7,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opt.$2,
                                style: TextStyle(
                                  color: selected
                                      ? (ApplePalette.isDarkOf(context)
                                          ? const Color(0xFF5AC8FA)
                                          : AppleColors.systemBlue)
                                      : ApplePalette.of(context).labelPrimary,
                                  fontSize: 14,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              SizedBox(height: 2.5),
                              Text(
                                opt.$3,
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelSecondary,
                                  fontSize: 11.5,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(
                          selected
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          size: 19,
                          color: selected
                              ? AppleColors.systemBlue
                              : ApplePalette.of(context).labelTertiary,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWallpaperDrawerBody({VoidCallback? onStateChanged}) {
    const presets = <(String, String, String, Color)>[
      ('obsidian', '曜石纯黑', '经典深邃纯黑影院底色', Color(0xFF141824)),
      ('midnight', '午夜深蓝', '静谧冷调深海蓝', Color(0xFF0E2240)),
      ('aurora', '极光紫韵', '灵动流光暗夜紫', Color(0xFF281542)),
      ('amber', '流金琥珀', '温暖复古鎏金棕', Color(0xFF382210)),
      ('emerald', '翡翠幽林', '沉稳护眼墨绿调', Color(0xFF0F3026)),
    ];
    final currentPreset = widget.storage.wallpaperPreset;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < presets.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          Builder(
            builder: (context) {
              final item = presets[i];
              final selected = currentPreset == item.$1 &&
                  widget.storage.customWallpaperUrl.isEmpty;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await widget.storage.setCustomWallpaperUrl('');
                  await widget.storage.setWallpaperPreset(item.$1);
                  if (onStateChanged != null) {
                    onStateChanged();
                  } else {
                    setState(() {});
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0x280A84FF)
                        : const Color(0x12FFFFFF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? const Color(0x775AC8FA)
                          : const Color(0x16FFFFFF),
                      width: 0.7,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: item.$4,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0x66FFFFFF),
                            width: 1,
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.$2,
                              style: TextStyle(
                                color: selected
                                    ? const Color(0xFF5AC8FA)
                                    : ApplePalette.of(context).labelPrimary,
                                fontSize: 14,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              item.$3,
                              style: TextStyle(
                                color: ApplePalette.of(context).labelSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        selected
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.circle,
                        size: 19,
                        color: selected
                            ? AppleColors.systemBlue
                            : ApplePalette.of(context).labelTertiary,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 6),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _showWallpaperSettingsSheet();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0x180A84FF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0x3D5AC8FA),
                width: 0.7,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.link,
                  size: 16,
                  color: AppleColors.systemBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.storage.customWallpaperUrl.isNotEmpty
                        ? '修改自定义壁纸地址（已启用）'
                        : '输入自定义高清壁纸 URL / 本地路径…',
                    style: const TextStyle(
                      color: AppleColors.systemBlue,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 14,
                  color: AppleColors.systemBlue,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSkipIntroOutroDrawerBody({VoidCallback? onStateChanged}) {
    final recordedCount = widget.storage.countVideoSkipRecords(
      forPrivate: _privateSessionUnlocked,
    );
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.film_fill,
                size: 16,
                color: AppleColors.systemBlue,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  recordedCount > 0
                      ? '当前空间已独立记录 $recordedCount 部影片'
                      : '当前空间暂无片头 / 片尾独立记录',
                  style: TextStyle(
                    color: settingsInk(context),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '每部影片独立记录片头与片尾跳过节点，仅保存在本机、不跨片共用也不参与全局同步。在播放页点击「跳片头 / 跳片尾」会优先默认设为当前播放时间，并支持按秒微调。',
            style: TextStyle(
              color: settingsMuted(context),
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          if (recordedCount > 0) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 9),
                minSize: 36,
                color: const Color(0x28FF453A),
                borderRadius: BorderRadius.circular(12),
                onPressed: () async {
                  await widget.storage.clearVideoSkipRecords(
                    forPrivate: _privateSessionUnlocked,
                  );
                  if (onStateChanged != null) {
                    onStateChanged();
                  } else if (mounted) {
                    setState(() {});
                  }
                },
                child: Text(
                  '清空全部片头片尾独立记录',
                  style: TextStyle(
                    color: AppleColors.systemRed,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _currentAppVersion = '读取中';
  Timer? _installedVersionTimer;

  Future<String> _resolveInstalledAppVersion() async {
    if (OhosRuntime.isOhos) {
      final ohosPkg = await OhosRuntime.getPackageInfo();
      if (ohosPkg != null && ohosPkg.version.isNotEmpty) {
        return ohosPkg.version;
      }
    }
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.trim().isNotEmpty) {
        return info.version.trim();
      }
    } catch (_) {}
    return '';
  }

  Future<void> _loadInstalledVersion() async {
    _installedVersionTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _currentAppVersion = '未知');
    });
    try {
      final version = await _resolveInstalledAppVersion();
      _installedVersionTimer?.cancel();
      if (mounted) {
        setState(
          () => _currentAppVersion = version.isNotEmpty ? version : '未知',
        );
      }
    } catch (_) {
      _installedVersionTimer?.cancel();
      if (mounted) setState(() => _currentAppVersion = '未知');
    }
  }

  static String _formatCleanReleaseNotes(String raw) =>
      ReleaseNotesSummary.formatPlainText(raw);

  static bool _isRemoteVersionNewer(String remote, String current) {
    List<int> parseParts(String v) => v
        .replaceAll(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[^0-9]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final r = parseParts(remote);
    final c = parseParts(current);
    final len = math.max(r.length, c.length);
    for (var i = 0; i < len; i++) {
      final rv = i < r.length ? r[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (rv != cv) return rv > cv;
    }
    return false;
  }

  Future<T?> _openIosOrModalPage<T>({
    required String title,
    BuildContext? hostContext,
    String backLabel = '返回',
    Widget? trailingAction,
    double maxWidth = 640,
    bool ignoreKeyboardInsets = false,
    required WidgetBuilder builder,
  }) {
    final targetCtx = hostContext ?? context;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _trackSecondaryRoute<T>(
        () => Navigator.of(targetCtx).push<T>(
          buildApplePageRoute<T>(
            builder: (pageCtx) => IosSettingsScaffold(
              title: title,
              backLabel: backLabel,
              trailing: trailingAction,
              body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: builder(pageCtx),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return showAppleModalSheet<T>(
      context: targetCtx,
      title: title,
      maxWidth: maxWidth,
      trailingAction: trailingAction,
      ignoreKeyboardInsets: ignoreKeyboardInsets,
      builder: builder,
    );
  }

  void _showUpdateCheckSheet() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _openIosOrModalPage<void>(
        title: '软件更新',
        backLabel: '返回',
        builder: (_) => IosUpdateSheet(installedVersion: _currentAppVersion),
      );
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      showAppleModalSheet<void>(
        context: context,
        title: '检查版本更新',
        builder: (_) => MacosUpdateSheet(installedVersion: _currentAppVersion),
      );
      return;
    }
    bool checking = true;
    bool downloading = false;
    bool checkFailed = false;
    double progress = 0.0;
    final isHarmony = OhosRuntime.isOhos;
    String statusText = isHarmony
        ? '正在检查 HarmonyOS NEXT 独立更新源…'
        : '正在连接镜像站检测最新版本…';
    String latestVersion = _currentAppVersion;
    String releaseNotes = '';
    String downloadUrl = '';
    bool hasNewer = false;
    int versionCompare = 0;
    bool checkStarted = false;
    AppUpdate? release;

    String formatMb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

    Future<void> openHarmonyOrCopyUrl(String targetUrl, String label) async {
      final opened = await OhosRuntime.openExternalUrl(targetUrl);
      if (opened) return;
      await Clipboard.setData(ClipboardData(text: targetUrl));
      _showAppleNotice('已复制$label', '请在系统浏览器中打开：$targetUrl');
    }

    showAppleModalSheet<void>(
      context: context,
      title: isHarmony ? 'HarmonyOS NEXT 版本更新' : '检查版本更新',
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> checkRemote() async {
              if (ctx.mounted) {
                setSheetState(() {
                  checking = true;
                  checkFailed = false;
                  release = null;
                  releaseNotes = '';
                  downloadUrl = '';
                  hasNewer = false;
                  versionCompare = 0;
                  statusText = isHarmony
                      ? '正在检查 HarmonyOS NEXT 独立更新源…'
                      : '正在连接镜像站检测最新版本…';
                });
              }
              try {
                final resolvedVersion = await _resolveInstalledAppVersion();
                if (resolvedVersion.isEmpty) {
                  throw const FormatException('无法读取已安装版本');
                }
                _currentAppVersion = resolvedVersion;
                if (mounted) setState(() {});
                release = await AppUpdate.check(
                  platform: isHarmony ? 'harmonyos' : null,
                );
                latestVersion = release!.version;
                releaseNotes = _formatCleanReleaseNotes(release!.notes);
                downloadUrl = isHarmony
                    ? (release!.harmonyosUrl?.toString() ?? '')
                    : (release!.windowsUrl?.toString() ?? '');
                if (isHarmony && downloadUrl.isEmpty) {
                  throw const FormatException('未获取到有效的鸿蒙 HAP 安装包或校验信息');
                }
                versionCompare = AppUpdate.compareVersions(
                  latestVersion,
                  _currentAppVersion,
                );
                hasNewer = versionCompare > 0;
                statusText = isHarmony
                    ? (versionCompare > 0
                        ? '发现新版本 v$latestVersion（当前 v$_currentAppVersion）'
                        : versionCompare == 0
                            ? '当前已是最新版本（v$_currentAppVersion）'
                            : '当前已装版本 v$_currentAppVersion 高于正式源版本 v$latestVersion（无需降级）')
                    : (hasNewer
                        ? '发现新版本 v$latestVersion（当前 v$_currentAppVersion）'
                        : '当前已是最新版本（v$_currentAppVersion）');
              } on FormatException catch (e) {
                checkFailed = true;
                release = null;
                downloadUrl = '';
                hasNewer = false;
                versionCompare = 0;
                statusText = '检查更新失败：${e.message}';
              } catch (_) {
                checkFailed = true;
                release = null;
                downloadUrl = '';
                hasNewer = false;
                versionCompare = 0;
                statusText = '暂时无法检查更新，请稍后重试或打开官方下载站';
              }
              if (ctx.mounted) setSheetState(() => checking = false);
            }

            if (!checkStarted) {
              checkStarted = true;
              Future.microtask(checkRemote);
            }

            Future<void> downloadAndInstallWindows() async {
              if (downloadUrl.isEmpty || downloading) return;
              setSheetState(() {
                downloading = true;
                progress = 0.02;
                statusText = '正在下载 Windows 安装更新包…';
              });
              final http = HttpClient()
                ..connectionTimeout = const Duration(seconds: 15);
              try {
                final uri = Uri.parse(downloadUrl);
                final req = await http.getUrl(uri);
                final resp = await req.close();
                if (resp.statusCode != 200) {
                  throw Exception('HTTP ${resp.statusCode}');
                }
                final total = release!.size!;
                if (resp.contentLength >= 0 && resp.contentLength != total) {
                  throw const FormatException('更新包大小与发布清单不一致');
                }
                final isExe =
                    downloadUrl.toLowerCase().contains('setup.exe') ||
                        downloadUrl.toLowerCase().endsWith('.exe');
                final ext = isExe ? 'exe' : 'zip';
                final filePath =
                    '${Directory.systemTemp.path}${Platform.pathSeparator}MarcoMovie-$latestVersion-update.$ext';
                final outFile = File(filePath);
                final sink = outFile.openWrite();
                var received = 0;
                try {
                await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
                  received += chunk.length;
                  if (received > total) throw const FormatException('更新包超过发布大小');
                  sink.add(chunk);
                  if (total > 0 && ctx.mounted) {
                    setSheetState(() {
                      progress = (received / total).clamp(0.02, 0.99);
                    });
                  }
                }
                await sink.flush();
                } finally {
                  await sink.close();
                }
                await release!.verifyFile(outFile);
                if (!ctx.mounted) return;
                if (isExe) {
                  if (ctx.mounted) {
                    setSheetState(() {
                      progress = 1.0;
                      statusText = '下载完成，正在打开安装向导…';
                    });
                  }
                  await Process.start(
                    filePath,
                    [
                      '/MERGETASKS=!desktopicon',
                      '/DIR=${File(Platform.resolvedExecutable).parent.path}',
                    ],
                    mode: ProcessStartMode.detached,
                  );
                  if (ctx.mounted) setSheetState(() {
                    downloading = false;
                    statusText = '安装向导已打开，请按提示完成更新';
                  });
                } else {
                  await Process.start(
                    'explorer.exe',
                    ['/select,', filePath],
                    mode: ProcessStartMode.detached,
                  );
                  if (ctx.mounted) {
                    setSheetState(() {
                      downloading = false;
                      statusText = '更新包已保存至：$filePath';
                    });
                  }
                }
              } catch (e) {
                if (ctx.mounted) {
                  setSheetState(() {
                    downloading = false;
                    statusText = '自动下载失败：$e';
                  });
                }
              } finally {
                http.close(force: true);
              }
            }

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (checking || downloading) ...[
                        const CupertinoActivityIndicator(radius: 10),
                        const SizedBox(width: 10),
                      ] else ...[
                        Icon(
                          checkFailed
                              ? CupertinoIcons.exclamationmark_triangle_fill
                              : hasNewer
                                  ? CupertinoIcons.arrow_down_circle_fill
                                  : CupertinoIcons.checkmark_seal_fill,
                          color: checkFailed
                              ? AppleColors.systemOrange
                              : hasNewer
                                  ? AppleColors.systemBlue
                                  : AppleColors.systemGreen,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          statusText,
                          style: TextStyle(
                            color: ApplePalette.of(context).labelPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isHarmony) ...[
                    const SizedBox(height: 6),
                    Text(
                      '当前已装版本：v$_currentAppVersion · 通道：HarmonyOS NEXT (arm64-v8a)',
                      style: TextStyle(
                        color: ApplePalette.of(context).labelSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                  if (downloading) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 6,
                        backgroundColor: const Color(0x26FFFFFF),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppleColors.systemBlue,
                        ),
                      ),
                    ),
                  ],
                  if (releaseNotes.isNotEmpty) ...[
                    SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 240),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ApplePalette.of(context).groupedSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppleColors.glassBorder,
                          width: 0.5,
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: ReleaseNotesSummaryView(
                          rawNotes: release?.notes ?? releaseNotes,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                  if (isHarmony && !checking && !checkFailed && release != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ApplePalette.of(context).groupedSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppleColors.glassBorder,
                          width: 0.5,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '安装包：${release!.packageFileName ?? "MarcoMovie-$latestVersion-harmonyos-universal.hap"}'
                            '${release!.size != null ? "（${formatMb(release!.size!)}）" : ""}',
                            style: TextStyle(
                              color: ApplePalette.of(context).labelPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if ((release!.checksum ?? '').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            SelectableText(
                              'SHA-256：${release!.checksum}',
                              style: TextStyle(
                                color: ApplePalette.of(context).labelSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                          if (versionCompare >= 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              AppUpdate.harmonyosUnsignedInstallGuide,
                              style: TextStyle(
                                color: ApplePalette.of(context).labelSecondary,
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (!checking && !downloading)
                    if (isHarmony)
                      Row(
                        children: [
                          if (downloadUrl.isNotEmpty && versionCompare >= 0) ...[
                            Expanded(
                              child: AppleCapsuleButton(
                                key: const ValueKey('ohos-update-download-hap'),
                                label: hasNewer
                                    ? '下载未签名 HAP v$latestVersion'
                                    : '重新下载 HAP v$latestVersion',
                                icon: CupertinoIcons.arrow_down_to_line,
                                primary: true,
                                onPressed: () => openHarmonyOrCopyUrl(
                                  downloadUrl,
                                  'HAP 下载链接',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ] else if (checkFailed) ...[
                            Expanded(
                              child: AppleCapsuleButton(
                                key: const ValueKey('ohos-update-retry'),
                                label: '重新检查更新',
                                icon: CupertinoIcons.refresh,
                                primary: true,
                                onPressed: checkRemote,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: AppleCapsuleButton(
                              key: const ValueKey('ohos-update-open-release'),
                              label: release?.releaseUrl != null
                                  ? '打开鸿蒙发布页'
                                  : '打开官方下载站',
                              icon: CupertinoIcons.globe,
                              primary: (downloadUrl.isEmpty || versionCompare < 0) &&
                                  !checkFailed,
                              onPressed: () => openHarmonyOrCopyUrl(
                                release?.releaseUrl?.toString() ??
                                    'https://marcotv.wlj9919.top/movie/',
                                '鸿蒙发布页地址',
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      Row(
                        children: [
                          if (!kIsWeb &&
                              Platform.isWindows &&
                              downloadUrl.isNotEmpty)
                            Expanded(
                              child: AppleCapsuleButton(
                                label: hasNewer
                                    ? '一键下载安装 v$latestVersion'
                                    : '重新下载安装 v$latestVersion',
                                icon: CupertinoIcons.arrow_down_to_line,
                                primary: true,
                                onPressed: downloadAndInstallWindows,
                              ),
                            ),
                          if (!kIsWeb &&
                              Platform.isWindows &&
                              downloadUrl.isNotEmpty)
                            const SizedBox(width: 10),
                          Expanded(
                            child: AppleCapsuleButton(
                              label: '打开官方下载站',
                              icon: CupertinoIcons.globe,
                              primary: kIsWeb || !Platform.isWindows,
                              onPressed: () async {
                                const mirror =
                                    'https://marcotv.wlj9919.top/movie/';
                                if (!kIsWeb && Platform.isWindows) {
                                  await Process.run(
                                    'cmd',
                                    ['/c', 'start', '', mirror],
                                  );
                                } else if (!kIsWeb && Platform.isMacOS) {
                                  await Process.run('open', [mirror]);
                                } else {
                                  await Clipboard.setData(
                                    const ClipboardData(text: mirror),
                                  );
                                  _showAppleNotice(
                                    '已复制下载站地址',
                                    '请在浏览器中打开：$mirror',
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showWallpaperSettingsSheet({
    String iosBackLabel = '返回',
  }) async {
    final urlCtrl = TextEditingController(
      text: widget.storage.customWallpaperUrl,
    );
    const presets = <(String, String, Color, Color)>[
      ('obsidian', '曜石纯黑', Color(0xFF141824), Color(0xFF050507)),
      ('midnight', '午夜深蓝', Color(0xFF0E2240), Color(0xFF060A14)),
      ('aurora', '极光紫韵', Color(0xFF281542), Color(0xFF090612)),
      ('amber', '流金琥珀', Color(0xFF382210), Color(0xFF0D0805)),
      ('emerald', '翡翠幽林', Color(0xFF0F3026), Color(0xFF050E0B)),
    ];
    await _openIosOrModalPage<void>(
      title: defaultTargetPlatform == TargetPlatform.iOS
          ? '自定义壁纸'
          : '背景壁纸与主题风格',
      backLabel: iosBackLabel,
      ignoreKeyboardInsets: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final currentPreset = widget.storage.wallpaperPreset;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              18,
              18,
              18,
              18 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  defaultTargetPlatform == TargetPlatform.iOS
                      ? '预设背景'
                      : 'Apple 影院级预设背景',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (key, label, c1, c2) in presets)
                      GestureDetector(
                        onTap: () async {
                          await widget.storage.setCustomWallpaperUrl('');
                          await widget.storage.setWallpaperPreset(key);
                          urlCtrl.clear();
                          setModalState(() {});
                          if (mounted) setState(() {});
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 112,
                          height: 68,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [c1, c2],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: currentPreset == key &&
                                      widget.storage.customWallpaperUrl.isEmpty
                                  ? AppleColors.systemBlue
                                  : AppleColors.glassBorder,
                              width: currentPreset == key &&
                                      widget.storage.customWallpaperUrl.isEmpty
                                  ? 1.6
                                  : 0.6,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: c1,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white38,
                                        width: 0.6,
                                      ),
                                    ),
                                  ),
                                  if (currentPreset == key &&
                                      widget.storage.customWallpaperUrl.isEmpty)
                                    const Icon(
                                      CupertinoIcons.checkmark_circle_fill,
                                      color: AppleColors.systemBlue,
                                      size: 16,
                                    ),
                                ],
                              ),
                              Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: 20),
                Text(
                  '自定义高清壁纸（支持图片直链 URL 或本地图片路径）',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 8),
                TextSelectionMouseGuard(
                  child: CupertinoTextField(
                    controller: urlCtrl,
                    placeholder: 'https://wallpaper.example/cinema.jpg 或本地图片路径',
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: ApplePalette.of(context).groupedSecondary,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppleColors.glassBorder,
                        width: 0.5,
                      ),
                    ),
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: 13.5,
                    ),
                    placeholderStyle: TextStyle(
                      color: ApplePalette.of(context).labelTertiary,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (widget.storage.customWallpaperUrl.isNotEmpty) ...[
                      AppleCapsuleButton(
                        label: '恢复默认背景',
                        compact: true,
                        onPressed: () async {
                          urlCtrl.clear();
                          await widget.storage.setCustomWallpaperUrl('');
                          await widget.storage.setWallpaperPreset('obsidian');
                          setModalState(() {});
                          if (mounted) setState(() {});
                        },
                      ),
                      const SizedBox(width: 10),
                    ],
                    AppleCapsuleButton(
                      label: '应用壁纸',
                      icon: CupertinoIcons.checkmark_alt,
                      primary: true,
                      compact: true,
                      onPressed: () async {
                        final val = urlCtrl.text.trim();
                        await widget.storage.setCustomWallpaperUrl(val);
                        if (val.isNotEmpty) {
                          await widget.storage.setWallpaperPreset('custom');
                        }
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
  Future<void> _showSubscriptionManagerSheet({
    String iosBackLabel = '返回',
  }) async {
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    StateSetter? refreshSubPage;
    await _openIosOrModalPage<void>(
      title: isIos ? '订阅管理' : '订阅源与分组管理中心',
      backLabel: iosBackLabel,
      trailingAction: isIos
          ? CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(36, 36),
              onPressed: () async {
                await _showImportConfigDialog(iosBackLabel: '订阅管理');
                refreshSubPage?.call(() {});
              },
              child: const Text(
                '添加',
                style: TextStyle(color: AppleColors.systemBlue, fontSize: 16),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minSize: 28,
                  onPressed: () {
                    Navigator.of(context).pop();
                    _quickImportFromClipboard();
                  },
                  child: Text(
                    '剪贴板导入',
                    style: TextStyle(
                      color: ApplePalette.of(context).labelSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minSize: 28,
                  onPressed: () {
                    Navigator.of(context).pop();
                    _showImportConfigDialog();
                  },
                  child: const Text(
                    '+ 批量导入',
                    style: TextStyle(
                      color: AppleColors.systemBlue,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          refreshSubPage = setSheetState;
          final depots = _config?.depots ?? const [];
          final subs = widget.storage
              .getSubscriptions()
              .where((s) => !s.isEffectivelyPrivate)
              .toList();
          if (subs.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.folder_badge_plus,
                    color: ApplePalette.of(context).labelTertiary,
                    size: 44,
                  ),
                  SizedBox(height: 12),
                  Text(
                    '暂未添加多订阅分组',
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    isIos
                        ? '支持同时导入多个 VOD / M3U / JSON 订阅地址，并按分组归类管理。'
                        : '支持同时导入多个 VOD / M3U / JSON 订阅地址，或一键从剪贴板读取并按分组归类管理。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      AppleCapsuleButton(
                        label: '批量导入订阅',
                        icon: CupertinoIcons.add,
                        primary: true,
                        compact: true,
                        onPressed: () async {
                          if (isIos) {
                            await _showImportConfigDialog(
                              iosBackLabel: '订阅管理',
                            );
                            if (ctx.mounted) setSheetState(() {});
                          } else {
                            Navigator.of(ctx).pop();
                            _showImportConfigDialog();
                          }
                        },
                      ),
                      if (!isIos)
                        AppleCapsuleButton(
                          label: '从剪贴板导入',
                          icon: CupertinoIcons.doc_on_clipboard,
                          compact: true,
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            _quickImportFromClipboard();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            );
          }
          final byGroup = <String, List<SubscriptionEntry>>{};
          for (final s in subs) {
            byGroup.putIfAbsent(s.group, () => []).add(s);
          }
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              if (isIos) ...[
                IosSettingsGroup(
                  header: '添加订阅',
                  children: [
                    IosSettingsRow(
                      icon: CupertinoIcons.plus_app_fill,
                      iconColor: AppleColors.systemBlue,
                      title: '批量导入订阅地址或 JSON',
                      showChevron: true,
                      onTap: () async {
                        await _showImportConfigDialog(iosBackLabel: '订阅管理');
                        if (ctx.mounted) setSheetState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (depots.isNotEmpty) ...[
                AppleGroupedSection(
                  header: '多仓子仓库切换 (${depots.length})',
                  children: [
                    AppleGroupedTile(
                      icon: CupertinoIcons.archivebox_fill,
                      iconBgColor: AppleColors.systemOrange,
                      title: '切换当前多仓子仓库',
                      subtitle: widget.storage.activeDepotName.isEmpty
                          ? '共 ${depots.length} 个可选子仓库'
                          : '当前：${widget.storage.activeDepotName}',
                      trailingText: '${depots.length} 个',
                      onTap: () async {
                        if (isIos) {
                          await _showDepotPickerDialog(iosBackLabel: '订阅管理');
                          if (ctx.mounted) setSheetState(() {});
                        } else {
                          Navigator.of(ctx).pop();
                          _showDepotPickerDialog();
                        }
                      },
                    ),
                  ],
                ),
                SizedBox(height: 14),
              ],
              for (final entry in byGroup.entries) ...[
                AppleGroupedSection(
                  header: '${entry.key} (${entry.value.length})',
                  children: entry.value.map((sub) {
                    return AppleGroupedTile(
                      icon: sub.isPrivate
                          ? CupertinoIcons.lock_shield_fill
                          : CupertinoIcons.link,
                      iconBgColor: sub.enabled
                          ? AppleColors.systemBlue
                          : ApplePalette.of(context).groupedTertiary,
                      title: '${sub.name} · [${sub.format}]',
                      subtitle:
                          '${sub.siteCount} 片源 · ${sub.liveCount} 直播${sub.warehouseUrl.isNotEmpty ? " · ${sub.warehouseUrl}" : (sub.url.isNotEmpty ? " · ${sub.url}" : "")}',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CupertinoSwitch(
                            value: sub.enabled,
                            activeTrackColor: AppleColors.systemGreen,
                            onChanged: (v) async {
                              await widget.storage.toggleSubscriptionEnabled(
                                sub.id,
                                v,
                              );
                              _reloadSavedConfig();
                              setSheetState(() {});
                            },
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.only(left: 6),
                            minSize: 28,
                            onPressed: () async {
                              final nextGroup = await _promptGroupSelection(
                                ctx,
                                privateMode: sub.isEffectivelyPrivate,
                                currentGroup: sub.group,
                                title: '修改订阅分组 · ${sub.name}',
                              );
                              if (nextGroup == null || !mounted) return;
                              await widget.storage.updateSubscriptionGroup(
                                sub.id,
                                nextGroup,
                              );
                              if (!mounted) return;
                              _reloadSavedConfig();
                              if (ctx.mounted) setSheetState(() {});
                            },
                            child: const Icon(
                              CupertinoIcons.folder,
                              color: AppleColors.systemBlue,
                              size: 18,
                            ),
                          ),
                          CupertinoButton(
                            padding: const EdgeInsets.only(left: 6),
                            minSize: 28,
                            onPressed: () async {
                              if (_isIosNativeFlow) {
                                final ok = await _confirmIosDestructiveAction(
                                  ctx,
                                  title: '删除订阅「${sub.name}」？',
                                  message:
                                      '删除后将移除该订阅下的片源与直播频道，已保存的收藏与观看历史会保留。',
                                  confirmLabel: '删除',
                                );
                                if (!ok || !mounted) return;
                              }
                              try {
                                await widget.storage.removeSubscription(sub.id);
                                if (!mounted) return;
                                _reloadSavedConfig();
                                if (ctx.mounted) setSheetState(() {});
                              } catch (_) {
                                if (mounted) {
                                  _showAppleNotice('删除未保存', '订阅变更未能保存，请重试。');
                                }
                              }
                            },
                            child: const Icon(
                              CupertinoIcons.trash,
                              color: AppleColors.systemRed,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
              ],
            ],
          );
        },
      ),
    );
  }
  Future<void> _showDepotPickerDialog({String iosBackLabel = '返回'}) async {
    final depots = _config?.depots ?? const [];
    if (depots.isEmpty) return;
    await _openIosOrModalPage<void>(
      title: '切换多仓子仓库 (${depots.length})',
      backLabel: iosBackLabel,
      builder: (ctx) {
        bool loading = false;
        String? errorMsg;
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CupertinoActivityIndicator(radius: 10),
                        SizedBox(width: 10),
                        Text(
                          '正在加载所选子仓库…',
                          style: TextStyle(
                            color: ApplePalette.of(context).labelSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (errorMsg != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Text(
                      errorMsg!,
                      style: const TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13,
                      ),
                    ),
                  ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: depots.length,
                    separatorBuilder: (_, __) => SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final d = depots[i];
                      final owners = widget.storage.getSubscriptions()
                          .where((sub) => sub.id == d.subscriptionId);
                      final owner = owners.isEmpty ? null : owners.first;
                      final isCurrent = d.url == (owner?.url ?? widget.storage.configOrigin);
                      return Container(
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? const Color(0x330A84FF)
                              : ApplePalette.of(context).groupedSecondary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: AppleGroupedTile(
                          icon: CupertinoIcons.archivebox_fill,
                          iconBgColor: isCurrent
                              ? AppleColors.systemBlue
                              : ApplePalette.of(context).groupedTertiary,
                          title: d.name,
                          subtitle: d.url,
                          trailing: isCurrent
                              ? const Icon(
                                  CupertinoIcons.checkmark_alt,
                                  color: AppleColors.systemBlue,
                                  size: 18,
                                )
                              : null,
                          onTap: loading
                              ? null
                              : () async {
                                  setModalState(() {
                                    loading = true;
                                    errorMsg = null;
                                  });
                                  try {
                                    if (owner != null) {
                                      final withDirectory = owner.copyWith(depots: depots
                                          .where((entry) => entry.subscriptionId == owner.id).toList());
                                      final updated = await widget.client.switchSubscriptionDepot(withDirectory, d);
                                      if (!ctx.mounted) return;
                                      await widget.storage.upsertSubscriptions([updated]);
                                    } else {
                                      final resolved = await widget.client.resolveConfigInput(urlInput: d.url);
                                      if (!ctx.mounted) return;
                                      await widget.storage.saveConfig(resolved.rawConfig,
                                        origin: resolved.origin,
                                        depots: [...depots, ...resolved.depots],
                                        activeDepotName: resolved.activeDepotName.isEmpty ? d.name : resolved.activeDepotName);
                                    }
                                    if (ctx.mounted) Navigator.of(ctx).pop();
                                    _reloadSavedConfig();
                                  } catch (e) {
                                    if (!ctx.mounted) return;
                                    setModalState(() {
                                      loading = false;
                                      errorMsg = '切换仓库失败：$e';
                                    });
                                  }
                                },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
  List<String> _collectExistingGroups(bool privateMode) {
    final def = privateMode ? '隐私分组' : '默认分组';
    final result = <String>[def];
    for (final s in _config?.sites ?? const <CmsSite>[]) {
      if (s.isEffectivelyPrivate != privateMode) continue;
      final g = s.group.trim().isEmpty ? def : s.group.trim();
      if (!result.contains(g)) result.add(g);
    }
    for (final sub in widget.storage.getSubscriptions()) {
      if (sub.isEffectivelyPrivate != privateMode) continue;
      final g = sub.group.trim().isEmpty ? def : sub.group.trim();
      if (!result.contains(g)) result.add(g);
    }
    if (!privateMode) {
      for (final preset in const ['常用秒播', '4K网盘', '备用线路']) {
        if (!result.contains(preset)) result.add(preset);
      }
    }
    return result;
  }

  Future<String?> _promptGroupSelection(
    BuildContext hostContext, {
    required bool privateMode,
    String currentGroup = '',
    String title = '修改分组',
  }) async {
    final def = privateMode ? '隐私分组' : '默认分组';
    final groups = _collectExistingGroups(privateMode);
    final ctrl = TextEditingController(
      text: currentGroup.trim().isEmpty ? def : currentGroup.trim(),
    );
    String? errorMsg;
    return await _openIosOrModalPage<String>(
      hostContext: hostContext,
      title: title,
      backLabel: '返回',
      maxWidth: 460,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setModalState) {
          final bottomInset = MediaQuery.viewInsetsOf(sheetCtx).bottom +
              MediaQuery.paddingOf(sheetCtx).bottom;
          void submitGroup(String candidate) {
            final clean = candidate.trim();
            if (clean.isEmpty) {
              setModalState(() => errorMsg = '分组名称不能为空');
              return;
            }
            if (!privateMode &&
                (clean.contains('隐私') || clean.contains('私密'))) {
              setModalState(() => errorMsg = '公开线路不能移入包含“隐私/私密”的分组');
              return;
            }
            Navigator.of(sheetCtx).pop(clean);
          }

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择已有分组或输入新分组名称：',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in groups)
                      GestureDetector(
                        onTap: () => submitGroup(g),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: g == ctrl.text.trim()
                                ? const Color(0x400A84FF)
                                : ApplePalette.of(context).groupedSecondary,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: g == ctrl.text.trim()
                                  ? AppleColors.systemBlue
                                  : const Color(0x2EFFFFFF),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            g,
                            style: TextStyle(
                              color: g == ctrl.text.trim()
                                  ? Colors.white
                                  : ApplePalette.of(context).labelPrimary,
                              fontSize: 13,
                              fontWeight: g == ctrl.text.trim()
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: 14),
                TextSelectionMouseGuard(
                  child: CupertinoTextField(
                    controller: ctrl,
                    placeholder: '输入自定义分组名称…',
                    style: TextStyle(
                      color: ApplePalette.of(sheetCtx).labelPrimary,
                      fontSize: 14.5,
                    ),
                    placeholderStyle: TextStyle(
                      color: ApplePalette.of(sheetCtx).labelTertiary,
                      fontSize: 14,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: ApplePalette.isDarkOf(sheetCtx)
                          ? const Color(0xFF2C2C2E)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: ApplePalette.of(sheetCtx).separator,
                        width: 0.65,
                      ),
                    ),
                    onChanged: (_) {
                      if (errorMsg != null) {
                        setModalState(() => errorMsg = null);
                      } else {
                        setModalState(() {});
                      }
                    },
                    onSubmitted: submitGroup,
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorMsg!,
                    style: const TextStyle(
                      color: AppleColors.systemRed,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: AppleCapsuleButton(
                    label: '确定分组',
                    primary: true,
                    onPressed: () => submitGroup(ctrl.text),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<bool> _confirmAndDeleteSingleSite(
    BuildContext hostContext,
    CmsSite site,
  ) async {
    final choice = await showAppleNativeAlert(
      hostContext,
      title: '删除「${site.name}」？',
      message: '删除后该线路将从片源列表移除，后续刷新订阅也不会重现；可在「管理线路 → 恢复已删」中恢复。',
      actions: const [
        AppleNativeAlertAction(id: 'cancel', title: '取消', isCancel: true),
        AppleNativeAlertAction(
          id: 'delete',
          title: '删除',
          isDestructive: true,
        ),
      ],
    );
    if (choice != 'delete' || !mounted) return false;
    try {
      await widget.storage.removeSite(widget.storage.siteIdentityOf(site));
      if (!site.isEffectivelyPrivate &&
          widget.storage.preferredSiteKey == site.key) {
        await widget.storage.setPreferredSiteKey('');
      }
      if (mounted) _reloadSavedConfig();
      return true;
    } catch (e) {
      if (mounted) _showAppleNotice('删除未保存', '$e');
      return false;
    }
  }

  Future<bool> _showEditSingleSiteDialog(
    BuildContext hostContext,
    CmsSite site,
  ) async {
    final privateMode = site.isEffectivelyPrivate;
    final defGroup = privateMode ? '隐私分组' : '默认分组';
    final existingGroups = _collectExistingGroups(privateMode);
    final original = widget.storage.getOriginalSite(site) ?? site;
    final existingOv = widget.storage.getSiteOverride(site);
    final nameCtrl = TextEditingController(text: site.name);
    final groupCtrl = TextEditingController(
      text: site.group.trim().isEmpty ? defGroup : site.group.trim(),
    );
    final apiCtrl = TextEditingController(text: site.api);
    final playUrlCtrl = TextEditingController(text: site.playUrl);
    final extCtrl = TextEditingController(
      text: site.rawExtension ?? site.ext,
    );
    bool searchable = site.searchable;
    bool saving = false;
    String? errorMsg;

    final result = await _openIosOrModalPage<bool>(
      hostContext: hostContext,
      title: '编辑线路',
      backLabel: '返回',
      maxWidth: 540,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setModalState) {
          final bottomInset = MediaQuery.viewInsetsOf(sheetCtx).bottom +
              MediaQuery.paddingOf(sheetCtx).bottom;
          Widget fieldLabel(String label) => Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 10),
            child: Text(
              label,
              style: TextStyle(
                color: ApplePalette.of(context).labelSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

          Widget textInput(
            TextEditingController ctrl,
            String placeholder, {
            int maxLines = 1,
          }) {
            final p = ApplePalette.of(sheetCtx);
            return TextSelectionMouseGuard(
              child: CupertinoTextField(
                controller: ctrl,
                placeholder: placeholder,
                maxLines: maxLines,
                autocorrect: false,
                style: TextStyle(color: p.labelPrimary, fontSize: 14.5),
                placeholderStyle: TextStyle(
                  color: p.labelTertiary,
                  fontSize: 14,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: p.isDark ? const Color(0xFF2C2C2E) : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: p.separator, width: 0.65),
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + bottomInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                fieldLabel('线路名称'),
                textInput(nameCtrl, '输入线路显示名称'),
                fieldLabel('所属分组'),
                textInput(groupCtrl, defGroup),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final g in existingGroups)
                      GestureDetector(
                        onTap: () => setModalState(() => groupCtrl.text = g),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: groupCtrl.text.trim() == g
                                ? const Color(0x400A84FF)
                                : ApplePalette.of(context).groupedSecondary,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: groupCtrl.text.trim() == g
                                  ? AppleColors.systemBlue
                                  : const Color(0x26FFFFFF),
                              width: 0.7,
                            ),
                          ),
                          child: Text(
                            g,
                            style: TextStyle(
                              color: ApplePalette.of(context).labelPrimary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                fieldLabel('接口地址 / Spider API'),
                textInput(apiCtrl, 'https://… 或 csp_…'),
                fieldLabel('解析地址 PlayUrl（可选）'),
                textInput(playUrlCtrl, '留空使用直连或全局解析'),
                fieldLabel('扩展参数 Ext（可选）'),
                textInput(extCtrl, '自定义扩展配置或规则地址', maxLines: 2),
                SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: ApplePalette.of(context).groupedSecondary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '允许参与全站聚合搜索',
                          style: TextStyle(
                            color: ApplePalette.of(context).labelPrimary,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      CupertinoSwitch(
                        value: searchable,
                        activeTrackColor: AppleColors.systemGreen,
                        onChanged: (v) => setModalState(() => searchable = v),
                      ),
                    ],
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorMsg!,
                    style: const TextStyle(
                      color: AppleColors.systemRed,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: AppleCapsuleButton(
                        label: '保存修改',
                        primary: true,
                        onPressed: saving
                            ? null
                            : () async {
                                final newName = nameCtrl.text.trim();
                                final newGroup = groupCtrl.text.trim().isEmpty
                                    ? defGroup
                                    : groupCtrl.text.trim();
                                final newApi = apiCtrl.text.trim();
                                final newPlay = playUrlCtrl.text.trim();
                                final newExt = extCtrl.text;
                                if (newName.isEmpty || newApi.isEmpty) {
                                  setModalState(
                                    () => errorMsg = '线路名称与接口地址不能为空',
                                  );
                                  return;
                                }
                                if (!privateMode &&
                                    (newGroup.contains('隐私') ||
                                        newGroup.contains('私密'))) {
                                  setModalState(
                                    () => errorMsg = '公开线路不能移入包含“隐私/私密”的分组',
                                  );
                                  return;
                                }
                                setModalState(() {
                                  saving = true;
                                  errorMsg = null;
                                });
                                try {
                                  final origGroup = original.group.trim().isEmpty
                                      ? defGroup
                                      : original.group.trim();
                                  final origExt =
                                      original.rawExtension ?? original.ext;
                                  final nextOv = SiteOverride(
                                    name: newName != original.name
                                        ? newName
                                        : null,
                                    group: newGroup != origGroup
                                        ? newGroup
                                        : null,
                                    api: newApi != original.api ? newApi : null,
                                    playUrl: newPlay != original.playUrl
                                        ? newPlay
                                        : null,
                                    ext: newExt != origExt ? newExt : null,
                                    searchable:
                                        searchable != original.searchable
                                        ? searchable
                                        : null,
                                  );
                                  await widget.storage.saveSiteOverride(
                                    site,
                                    nextOv.isEmpty ? null : nextOv,
                                  );
                                  if (mounted) _reloadSavedConfig();
                                  if (sheetCtx.mounted) {
                                    Navigator.of(sheetCtx).pop(true);
                                  }
                                } catch (e) {
                                  if (sheetCtx.mounted) {
                                    setModalState(() {
                                      saving = false;
                                      errorMsg = '$e';
                                    });
                                  }
                                }
                              },
                      ),
                    ),
                    if (existingOv != null) ...[
                      const SizedBox(width: 10),
                      AppleCapsuleButton(
                        label: '恢复原始',
                        onPressed: saving
                            ? null
                            : () async {
                                setModalState(() => saving = true);
                                try {
                                  await widget.storage.saveSiteOverride(
                                    site,
                                    null,
                                  );
                                  if (mounted) _reloadSavedConfig();
                                  if (sheetCtx.mounted) {
                                    Navigator.of(sheetCtx).pop(true);
                                  }
                                } catch (e) {
                                  if (sheetCtx.mounted) {
                                    setModalState(() {
                                      saving = false;
                                      errorMsg = '$e';
                                    });
                                  }
                                }
                              },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Center(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    minimumSize: const Size(28, 28),
                    onPressed: saving
                        ? null
                        : () async {
                            final deleted = await _confirmAndDeleteSingleSite(
                              sheetCtx,
                              site,
                            );
                            if (deleted && sheetCtx.mounted) {
                              Navigator.of(sheetCtx).pop(true);
                            }
                          },
                    child: const Text(
                      '删除这条线路',
                      style: TextStyle(
                        color: AppleColors.systemRed,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    return result == true;
  }

  Future<void> _showSingleSiteActionSheet(
    BuildContext hostContext,
    CmsSite site, {
    required bool privateMode,
    VoidCallback? onChanged,
  }) async {
    final hasOv = widget.storage.hasSiteOverride(site);
    final isPref = !privateMode && widget.storage.preferredSiteKey == site.key;
    final curGroup = site.group.trim().isEmpty
        ? (privateMode ? '隐私分组' : '默认分组')
        : site.group.trim();
    final choice = await showAppleNativeActionSheet<String>(
      hostContext,
      title: site.name,
      message: '当前分组：$curGroup · 接口：${site.api}',
      options: [
        const AppleNativeSheetOption<String>(value: 'group', title: '修改分组'),
        const AppleNativeSheetOption<String>(value: 'edit', title: '编辑线路信息'),
        if (!privateMode && site.supported)
          AppleNativeSheetOption<String>(
            value: 'preferred',
            title: isPref ? '取消默认偏好源' : '设为默认偏好源',
          ),
        if (hasOv)
          const AppleNativeSheetOption<String>(value: 'reset', title: '恢复原始配置'),
        const AppleNativeSheetOption<String>(
          value: 'delete',
          title: '删除这条线路',
          isDestructive: true,
        ),
      ],
      cancelLabel: '取消',
    );
    if (choice == null || !hostContext.mounted) return;
    if (choice == 'group') {
      final nextGroup = await _promptGroupSelection(
        hostContext,
        privateMode: privateMode,
        currentGroup: curGroup,
        title: '修改分组 · ${site.name}',
      );
      if (nextGroup != null && mounted) {
        try {
          await widget.storage.updateSitesGroupBatch([site], nextGroup);
          _reloadSavedConfig();
          onChanged?.call();
        } catch (e) {
          if (mounted) _showAppleNotice('分组未保存', '$e');
        }
      }
    } else if (choice == 'edit') {
      final changed = await _showEditSingleSiteDialog(hostContext, site);
      if (changed) onChanged?.call();
    } else if (choice == 'preferred') {
      await widget.storage.setPreferredSiteKey(isPref ? '' : site.key);
      onChanged?.call();
    } else if (choice == 'reset') {
      await widget.storage.saveSiteOverride(site, null);
      if (mounted) _reloadSavedConfig();
      onChanged?.call();
    } else if (choice == 'delete') {
      final deleted = await _confirmAndDeleteSingleSite(hostContext, site);
      if (deleted) onChanged?.call();
    }
  }

  Future<bool> _showRestoreRemovedSitesSheet(
    BuildContext hostContext,
    bool privateMode,
  ) async {
    bool changed = false;
    await _openIosOrModalPage<void>(
      hostContext: hostContext,
      title: '已删线路恢复',
      backLabel: '返回',
      maxWidth: 520,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setModalState) {
          final entries = widget.storage.getRemovedSiteEntries(
            privateMode: privateMode,
          );
          if (entries.isEmpty) {
            return Padding(
              padding: EdgeInsets.all(28),
              child: Center(
                child: Text(
                  '暂无已删除的线路',
                  style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${entries.length} 条已删线路',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(28, 28),
                      onPressed: () async {
                        await widget.storage.resetRemovedSites(
                          privateMode: privateMode,
                        );
                        changed = true;
                        if (mounted) _reloadSavedConfig();
                        if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                      },
                      child: const Text(
                        '全部恢复',
                        style: TextStyle(
                          color: AppleColors.systemBlue,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final item = entries[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: ApplePalette.of(context).groupedSecondary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.site.name,
                                  style: TextStyle(
                                    color: ApplePalette.of(context).labelPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '${item.site.group} · ${item.site.api}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: ApplePalette.of(context).labelSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          AppleCapsuleButton(
                            label: '恢复',
                            compact: true,
                            onPressed: () async {
                              await widget.storage.restoreSite(item.identity);
                              changed = true;
                              if (mounted) _reloadSavedConfig();
                              if (sheetCtx.mounted) setModalState(() {});
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
    return changed;
  }

  Future<void> _managePickerSites(bool privateGroup) async {
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final defGroup = privateGroup ? '隐私分组' : '默认分组';
    List<CmsSite> ordered = (_config?.sites ?? const <CmsSite>[])
        .where((s) => s.isEffectivelyPrivate == privateGroup)
        .toList();
    final removed = <CmsSite>[];
    final selectedKeys = <String>{};
    bool batchMode = false;
    String selectedGroup = '全部';
    bool saving = false;

    void syncOrderedFromConfig() {
      final freshById = <String, CmsSite>{
        for (final s in (_config?.sites ?? const <CmsSite>[]))
          if (s.isEffectivelyPrivate == privateGroup)
            widget.storage.siteIdentityOf(s): s,
      };
      final removedIds = removed.map(widget.storage.siteIdentityOf).toSet();
      final nextOrdered = <CmsSite>[];
      for (final old in ordered) {
        final id = widget.storage.siteIdentityOf(old);
        final updated = freshById.remove(id);
        if (updated != null && !removedIds.contains(id)) {
          nextOrdered.add(updated);
        }
      }
      for (final entry in freshById.entries) {
        if (!removedIds.contains(entry.key)) {
          nextOrdered.add(entry.value);
        }
      }
      ordered = nextOrdered;
      final validKeys = ordered.map((s) => s.key).toSet();
      selectedKeys.retainAll(validKeys);
    }

    await _openIosOrModalPage<void>(
      title: '管理线路',
      backLabel: '返回',
      maxWidth: 640,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
        final safeBottom = MediaQuery.paddingOf(ctx).bottom;
        final groups = <String>['全部'];
        final groupCounts = <String, int>{'全部': ordered.length};
        for (final s in ordered) {
          final g = s.group.trim().isEmpty ? defGroup : s.group.trim();
          if (!groups.contains(g)) groups.add(g);
          groupCounts[g] = (groupCounts[g] ?? 0) + 1;
        }
        if (!groups.contains(selectedGroup)) selectedGroup = '全部';
        final visibleSites = selectedGroup == '全部'
            ? ordered
            : ordered
                  .where(
                    (s) =>
                        (s.group.trim().isEmpty ? defGroup : s.group.trim()) ==
                        selectedGroup,
                  )
                  .toList();
        final persistedRemovedCount = widget.storage
            .getRemovedSiteEntries(privateMode: privateGroup)
            .length;

        Widget buildRowTile(CmsSite site, {int? reorderIndex}) {
          final g = site.group.trim().isEmpty ? defGroup : site.group.trim();
          final checked = selectedKeys.contains(site.key);
          return ListTile(
            key: ValueKey(site.key),
            dense: true,
            title: Text(
              site.name,
              style: TextStyle(color: ApplePalette.of(context).labelPrimary),
            ),
            subtitle: Text(
              '$g · ${site.supported ? "可用" : "未适配"}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ApplePalette.of(context).labelSecondary,
                fontSize: 12,
              ),
            ),
            onTap: batchMode
                ? () => update(() {
                    if (checked) {
                      selectedKeys.remove(site.key);
                    } else {
                      selectedKeys.add(site.key);
                    }
                  })
                : null,
            leading: batchMode
                ? Icon(
                    checked
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                    color: checked
                        ? AppleColors.systemBlue
                        : ApplePalette.of(context).labelSecondary,
                    size: 21,
                  )
                : (reorderIndex != null
                      ? ReorderableDragStartListener(
                          index: reorderIndex,
                          child: Icon(Icons.drag_handle),
                        )
                      : Icon(
                          CupertinoIcons.line_horizontal_3,
                          size: 18,
                          color: ApplePalette.of(context).labelTertiary,
                        )),
            trailing: batchMode
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: saving
                            ? null
                            : () async {
                                final nextGroup = await _promptGroupSelection(
                                  ctx,
                                  privateMode: privateGroup,
                                  currentGroup: g,
                                  title: '修改分组 · ${site.name}',
                                );
                                if (nextGroup == null || !mounted) return;
                                await widget.storage.updateSitesGroupBatch(
                                  [site],
                                  nextGroup,
                                );
                                if (mounted) _reloadSavedConfig();
                                if (ctx.mounted) {
                                  update(syncOrderedFromConfig);
                                }
                              },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: ApplePalette.of(context).groupedSecondary,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0x2EFFFFFF),
                              width: 0.6,
                            ),
                          ),
                          child: Text(
                            g,
                            style: TextStyle(
                              color: ApplePalette.of(context).labelSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '编辑这条线路',
                        icon: const Icon(Icons.edit_outlined, size: 19),
                        onPressed: saving
                            ? null
                            : () async {
                                final changed = await _showEditSingleSiteDialog(
                                  ctx,
                                  site,
                                );
                                if (changed && ctx.mounted) {
                                  update(syncOrderedFromConfig);
                                }
                              },
                      ),
                      IconButton(
                        tooltip: '删除这条线路',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: saving
                            ? null
                            : () => update(() {
                                ordered.removeWhere((s) => s.key == site.key);
                                selectedKeys.remove(site.key);
                                removed.add(site);
                              }),
                      ),
                    ],
                  ),
          );
        }

        final canDragReorder = selectedGroup == '全部' && !batchMode;

        final unsupportedCount = ordered.where((s) => !s.supported).length;
        final content = Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: const Size(28, 28),
                    onPressed: saving
                        ? null
                        : () => update(() {
                            batchMode = !batchMode;
                            if (!batchMode) selectedKeys.clear();
                          }),
                    child: Text(
                      batchMode ? '完成多选' : '批量分组/删除',
                      style: const TextStyle(
                        color: AppleColors.systemBlue,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!batchMode && unsupportedCount > 0)
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      minimumSize: const Size(28, 28),
                      onPressed: saving
                          ? null
                          : () => update(() {
                              final toRemove = ordered
                                  .where((s) => !s.supported)
                                  .toList();
                              for (final s in toRemove) {
                                ordered.removeWhere((e) => e.key == s.key);
                                selectedKeys.remove(s.key);
                                removed.add(s);
                              }
                            }),
                      child: Text(
                        '隐藏未适配 ($unsupportedCount)',
                        style: const TextStyle(
                          color: AppleColors.systemOrange,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (batchMode) ...[
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      minimumSize: const Size(28, 28),
                      onPressed: () => update(() {
                        final visibleKeys = visibleSites
                            .map((s) => s.key)
                            .toSet();
                        if (visibleKeys.isNotEmpty &&
                            visibleKeys.every(selectedKeys.contains)) {
                          selectedKeys.removeAll(visibleKeys);
                        } else {
                          selectedKeys.addAll(visibleKeys);
                        }
                      }),
                      child: Text(
                        '全选当前组',
                        style: TextStyle(
                          color: ApplePalette.of(context).labelSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    if (selectedKeys.isNotEmpty) ...[
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        minimumSize: const Size(28, 28),
                        onPressed: () async {
                          final chosen = ordered
                              .where((s) => selectedKeys.contains(s.key))
                              .toList();
                          final nextGroup = await _promptGroupSelection(
                            ctx,
                            privateMode: privateGroup,
                            title: '批量移动 ${chosen.length} 条线路到分组',
                          );
                          if (nextGroup == null || !mounted) return;
                          await widget.storage.updateSitesGroupBatch(
                            chosen,
                            nextGroup,
                          );
                          if (mounted) _reloadSavedConfig();
                          if (ctx.mounted) {
                            update(() {
                              syncOrderedFromConfig();
                              selectedKeys.clear();
                              batchMode = false;
                            });
                          }
                        },
                        child: Text(
                          '移至分组 (${selectedKeys.length})',
                          style: const TextStyle(
                            color: AppleColors.systemGreen,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        minimumSize: const Size(28, 28),
                        onPressed: () => update(() {
                          final toRemove = ordered
                              .where((s) => selectedKeys.contains(s.key))
                              .toList();
                          ordered.removeWhere(
                            (s) => selectedKeys.contains(s.key),
                          );
                          removed.addAll(toRemove);
                          selectedKeys.clear();
                          batchMode = false;
                        }),
                        child: Text(
                          '移除 (${selectedKeys.length})',
                          style: const TextStyle(
                            color: AppleColors.systemRed,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                  const Spacer(),
                  if (persistedRemovedCount > 0)
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(28, 28),
                      onPressed: saving
                          ? null
                          : () async {
                              final restored =
                                  await _showRestoreRemovedSitesSheet(
                                    ctx,
                                    privateGroup,
                                  );
                              if (restored && ctx.mounted) {
                                update(syncOrderedFromConfig);
                              }
                            },
                      child: Text(
                        '恢复已删 ($persistedRemovedCount)',
                        style: const TextStyle(
                          color: AppleColors.systemOrange,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (groups.length > 1)
              SizedBox(
                height: 34,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: groups.length,
                  separatorBuilder: (_, __) => SizedBox(width: 6),
                  itemBuilder: (_, idx) {
                    final g = groups[idx];
                    final isSel = g == selectedGroup;
                    return GestureDetector(
                      onTap: () => update(() => selectedGroup = g),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppleColors.systemBlue
                              : ApplePalette.of(context).groupedSecondary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$g ${groupCounts[g] ?? 0}',
                          style: TextStyle(
                            color: isSel
                                ? Colors.white
                                : ApplePalette.of(context).labelPrimary,
                            fontSize: 12,
                            fontWeight: isSel
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(ctx).copyWith(
                  dragDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: canDragReorder
                    ? ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: isIos
                            ? const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              )
                            : null,
                        itemCount: ordered.length,
                        onReorder: (from, to) => update(() {
                          if (to > from) to--;
                          ordered.insert(to, ordered.removeAt(from));
                        }),
                        itemBuilder: (_, i) =>
                            buildRowTile(ordered[i], reorderIndex: i),
                      )
                    : ListView.builder(
                        padding: isIos
                            ? const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              )
                            : null,
                        itemCount: visibleSites.length,
                        itemBuilder: (_, i) => buildRowTile(visibleSites[i]),
                      ),
              ),
            ),
            Padding(
              padding: isIos
                  ? EdgeInsets.fromLTRB(16, 8, 16, safeBottom + 16)
                  : const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: AppleCapsuleButton(
                label: removed.isEmpty
                    ? '保存顺序'
                    : '保存并移除 ${removed.length} 条线路',
                onPressed: saving
                    ? null
                    : () async {
                        update(() => saving = true);
                        try {
                          await widget.storage.savePickerEdits(
                            ordered,
                            removed,
                          );
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          if (mounted) _reloadSavedConfig();
                        } catch (_) {
                          if (mounted) {
                            _showAppleNotice('线路变更未保存', '保存未完成，请重试。');
                          }
                        } finally {
                          if (ctx.mounted) update(() => saving = false);
                        }
                      },
              ),
            ),
          ],
        );
        if (isIos) return content;
        return SizedBox(
          height: (MediaQuery.sizeOf(ctx).height * .68).clamp(380.0, 620.0),
          child: content,
        );
      }),
    );
  }

  Future<void> _openSpiderExtensionsPage({String iosBackLabel = '切换片源'}) {
    final sites = _config?.sites ?? const <CmsSite>[];
    return _openIosOrModalPage<void>(
      title: '蜘蛛扩展与网关',
      backLabel: iosBackLabel,
      maxWidth: 640,
      builder: (ctx) => ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          18,
          16,
          MediaQuery.paddingOf(ctx).bottom + 36,
        ),
        children: [
          SpiderExtensionsPanel(
            storage: widget.storage,
            client: widget.client,
            sites: sites,
            onChanged: () {
              _reloadSavedConfig();
              if (mounted) setState(() {});
            },
            onNotice: _showAppleNotice,
          ),
        ],
      ),
    );
  }

  void _showSitePickerDialog() {
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final inPrivacyMode = _privateSessionUnlocked;
    final defaultGroupName = inPrivacyMode ? '隐私分组' : '默认分组';
    List<CmsSite> computeSupported() {
      final rawSupported = inPrivacyMode
          ? (_config?.privateSupportedSites ?? const <CmsSite>[])
          : (_config?.publicSupportedSites ?? const <CmsSite>[]);
      final hasRealSupported = rawSupported.any(
        (s) => !CspBridge.isPickerHiddenUtilitySite(s),
      );
      return hasRealSupported
          ? rawSupported
              .where((s) =>
                  !CspBridge.isPickerHiddenUtilitySite(s) ||
                  s.key == _activeSite?.key)
              .toList()
          : rawSupported;
    }

    final initialSupported = computeSupported();
    final initialCountSource = initialSupported.isNotEmpty
        ? initialSupported
        : (_config?.sites ?? const <CmsSite>[])
            .where((s) =>
                (inPrivacyMode ? s.isEffectivelyPrivate : !s.isEffectivelyPrivate) &&
                !CspBridge.isPickerHiddenUtilitySite(s))
            .toList();
    final initialTotalCount = initialCountSource.length;
    final initialAvailableCount =
        initialCountSource.where((s) => s.supported).length;
    String selectedGroup = '全部';
    String searchQuery = '';
    bool onlyAvailable = false;
    final searchCtrl = TextEditingController();
    final importPrivateButton = CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(28, 28),
      onPressed: () {
        Navigator.of(context).pop();
        _showImportConfigDialog(
          initialGroup: '隐私分组',
          initialIsPrivate: true,
        );
      },
      child: const Text(
        '+ 导入隐私源',
        style: TextStyle(color: AppleColors.systemBlue, fontSize: 13),
      ),
    );
    _openIosOrModalPage<void>(
      title: inPrivacyMode
          ? '切换隐私片源 (可用 $initialAvailableCount / 共 $initialTotalCount)'
          : '切换片源 (可用 $initialAvailableCount / 共 $initialTotalCount)',
      backLabel: '返回',
      maxWidth: 680,
      ignoreKeyboardInsets: true,
      trailingAction: inPrivacyMode
          ? (isIos
              ? importPrivateButton
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(28, 28),
                      onPressed: () {
                        Navigator.of(context).pop();
                        _showPrivateResourcesSheet();
                      },
                      child: const Text(
                        '管理 / 密码',
                        style: TextStyle(
                          color: Color(0xFFBF5AF2),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    importPrivateButton,
                  ],
                ))
          : CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(28, 28),
              onPressed: () {
                Navigator.of(context).pop();
                _showImportConfigDialog();
              },
              child: const Text(
                '+ 导入订阅',
                style: TextStyle(color: AppleColors.systemBlue, fontSize: 13.5),
              ),
            ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setPickerState) {
          final size = MediaQuery.sizeOf(ctx);
          final safeBottom = MediaQuery.paddingOf(ctx).bottom;
          final supported = computeSupported();
          final countSource = supported.isNotEmpty
              ? supported
              : (_config?.sites ?? const <CmsSite>[])
                  .where((s) =>
                      (inPrivacyMode
                          ? s.isEffectivelyPrivate
                          : !s.isEffectivelyPrivate) &&
                      !CspBridge.isPickerHiddenUtilitySite(s))
                  .toList();
          final availableCount =
              countSource.where((s) => s.supported).length;
          final unsupportedSites =
              countSource.where((s) => !s.supported).toList();
          final unsupportedCount = unsupportedSites.length;
          final groupCounts = <String, int>{'全部': countSource.length};
          final groups = <String>['全部'];
          for (final s in countSource) {
            if (!inPrivacyMode && s.isEffectivelyPrivate) continue;
            if (inPrivacyMode && !s.isEffectivelyPrivate) continue;
            final g =
                s.group.trim().isEmpty ? defaultGroupName : s.group.trim();
            if (!groups.contains(g)) groups.add(g);
            groupCounts[g] = (groupCounts[g] ?? 0) + 1;
          }
          if (!groups.contains(selectedGroup)) {
            selectedGroup = '全部';
          }
          bool matchesFilter(CmsSite s) {
            if (onlyAvailable && !s.supported) return false;
            final g =
                s.group.trim().isEmpty ? defaultGroupName : s.group.trim();
            final groupMatch = selectedGroup == '全部' || g == selectedGroup;
            if (!groupMatch) return false;
            final q = searchQuery.trim().toLowerCase();
            if (q.isEmpty) return true;
            return s.name.toLowerCase().contains(q) ||
                g.toLowerCase().contains(q) ||
                s.api.toLowerCase().contains(q);
          }
          // Keep all working routes grouped cleanly at the top and unsupported
          // Android .so-only routes grouped neatly at the bottom.
          final matchedSites = supported.where(matchesFilter).toList();
          final filteredSites = <CmsSite>[
            for (final s in matchedSites)
              if (s.supported) s,
            for (final s in matchedSites)
              if (!s.supported) s,
          ];

          String siteBadgeLabel(CmsSite s) {
            final lower = '${s.name} ${s.api} ${s.key}'.toLowerCase();
            if (s.usesAdapterPack) return '扩展插件';
            if (s.usesSpiderGateway) return '网关代理';
            if (CspBridge.isMyDriveSite(s)) return '云盘配置';
            if (CspBridge.isSearchOnlySite(s)) return '搜索专用';
            if (CspBridge.isNetdiskSite(s)) return '4K网盘';
            if (lower.contains('豆瓣') || lower.contains('douban')) {
              return '官方片单';
            }
            if (lower.contains('4k') || lower.contains('2160')) {
              return '4K超清';
            }
            if (s.isScriptOrJarApi) return '专用适配';
            return '直连点播';
          }

          Color siteBadgeColor(CmsSite s) {
            final badge = siteBadgeLabel(s);
            return switch (badge) {
              '扩展插件' => const Color(0xFFBF5AF2),
              '网关代理' => const Color(0xFF5AC8FA),
              '云盘配置' => const Color(0xFF0A84FF),
              '搜索专用' => const Color(0xFF64D2FF),
              '4K网盘' => const Color(0xFF30D158),
              '4K超清' => const Color(0xFF30D158),
              '官方片单' => const Color(0xFFFF9F0A),
              '专用适配' => const Color(0xFF5E5CE6),
              _ => const Color(0xFF0A84FF),
            };
          }

          final scrollView = CustomScrollView(
            key: const ValueKey('site-picker-scroll'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(
                children: [
                  Expanded(
                    child: AppleSearchField(
                      controller: searchCtrl,
                      placeholder: '快速筛选片源名称或分组…',
                      onChanged: (v) => setPickerState(() => searchQuery = v),
                    ),
                  ),
                  if (isIos && inPrivacyMode) ...[
                    const SizedBox(width: 6),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      minimumSize: const Size(28, 28),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _showPrivateResourcesSheet();
                      },
                      child: const Text(
                        '管理 / 密码',
                        style: TextStyle(
                          color: Color(0xFFBF5AF2),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    minimumSize: const Size(28, 28),
                    child: const Text(
                      '管理线路',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _managePickerSites(inPrivacyMode);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Centered Group Pills Row
              SizedBox(
                height: MediaQuery.textScalerOf(ctx).scale(16) + 20,
                child: _SheetOwnedScrollController(
                  builder: (ctx, groupsScrollController) =>
                      DesktopHorizontalScroller(
                    controller: groupsScrollController,
                    child: ListView.separated(
                      controller: groupsScrollController,
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: groups.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (ctx, idx) {
                    final g = groups[idx];
                    final count = groupCounts[g] ?? 0;
                    final isSelected = selectedGroup == g;
                    final pickerPalette = ApplePalette.of(ctx);
                    final pickerDark = pickerPalette.isDark;
                    return GestureDetector(
                      onTap: () => setPickerState(() => selectedGroup = g),
                      child: AnimatedContainer(
                        duration: (isWindowsDesktopUi || OhosRuntime.isOhos)
                            ? const Duration(milliseconds: 200)
                            : Ios27Spring.snappy.nominalDuration,
                        curve: (isWindowsDesktopUi || OhosRuntime.isOhos)
                            ? Curves.easeOutCubic
                            : Ios27Spring.snappy.curve,
                        height: MediaQuery.textScalerOf(ctx).scale(16) + 20,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          gradient: isSelected
                              ? const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0xFF0A84FF),
                                    Color(0xFF0066CC),
                                  ],
                                )
                              : LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: pickerDark
                                      ? const [
                                          Color(0xCC2A2A32),
                                          Color(0xB81D1D24),
                                        ]
                                      : const [
                                          Color(0xFFF9FAFD),
                                          Color(0xFFF0F2F8),
                                        ],
                                ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: isSelected
                                ? const Color(0x995AC8FA)
                                : (pickerDark
                                    ? const Color(0x2EFFFFFF)
                                    : Colors.black.withValues(alpha: 0.085)),
                            width: 0.7,
                          ),
                          boxShadow: !pickerDark && !isSelected
                              ? const [
                                  BoxShadow(
                                    color: Color(0x0A0F172A),
                                    blurRadius: 6,
                                    offset: Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              g,
                              textAlign: TextAlign.center,
                              strutStyle: const StrutStyle(
                                forceStrutHeight: true,
                                height: 1.1,
                                fontSize: 13,
                              ),
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : pickerPalette.labelPrimary,
                                fontSize: 13,
                                height: 1.1,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$count',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : pickerPalette.labelSecondary,
                                fontSize: 11,
                                height: 1.0,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
            if (unsupportedCount > 0 && availableCount > 0) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (chipCtx) {
                  final cp = ApplePalette.of(chipCtx);
                  return Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setPickerState(
                            () => onlyAvailable = !onlyAvailable,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: onlyAvailable
                                  ? (cp.isDark
                                      ? const Color(0x330A84FF)
                                      : const Color(0x1F007AFF))
                                  : (cp.isDark
                                      ? const Color(0x22FFFFFF)
                                      : cp.groupedPrimary),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: onlyAvailable
                                    ? const Color(0x990A84FF)
                                    : (cp.isDark
                                        ? const Color(0x28FFFFFF)
                                        : Colors.black.withValues(alpha: 0.08)),
                                width: 0.7,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  onlyAvailable
                                      ? CupertinoIcons.checkmark_circle_fill
                                      : CupertinoIcons
                                          .line_horizontal_3_decrease_circle,
                                  size: 13.5,
                                  color: onlyAvailable
                                      ? cp.accent
                                      : cp.labelSecondary,
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    onlyAvailable
                                        ? '仅看可用 · 已过滤 $unsupportedCount 条'
                                        : '仅看可用（隐藏 $unsupportedCount 条暂不支持线路）',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: onlyAvailable
                                          ? (cp.isDark
                                              ? Colors.white
                                              : cp.accent)
                                          : cp.labelSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
            SizedBox(height: 12),
                ],
              )),
              if (filteredSites.isEmpty)
                SliverToBoxAdapter(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('未找到匹配的片源', style: TextStyle(
                    color: ApplePalette.of(context).labelSecondary, fontSize: 14)),
                ))
              else
                SourceChoiceSliver(
                  sites: filteredSites,
                  selectedKey: _activeSite?.key,
                  preferredKey: widget.storage.preferredSiteKey,
                  onPreferred: inPrivacyMode ? null : (s) async {
                    await widget.storage.setPreferredSiteKey(
                      widget.storage.preferredSiteKey == s.key ? '' : s.key);
                    if (ctx.mounted) setPickerState(() {});
                  },
                  onManageSite: (s) {
                    _showSingleSiteActionSheet(
                      ctx,
                      s,
                      privateMode: inPrivacyMode,
                      onChanged: () {
                        if (ctx.mounted) setPickerState(() {});
                      },
                    );
                  },
                  badgeLabel: siteBadgeLabel,
                  badgeColor: siteBadgeColor,
                  onUnsupportedSelected: (s) {
                    unawaited(
                      showAppleNativeAlert(
                        ctx,
                        title: s.name,
                        message: s.unsupportedReason,
                        actions: [
                          const AppleNativeAlertAction(
                            id: 'open_extensions',
                            title: '查看新手教程 / 配置扩展与网关',
                          ),
                          if (unsupportedCount > 1)
                            AppleNativeAlertAction(
                              id: 'hide_all_unsupported',
                              title: '一键隐藏全部未适配 ($unsupportedCount)',
                              isDestructive: true,
                            ),
                          const AppleNativeAlertAction(
                            id: 'edit',
                            title: '编辑线路',
                          ),
                          const AppleNativeAlertAction(
                            id: 'delete',
                            title: '删除线路',
                            isDestructive: true,
                          ),
                          const AppleNativeAlertAction(
                            id: 'ok',
                            title: '我知道了',
                            isDefault: true,
                          ),
                        ],
                      ).then((action) async {
                        if (!ctx.mounted) return;
                        if (action == 'open_extensions') {
                          await _openSpiderExtensionsPage(
                            iosBackLabel: '切换片源',
                          );
                          if (ctx.mounted) setPickerState(() {});
                        } else if (action == 'hide_all_unsupported') {
                          final ids = unsupportedSites
                              .map(widget.storage.siteIdentityOf)
                              .toList();
                          await widget.storage.hideSites(ids);
                          if (mounted) _reloadSavedConfig();
                          if (ctx.mounted) setPickerState(() {});
                        } else if (action == 'edit') {
                          final changed = await _showEditSingleSiteDialog(
                            ctx,
                            s,
                          );
                          if (changed && ctx.mounted) setPickerState(() {});
                        } else if (action == 'delete') {
                          final deleted = await _confirmAndDeleteSingleSite(
                            ctx,
                            s,
                          );
                          if (deleted && ctx.mounted) setPickerState(() {});
                        }
                      }),
                    );
                  },
                  onSelected: (s) {
                    Navigator.of(ctx).pop();
                    if (s.isCatPaw && Uri.parse(s.api).path == '/api/baseset') {
                      _showCatPawSettings(s);
                      return;
                    }
                    if (inPrivacyMode) {
                      setState(() {
                        _privateSessionUnlocked = true;
                        _selectedPrivateSiteKey = s.key;
                        _activeSite = s;
                      });
                    } else {
                      widget.storage.setSelectedSiteKey(s.key);
                      unawaited(CmsClient.retainScriptSessions(
                        (_config?.scriptOwners ?? const <CmsSite>[])
                            .where((site) => !site.isEffectivelyPrivate),
                      ));
                      setState(() {
                        _privateSessionUnlocked = false;
                        _activeSite = s;
                      });
                    }
                    _loadSiteHome();
                  },
                ),
              if (isIos)
                SliverToBoxAdapter(
                  child: SizedBox(height: safeBottom + 28),
                ),
            ],
          );

          if (isIos) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: scrollView,
            );
          }

          return SizedBox(
            height: (size.height * 0.72).clamp(380.0, 620.0),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: scrollView,
            ),
          );
        },
      ),
    );
  }
  Future<void> _showImportConfigDialog({
    String? initialInput,
    String? initialError,
    String initialGroup = '默认分组',
    bool initialIsPrivate = false,
    String iosBackLabel = '返回',
  }) async {
    final allSites = _config?.publicSupportedSites ?? const <CmsSite>[];
    await _openIosOrModalPage<void>(
      title: initialIsPrivate ? '添加隐私资源库' : '添加资源库',
      backLabel: iosBackLabel,
      builder: (ctx) => AddResourceLibraryView(
        storage: widget.storage,
        client: widget.client,
        initialInput: initialInput,
        initialError: initialError,
        initialGroup: initialGroup,
        initialIsPrivate: initialIsPrivate,
        loadedSites: allSites,
        activeGroup: _activeSite?.group ?? '',
        onOpenCatPawSettings:
            allSites.any((s) => s.isCatPaw) ? _showCatPawSettings : null,
        onLibraryAdded: () {
          if (!initialIsPrivate) {
            _privateSessionUnlocked = false;
          }
          _reloadSavedConfig();
        },
        onNeedsPrivacyPassword: () async {
          _showSetPrivacyPasswordDialog(
            title: '设置隐私访问密码',
            subtitle: '请为隐私分组设置访问密码：',
          );
        },
      ),
    );
  }
  Future<void> _showBackupRestoreDialog({String iosBackLabel = '返回'}) async {
    const int inlineTextFieldCharLimit = 256 * 1024;
    final initialBackup = widget.storage.exportBackupJson();
    String? fullBackupPayload =
        initialBackup.length > inlineTextFieldCharLimit ? initialBackup : null;
    final ctrl = TextEditingController(
      text: fullBackupPayload == null ? initialBackup : '',
    );
    String? loadedLargeSummary = fullBackupPayload == null
        ? null
        : '当前备份较大（${(utf8.encode(fullBackupPayload).length / (1024 * 1024)).toStringAsFixed(1)} MB），已就绪可直接导出或恢复';
    String effectivePayload() => fullBackupPayload ?? ctrl.text;
    String? errorText;
    await _openIosOrModalPage<void>(
      title: defaultTargetPlatform == TargetPlatform.iOS
          ? '备份与恢复'
          : '跨平台备份导出 / 恢复',
      backLabel: iosBackLabel,
      trailingAction: CupertinoButton(
        key: const ValueKey('backup-copy-export'),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(28, 28),
        onPressed: () {
          final payload = effectivePayload();
          if (OhosRuntime.isOhos) {
            try {
              StorageService.encodeValidatedLocalBackupUtf8(payload);
            } on FormatException catch (e) {
              _showAppleNotice('复制导出失败', e.message);
              return;
            }
          }
          Clipboard.setData(ClipboardData(text: payload));
          _showAppleNotice('已复制备份', '备份 JSON 已复制到剪贴板，可发送至其他设备恢复。');
        },
        child: const Text(
          '复制导出',
          style: TextStyle(color: AppleColors.systemBlue, fontSize: 14),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                OhosRuntime.isOhos
                    ? '与 Android 电视/手机端 MarcoMovie-1 备份格式双向兼容（鸿蒙本地备份上限 ${StorageService.formatLocalBackupByteLimit()}）：'
                    : '与 Android 电视/手机端 MarcoMovie-1 备份格式双向兼容：',
                style: TextStyle(
                  color: ApplePalette.of(context).labelSecondary,
                  fontSize: 12,
                ),
              ),
              if (loadedLargeSummary != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppleColors.systemBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    loadedLargeSummary!,
                    style: const TextStyle(
                      color: AppleColors.systemBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              SizedBox(height: 10),
              TextSelectionMouseGuard(
                child: CupertinoTextField(
                  controller: ctrl,
                  onChanged: (_) {
                    if (fullBackupPayload != null || loadedLargeSummary != null) {
                      setModalState(() {
                        fullBackupPayload = null;
                        loadedLargeSummary = null;
                      });
                    }
                  },
                  placeholder: loadedLargeSummary != null
                      ? '大体积备份已加载（可省略预览直接导出/恢复，或在此粘贴覆盖）'
                      : null,
                  maxLines: 9,
                  minLines: 6,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  padding: const EdgeInsets.all(12),
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 12,
                  ),
                  decoration: BoxDecoration(
                    color: ApplePalette.of(context).groupedSecondary,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: AppleColors.glassBorder,
                      width: 0.5,
                    ),
                  ),
                ),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  errorText!,
                  style: const TextStyle(
                    color: AppleColors.systemRed,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: AppleCapsuleButton(
                      key: const ValueKey('backup-save-json-file'),
                      label: '导出为 JSON 文件',
                      icon: CupertinoIcons.square_arrow_down,
                      onPressed: () async {
                        try {
                          final payload = effectivePayload();
                          if (OhosRuntime.isOhos) {
                            StorageService.encodeValidatedLocalBackupUtf8(
                              payload,
                            );
                            final savedUri = await OhosRuntime.saveTextFile(
                              fileName: 'marco-movie-backup.json',
                              content: payload,
                              maxBytes: StorageService.maxLocalBackupBytes,
                            );
                            if (savedUri == null || !ctx.mounted) return;
                            setModalState(() => errorText = null);
                            _showAppleNotice('导出成功', '备份 JSON 文件已保存。');
                            return;
                          }
                          final bytes = Uint8List.fromList(utf8.encode(payload));
                          final outputPath = await FilePicker.platform.saveFile(
                            dialogTitle: '导出 Marco Movie 备份 JSON',
                            fileName: 'marco-movie-backup.json',
                            type: FileType.custom,
                            allowedExtensions: const ['json'],
                            bytes: bytes,
                          );
                          if (outputPath == null || !ctx.mounted) return;
                          if (!Platform.isIOS && !Platform.isAndroid && outputPath.isNotEmpty) {
                            await File(outputPath).writeAsBytes(bytes, flush: true);
                          }
                          setModalState(() => errorText = null);
                          _showAppleNotice('导出成功', '备份 JSON 文件已保存。');
                        } on FormatException catch (e) {
                          if (ctx.mounted) {
                            setModalState(() => errorText = '保存 JSON 文件失败：${e.message}');
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setModalState(() => errorText = '保存 JSON 文件失败：$e');
                          }
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppleCapsuleButton(
                      key: const ValueKey('backup-load-json-file'),
                      label: '选择 JSON 文件',
                      icon: CupertinoIcons.folder,
                      onPressed: () async {
                        try {
                          final String text;
                          final int byteLength;
                          if (OhosRuntime.isOhos) {
                            final picked = await OhosRuntime.pickDocumentFile(
                              purpose: OhosDocumentPurpose.backup,
                              maxBytes: StorageService.maxLocalBackupBytes,
                            );
                            if (picked == null || !ctx.mounted) return;
                            StorageService.validateLocalBackupUtf8Bytes(
                              picked.bytes,
                            );
                            byteLength = picked.bytes.length;
                            text = picked.decodeUtf8(allowMalformed: false);
                          } else {
                            final picked = await FilePicker.platform.pickFiles(
                              type: FileType.any,
                              withData: false,
                            );
                            final entry = picked?.files.single;
                            if (entry == null || !ctx.mounted) return;
                            if (entry.path != null && entry.path!.isNotEmpty) {
                              final file = File(entry.path!);
                              final len = await file.length();
                              if (len > StorageService.maxSyncPayloadBytes) {
                                throw const FormatException('备份文件超过 8 MB 限制');
                              }
                              byteLength = len;
                              text = await file.readAsString();
                            } else if (entry.bytes != null) {
                              if (entry.bytes!.length > StorageService.maxSyncPayloadBytes) {
                                throw const FormatException('备份文件超过 8 MB 限制');
                              }
                              byteLength = entry.bytes!.length;
                              text = utf8.decode(entry.bytes!);
                            } else {
                              return;
                            }
                          }
                          if (!ctx.mounted) return;
                          setModalState(() {
                            if (text.length > inlineTextFieldCharLimit) {
                              fullBackupPayload = text;
                              ctrl.text = '';
                              loadedLargeSummary =
                                  '已载入备份文件（${(byteLength / (1024 * 1024)).toStringAsFixed(1)} MB），点击下方按钮恢复';
                            } else {
                              fullBackupPayload = null;
                              loadedLargeSummary = null;
                              ctrl.text = text;
                            }
                            errorText = null;
                          });
                        } on FormatException catch (e) {
                          if (ctx.mounted) {
                            setModalState(() => errorText = '读取备份文件失败：${e.message}');
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setModalState(() => errorText = '读取备份文件失败：$e');
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: AppleCapsuleButton(
                  key: const ValueKey('backup-restore-confirm'),
                  label: '从此备份文本恢复',
                  icon: CupertinoIcons.arrow_counterclockwise,
                  primary: true,
                  onPressed: () async {
                    try {
                      final payload = effectivePayload();
                      if (OhosRuntime.isOhos) {
                        await widget.storage.importValidatedLocalBackupJson(
                          payload,
                        );
                      } else {
                        await widget.storage.importBackupJson(payload);
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      _reloadSavedConfig();
                    } catch (e) {
                      setModalState(() => errorText = '恢复备份失败：$e');
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportDiagnosticsBundle(
    BuildContext context, {
    String iosBackLabel = '返回',
  }) async {
    final bundle = await AppLog.generateDiagnosticsBundle(
      storage: widget.storage,
      currentAppVersion: _currentAppVersion,
    );
    if (!mounted) return;
    await _openIosOrModalPage<void>(
      title: '导出诊断日志包',
      backLabel: iosBackLabel,
      trailingAction: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(28, 28),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: bundle));
          _showAppleNotice('已复制诊断包', '脱敏后的诊断日志已复制到剪贴板。');
        },
        child: const Text(
          '复制',
          style: TextStyle(color: AppleColors.systemBlue, fontSize: 14),
        ),
      ),
      builder: (ctx) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(ctx).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '诊断包已自动脱敏所有 Cookie、Token、密码及私有 URL 参数，可安全分享用于排查故障：',
              style: TextStyle(
                color: ApplePalette.of(context).labelSecondary,
                fontSize: 12,
              ),
            ),
            SizedBox(height: 12),
            TextSelectionMouseGuard(
              child: CupertinoTextField(
                controller: TextEditingController(text: bundle),
                maxLines: 12,
                minLines: 8,
                readOnly: true,
                style: TextStyle(
                  color: ApplePalette.of(context).labelPrimary,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
                decoration: BoxDecoration(
                  color: ApplePalette.of(context).groupedSecondary,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 16),
            CupertinoButton.filled(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: bundle));
                if (ctx.mounted) Navigator.of(ctx).pop();
                _showAppleNotice('已复制诊断包', '脱敏后的诊断日志已复制到剪贴板。');
              },
              child: const Text('复制诊断包内容到剪贴板'),
            ),
          ],
        ),
      ),
    );
  }
}

class _IosBackupRestorePanel extends StatefulWidget {
  final StorageService storage;
  final VoidCallback onRestored;
  final void Function(String title, String message) onNotice;

  const _IosBackupRestorePanel({
    required this.storage,
    required this.onRestored,
    required this.onNotice,
  });

  @override
  State<_IosBackupRestorePanel> createState() => _IosBackupRestorePanelState();
}

class _IosBackupRestorePanelState extends State<_IosBackupRestorePanel> {
  late final TextEditingController _ctrl;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.storage.exportBackupJson());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSettingsGroup(
          header: '导出与复制',
          footer: '与 iPad、Mac、Windows 及 Android 电视/手机端备份格式双向兼容。',
          children: [
            IosSettingsRow(
              key: const ValueKey('ios-backup-copy'),
              icon: CupertinoIcons.doc_on_doc_fill,
              iconColor: AppleColors.systemBlue,
              title: '复制当前备份 JSON',
              onTap: () {
                final latest = widget.storage.exportBackupJson();
                _ctrl.text = latest;
                Clipboard.setData(ClipboardData(text: latest));
                widget.onNotice('已复制备份', '备份 JSON 已复制到剪贴板，可发送至其他设备恢复。');
              },
            ),
            IosSettingsRow(
              icon: CupertinoIcons.doc_on_clipboard_fill,
              iconColor: AppleColors.systemTeal,
              title: '从剪贴板粘贴备份文本',
              onTap: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = (data?.text ?? '').trim();
                if (text.isEmpty) return;
                setState(() {
                  _ctrl.text = text;
                  _errorText = null;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        IosSettingsGroup(
          header: '备份文本（可编辑或粘贴恢复）',
          dividerIndent: 16,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextSelectionMouseGuard(
                child: CupertinoTextField(
                  key: const ValueKey('ios-backup-textfield'),
                  controller: _ctrl,
                  maxLines: 8,
                  minLines: 5,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  padding: const EdgeInsets.all(12),
                  style: TextStyle(
                    color: ApplePalette.of(context).labelPrimary,
                    fontSize: 13.5,
                  ),
                  decoration: BoxDecoration(
                    color: ApplePalette.isDarkOf(context)
                        ? const Color(0xFF2C2C2E)
                        : ApplePalette.of(context).groupedSecondary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: ApplePalette.of(context).separator,
                      width: 0.6,
                    ),
                  ),
                ),
              ),
            ),
            if (_errorText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  _errorText!,
                  style: const TextStyle(
                    color: AppleColors.systemRed,
                    fontSize: 13,
                  ),
                ),
              ),
            IosSettingsRow(
              key: const ValueKey('ios-backup-restore-btn'),
              icon: CupertinoIcons.arrow_counterclockwise,
              iconColor: AppleColors.systemGreen,
              title: '从此备份文本恢复',
              titleColor: AppleColors.systemBlue,
              onTap: () async {
                try {
                  await widget.storage.importBackupJson(_ctrl.text);
                  if (!mounted) return;
                  setState(() => _errorText = null);
                  widget.onRestored();
                  widget.onNotice('恢复成功', '已从备份文本恢复订阅源、收藏、观看历史与偏好设置。');
                } catch (e) {
                  if (mounted) {
                    setState(() => _errorText = '恢复备份失败：$e');
                  }
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// iOS-style left-swipe row that reveals a red "删除" action button on the right,
/// and also supports full swipe or tapping the red delete button to remove a single watch history item.
class _SwipeToDeleteHistoryTile extends StatefulWidget {
  final WatchHistoryEntry entry;
  final String? posterUrl;
  final String? sourceCardId;
  final VoidCallback onTap;
  final void Function(BuildContext posterContext, double radius, String cardId)?
      onTapWithSource;
  final VoidCallback onDelete;

  const _SwipeToDeleteHistoryTile({
    super.key,
    required this.entry,
    this.posterUrl,
    this.sourceCardId,
    required this.onTap,
    this.onTapWithSource,
    required this.onDelete,
  });

  @override
  State<_SwipeToDeleteHistoryTile> createState() =>
      _SwipeToDeleteHistoryTileState();
}

class _SwipeToDeleteHistoryTileState extends State<_SwipeToDeleteHistoryTile> {
  static const double _actionWidth = 86.0;
  double _dragOffset = 0.0;
  bool _dragging = false;

  void _handleDragStart(DragStartDetails _) {
    setState(() => _dragging = true);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final next = (_dragOffset + details.delta.dx).clamp(-150.0, 0.0);
    setState(() => _dragOffset = next);
  }

  void _handleDragEnd(DragEndDetails details) {
    final vx = details.primaryVelocity ?? 0.0;
    if (_dragOffset <= -125.0 || vx < -950.0) {
      HapticFeedback.mediumImpact();
      setState(() {
        _dragging = false;
        _dragOffset = 0.0;
      });
      widget.onDelete();
      return;
    }
    final shouldOpen = _dragOffset < -(_actionWidth * 0.42) || vx < -280.0;
    setState(() {
      _dragging = false;
      _dragOffset = shouldOpen ? -_actionWidth : 0.0;
    });
  }

  void _closeIfOpen() {
    if (_dragOffset != 0.0) {
      setState(() => _dragOffset = 0.0);
    }
  }

  Widget _buildFallbackPosterPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF26262C), Color(0xFF17171B)],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.film,
        color: ApplePalette.of(context).labelTertiary,
        size: 22,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.entry;
    final effectivePoster = (widget.posterUrl ?? h.poster).trim();
    final pct = (h.progressFraction * 100).round();
    final epLabel = h.episode.isEmpty ? '第 ${h.index + 1} 集' : h.episode;
    final revealProgress = (-_dragOffset / _actionWidth).clamp(0.0, 1.0);
    final showDeleteBg = _dragOffset < -0.5;
    final tileCardId = widget.sourceCardId ?? 'hist_${h.site}_${h.id}';
    BuildContext? posterCtx;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _handleDragStart,
          onHorizontalDragUpdate: _handleDragUpdate,
          onHorizontalDragEnd: _handleDragEnd,
          child: Stack(
            children: [
              if (showDeleteBg)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Opacity(
                      opacity: revealProgress,
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          setState(() => _dragOffset = 0.0);
                          widget.onDelete();
                        },
                        child: Container(
                          width: _actionWidth + 16,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 18),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                Color(0xFFE0352B),
                                Color(0xFFFF453A),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.trash_fill,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(height: 3),
                              Text(
                                '删除',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(_dragOffset, 0, 0),
              child: Listener(
                onPointerDown: (_) {
                  if (_dragOffset <= -10) {
                    _closeIfOpen();
                  }
                },
                child: ApplePressableScale(
                  pressedScale: 0.97,
                  pressedOpacity: 0.88,
                  onTap: () {
                    if (_dragOffset <= -10) {
                      _closeIfOpen();
                      return;
                    }
                    final withSource = widget.onTapWithSource;
                    if (withSource != null) {
                      withSource(posterCtx ?? context, 12.0, tileCardId);
                    } else {
                      widget.onTap();
                    }
                  },
                  child: AppleSettingsGlassCard(
                    borderRadius: BorderRadius.circular(18),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        PosterExpandSourceCard(
                          cardId: tileCardId,
                          child: Builder(
                            builder: (ctx) {
                              posterCtx = ctx;
                              return SizedBox(
                                width: 52,
                                height: 72,
                                child: AppleSmoothClipCard(
                                  borderRadius: 12,
                                  backgroundColor: const Color(0xFF1A1A20),
                                  rimStrength: 0.85,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      PosterImage(
                                        url: effectivePoster,
                                        title: h.title,
                                        placeholder:
                                            _buildFallbackPosterPlaceholder(),
                                      ),
                                      Positioned(
                                        right: 4,
                                        bottom: 4,
                                        child: Container(
                                          width: 18,
                                          height: 18,
                                          decoration: BoxDecoration(
                                            color: const Color(0xB8000000),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: const Color(0x66FFFFFF),
                                              width: 0.6,
                                            ),
                                          ),
                                          alignment: Alignment.center,
                                          child: const Icon(
                                            CupertinoIcons.play_fill,
                                            color: Colors.white,
                                            size: 9.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                h.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelPrimary,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.25,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                h.duration > 0
                                    ? '$epLabel · 已看 $pct%'
                                    : epLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: ApplePalette.of(context).labelSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                              if (h.duration > 0) ...[
                                SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: h.progressFraction.clamp(0.0, 1.0),
                                    minHeight: 3.5,
                                    backgroundColor: ApplePalette.of(context).groupedTertiary,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                      AppleColors.systemBlue,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppleColors.systemBlue.withValues(
                              alpha: ApplePalette.isDarkOf(context) ? 0.22 : 0.12,
                            ),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: AppleColors.systemBlue.withValues(
                                alpha: ApplePalette.isDarkOf(context) ? 0.45 : 0.28,
                              ),
                              width: 0.6,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '继续播放',
                                style: TextStyle(
                                  color: ApplePalette.isDarkOf(context)
                                      ? const Color(0xFF5AC8FA)
                                      : AppleColors.systemBlue,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 3),
                              Icon(
                                CupertinoIcons.chevron_right,
                                color: ApplePalette.isDarkOf(context)
                                    ? const Color(0xFF5AC8FA)
                                    : AppleColors.systemBlue,
                                size: 12,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// Full-screen iOS 27 Liquid Glass Cyber-Aurora portal animation played when entering Privacy Mode.
class _PrivacyModePortalAnimation extends StatefulWidget {
  final VoidCallback onFinished;

  const _PrivacyModePortalAnimation({
    super.key,
    required this.onFinished,
  });

  @override
  State<_PrivacyModePortalAnimation> createState() =>
      _PrivacyModePortalAnimationState();
}

class _PrivacyModePortalAnimationState
    extends State<_PrivacyModePortalAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1280),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onFinished();
        }
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // Fade in quickly (0..0.22), hold (0.22..0.72), fade out smoothly (0.72..1.0)
        final double masterOpacity;
        if (t < 0.22) {
          masterOpacity = Curves.easeOutCubic.transform(t / 0.22);
        } else if (t < 0.72) {
          masterOpacity = 1.0;
        } else {
          masterOpacity =
              1.0 - Curves.easeInOutCubic.transform((t - 0.72) / 0.28);
        }

        final ring1Scale = 0.35 + Curves.easeOutExpo.transform(t) * 2.45;
        final ring2Scale =
            0.2 + Curves.easeOutCubic.transform((t - 0.08).clamp(0.0, 1.0)) * 1.85;
        final shieldScale = t < 0.32
            ? 0.68 + Curves.easeOutBack.transform(t / 0.32) * 0.36
            : 1.04 + (t - 0.32) * 0.14;
        final blurSigma = (26.0 * masterOpacity).clamp(0.01, 28.0);

        return Opacity(
          opacity: masterOpacity.clamp(0.0, 1.0),
          child: BackdropFilter(
            enabled: !isWindowsDesktopUi,
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.0, -0.08),
                  radius: 1.05,
                  colors: [
                    Color(0xEE2B124C),
                    Color(0xF2120924),
                    Color(0xF807070C),
                  ],
                  stops: [0.0, 0.52, 1.0],
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding Liquid Aurora Wave Ring 1
                  Transform.scale(
                    scale: ring1Scale,
                    child: Container(
                      width: 260,
                      height: 260,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFBF5AF2).withValues(
                            alpha: ((1.0 - t) * 0.65).clamp(0.0, 1.0),
                          ),
                          width: 2.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF5E5CE6).withValues(
                              alpha: ((1.0 - t) * 0.42).clamp(0.0, 1.0),
                            ),
                            blurRadius: 42,
                            spreadRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Expanding Liquid Aurora Wave Ring 2
                  Transform.scale(
                    scale: ring2Scale,
                    child: Container(
                      width: 210,
                      height: 210,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF5AC8FA).withValues(
                            alpha: ((1.0 - t) * 0.5).clamp(0.0, 1.0),
                          ),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  // Center Shield & Status Badge
                  Transform.scale(
                    scale: shieldScale,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFBF5AF2),
                                Color(0xFF5E5CE6),
                                Color(0xFF0A84FF),
                              ],
                            ),
                            border: Border.all(
                              color: const Color(0x99FFFFFF),
                              width: 1.2,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x88BF5AF2),
                                blurRadius: 36,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            t < 0.28
                                ? CupertinoIcons.lock_shield
                                : CupertinoIcons.lock_shield_fill,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 22),
                        const Text(
                          '已进入隐私专属空间',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x28FFFFFF),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0x45BF5AF2),
                              width: 0.7,
                            ),
                          ),
                          child: const Text(
                            '无痕播放 · 独立片源与搜索 · 数据零留存隔离',
                            style: TextStyle(
                              color: Color(0xFFE5D4FF),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Provides a dedicated [ScrollController] owned and disposed by an individual
/// modal sheet instance (M-F7), preventing multiple overlapping sheet routes
/// (e.g. during exit/enter animations) from attaching to a shared controller.
class _SheetOwnedScrollController extends StatefulWidget {
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  const _SheetOwnedScrollController({required this.builder});

  @override
  State<_SheetOwnedScrollController> createState() =>
      _SheetOwnedScrollControllerState();
}

class _SheetOwnedScrollControllerState
    extends State<_SheetOwnedScrollController> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

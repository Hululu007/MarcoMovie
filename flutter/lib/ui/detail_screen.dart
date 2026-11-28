import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'dart:ui' as ui show FragmentProgram, Image;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/services.dart' show HapticFeedback, SystemUiOverlayStyle;
import '../core/ai_lab_features.dart';
import '../core/ai_lab_passcode.dart';
import '../core/ai_service.dart';
import '../core/ai_title_cleaner.dart';
import '../core/cms_client.dart';
import '../core/cms_parser.dart';
import '../core/csp_bridge.dart';
import '../core/curated_discovery.dart';
import '../core/download_service.dart';
import '../core/episode_scraper.dart';
import '../core/media_badges.dart';
import '../core/models.dart';
import '../core/ohos_runtime.dart';
import '../core/series_scraper.dart' hide ScrapedEpisodeInfo;
import '../core/storage_service.dart';
import '../core/web_media_resolver.dart';
import '../core/wogg_source.dart';
import '../core/work_aggregation.dart';
import 'apple_theme.dart';
import 'cast_avatar_section.dart';
import 'desktop_horizontal_scroller.dart';
import 'episode_scrape_sheet.dart';
import 'favorite_postcard_animation.dart';
import 'ios_ai_lab_sheets.dart';
import 'ios_drive_priority_sheet.dart';
import 'ios_liquid_glass.dart';
import 'media_badge.dart';
import 'motion/ios27_springs.dart';
import 'motion/player_enter_transition.dart';
import 'netdisk_sheet.dart';
import 'player_screen.dart';
import 'poster_image.dart';
import 'series_scrape_sheet.dart';
import 'source_verification_dialog.dart';
import 'windows_appearance.dart';
import 'windows_title_bar.dart';
part 'windows_detail.dart';

/// Apple TV+ / Infuse inspired responsive video detail page for iPhone, iPad, Mac, and Windows.
/// Features:
/// - Full-screen `Positioned.fill` ambient canvas & backdrop (zero horizontal or vertical seam lines
///   in both portrait and landscape when scrolling/blurring)
/// - Top solid-color transition with downward-shifted hero poster framing, plus bottom progressive
///   frosted-glass blur transition (`ShaderMask` + `BackdropFilter`) behind overlaid typography
/// - Real per-episode 16:9 frame stills & real per-episode plot synopses (`分集剧情`) from
///   360 Baike `tvplot`, Bilibili PGC, and Bangumi, with honest non-repetitive display
class DetailScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo initialVideo;
  final CmsClient client;
  final StorageService storage;
  final List<WorkSourceRef> initialSources;
  @visibleForTesting
  final Widget Function(
    BuildContext context,
    CmsSite site,
    CmsVideo video,
    int lineIndex,
    int episodeIndex,
    int resumeMs,
  )? debugPlayerBuilder;
  @visibleForTesting
  final Widget Function(
    BuildContext context,
    CmsSite site,
    CmsVideo video,
    int lineIndex,
    int episodeIndex,
    int resumeMs,
    ValueChanged<PlayerPlaybackConfirmation> onPlaybackConfirmed,
  )? debugPlayerWithConfirmationBuilder;
  @visibleForTesting
  final BackdropImageCapturer? debugTransitionCapturer;
  @visibleForTesting
  final ui.FragmentProgram? debugTransitionShaderProgram;
  @visibleForTesting
  final ValueChanged<PlayerTransitionMode>? debugOnTransitionModeResolved;
  @visibleForTesting
  final SeriesScrapeSearchFn? debugScrapeSearchFn;
  @visibleForTesting
  final SeriesScrapeHydrateFn? debugScrapeHydrateFn;
  const DetailScreen({
    super.key,
    required this.site,
    required this.initialVideo,
    required this.client,
    required this.storage,
    this.initialSources = const [],
    this.debugPlayerBuilder,
    this.debugPlayerWithConfirmationBuilder,
    this.debugTransitionCapturer,
    this.debugTransitionShaderProgram,
    this.debugOnTransitionModeResolved,
    this.debugScrapeSearchFn,
    this.debugScrapeHydrateFn,
  });

  static List<CmsSite> selectRelatedSeasonSiblings(
    CmsSite site,
    Iterable<CmsSite> allSites, {
    int limit = 6,
  }) {
    return allSites
        .where(
          (s) =>
              s.supported &&
              s.key != site.key &&
              s.searchable &&
              s.isEffectivelyPrivate == site.isEffectivelyPrivate &&
              (s.group == site.group || !site.isEffectivelyPrivate),
        )
        .take(limit)
        .toList();
  }

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _OtherSourceResults extends StatefulWidget {
  final Stream<(CmsSite, List<CmsVideo>)> results;
  const _OtherSourceResults({required this.results});

  @override
  State<_OtherSourceResults> createState() => _OtherSourceResultsState();
}

class _OtherSourceResultsState extends State<_OtherSourceResults> {
  final _matches = <(CmsSite, CmsVideo)>[];
  late final StreamSubscription<(CmsSite, List<CmsVideo>)> _search;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _search = widget.results.listen((result) {
      if (mounted) setState(() {
        _matches.addAll(result.$2.map((v) => (result.$1, v)));
      });
    }, onDone: () { if (mounted) setState(() => _done = true); },
       onError: (Object error) { if (mounted) setState(() => _failed = true); });
  }

  @override
  void dispose() {
    _search.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useAiRank = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        AiService.instance.isLabUnlocked &&
        _matches.length > 1;
    final ranked = useAiRank
        ? AiLabService.rankCrossSourceMatches('', _matches)
        : null;
    final count = ranked?.length ?? _matches.length;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: count + (_done && count > 0 ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == count) {
          return Padding(padding: const EdgeInsets.all(20), child: Center(
            child: _done ? Text(_failed ? '搜索失败，可关闭后重试' : '已导入的可搜索片源没有返回匹配影片')
                : const CupertinoActivityIndicator(),
          ));
        }
        final site = ranked != null ? ranked[index].site : _matches[index].$1;
        final video = ranked != null ? ranked[index].video : _matches[index].$2;
        final badge = ranked != null ? ranked[index].badgeLabel : '';
        return ListTile(
          title: Text(video.title),
          subtitle: Text(
            [
              if (badge.isNotEmpty) '✦ $badge',
              site.name,
              video.year,
              video.remarks,
            ].where((s) => s.isNotEmpty).join(' · '),
          ),
          onTap: () => Navigator.of(context).pop((site, video)),
        );
      },
    );
  }
}

enum _DetailPullRefreshPhase { idle, armed, refreshing }

typedef _LineIdentitySnapshot = ({
  String siteKey,
  String videoId,
  String lineId,
  String lineName,
  bool idWasUnique,
  bool nameWasUnique,
  List<String> episodeUrls,
  List<String> distinguishingUrls,
  List<String> episodeNames,
});

class _DetailScreenState extends State<DetailScreen> {
  static const double _kPullRefreshArmThreshold = 72.0;
  static const double _kPullRefreshDisarmThreshold = 48.0;

  late CmsSite _activeSite;
  late CmsVideo _video;
  late CmsVideo _detailSeedVideo;
  bool _loading = true;
  String? _error;
  Object? _errorCause;
  String? _curatedUnavailableMessage;
  int _selectedLine = 0;
  _LineIdentitySnapshot? _manualLineSelection;
  int _selectedPage = 0;
  int? _selectedInLineSeason;
  EpisodeScrapeOverride _episodeScrapeOverride = const EpisodeScrapeOverride();
  List<({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})>
      _relatedSeasons = const [];
  bool _discoveringSeasons = false;
  String _discoveredFranchiseKey = '';
  bool _synopsisExpanded = false;
  bool _sourceWarningsExpanded = false;
  bool _windowsLinesExpanded = false;
  bool _windowsEpisodesExpanded = false;
  bool _windowsManualLineFilter = false;
  bool _windowsSynopsisExpanded = false;
  bool _windowsHeroHasLandscape = false;
  bool _macHeroHasLandscape = false;
  bool get _isMacosDetail =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      !OhosRuntime.isOhos;
  late bool _descending;
  late bool _isFavorite;
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);
  final ValueNotifier<double> _pullOverscroll = ValueNotifier<double>(0.0);
  final ValueNotifier<_DetailPullRefreshPhase> _pullRefreshPhase =
      ValueNotifier<_DetailPullRefreshPhase>(_DetailPullRefreshPhase.idle);
  bool _pullRefreshing = false;
  final ScrollController _seasonsScrollController = ScrollController();
  final ScrollController _quickEpisodesScrollController = ScrollController();
  final ScrollController _previewCardsScrollController = ScrollController();
  final ScrollController _pageRangeScrollController = ScrollController();

  // iOS episode strip state: strictly separates confirmed playing episode from
  // user's temporary browsing selection and guards two-row identity sync.
  // Backed by a ValueNotifier so tapping a circle or scrubbing cards only
  // rebuilds the affected circle/card border instead of the entire DetailScreen.
  PlayerPlaybackConfirmation? _confirmedPlayback;
  final ValueNotifier<
      ({
        String lineId,
        String lineName,
        String episodeUrl,
        String episodeName,
        int originalIndex,
      })?> _browsingEpisodeNotifier = ValueNotifier(null);
  ({
    String lineId,
    String lineName,
    String episodeUrl,
    String episodeName,
    int originalIndex,
  })? get _browsingEpisode => _browsingEpisodeNotifier.value;
  set _browsingEpisode(
    ({
      String lineId,
      String lineName,
      String episodeUrl,
      String episodeName,
      int originalIndex,
    })? value,
  ) {
    _browsingEpisodeNotifier.value = value;
  }
  int _programmaticCardScrollGuard = 0;
  final Map<int, GlobalKey> _circleSlotKeys = <int, GlobalKey>{};
  bool _pendingPostPopSync = false;
  WatchHistoryEntry? _bookmarkBeforeLastPlayer;
  PlayerPlaybackConfirmation? _confirmedBeforeLastPlayer;

  bool get _isIosDetail =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !OhosRuntime.isOhos;

  static const double _kEpisodeCardWidth = 226.0;
  static const double _kEpisodeCardGap = 14.0;
  static const double _kEpisodeCardStride = _kEpisodeCardWidth + _kEpisodeCardGap;
  static const double _kEpisodeCircleMinWidth = 44.0;
  static const double _kEpisodeCircleGap = 8.0;
  static const double _kEpisodeCircleApproxStride =
      _kEpisodeCircleMinWidth + _kEpisodeCircleGap;
  bool _initialEpisodeAligned = false;
  Color? _posterAmbientColor;
  String _externalSynopsis = '';
  double? _resolvedDoubanScore;
  int? _resolvedRtScore;
  int _lastMetadataSnapshotSig = 0;
  Completer<void>? _detailAbort;
  Completer<void>? _seasonAbort;
  Completer<void>? _aggregationAbort;
  int _detailEpoch = 0;
  int _aggregationEpoch = 0;
  List<WorkSourceRef> _aggregatedSources = const [];
  final Map<String, WorkSourceDetail> _aggregatedDetails = {};
  final Map<String, String> _aggregatedSourceErrors = {};
  bool _hydratingAggregatedSources = false;
  int _unifiedEpisodesVersion = 0;
  int _cachedUnifiedEpisodesVersion = -1;
  List<AggregatedEpisodeSlot> _cachedUnifiedEpisodes = const [];
  final GlobalKey _transitionBackdropKey = GlobalKey();
  final GlobalKey _transitionPosterKey = GlobalKey();
  Uint8List? _loadedPosterBytes;
  String _loadedPosterIdentity = '';
  SeriesScrapeOverride? _scrapeOverride;
  final TextEditingController _windowsEpisodeQueryCtrl = TextEditingController();
  String _windowsEpisodeQuery = '';
  final Map<String, CleanedMediaTitle> _windowsAiCleanedEpisodes =
      <String, CleanedMediaTitle>{};
  bool _windowsAiCleaningEpisodes = false;
  String? _windowsAiCleanNotice;
  CmsLine? _cachedScrapeLine;
  String _cachedScrapeSig = '';
  LineEpisodeScrapeResult? _cachedScrapeResult;

  void _loadScrapeOverride() {
    _scrapeOverride = widget.storage.getSeriesScrapeOverride(
      _activeSite.key,
      _video.id,
      isPrivate: _activeSite.isEffectivelyPrivate,
    );
    _cachedScrapeLine = null;
    _cachedScrapeSig = '';
    _cachedScrapeResult = null;
  }

  bool get _effectiveWantMotionComic {
    final ov = _scrapeOverride;
    if (ov != null && ov.hasWorkBinding) return ov.isMotionComic;
    return SeriesScraper.isMotionComicText(
      _video.title,
      extraContext: '${_video.tag} ${_video.remarks}',
    );
  }

  String get _effectiveLookupTitle {
    if (_activeSite.isEffectivelyPrivate) return '';
    final ov = _scrapeOverride;
    if (ov != null && ov.matchedTitle.trim().isNotEmpty) {
      return ov.matchedTitle.trim();
    }
    return _video.title;
  }

  String get _effectiveLookupYear {
    final ov = _scrapeOverride;
    if (!_activeSite.isEffectivelyPrivate &&
        ov != null &&
        ov.matchedYear.trim().isNotEmpty) {
      return ov.matchedYear.trim();
    }
    return _video.year;
  }

  String get _effectiveDoubanId {
    if (_activeSite.isEffectivelyPrivate) return '';
    return _scrapeOverride?.doubanId.trim() ?? '';
  }

  bool get _effectiveDoubanIsTv => _scrapeOverride?.isTv ?? true;

  String get _effectiveBackdropUrl {
    if (_activeSite.isEffectivelyPrivate) return '';
    return _scrapeOverride?.backdropUrl.trim() ?? '';
  }

  String get _effectivePosterUrl {
    final ov = _scrapeOverride;
    if (!_activeSite.isEffectivelyPrivate &&
        ov != null &&
        ov.posterUrl.trim().isNotEmpty) {
      return ov.posterUrl.trim();
    }
    return _video.poster;
  }

  LineEpisodeScrapeResult _scrapeResultForLine(CmsLine line) {
    final ov = _scrapeOverride;
    final title = _effectiveLookupTitle.isNotEmpty
        ? _effectiveLookupTitle
        : _video.title;
    final offset = ov?.episodeOffset ?? 0;
    final overrides = ov?.episodeNumberOverrides ?? const <String, int>{};
    final calibs = ov?.episodeCalibrations ??
        const <String, EpisodeManualCalibration>{};
    final sig =
        '${line.name}|${line.episodes.length}|$title|$offset|'
        '${overrides.entries.map((e) => "${e.key}:${e.value}").join(",")}|'
        '${calibs.entries.map((e) => "${e.key}:${e.value.seasonNumber}:${e.value.episodeNumber}:${e.value.isSpecial}").join(",")}';
    if (identical(_cachedScrapeLine, line) &&
        _cachedScrapeSig == sig &&
        _cachedScrapeResult != null) {
      return _cachedScrapeResult!;
    }
    final result = SeriesScraper.scrapeLineEpisodes(
      line.episodes,
      seriesTitle: title,
      episodeOffset: offset,
      manualOverrides: overrides,
      episodeCalibrations: calibs,
    );
    _cachedScrapeLine = line;
    _cachedScrapeSig = sig;
    _cachedScrapeResult = result;
    return result;
  }

  Future<void> _openSeriesScrapeSheet({int initialTab = 0}) async {
    if (_activeSite.isEffectivelyPrivate) return;
    final activeLine = _video.lines.isNotEmpty
        ? _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)]
        : null;
    await showSeriesScrapeSheet(
      context,
      site: _activeSite,
      video: _video,
      storage: widget.storage,
      activeLine: activeLine,
      initialOverride: _scrapeOverride,
      initialTab: initialTab,
      debugSearchFn: widget.debugScrapeSearchFn,
      debugHydrateFn: widget.debugScrapeHydrateFn,
    );
  }

  void _onSeriesScrapeRevision() {
    if (!mounted) return;
    _loadScrapeOverride();
    _externalSynopsis = '';
    _resolvedDoubanScore = null;
    _resolvedRtScore = null;
    _seedCachedExternalFields();
    final hasCachedLandscape = !_activeSite.isEffectivelyPrivate &&
        PosterLoader.peekLandscapeMemory(
              _effectiveLookupTitle,
              year: _effectiveLookupYear,
              wantMotionComic: _effectiveWantMotionComic,
              preferredBackdropUrl: _effectiveBackdropUrl,
              preferredDoubanId: _effectiveDoubanId,
            ) !=
            null;
    _windowsHeroHasLandscape = hasCachedLandscape;
    _macHeroHasLandscape = hasCachedLandscape;
    setState(() {
      _selectedPage = 0;
    });
    _warmRatings(_effectiveLookupTitle, year: _effectiveLookupYear);
    _warmExternalMetadata(_effectiveLookupTitle);
  }

  static bool _canShowInitialLinesImmediately(CmsSite site, CmsVideo video) {
    if (!video.lines.any((l) => l.episodes.isNotEmpty)) return false;
    if (WoggSource.supports(site) ||
        CspBridge.isDoubanSite(site) ||
        CspBridge.isMyDriveSite(site)) {
      return false;
    }
    if (CmsClient.hasUnverifiedCloudLines(video)) {
      return false;
    }
    if (site.isScriptOrJarApi) {
      return video.lines.every(
        (l) => l.episodes.every(
          (e) => !e.url.startsWith('mmshare://') && e.needsSourceResolution,
        ),
      );
    }
    return true;
  }

  void _seedCachedExternalFields() {
    if (_activeSite.isEffectivelyPrivate || _activeSite.isEmby) {
      _resolvedDoubanScore = null;
      _resolvedRtScore = null;
      return;
    }
    final lookupTitle = _effectiveLookupTitle;
    final lookupYear = _effectiveLookupYear;
    final wantMc = _effectiveWantMotionComic;
    final syn = PosterLoader.peekSeriesSynopsis(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    if (syn.isNotEmpty) {
      _externalSynopsis = syn;
    }
    final cachedRatings = PosterLoader.peekRatings(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    _resolvedDoubanScore = _scrapeOverride?.doubanScore ?? cachedRatings?.douban;
    _resolvedRtScore = cachedRatings?.rt;
  }

  bool _windowsDarkSurfaceApplied = false;

  void _updateWindowsState(VoidCallback change) => setState(change);
  static CmsVideo _stripVideoLines(CmsVideo video) => CmsVideo(
        id: video.id,
        title: video.title,
        poster: video.poster,
        remarks: video.remarks,
        year: video.year,
        area: video.area,
        actor: video.actor,
        description: video.description,
        tag: video.tag,
        doubanScore: video.doubanScore,
        rtScore: video.rtScore,
        sourceWarnings: video.sourceWarnings,
      );

  CmsVideo _sanitizeInitialVideo(CmsSite site, CmsVideo raw) {
    final normalized = WoggSource.normalizeCachedVideoLabels(site, raw);
    if (normalized.lines.isEmpty) {
      return normalized;
    }
    final hasId = normalized.id.trim().isNotEmpty;
    if (hasId &&
        (widget.client.hasAuthoritativeEmptyDetail(site, normalized) ||
            widget.client.hasPendingDetailRetry(site, normalized))) {
      return _stripVideoLines(normalized);
    }
    if (!_canShowInitialLinesImmediately(site, normalized)) {
      final freshCached = hasId
          ? widget.client.peekFreshCachedDetail(site, normalized)
          : null;
      if (freshCached != null &&
          freshCached.lines.any((l) => l.episodes.isNotEmpty)) {
        return WoggSource.normalizeCachedVideoLabels(site, freshCached);
      }
      return _stripVideoLines(normalized);
    }
    return normalized;
  }

  /// Returns the video payload to hand to `CmsClient.playableDetail`.
  ///
  /// `_video` intentionally strips unverified cloud-share lines before network
  /// resolution so UI and playback buttons never expose stale or unexpanded
  /// URLs. For M3U inline share cards (whose only input is the raw card URL)
  /// and cards whose initial lines were stripped pending verification, retain
  /// the raw `_detailSeedVideo` for the client request.
  CmsVideo _detailRequestVideoFor(CmsSite site, CmsVideo current) {
    if (_detailSeedVideo.id != current.id) {
      return current;
    }
    if (current.lines.isEmpty ||
        widget.client.isM3uVodSite(site) ||
        current.id.trim().isEmpty) {
      return _detailSeedVideo;
    }
    return current;
  }

  @override
  void initState() {
    super.initState();
    if (isWindowsDesktopUi) {
      scheduleMicrotask(() {
        if (!mounted || _windowsDarkSurfaceApplied) return;
        _windowsDarkSurfaceApplied = true;
        WindowsImmersiveFrame.darkSurfaceDepth.value += 1;
      });
    }
    _activeSite = widget.site;
    _detailSeedVideo = widget.initialVideo;
    _video = _sanitizeInitialVideo(
      widget.site,
      WoggSource.normalizeCachedVideoLabels(widget.site, widget.initialVideo),
    );
    _episodeScrapeOverride = widget.storage.getEpisodeScrapeOverride(
      siteKey: _activeSite.key,
      videoId: _video.id,
      videoTitle: _video.title,
    );
    _seedAggregatedSources();
    final curInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    _relatedSeasons = [
      (
        seasonNumber: curInfo.seasonNumber,
        seasonLabel: curInfo.seasonLabel,
        site: _activeSite,
        video: _detailSeedVideo,
      ),
    ];
    _descending = _isIosDetail ? false : widget.storage.episodesDescending;
    if (!OhosRuntime.isOhos) {
      unawaited(MediaBadges.ensureInitialized().then((_) {
        if (mounted) setState(() {});
      }));
      if (_isIosDetail) {
        AiService.instance.addListener(_onIosDetailAiStateChanged);
        unawaited(AiService.instance.ensureLoaded());
      }
      if (!isWindowsDesktopUi) {
        unawaited(PlayerEnterTransition.prewarmShader());
      }
    }
    _isFavorite = widget.storage.isFavorite(
      _activeSite.key,
      _video.id,
      forPrivate: _activeSite.isEffectivelyPrivate,
    );
    _loadScrapeOverride();
    _seedCachedExternalFields();
    _windowsHeroHasLandscape = !_activeSite.isEffectivelyPrivate &&
        PosterLoader.peekLandscapeMemory(
              _effectiveLookupTitle,
              year: _effectiveLookupYear,
              wantMotionComic: _effectiveWantMotionComic,
              preferredBackdropUrl: _effectiveBackdropUrl,
              preferredDoubanId: _effectiveDoubanId,
            ) !=
            null;
    _macHeroHasLandscape = _windowsHeroHasLandscape;
    PosterLoader.metadataRevision.addListener(_onExternalMetadataRevision);
    widget.storage.watchHistoryRevision.addListener(_onWatchHistoryChanged);
    widget.storage.seriesScrapeRevision.addListener(_onSeriesScrapeRevision);
    final isPrivPoster = _isPrivatePosterContext;
    final immediateBytes = PosterLoader.peekMemory(
      _effectivePosterUrl,
      title: isPrivPoster ? '' : _effectiveLookupTitle,
      year: isPrivPoster ? '' : _effectiveLookupYear,
      preferHd: !isPrivPoster,
      isPrivate: isPrivPoster,
    );
    if (immediateBytes != null) {
      _loadedPosterBytes = immediateBytes;
      _loadedPosterIdentity = _currentPosterIdentity;
      _posterAmbientColor = PosterLoader.peekAmbientColor(immediateBytes);
      if (_posterAmbientColor == null) {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
    _loadDetail();
    _warmRatings(_effectiveLookupTitle, year: _effectiveLookupYear);
    if (!_loading) {
      _warmExternalMetadata(_effectiveLookupTitle);
    }
  }

  String get _publicLookupTitle => _effectiveLookupTitle;

  String get _effectiveScrapeTitle {
    if (_activeSite.isEffectivelyPrivate) return _video.title;
    final custom = _episodeScrapeOverride.customTitle.trim();
    return custom.isNotEmpty ? custom : _video.title;
  }

  ScrapedLineResult _scrapeLine(CmsLine line) {
    return EpisodeScraper.scrapeLine(
      line.episodes,
      override: _episodeScrapeOverride,
      seriesTitle: _effectiveScrapeTitle,
    );
  }

  Future<void> _openEpisodeScrapeSheet() async {
    if (_video.lines.isEmpty) return;
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLineIdx];
    final next = await showEpisodeScrapeSheet(
      context: context,
      seriesTitle: _video.title,
      year: _video.year,
      episodes: line.episodes,
      currentOverride: _episodeScrapeOverride,
      isVariety: _isVarietyShow,
    );
    if (next == null || !mounted) return;
    await widget.storage.setEpisodeScrapeOverride(
      siteKey: _activeSite.key,
      videoId: _video.id,
      videoTitle: _video.title,
      override: next,
    );
    if (!mounted) return;
    setState(() {
      _episodeScrapeOverride = next;
      _selectedPage = 0;
    });
    if (!_activeSite.isEffectivelyPrivate && !_isVarietyShow) {
      unawaited(PosterLoader.fetchSeriesEpisodeMetadata(_effectiveScrapeTitle));
    }
    _toast(next.isDefault ? '已恢复默认剧集顺序' : '已应用剧集刮削与集数校准');
  }

  bool get _isPrivatePosterContext =>
      _activeSite.isEffectivelyPrivate ||
      AiService.instance.isPrivacySessionActive;

  String get _currentPosterIdentity =>
      '${_isPrivatePosterContext ? 'priv' : 'pub'}|${_activeSite.key}|${_video.id}|$_effectivePosterUrl|${_isPrivatePosterContext ? '' : _effectiveLookupTitle}|${_isPrivatePosterContext ? '' : _effectiveLookupYear}|${_isPrivatePosterContext ? '' : _effectiveDoubanId}';

  void _onPosterCardBytesLoaded(Uint8List bytes) {
    _loadedPosterBytes = bytes;
    _loadedPosterIdentity = _currentPosterIdentity;
    unawaited(_updateAmbientFromBytes(bytes));
  }

  Future<ui.Image?> _obtainTransitionPosterImage() async {
    if (OhosRuntime.isOhos || isWindowsDesktopUi) return null;
    final isPrivPoster = _isPrivatePosterContext;
    final currentId = _currentPosterIdentity;
    final bytes = (_loadedPosterIdentity == currentId
            ? _loadedPosterBytes
            : null) ??
        PosterLoader.peekMemory(
          _effectivePosterUrl,
          title: isPrivPoster ? '' : _publicLookupTitle,
          year: isPrivPoster ? '' : _video.year,
          preferHd: !isPrivPoster,
          isPrivate: isPrivPoster,
        );
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final cloned =
        PlayerEnterTransition.cloneRenderedImage(_transitionPosterKey);
    if (cloned != null) {
      return cloned;
    }
    return PlayerEnterTransition.decodePosterBytes(bytes);
  }

  @override
  void dispose() {
    if (_windowsDarkSurfaceApplied) {
      _windowsDarkSurfaceApplied = false;
      scheduleMicrotask(() {
        final next = WindowsImmersiveFrame.darkSurfaceDepth.value - 1;
        WindowsImmersiveFrame.darkSurfaceDepth.value = next < 0 ? 0 : next;
      });
    }
    _cancelDetailWork();
    AiService.instance.removeListener(_onIosDetailAiStateChanged);
    PosterLoader.metadataRevision.removeListener(_onExternalMetadataRevision);
    widget.storage.watchHistoryRevision.removeListener(_onWatchHistoryChanged);
    widget.storage.seriesScrapeRevision.removeListener(_onSeriesScrapeRevision);
    _windowsEpisodeQueryCtrl.dispose();
    _scrollOffset.dispose();
    _pullOverscroll.dispose();
    _pullRefreshPhase.dispose();
    _browsingEpisodeNotifier.dispose();
    _seasonsScrollController.dispose();
    _quickEpisodesScrollController.dispose();
    _previewCardsScrollController.dispose();
    _pageRangeScrollController.dispose();
    super.dispose();
  }

  void _onIosDetailAiStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onWatchHistoryChanged() {
    if (!mounted) return;
    if (_isIosDetail && _pendingPostPopSync) {
      final synced = _syncAfterPlayerReturn(
        bookmarkBefore: _bookmarkBeforeLastPlayer,
        confirmedBefore: _confirmedBeforeLastPlayer,
      );
      if (synced) {
        _bookmarkBeforeLastPlayer = _findBookmark();
        _confirmedBeforeLastPlayer = _confirmedPlayback;
        return;
      }
    }
    setState(() {});
  }

  void _cancelDetailWork() {
    if (_detailAbort?.isCompleted == false) _detailAbort!.complete();
    if (_seasonAbort?.isCompleted == false) _seasonAbort!.complete();
    if (_aggregationAbort?.isCompleted == false) _aggregationAbort!.complete();
  }

  WorkSourceRef _sourceRefFor(CmsSite site, CmsVideo video) => WorkSourceRef(
        subscriptionId: site.subscriptionId,
        site: site,
        videoId: video.id,
        video: video,
        sourceLabel: site.name,
      );

  void _seedAggregatedSources() {
    final primary = _sourceRefFor(_activeSite, _video);
    final seen = <String>{primary.identityKey};
    final seeded = <WorkSourceRef>[primary];
    for (final ref in widget.initialSources) {
      if (seen.add(ref.identityKey)) {
        seeded.add(ref);
      }
    }
    _aggregatedSources = seeded;
    if (_canShowInitialLinesImmediately(_activeSite, _video)) {
      _aggregatedDetails[primary.identityKey] = WorkSourceDetail(
        source: primary,
        video: _video,
      );
      _unifiedEpisodesVersion++;
    }
  }

  void _recordHydratedSource(CmsSite site, CmsVideo detailed) {
    final normalized = WoggSource.normalizeCachedVideoLabels(site, detailed);
    final ref = _sourceRefFor(site, normalized);
    final idx =
        _aggregatedSources.indexWhere((s) => s.identityKey == ref.identityKey);
    if (idx >= 0) {
      final updated = List<WorkSourceRef>.from(_aggregatedSources);
      updated[idx] = ref;
      _aggregatedSources = updated;
    } else {
      _aggregatedSources = <WorkSourceRef>[..._aggregatedSources, ref];
    }
    if (normalized.lines.any((l) => l.episodes.isNotEmpty)) {
      _aggregatedDetails[ref.identityKey] = WorkSourceDetail(
        source: ref,
        video: normalized,
      );
      _aggregatedSourceErrors.remove(ref.identityKey);
      _unifiedEpisodesVersion++;
    }
  }

  List<AggregatedEpisodeSlot> _unifiedEpisodeSlots() {
    if (_cachedUnifiedEpisodesVersion == _unifiedEpisodesVersion) {
      return _cachedUnifiedEpisodes;
    }
    final activeKey = _sourceRefFor(_activeSite, _video).identityKey;
    final ordered = <WorkSourceDetail>[];
    final added = <String>{};
    final activeDetail = _aggregatedDetails[activeKey];
    if (activeDetail != null) {
      ordered.add(activeDetail);
      added.add(activeKey);
    }
    for (final ref in _aggregatedSources) {
      final d = _aggregatedDetails[ref.identityKey];
      if (d != null && added.add(ref.identityKey)) {
        ordered.add(d);
      }
    }
    for (final entry in _aggregatedDetails.entries) {
      if (added.add(entry.key)) {
        ordered.add(entry.value);
      }
    }
    _cachedUnifiedEpisodes = WorkAggregation.buildUnifiedEpisodes(
      details: ordered,
      seriesTitle: _video.title,
    );
    _cachedUnifiedEpisodesVersion = _unifiedEpisodesVersion;
    return _cachedUnifiedEpisodes;
  }

  Map<String, CmsVideo> _preloadedSourceVideoMap() => <String, CmsVideo>{
        for (final entry in _aggregatedDetails.entries)
          entry.key: entry.value.video,
      };

  bool get _hasMultiSiteHydratedDetails {
    final siteKeys = <String>{
      for (final d in _aggregatedDetails.values) d.source.siteIdentityKey,
    };
    return siteKeys.length > 1;
  }

  bool get _hasAggregatedMultiOfferDetails {
    if (_hasMultiSiteHydratedDetails) return true;
    final totalPlayableLines = _aggregatedDetails.values.fold<int>(
      0,
      (sum, d) =>
          sum + d.video.lines.where((l) => l.episodes.isNotEmpty).length,
    );
    return totalPlayableLines > 1;
  }

  void _onUnifiedEpisodeSlotTap(
    AggregatedEpisodeSlot slot,
    WatchHistoryEntry? bookmark,
  ) {
    if (slot.offers.isEmpty) return;
    if (slot.offers.length == 1) {
      unawaited(_openPlayerForOffer(slot.offers.single));
      return;
    }
    _showUnifiedEpisodeOffersSheet(slot, bookmark);
  }

  Future<void> _hydrateAndDiscoverAggregatedSources(int detailEpoch) async {
    // Automatic cross-site hydration and background discovery is Windows-only
    // so iOS/macOS/Android/HarmonyOS detail pages never trigger extra searches.
    if (!isWindowsDesktopUi ||
        !mounted ||
        detailEpoch != _detailEpoch ||
        _activeSite.isEmby ||
        CuratedDiscoveryService.isCuratedSite(_activeSite)) {
      return;
    }
    if (_aggregationAbort?.isCompleted == false) _aggregationAbort!.complete();
    final abort = _aggregationAbort = Completer<void>();
    final aggEpoch = ++_aggregationEpoch;
    final primaryIdentity = WorkAggregation.extractIdentity(
      _video,
      site: _activeSite,
    );
    if (mounted) {
      setState(() => _hydratingAggregatedSources = true);
    }

    Future<void> hydrateRef(WorkSourceRef ref) async {
      if (!mounted ||
          abort.isCompleted ||
          detailEpoch != _detailEpoch ||
          aggEpoch != _aggregationEpoch) {
        return;
      }
      if (_aggregatedDetails.containsKey(ref.identityKey)) return;
      final reqAbort = Completer<void>();
      final timer = Timer(const Duration(seconds: 8), () {
        if (!reqAbort.isCompleted) reqAbort.complete();
      });
      try {
        final (owner, detailed) = await widget.client.runSourceOperation(
          () => widget.client.playableDetail(ref.site, ref.video, const []),
          cancellation: reqAbort,
        );
        if (!mounted ||
            abort.isCompleted ||
            detailEpoch != _detailEpoch ||
            aggEpoch != _aggregationEpoch) {
          return;
        }
        if (owner.key == ref.site.key &&
            detailed.lines.any((l) => l.episodes.isNotEmpty)) {
          final detailedIdentity = WorkAggregation.extractIdentity(
            detailed,
            site: owner,
          );
          if (!WorkAggregation.isSameWorkIdentity(
            primaryIdentity,
            detailedIdentity,
          )) {
            setState(() {
              _aggregatedSources = _aggregatedSources
                  .where((s) => s.identityKey != ref.identityKey)
                  .toList();
              _aggregatedSourceErrors[ref.identityKey] = '目标片源年份或版本与当前作品不一致';
            });
            return;
          }
          setState(() => _recordHydratedSource(owner, detailed));
          return;
        }
        if (ref.video.lines.any((l) => l.episodes.isNotEmpty)) {
          final fallbackIdentity = WorkAggregation.extractIdentity(
            ref.video,
            site: ref.site,
          );
          if (WorkAggregation.isSameWorkIdentity(
            primaryIdentity,
            fallbackIdentity,
          )) {
            setState(() => _recordHydratedSource(ref.site, ref.video));
          }
        }
      } catch (e) {
        if (!mounted ||
            abort.isCompleted ||
            detailEpoch != _detailEpoch ||
            aggEpoch != _aggregationEpoch) {
          return;
        }
        if (ref.video.lines.any((l) => l.episodes.isNotEmpty)) {
          final fallbackIdentity = WorkAggregation.extractIdentity(
            ref.video,
            site: ref.site,
          );
          if (WorkAggregation.isSameWorkIdentity(
            primaryIdentity,
            fallbackIdentity,
          )) {
            setState(() => _recordHydratedSource(ref.site, ref.video));
          }
        } else {
          setState(() {
            _aggregatedSourceErrors[ref.identityKey] =
                CmsClient.cleanErrorMessage(e);
          });
        }
      } finally {
        timer.cancel();
      }
    }

    try {
      // Phase 1: Hydrate sibling sources already known from aggregated search.
      final pendingInitial = _aggregatedSources
          .where((ref) => !_aggregatedDetails.containsKey(ref.identityKey))
          .toList();
      for (var i = 0; i < pendingInitial.length && !abort.isCompleted; i += 2) {
        final batch = pendingInitial.skip(i).take(2).toList();
        await Future.wait(batch.map(hydrateRef));
      }

      if (!mounted ||
          abort.isCompleted ||
          detailEpoch != _detailEpoch ||
          aggEpoch != _aggregationEpoch) {
        return;
      }

      // Phase 2: Discover sibling sources from other enabled searchable sites
      // (covers entering Detail from Home, Favorites, Watch History, or single-hit search).
      final keyword = WorkAggregation.searchKeywordFor(_video);
      if (keyword.isNotEmpty) {
        final knownSiteKeys = <String>{
          for (final ref in _aggregatedSources) ref.siteIdentityKey,
        };
        final knownRawSiteKeys = <String>{
          for (final ref in _aggregatedSources) ref.site.key,
        };
        final savedSites = widget.storage.prioritizeSites(
          widget.storage.loadSavedConfig()?.availableSites ?? const <CmsSite>[],
        );
        final discoveryTargets = savedSites
            .where((s) =>
                s.supported &&
                s.searchable &&
                !s.isEmby &&
                !CuratedDiscoveryService.isCuratedSite(s) &&
                s.isEffectivelyPrivate == _activeSite.isEffectivelyPrivate &&
                !knownSiteKeys.contains('${s.subscriptionId}:${s.key}') &&
                !knownRawSiteKeys.contains(s.key))
            .take(6)
            .toList();

        if (discoveryTargets.isNotEmpty) {
          final primaryIdentity = WorkAggregation.extractIdentity(
            _video,
            site: _activeSite,
          );
          for (var i = 0;
              i < discoveryTargets.length && !abort.isCompleted;
              i += 2) {
            final batch = discoveryTargets.skip(i).take(2).toList();
            final discoveredRefs = <WorkSourceRef>[];
            await Future.wait(batch.map((site) async {
              if (abort.isCompleted) return;
              final reqAbort = Completer<void>();
              final timer = Timer(const Duration(seconds: 6), () {
                if (!reqAbort.isCompleted) reqAbort.complete();
              });
              try {
                final listing = await widget.client.runSourceOperation(
                  () => widget.client.fetchSearch(site, keyword),
                  cancellation: reqAbort,
                );
                if (!mounted ||
                    abort.isCompleted ||
                    detailEpoch != _detailEpoch ||
                    aggEpoch != _aggregationEpoch) {
                  return;
                }
                for (final candidate in listing.videos) {
                  final candId = WorkAggregation.extractIdentity(
                    candidate,
                    site: site,
                  );
                  if (WorkAggregation.isSameWorkIdentity(
                    primaryIdentity,
                    candId,
                  )) {
                    discoveredRefs.add(_sourceRefFor(site, candidate));
                    break;
                  }
                }
              } catch (_) {
              } finally {
                timer.cancel();
              }
            }));

            if (!mounted ||
                abort.isCompleted ||
                detailEpoch != _detailEpoch ||
                aggEpoch != _aggregationEpoch) {
              return;
            }
            if (discoveredRefs.isNotEmpty) {
              final existingKeys = <String>{
                for (final r in _aggregatedSources) r.identityKey,
              };
              final newlyAdded = <WorkSourceRef>[
                for (final ref in discoveredRefs)
                  if (existingKeys.add(ref.identityKey)) ref,
              ];
              if (newlyAdded.isNotEmpty) {
                setState(() {
                  _aggregatedSources = <WorkSourceRef>[
                    ..._aggregatedSources,
                    ...newlyAdded,
                  ];
                });
                await Future.wait(newlyAdded.map(hydrateRef));
              }
            }
          }
        }
      }
    } finally {
      if (mounted &&
          detailEpoch == _detailEpoch &&
          aggEpoch == _aggregationEpoch) {
        setState(() => _hydratingAggregatedSources = false);
      }
    }
  }

  void _switchToAggregatedSource(WorkSourceRef ref) {
    final hydrated = _aggregatedDetails[ref.identityKey];
    if (hydrated != null) {
      setState(() {
        _activeSite = hydrated.source.site;
        _video = hydrated.video;
        _selectedLine = _pickRecommendedPlayableLineIndex(
          hydrated.video.lines,
          siteOverride: hydrated.source.site,
        );
        _selectedPage = 0;
        _selectedInLineSeason = null;
        _error = null;
        _errorCause = null;
        _isFavorite = widget.storage.isFavorite(
          _activeSite.key,
          _video.id,
          forPrivate: _activeSite.isEffectivelyPrivate,
        );
        _unifiedEpisodesVersion++;
      });
      _loadScrapeOverride();
      return;
    }
    setState(() {
      _activeSite = ref.site;
      _video = WoggSource.normalizeCachedVideoLabels(ref.site, ref.video);
      _selectedLine = 0;
      _selectedPage = 0;
      _selectedInLineSeason = null;
      _isFavorite = widget.storage.isFavorite(
        _activeSite.key,
        _video.id,
        forPrivate: _activeSite.isEffectivelyPrivate,
      );
    });
    _loadScrapeOverride();
    _loadDetail();
  }

  void _onExternalMetadataRevision() {
    if (!mounted || _activeSite.isEffectivelyPrivate) return;
    final lookupTitle = _effectiveLookupTitle;
    final lookupYear = _effectiveLookupYear;
    final wantMc = _effectiveWantMotionComic;
    final syn = PosterLoader.peekSeriesSynopsis(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    final epMetaLen = PosterLoader.peekAllEpisodeMeta(
      lookupTitle,
      wantMotionComic: wantMc,
    ).length;
    final capLen = PosterLoader.peekSeriesEpisodeCaptions(
      lookupTitle,
      wantMotionComic: wantMc,
    ).length;
    final ratings = PosterLoader.peekRatings(
      lookupTitle,
      year: lookupYear,
      wantMotionComic: wantMc,
    );
    final sig = Object.hash(
      syn,
      epMetaLen,
      capLen,
      ratings?.douban,
      ratings?.rt,
    );
    if (sig == _lastMetadataSnapshotSig) return;
    _lastMetadataSnapshotSig = sig;
    if (syn.isNotEmpty && syn != _externalSynopsis) {
      _externalSynopsis = syn;
    }
    if (ratings != null) {
      _resolvedDoubanScore =
          _scrapeOverride?.doubanScore ?? ratings.douban ?? _resolvedDoubanScore;
      _resolvedRtScore = ratings.rt ?? _resolvedRtScore;
    }
    setState(() {});
  }

  Future<void> _updateAmbientFromBytes(Uint8List bytes) async {
    final extracted = await PosterLoader.extractEdgeAmbientColor(bytes);
    if (!mounted) return;
    if (_posterAmbientColor != extracted) {
      setState(() {
        _posterAmbientColor = extracted;
      });
    }
  }

  bool get _isVarietyShow {
    final metaText =
        '${_video.tag} ${_video.remarks} ${_video.title}'.toLowerCase();
    if (metaText.contains('综艺') ||
        metaText.contains('真人秀') ||
        metaText.contains('脱口秀') ||
        metaText.contains('晚会') ||
        metaText.contains('选秀') ||
        metaText.contains('演唱会')) {
      return true;
    }
    if (_video.lines.isNotEmpty) {
      final eps = _video.lines.first.episodes;
      int issueLikeCount = 0;
      final sampleCount = eps.length < 6 ? eps.length : 6;
      for (int i = 0; i < sampleCount; i++) {
        final n = eps[i].name;
        if (n.contains('期') ||
            n.contains('先导') ||
            n.contains('加更') ||
            n.contains('纯享') ||
            RegExp(r'\b20\d{6}\b').hasMatch(n)) {
          issueLikeCount++;
        }
      }
      if (sampleCount > 0 && issueLikeCount * 2 >= sampleCount) {
        return true;
      }
    }
    return false;
  }

  Future<void> _warmRatings(String title, {String year = ''}) async {
    if (_activeSite.isEmby || _activeSite.isEffectivelyPrivate) return;
    final trimmed = _effectiveLookupTitle.trim().isNotEmpty
        ? _effectiveLookupTitle.trim()
        : title.trim();
    if (trimmed.isEmpty) return;
    final effectiveYear =
        _effectiveLookupYear.isNotEmpty ? _effectiveLookupYear : year;
    final epoch = _detailEpoch;
    final ratings = await PosterLoader.fetchRatings(
      trimmed,
      year: effectiveYear,
      wantMotionComic: _effectiveWantMotionComic,
      preferredDoubanId: _effectiveDoubanId,
      preferredDoubanIsTv: _effectiveDoubanIsTv,
    );
    if (!mounted || epoch != _detailEpoch) return;
    if ((ratings.douban != null && ratings.douban != _resolvedDoubanScore) ||
        (ratings.rt != null && ratings.rt != _resolvedRtScore)) {
      setState(() {
        _resolvedDoubanScore =
            _scrapeOverride?.doubanScore ?? ratings.douban ?? _resolvedDoubanScore;
        _resolvedRtScore = ratings.rt ?? _resolvedRtScore;
      });
    }
  }

  Future<void> _warmExternalMetadata(String title) async {
    if (_activeSite.isEmby || _activeSite.isEffectivelyPrivate) return;
    final lookupTitle = _effectiveLookupTitle.trim().isNotEmpty
        ? _effectiveLookupTitle.trim()
        : title.trim();
    if (lookupTitle.isEmpty) return;
    final lookupYear = _effectiveLookupYear;
    final wantMc = _effectiveWantMotionComic;
    unawaited(
      PosterLoader.fetchSeriesSynopsis(
        lookupTitle,
        year: lookupYear,
        wantMotionComic: wantMc,
      ).then((syn) {
        if (!mounted || syn.isEmpty) return;
        if (_externalSynopsis != syn) {
          setState(() {
            _externalSynopsis = syn;
          });
        }
      }),
    );
    final isMultiVersionMovie = _video.lines.isNotEmpty &&
        _isMultiVersionMovieLine(_video.lines.first);
    if (!_isVarietyShow && !isMultiVersionMovie) {
      unawaited(
        PosterLoader.fetchSeriesEpisodeMetadata(
          lookupTitle,
          year: lookupYear,
          wantMotionComic: wantMc,
        ),
      );
    }
    if (!isMultiVersionMovie) {
      unawaited(
        PosterLoader.fetchSeriesEpisodeStills(
          lookupTitle,
          year: lookupYear,
          wantMotionComic: wantMc,
        ),
      );
    }
  }

  bool _isMultiVersionMovieLine(CmsLine line) =>
      !_isVarietyShow &&
      EpisodeScraper.isLikelyMultiVersionMovie(
        line.episodes,
        videoTitle: _video.title,
        videoTag: _video.tag,
        videoRemarks: _video.remarks,
        override: _episodeScrapeOverride,
      );

  final Map<(CmsLine, String, List<CmsParse>), String?> _lineUnavailableCache =
      {};

  List<CmsParse> get _configuredParses =>
      widget.storage.loadSavedConfig()?.parses ?? const [];

  String? _episodeUnavailableReason(
    CmsEpisode episode, {
    CmsSite? siteOverride,
  }) =>
      WebMediaResolver.episodeUnavailableReason(
        episode,
        site: siteOverride ?? _activeSite,
        parses: _configuredParses,
      );

  String? _lineUnavailableReason(CmsLine line, {CmsSite? siteOverride}) {
    if (line.episodes.isEmpty) return '当前线路暂无剧集';
    final effectiveSite = siteOverride ?? _activeSite;
    final parses = _configuredParses;
    final cacheKey = (line, effectiveSite.key, parses);
    if (_lineUnavailableCache.containsKey(cacheKey)) {
      return _lineUnavailableCache[cacheKey];
    }
    String? firstReason;
    for (final ep in line.episodes) {
      final r = WebMediaResolver.episodeUnavailableReason(
        ep,
        site: effectiveSite,
        parses: parses,
      );
      if (r == null) {
        _lineUnavailableCache[cacheKey] = null;
        return null;
      }
      firstReason ??= r;
    }
    _lineUnavailableCache[cacheKey] = firstReason;
    return firstReason;
  }

  int _pickRecommendedPlayableLineIndex(
    List<CmsLine> lines, {
    CmsSite? siteOverride,
  }) {
    if (lines.isEmpty) return 0;
    final picked = widget.storage.pickRecommendedLineIndex(lines);
    if (_lineUnavailableReason(lines[picked], siteOverride: siteOverride) ==
        null) {
      return picked;
    }
    for (var i = 0; i < lines.length; i++) {
      if (_lineUnavailableReason(lines[i], siteOverride: siteOverride) ==
          null) {
        return i;
      }
    }
    return picked;
  }

  _LineIdentitySnapshot _captureLineIdentity(
    List<CmsLine> lines,
    int index, {
    String? siteKey,
    String? videoId,
  }) {
    final line = lines[index];
    final trimmedId = line.id.trim();
    final idCount = trimmedId.isEmpty
        ? 0
        : lines.where((l) => l.id.trim() == trimmedId).length;
    final nameCount = lines.where((l) => l.name == line.name).length;
    // URLs already shared with same-name (or same-ID) sibling lines at snapshot
    // time must NOT be used as evidence that a surviving sibling is this line.
    final siblingSharedUrls = <String>{};
    for (var j = 0; j < lines.length; j++) {
      if (j == index) continue;
      final sameName = lines[j].name == line.name;
      final sameId = trimmedId.isNotEmpty && lines[j].id.trim() == trimmedId;
      if (!sameName && !sameId) continue;
      for (final ep in lines[j].episodes) {
        final u = ep.url.trim();
        if (u.isNotEmpty) siblingSharedUrls.add(u);
      }
    }
    final episodeUrls = <String>[
      for (final ep in line.episodes) ep.url.trim(),
    ];
    final distinguishingUrls = <String>[
      for (final u in episodeUrls)
        if (u.isNotEmpty && !siblingSharedUrls.contains(u)) u,
    ];
    return (
      siteKey: siteKey ?? _activeSite.key,
      videoId: videoId ?? _video.id,
      lineId: trimmedId,
      lineName: line.name,
      idWasUnique: trimmedId.isNotEmpty && idCount == 1,
      nameWasUnique: nameCount == 1,
      episodeUrls: episodeUrls,
      distinguishingUrls: distinguishingUrls,
      episodeNames: [
        for (final ep in line.episodes) ep.name.trim(),
      ],
    );
  }

  void _selectLineManually(int index) {
    if (index < 0 || index >= _video.lines.length) return;
    _selectedLine = index;
    _manualLineSelection = _captureLineIdentity(_video.lines, index);
    _selectedPage = 0;
    _selectedInLineSeason = null;
    _browsingEpisode = null;
  }

  int? _matchPlayableLineByName(
    List<CmsLine> lines,
    String lineName, {
    required CmsSite siteOverride,
  }) {
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].name == lineName &&
          _lineUnavailableReason(lines[i], siteOverride: siteOverride) ==
              null) {
        return i;
      }
    }
    return null;
  }

  static bool _sameEpisodeUrlList(
    List<CmsEpisode> episodes,
    List<String> expectedUrls,
  ) {
    if (episodes.length != expectedUrls.length) return false;
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].url.trim() != expectedUrls[i]) return false;
    }
    return true;
  }

  int? _matchLineIndexByIdentity(
    List<CmsLine> lines,
    _LineIdentitySnapshot snapshot, {
    CmsSite? siteOverride,
    String? videoIdOverride,
    bool requirePlayable = false,
  }) {
    final currentSite = siteOverride ?? _activeSite;
    final currentVideoId = videoIdOverride ?? _video.id;
    if (currentSite.key != snapshot.siteKey ||
        currentVideoId != snapshot.videoId) {
      return null;
    }
    bool isEligible(int idx) =>
        !requirePlayable ||
        _lineUnavailableReason(lines[idx], siteOverride: currentSite) == null;

    List<int>? narrowedCandidates;
    if (snapshot.idWasUnique && snapshot.lineId.isNotEmpty) {
      final idMatches = <int>[
        for (var idx = 0; idx < lines.length; idx++)
          if (lines[idx].id.trim() == snapshot.lineId) idx,
      ];
      if (idMatches.length == 1) {
        final matched = idMatches.single;
        return isEligible(matched) ? matched : null;
      }
      if (idMatches.isEmpty) {
        if (lines.any((l) => l.id.trim().isNotEmpty)) {
          return null;
        }
      } else {
        narrowedCandidates = idMatches;
      }
    }

    final candidates = narrowedCandidates ??
        <int>[
          for (var idx = 0; idx < lines.length; idx++)
            if (lines[idx].name == snapshot.lineName) idx,
        ];
    if (candidates.isEmpty) {
      return null;
    }

    if (snapshot.episodeUrls.isNotEmpty) {
      final exactMatches = <int>[
        for (final idx in candidates)
          if (_sameEpisodeUrlList(lines[idx].episodes, snapshot.episodeUrls))
            idx,
      ];
      if (exactMatches.length == 1) {
        final matched = exactMatches.single;
        return isEligible(matched) ? matched : null;
      }
      if (exactMatches.length > 1) {
        return null;
      }

      final snapshotUrlSet = <String>{
        for (final u in snapshot.distinguishingUrls)
          if (u.isNotEmpty) u,
      };
      if (snapshotUrlSet.isNotEmpty) {
        var bestOverlap = 0;
        final bestIndices = <int>[];
        for (final idx in candidates) {
          final candidateUrlSet = <String>{
            for (final ep in lines[idx].episodes)
              if (ep.url.trim().isNotEmpty) ep.url.trim(),
          };
          final overlap = candidateUrlSet.intersection(snapshotUrlSet).length;
          if (overlap > bestOverlap) {
            bestOverlap = overlap;
            bestIndices
              ..clear()
              ..add(idx);
          } else if (overlap > 0 && overlap == bestOverlap) {
            bestIndices.add(idx);
          }
        }
        if (bestOverlap > 0) {
          if (bestIndices.length == 1) {
            final matched = bestIndices.single;
            return isEligible(matched) ? matched : null;
          }
          return null;
        }
      }
    }

    // Only fall back to display-name-only match when the display name was
    // unique at snapshot time AND remains unique now. If duplicate display
    // names existed, a lone surviving line with disjoint episode URLs cannot
    // be assumed to be the original line.
    if (snapshot.nameWasUnique && candidates.length == 1) {
      final matched = candidates.single;
      return isEligible(matched) ? matched : null;
    }
    return null;
  }

  (int lineIndex, int episodeIndex)? _resolveEpisodeTargetByIdentity({
    required _LineIdentitySnapshot snapshotLineIdentity,
    required CmsEpisode snapshotEpisode,
  }) {
    final lineIdx = _matchLineIndexByIdentity(
      _video.lines,
      snapshotLineIdentity,
    );
    if (lineIdx == null) {
      return null;
    }
    final line = _video.lines[lineIdx];
    final targetUrl = snapshotEpisode.url.trim();
    final targetName = snapshotEpisode.name;

    final exactBoth = <int>[
      for (var j = 0; j < line.episodes.length; j++)
        if (line.episodes[j].name == targetName &&
            line.episodes[j].url.trim() == targetUrl)
          j,
    ];
    if (exactBoth.length == 1) return (lineIdx, exactBoth.single);
    if (exactBoth.length > 1) return null;

    if (targetUrl.isNotEmpty) {
      final byUrl = <int>[
        for (var j = 0; j < line.episodes.length; j++)
          if (line.episodes[j].url.trim() == targetUrl) j,
      ];
      if (byUrl.length == 1) return (lineIdx, byUrl.single);
      if (byUrl.length > 1) return null;
    }

    final trimmedTargetName = targetName.trim();
    if (trimmedTargetName.isNotEmpty) {
      final snapshotNameCount = snapshotLineIdentity.episodeNames
          .where((name) => name == trimmedTargetName)
          .length;
      if (snapshotNameCount == 1) {
        final byName = <int>[
          for (var j = 0; j < line.episodes.length; j++)
            if (line.episodes[j].name.trim() == trimmedTargetName) j,
        ];
        if (byName.length == 1) return (lineIdx, byName.single);
      }
    }
    return null;
  }

  Future<void> _handleDetailPullRefresh() async {
    if (_pullRefreshing || !mounted) return;
    _pullRefreshing = true;
    _pullRefreshPhase.value = _DetailPullRefreshPhase.refreshing;
    setState(() {});
    try {
      await _loadDetail(forceRefresh: true);
    } finally {
      _pullRefreshing = false;
      if (mounted) {
        _pullRefreshPhase.value = _DetailPullRefreshPhase.idle;
        setState(() {});
      }
    }
  }

  void _setScrollMetricSafe(ValueNotifier<double> notifier, double value) {
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && notifier.value != value) {
          notifier.value = value;
        }
      });
      return;
    }
    notifier.value = value;
  }

  void _triggerPullRefreshFromGesture() {
    if (_pullRefreshing ||
        _pullRefreshPhase.value != _DetailPullRefreshPhase.armed) {
      return;
    }
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_pullRefreshing) {
          _pullRefreshPhase.value = _DetailPullRefreshPhase.refreshing;
          unawaited(_handleDetailPullRefresh());
        }
      });
      return;
    }
    _pullRefreshPhase.value = _DetailPullRefreshPhase.refreshing;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pullRefreshing) {
        unawaited(_handleDetailPullRefresh());
      }
    });
  }

  bool _handleDetailScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final pixels = notification.metrics.pixels;
    final nextOffset = pixels.clamp(0.0, 500.0);
    if ((_scrollOffset.value - nextOffset).abs() > 0.5) {
      _setScrollMetricSafe(_scrollOffset, nextOffset);
    }
    final overscroll = math.max(0.0, -pixels);
    if ((_pullOverscroll.value - overscroll).abs() > 0.5 ||
        (overscroll == 0.0 && _pullOverscroll.value != 0.0)) {
      _setScrollMetricSafe(_pullOverscroll, overscroll);
    }
    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        if (_pullRefreshPhase.value == _DetailPullRefreshPhase.idle &&
            !_pullRefreshing &&
            overscroll >= _kPullRefreshArmThreshold) {
          _pullRefreshPhase.value = _DetailPullRefreshPhase.armed;
          HapticFeedback.mediumImpact();
        } else if (_pullRefreshPhase.value == _DetailPullRefreshPhase.armed &&
            overscroll < _kPullRefreshDisarmThreshold) {
          _pullRefreshPhase.value = _DetailPullRefreshPhase.idle;
        }
      } else if (_pullRefreshPhase.value == _DetailPullRefreshPhase.armed) {
        _triggerPullRefreshFromGesture();
      }
    } else if (notification is ScrollEndNotification) {
      if (_pullRefreshPhase.value == _DetailPullRefreshPhase.armed) {
        _triggerPullRefreshFromGesture();
      }
    }
    return false;
  }

  Widget _buildDetailPullRefreshPill(double topPad) {
    return AnimatedBuilder(
      animation: Listenable.merge([_pullOverscroll, _pullRefreshPhase]),
      builder: (context, _) {
        final overscroll = _pullOverscroll.value;
        final phase = _pullRefreshPhase.value;
        final isRefreshing =
            _pullRefreshing || phase == _DetailPullRefreshPhase.refreshing;
        final isArmed = phase == _DetailPullRefreshPhase.armed;
        final pullProgress = ((overscroll - 12.0) / 60.0).clamp(0.0, 1.0);
        final showPill = isRefreshing || isArmed || pullProgress > 0.06;
        if (!showPill) return const SizedBox.shrink();
        final opacity = (isRefreshing || isArmed) ? 1.0 : pullProgress;
        final label = isRefreshing
            ? '正在刷新详情'
            : (isArmed ? '松手立即刷新' : '下拉刷新详情');
        return Positioned(
          top: topPad + 54 + (overscroll * 0.24).clamp(0.0, 26.0),
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: Opacity(
                opacity: opacity,
                child: Container(
                  key: const ValueKey('detail-pull-refresh-pill'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5.5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.66),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.22),
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
                        label,
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
        );
      },
    );
  }

  Future<void> _loadDetail({bool forceRefresh = false}) async {
    _cancelDetailWork();
    final epoch = ++_detailEpoch;
    final abort = _detailAbort = Completer<void>();
    final targetSite = _activeSite;
    final targetVideo = _video;
    final requestVideo = _detailRequestVideoFor(targetSite, targetVideo);
    if (forceRefresh) {
      _lineUnavailableCache.clear();
    }
    final _LineIdentitySnapshot? preservedLineOnStart =
        forceRefresh && targetVideo.lines.isNotEmpty
            ? _captureLineIdentity(
                targetVideo.lines,
                _selectedLine.clamp(0, targetVideo.lines.length - 1),
                siteKey: targetSite.key,
                videoId: targetVideo.id,
              )
            : null;
    final hasFreshCache = !forceRefresh &&
        targetVideo.lines.any((l) => l.episodes.isNotEmpty) &&
        widget.client.peekFreshCachedDetail(targetSite, targetVideo) != null;
    final showImmediately = hasFreshCache ||
        _canShowInitialLinesImmediately(
          targetSite,
          targetVideo,
        );
    final keepExistingVisible = forceRefresh && targetVideo.lines.isNotEmpty;
    int initialImmediateLine = _selectedLine;
    if (!forceRefresh && showImmediately && targetVideo.lines.isNotEmpty) {
      final manual = _manualLineSelection;
      final manualMatch = manual != null
          ? _matchLineIndexByIdentity(
              targetVideo.lines,
              manual,
              siteOverride: targetSite,
              videoIdOverride: targetVideo.id,
              requirePlayable: true,
            )
          : null;
      if (manualMatch != null) {
        initialImmediateLine = manualMatch;
      } else {
        final immediateBookmark = _findBookmark(targetVideo);
        if (immediateBookmark != null) {
          final strictLine = _isIosDetail
              ? _matchLineIndexStrict(
                  targetVideo.lines,
                  lineId: immediateBookmark.lineId,
                  lineName: immediateBookmark.line,
                  episodeUrl: immediateBookmark.effectiveMediaId,
                  episodeName: immediateBookmark.episode,
                )
              : null;
          final found = (strictLine != null &&
                  _lineUnavailableReason(
                        targetVideo.lines[strictLine],
                        siteOverride: targetSite,
                      ) ==
                      null)
              ? strictLine
              : _matchPlayableLineByName(
                  targetVideo.lines,
                  immediateBookmark.line,
                  siteOverride: targetSite,
                );
          initialImmediateLine = found ??
              _pickRecommendedPlayableLineIndex(
                targetVideo.lines,
                siteOverride: targetSite,
              );
        } else {
          initialImmediateLine = _pickRecommendedPlayableLineIndex(
            targetVideo.lines,
            siteOverride: targetSite,
          );
        }
      }
    }
    int? immediateAlignSlot;
    setState(() {
      _loading = !(showImmediately || keepExistingVisible);
      if (!forceRefresh && showImmediately) {
        _selectedLine = initialImmediateLine;
        if (_isIosDetail &&
            _browsingEpisode == null &&
            targetVideo.lines.isNotEmpty) {
          final safeLine =
              initialImmediateLine.clamp(0, targetVideo.lines.length - 1);
          final target = _resolveSeasonPageAndSlotForPlayedEpisode(
            video: targetVideo,
            lineIdx: safeLine,
            bookmark: _findBookmark(targetVideo),
          );
          if (target != null) {
            _selectedInLineSeason = target.inLineSeason;
            _selectedPage = target.page;
            immediateAlignSlot = target.slotInPage;
          }
        }
      }
      _error = null;
      _errorCause = null;
      _curatedUnavailableMessage = null;
      _discoveringSeasons = false;
    });
    if (_isIosDetail && immediateAlignSlot != null && !_initialEpisodeAligned) {
      _initialEpisodeAligned = true;
      _scheduleAlignEpisodeStripsToSlot(immediateAlignSlot!, animate: false);
    }
    if (CuratedDiscoveryService.isCuratedSite(targetSite)) {
      await _resolveCuratedFromUserSources(
        targetVideo: targetVideo,
        epoch: epoch,
        abort: abort,
        forceRefresh: forceRefresh,
      );
      return;
    }
    try {
      final (owner, detailed) = await widget.client.runSourceOperation(
        () => widget.client.playableDetail(
          targetSite,
          requestVideo,
          widget.storage.prioritizeSites(
            widget.storage.loadSavedConfig()?.availableSites ?? const [],
          ),
          forceRefresh: forceRefresh,
        ),
        cancellation: abort,
      );
      if (!mounted ||
          abort.isCompleted ||
          epoch != _detailEpoch ||
          targetSite.key != _activeSite.key ||
          targetVideo.id != _video.id) {
        return;
      }
      final switchedTarget =
          owner.key != targetSite.key || detailed.id != targetVideo.id;
      _activeSite = owner;
      if (switchedTarget) {
        _detailSeedVideo = detailed;
      }
      _isFavorite = widget.storage.isFavorite(
        owner.key,
        detailed.id,
        forPrivate: owner.isEffectivelyPrivate,
      );
      int initialLine = 0;
      var manualSelectionLost = false;
      if (detailed.lines.isNotEmpty) {
        final latestManual = _manualLineSelection;
        final sameIdentity =
            owner.key == targetSite.key && detailed.id == targetVideo.id;
        final manualMatchesVideo = latestManual != null &&
            latestManual.siteKey == owner.key &&
            latestManual.videoId == detailed.id;
        _LineIdentitySnapshot? preferredLineIdentity;
        if (manualMatchesVideo) {
          preferredLineIdentity = latestManual;
        } else if (forceRefresh &&
            sameIdentity &&
            preservedLineOnStart != null) {
          preferredLineIdentity = preservedLineOnStart;
        }
        final matchedPreferred = preferredLineIdentity != null
            ? _matchLineIndexByIdentity(
                detailed.lines,
                preferredLineIdentity,
                siteOverride: owner,
                videoIdOverride: detailed.id,
                requirePlayable: true,
              )
            : null;
        if (matchedPreferred != null) {
          initialLine = matchedPreferred;
          if (manualMatchesVideo) {
            _manualLineSelection = _captureLineIdentity(
              detailed.lines,
              matchedPreferred,
              siteKey: owner.key,
              videoId: detailed.id,
            );
          }
        } else {
          if (manualMatchesVideo) {
            _manualLineSelection = null;
            manualSelectionLost = true;
          }
          final bookmark = _findBookmark(detailed);
          if (bookmark != null) {
            final strictLine = _isIosDetail
                ? _matchLineIndexStrict(
                    detailed.lines,
                    lineId: bookmark.lineId,
                    lineName: bookmark.line,
                    episodeUrl: bookmark.effectiveMediaId,
                    episodeName: bookmark.episode,
                  )
                : null;
            final found = (strictLine != null &&
                    _lineUnavailableReason(
                          detailed.lines[strictLine],
                          siteOverride: owner,
                        ) ==
                        null)
                ? strictLine
                : _matchPlayableLineByName(
                    detailed.lines,
                    bookmark.line,
                    siteOverride: owner,
                  );
            initialLine = found ??
                _pickRecommendedPlayableLineIndex(
                  detailed.lines,
                  siteOverride: owner,
                );
          } else {
            initialLine = _pickRecommendedPlayableLineIndex(
              detailed.lines,
              siteOverride: owner,
            );
          }
        }
      } else if (_manualLineSelection != null &&
          _manualLineSelection!.siteKey == owner.key &&
          _manualLineSelection!.videoId == detailed.id) {
        _manualLineSelection = null;
      }
      int? alignedSlotAfterLoad;
      setState(() {
        _video = detailed;
        _selectedLine = initialLine;
        _loading = false;
        if (_isIosDetail &&
            !forceRefresh &&
            _browsingEpisode == null &&
            detailed.lines.isNotEmpty) {
          final safeLine = initialLine.clamp(0, detailed.lines.length - 1);
          final initLine = detailed.lines[safeLine];
          final target = _resolveSeasonPageAndSlotForPlayedEpisode(
            video: detailed,
            lineIdx: safeLine,
            bookmark: _findBookmark(detailed),
          );
          if (target != null) {
            _selectedInLineSeason = target.inLineSeason;
            _selectedPage = target.page;
            alignedSlotAfterLoad = target.slotInPage;
          } else {
            // Keep selected page valid for active line if episode count shrank
            final initActive = _activeEpisodeIndicesFor(initLine);
            final maxPage = initActive.isEmpty
                ? 0
                : (initActive.length - 1) ~/ CmsParser.episodePageSize;
            if (_selectedPage > maxPage) _selectedPage = maxPage;
          }
        }
        _recordHydratedSource(_activeSite, detailed);
      });
      if (_isIosDetail && alignedSlotAfterLoad != null && !_initialEpisodeAligned) {
        _initialEpisodeAligned = true;
        _scheduleAlignEpisodeStripsToSlot(alignedSlotAfterLoad!, animate: false);
      }
      if (manualSelectionLost) {
        _toast('原播放线路已变更或下架，请重新选择');
      }
      _mergeSeasonCandidates(_activeSite, [detailed]);
      unawaited(_hydrateAndDiscoverAggregatedSources(epoch));
      if (detailed.title.trim().isNotEmpty) {
        _warmRatings(detailed.title, year: detailed.year);
        _warmExternalMetadata(detailed.title);
        unawaited(_discoverRelatedSeasons(detailed.title));
      }
    } catch (e) {
      if (!mounted ||
          abort.isCompleted ||
          epoch != _detailEpoch ||
          targetSite.key != _activeSite.key ||
          targetVideo.id != _video.id) {
        return;
      }
      final clearedByPendingRetry =
          widget.client.hasPendingDetailRetry(targetSite, targetVideo);
      setState(() {
        _loading = false;
        if (clearedByPendingRetry && _video.lines.isNotEmpty) {
          _video = _stripVideoLines(_video);
          _manualLineSelection = null;
          _selectedLine = 0;
        }
        if (clearedByPendingRetry ||
            !(showImmediately || keepExistingVisible) ||
            _video.lines.isEmpty) {
          _error = '读取详情失败：${CmsClient.cleanErrorMessage(e)}';
          _errorCause = e;
        }
      });
      unawaited(_hydrateAndDiscoverAggregatedSources(epoch));
    }
  }

  /// Resolves a curated Rex-style discovery card STRICTLY against the user's
  /// own added CMS sources. Never supplies built-in stream URLs; when no user
  /// source contains the title, clearly marks playback unavailable.
  Future<void> _resolveCuratedFromUserSources({
    required CmsVideo targetVideo,
    required int epoch,
    required Completer<void> abort,
    bool forceRefresh = false,
  }) async {
    if (targetVideo.title.trim().isNotEmpty) {
      _warmRatings(targetVideo.title, year: targetVideo.year);
      _warmExternalMetadata(targetVideo.title);
    }
    final userSites = widget.storage
        .prioritizeSites(
          widget.storage.loadSavedConfig()?.publicAvailableSites ?? const [],
        )
        .where((s) => s.searchable && !CuratedDiscoveryService.isCuratedSite(s))
        .toList();
    if (userSites.isEmpty) {
      if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
      setState(() {
        _loading = false;
        _curatedUnavailableMessage =
            '您暂未添加可用片源，无法播放《${targetVideo.title}》。请先在「片源」中添加片源。';
      });
      return;
    }

    final query = targetVideo.title
        .replaceAll(RegExp(r'\s+第[一二三四五六七八九十0-9]+季$'), '')
        .trim();
    final searchTargets = userSites.take(8).toList();
    ({int score, CmsSite site, CmsVideo video})? bestMatch;

    try {
      await widget.client.runSourceOperation(() async {
        for (var i = 0; i < searchTargets.length && !abort.isCompleted; i += 2) {
          final batch = searchTargets.skip(i).take(2).toList();
          await Future.wait(
            batch.map((site) async {
              if (abort.isCompleted) return;
              final reqAbort = Completer<void>();
              final timer = Timer(const Duration(seconds: 5), () {
                if (!reqAbort.isCompleted) reqAbort.complete();
              });
              try {
                final listing = await widget.client.runSourceOperation(
                  () => widget.client.fetchSearch(
                    site,
                    query.isEmpty ? targetVideo.title : query,
                  ),
                  cancellation: reqAbort,
                );
                for (final candidate in listing.videos) {
                  final score = CuratedDiscoveryService.titleMatchScore(
                    targetVideo.title,
                    candidate.title,
                  );
                  if (score >= 60 &&
                      (bestMatch == null || score > bestMatch!.score)) {
                    bestMatch = (score: score, site: site, video: candidate);
                  }
                }
              } catch (_) {
              } finally {
                timer.cancel();
              }
            }),
          );
          if (bestMatch != null && bestMatch!.score >= 100) break;
        }
      }, cancellation: abort);
    } catch (_) {}

    if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
    if (bestMatch == null) {
      setState(() {
        _loading = false;
        _curatedUnavailableMessage =
            '您已添加的片源中暂未找到《${targetVideo.title}》的播放资源，无法播放';
      });
      return;
    }

    try {
      final (owner, detailed) = await widget.client.runSourceOperation(
        () => widget.client.playableDetail(
          bestMatch!.site,
          bestMatch!.video,
          userSites,
          forceRefresh: forceRefresh,
        ),
        cancellation: abort,
      );
      if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
      if (detailed.lines.isEmpty) {
        setState(() {
          _loading = false;
          _curatedUnavailableMessage =
              '片源「${owner.name}」暂未提供《${targetVideo.title}》的可播放线路，无法播放';
        });
        return;
      }
      final mergedVideo = CmsVideo(
        id: detailed.id,
        title: detailed.title.isNotEmpty ? detailed.title : targetVideo.title,
        poster:
            detailed.poster.isNotEmpty ? detailed.poster : targetVideo.poster,
        remarks:
            detailed.remarks.isNotEmpty ? detailed.remarks : targetVideo.remarks,
        year: detailed.year.isNotEmpty ? detailed.year : targetVideo.year,
        area: detailed.area.isNotEmpty ? detailed.area : targetVideo.area,
        actor: detailed.actor.isNotEmpty ? detailed.actor : targetVideo.actor,
        description: detailed.description.isNotEmpty
            ? detailed.description
            : targetVideo.description,
        tag: detailed.tag.isNotEmpty ? detailed.tag : targetVideo.tag,
        doubanScore: detailed.doubanScore ?? targetVideo.doubanScore,
        rtScore: detailed.rtScore ?? targetVideo.rtScore,
        lines: detailed.lines,
        sourceWarnings: detailed.sourceWarnings,
      );
      _activeSite = owner;
      _detailSeedVideo =
          bestMatch!.site.key == owner.key &&
                  bestMatch!.video.id == mergedVideo.id
              ? bestMatch!.video
              : mergedVideo;
      _isFavorite = widget.storage.isFavorite(
        owner.key,
        mergedVideo.id,
        forPrivate: owner.isEffectivelyPrivate,
      );
      final initialLine = _pickRecommendedPlayableLineIndex(
        mergedVideo.lines,
        siteOverride: owner,
      );
      setState(() {
        _video = mergedVideo;
        _selectedLine = initialLine;
        _loading = false;
        _curatedUnavailableMessage = null;
      });
    } catch (_) {
      if (!mounted || abort.isCompleted || epoch != _detailEpoch) return;
      setState(() {
        _loading = false;
        _curatedUnavailableMessage =
            '您已添加的片源中暂无法解析《${targetVideo.title}》的播放资源，无法播放';
      });
    }
  }

  Widget _buildDetailError() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(children: [
      Text(_error!, textAlign: TextAlign.center,
          style: const TextStyle(color: AppleColors.systemRed, fontSize: 14)),
      if (CmsClient.needsSourceVerification(_activeSite, _errorCause))
        Padding(padding: const EdgeInsets.only(top: 12), child: SourceVerificationButton(
          client: widget.client, site: _activeSite, onVerified: _loadDetail)),
    ]),
  );

  Future<void> _discoverRelatedSeasons(String title) async {
    final site = _activeSite;
    final epoch = _detailEpoch;
    if (site.isEmby) return;
    final info = CmsParser.parseSeriesSeasonInfo(title);
    if (!info.hasExplicitSeason) return;
    final base = info.baseTitle.trim();
    if (base.isEmpty) return;
    _mergeSeasonCandidates(site, [_video]);
    final normKey = '${site.isEffectivelyPrivate}_${base.toLowerCase()}';
    if (_discoveredFranchiseKey == normKey && _relatedSeasons.length > 1) return;
    if (_seasonAbort?.isCompleted == false) _seasonAbort!.complete();
    final abort = _seasonAbort = Completer<void>();
    bool current() => mounted && !abort.isCompleted &&
        identical(_seasonAbort, abort) && epoch == _detailEpoch;
    try {
      // Let the episode list become usable before optional season discovery.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!current()) return;
      _discoveredFranchiseKey = normKey;
      setState(() => _discoveringSeasons = true);
      await widget.client.runSourceOperation(() async {
        Future<void> search(CmsSite candidate) async {
          if (!current()) return;
          final requestAbort = Completer<void>();
          final timer = Timer(const Duration(seconds: 6), () {
            if (!requestAbort.isCompleted) requestAbort.complete();
          });
          try {
            final result = await widget.client.runSourceOperation(
              () => widget.client.fetchSearch(candidate, base),
              cancellation: requestAbort,
            );
            if (current() && result.videos.isNotEmpty) {
              _mergeSeasonCandidates(candidate, result.videos);
            }
          } catch (_) {
            // Optional discovery cannot turn a usable episode list into an error.
          } finally {
            timer.cancel();
          }
        }
        if (site.supported && site.searchable) await search(site);
        if (!current() || !(_relatedSeasons.length < 3 ||
            (info.seasonNumber > 1 && _relatedSeasons.length < info.seasonNumber))) return;
        final allSites = widget.storage.loadSavedConfig()?.supportedSites ?? const <CmsSite>[];
        final siblings = DetailScreen.selectRelatedSeasonSiblings(site, allSites);
        // Leave capacity for the foreground detail/player instead of starting
        // six background source runtimes at once on a phone.
        for (var i = 0; i < siblings.length && current(); i += 2) {
          await Future.wait(siblings.skip(i).take(2).map(search));
        }
      }, cancellation: abort);
    } catch (_) {
      // Closing or replacing this screen cancels the discovery operation.
    } finally {
      if (current()) setState(() => _discoveringSeasons = false);
    }
  }

  void _mergeSeasonCandidates(
    CmsSite candidateSite,
    List<CmsVideo> candidates,
  ) {
    final bySeason = <int,
        ({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})>{
      for (final item in _relatedSeasons) item.seasonNumber: item,
    };
    final curInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final currentSeed = _detailRequestVideoFor(_activeSite, _video);
    bySeason[curInfo.seasonNumber] = (
      seasonNumber: curInfo.seasonNumber,
      seasonLabel: curInfo.seasonLabel,
      site: _activeSite,
      video: currentSeed,
    );
    for (final cand in candidates) {
      if (!CmsParser.isSameFranchiseSeasonCandidate(_video.title, cand.title)) {
        continue;
      }
      final candInfo = CmsParser.parseSeriesSeasonInfo(cand.title);
      if (!curInfo.hasExplicitSeason &&
          !candInfo.hasExplicitSeason &&
          cand.id != _video.id) {
        continue;
      }
      final existing = bySeason[candInfo.seasonNumber];
      if (existing == null) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: candidateSite,
          video: cand,
        );
      } else if (existing.video.id == _video.id &&
          existing.site.key == _activeSite.key) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: _activeSite,
          video: currentSeed,
        );
      } else if (existing.site.key != _activeSite.key &&
          candidateSite.key == _activeSite.key) {
        bySeason[candInfo.seasonNumber] = (
          seasonNumber: candInfo.seasonNumber,
          seasonLabel: candInfo.seasonLabel,
          site: candidateSite,
          video: cand,
        );
      }
    }
    final sorted = bySeason.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    if (mounted) {
      setState(() {
        _relatedSeasons = sorted;
      });
    } else {
      _relatedSeasons = sorted;
    }
  }

  void _switchToRelatedSeason(
    ({int seasonNumber, String seasonLabel, CmsSite site, CmsVideo video})
        option,
  ) {
    if (option.video.id == _video.id && option.site.key == _activeSite.key) {
      if (_selectedInLineSeason != null) {
        setState(() {
          _selectedInLineSeason = null;
          _selectedPage = 0;
        });
      }
      return;
    }
    setState(() {
      _activeSite = option.site;
      _detailSeedVideo = option.video;
      _video = _sanitizeInitialVideo(option.site, option.video);
      _selectedLine = 0;
      _manualLineSelection = null;
      _selectedPage = 0;
      _selectedInLineSeason = null;
      _browsingEpisode = null;
      _confirmedPlayback = null;
      if (_isIosDetail) {
        _descending = false;
      }
      _windowsEpisodeQuery = '';
      _windowsEpisodeQueryCtrl.clear();
      _externalSynopsis = '';
      _loadScrapeOverride();
      _seedCachedExternalFields();
      _isFavorite = widget.storage.isFavorite(
        _activeSite.key,
        _video.id,
        forPrivate: _activeSite.isEffectivelyPrivate,
      );
    });
    final isPrivPoster = _isPrivatePosterContext;
    final immediateBytes = PosterLoader.peekMemory(
      _effectivePosterUrl,
      title: isPrivPoster ? '' : _publicLookupTitle,
      year: isPrivPoster ? '' : _video.year,
      preferHd: !isPrivPoster,
      isPrivate: isPrivPoster,
    );
    _loadedPosterBytes = immediateBytes;
    _loadedPosterIdentity =
        immediateBytes != null ? _currentPosterIdentity : '';
    if (immediateBytes != null) {
      final cachedColor = PosterLoader.peekAmbientColor(immediateBytes);
      if (cachedColor != null) {
        _posterAmbientColor = cachedColor;
      } else {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
    _loadDetail();
    _warmRatings(_video.title, year: _video.year);
    if (!_loading) {
      _warmExternalMetadata(_video.title);
    }
  }

  String _currentSeasonLabel([CmsLine? activeLine]) {
    if (activeLine != null) {
      if (_isMultiVersionMovieLine(activeLine)) {
        return '片源版本';
      }
      final inLine = CmsParser.extractInLineSeasons(activeLine.episodes);
      if (inLine.length >= 2) {
        final activeNum = _selectedInLineSeason ?? inLine.first.seasonNumber;
        final matched = inLine.where((s) => s.seasonNumber == activeNum);
        if (matched.isNotEmpty) {
          return matched.first.seasonLabel;
        }
        return inLine.first.seasonLabel;
      }
    }
    return CmsParser.parseSeriesSeasonInfo(_video.title).seasonLabel;
  }

  WatchHistoryEntry? _findBookmark([CmsVideo? currentVideo]) {
    if (_activeSite.isEffectivelyPrivate) return null;
    final video = currentVideo ?? _video;
    for (final item in widget.storage.getWatchHistory()) {
      if (item.site == _activeSite.key && item.id == video.id) {
        final bookmark = WoggSource.normalizeCachedBookmark(_activeSite, video, item);
        if (WoggSource.supports(_activeSite) &&
            WoggSource.resolveCachedBookmarkTarget(_activeSite, video, bookmark) == null) return null;
        return bookmark;
      }
    }
    return null;
  }

  Color _resolveBaseAmbientColor() {
    if (_posterAmbientColor != null) return _posterAmbientColor!;
    const fallbackPalettes = <Color>[
      Color(0xFF1F1610),
      Color(0xFF211518),
      Color(0xFF131A26),
      Color(0xFF1B1511),
      Color(0xFF111D1B),
      Color(0xFF1C1321),
    ];
    final key = '${_video.title}_${_video.id}';
    int hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return fallbackPalettes[hash % fallbackPalettes.length];
  }

  String _effectiveSeriesSynopsis() {
    final raw = _video.description.trim();
    if (_activeSite.isEffectivelyPrivate) return raw;
    final boundSyn = _scrapeOverride?.synopsis.trim() ?? '';
    if (boundSyn.isNotEmpty) return boundSyn;
    final ext = _externalSynopsis.trim().isNotEmpty
        ? _externalSynopsis.trim()
        : PosterLoader.peekSeriesSynopsis(
            _effectiveLookupTitle,
            year: _effectiveLookupYear,
            wantMotionComic: _effectiveWantMotionComic,
          ).trim();
    // Always preserve the CMS's own authentic description unless it is empty
    // or a generic placeholder slogan (e.g. "正式启动！", "敬请期待", "暂无简介").
    final isPlaceholderSlogan = raw.length < 14 ||
        raw.contains('正式启动') ||
        raw.contains('敬请期待') ||
        raw.contains('即将开播') ||
        raw.contains('暂无简介') ||
        raw.contains('暂缺');
    if (!isPlaceholderSlogan) {
      return raw;
    }
    if (ext.isNotEmpty && ext.length > raw.length) {
      return ext;
    }
    return raw;
  }

  (String, String?) _parseEpisodeDisplay(String rawName, int oneBasedIndex) {
    final trimmed = rawName.trim();
    String? sizeOrSpec;
    var cleaned = trimmed;
    final sizeMatch =
        RegExp(r'\[(\d+(?:\.\d+)?\s*[GM]B)\]', caseSensitive: false)
            .firstMatch(cleaned);
    if (sizeMatch != null) {
      sizeOrSpec = sizeMatch.group(1)!.toUpperCase();
      cleaned = cleaned.replaceFirst(sizeMatch.group(0)!, '').trim();
    } else if (cleaned.toUpperCase().contains('4K') ||
        cleaned.toUpperCase().contains('2160P')) {
      sizeOrSpec = '4K';
    } else if (cleaned.toUpperCase().contains('1080P')) {
      sizeOrSpec = '1080P';
    }
    cleaned = cleaned
        .replaceAll(
          RegExp(r'\.(mkv|mp4|ts|flv|avi|m3u8)$', caseSensitive: false),
          '',
        )
        .trim();
    if (cleaned.isEmpty) {
      cleaned = '第$oneBasedIndex集';
    }
    return (cleaned, sizeOrSpec);
  }

  /// Extracts any meaningful episode subtitle embedded in [cleanEpName].
  String _extractEmbeddedSubtitle(String cleanEpName) {
    final stripped = cleanEpName
        .replaceAll(
          RegExp(
            r'^(?:[Ee][Pp]?\s*0*\d+|第\s*0*\d+\s*[集话期章节回]|0*\d+)\s*[·:：\-_]*\s*',
          ),
          '',
        )
        .trim();
    if (stripped.isNotEmpty &&
        !RegExp(r'^(?:[Ee][Pp]?\s*)?\d+$').hasMatch(stripped)) {
      return stripped;
    }
    return '';
  }

  /// Builds a clean, authentic episode card headline:
  /// 1. For variety shows (`综艺`), preserves the real issue/date/guest name (e.g. `20261105期`, `先导片`)
  /// 2. Uses real subtitle from CMS episode name if present
  /// 3. Uses real episode title from verified 360 Baike / Bilibili PGC / Bangumi if present
  /// 4. Falls back cleanly to `第 X 集` / `第 X 期` (never fabricated text)
  String _formatEpisodeCardHeadline(
    String cleanEpName,
    int oneBasedIndex, {
    ScrapedEpisodeInfo? scrapedInfo,
  }) {
    if (scrapedInfo != null && scrapedInfo.isSpecial) {
      final tag = scrapedInfo.specialTag ?? '特辑';
      if (scrapedInfo.cleanSubtitle.isNotEmpty &&
          scrapedInfo.cleanSubtitle != tag) {
        return '$tag · ${scrapedInfo.cleanSubtitle}';
      }
      return cleanEpName.trim().isNotEmpty ? cleanEpName.trim() : tag;
    }
    final epNum = scrapedInfo?.effectiveEpisodeNumber ?? oneBasedIndex;
    if (_isVarietyShow) {
      final trimmed = cleanEpName.trim();
      if (trimmed.isNotEmpty &&
          !RegExp(r'^(?:[Ee][Pp]?\s*)?\d+$').hasMatch(trimmed)) {
        return trimmed;
      }
      return '第 $epNum 期';
    }
    final embedded = _extractEmbeddedSubtitle(cleanEpName);
    if (embedded.isNotEmpty) {
      return 'E$epNum · $embedded';
    }
    final realMeta = PosterLoader.peekEpisodeMeta(_effectiveScrapeTitle, epNum);
    if (realMeta != null && realMeta.title.trim().isNotEmpty) {
      return 'E$epNum · ${realMeta.title.trim()}';
    }
    if (scrapedInfo != null && scrapedInfo.cleanSubtitle.isNotEmpty) {
      return 'E$epNum · ${scrapedInfo.cleanSubtitle}';
    }
    return '第 $epNum 集';
  }

  /// Resolves the authentic per-episode plot synopsis (`分集剧情`).
  /// Returns an empty string if no real per-episode plot exists yet so we NEVER
  /// display fake/repeated series slogans or mismatched plots under episode cards.
  String _resolveAuthenticEpisodeSummary(
    int oneBasedIndex,
    String cleanEpName, {
    ScrapedEpisodeInfo? scrapedInfo,
  }) {
    if (scrapedInfo != null && scrapedInfo.isSpecial) {
      return '';
    }
    final epNum = scrapedInfo?.effectiveEpisodeNumber ?? oneBasedIndex;
    if (_isVarietyShow) {
      final embedded = _extractEmbeddedSubtitle(cleanEpName);
      if (embedded.length >= 16 && embedded != cleanEpName.trim()) {
        return embedded;
      }
      return '';
    }
    final realMeta = PosterLoader.peekEpisodeMeta(_effectiveScrapeTitle, epNum);
    if (realMeta != null && realMeta.summary.trim().isNotEmpty) {
      return realMeta.summary.trim();
    }
    final embedded = _extractEmbeddedSubtitle(cleanEpName);
    if (embedded.length >= 14) {
      return embedded;
    }
    return '';
  }

  String _formatBookmarkTime(int ms) {
    final totalSec = ms <= 0 ? 0 : ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _handlePlayerPlaybackConfirmed(PlayerPlaybackConfirmation info) {
    if (!mounted) return;
    if (info.siteKey != _activeSite.key || info.videoId != _video.id) return;
    setState(() {
      _confirmedPlayback = info;
      _browsingEpisode = null;
    });
  }

  /// Strictly resolves the unique line index in [lines] that matches an episode
  /// record. Prefers stable [lineId], then exact [episodeUrl], and only falls
  /// back to [lineName] when that label is unique across [lines]. Returns `null`
  /// when ambiguous or missing (never guesses across duplicate-named lines).
  int? _matchLineIndexStrict(
    List<CmsLine> lines, {
    required String lineId,
    required String lineName,
    required String episodeUrl,
    required String episodeName,
  }) {
    if (lines.isEmpty) return null;
    final cleanId = lineId.trim();
    final cleanUrl = episodeUrl.trim();
    final cleanName = lineName.trim();

    if (cleanId.isNotEmpty) {
      final idMatches = <int>[
        for (int i = 0; i < lines.length; i++)
          if (lines[i].id.trim() == cleanId) i,
      ];
      if (idMatches.length == 1) return idMatches.first;
      if (idMatches.length > 1 && cleanUrl.isNotEmpty) {
        final narrowed = idMatches
            .where((i) => lines[i].episodes.any((e) =>
                WatchHistoryEntry.matchesEpisodeUrl(cleanUrl, e.url)))
            .toList();
        if (narrowed.length == 1) return narrowed.first;
      }
      return null;
    }

    if (cleanUrl.isNotEmpty) {
      final urlMatches = <int>[
        for (int i = 0; i < lines.length; i++)
          if ((cleanName.isEmpty || lines[i].name.trim() == cleanName) &&
              lines[i].episodes.any((e) =>
                  WatchHistoryEntry.matchesEpisodeUrl(cleanUrl, e.url)))
            i,
      ];
      if (urlMatches.length == 1) return urlMatches.first;
      return null;
    }

    if (cleanName.isEmpty) return null;
    final nameMatches = <int>[
      for (int i = 0; i < lines.length; i++)
        if (lines[i].name.trim() == cleanName) i,
    ];
    // Legacy bookmark without lineId/episodeUrl: ONLY unambiguous if the line
    // name itself is unique within this video. Duplicate-named lines cannot be
    // disambiguated safely, so return null instead of guessing.
    if (nameMatches.length == 1) return nameMatches.first;
    return null;
  }

  /// Strictly resolves an episode raw index within [line] without guessing:
  /// - When [episodeUrl] is present, matches ONLY by exact URL (if the played
  ///   file was deleted on refresh, NEVER falls back to another file with the
  ///   same display name!).
  /// - When [episodeUrl] is absent (legacy bookmark), matches by [episodeName]
  ///   ONLY if that name is unique within [line].
  /// - Never guesses from a bare index when identity is missing or ambiguous.
  int? _matchEpisodeIndexStrict(
    CmsLine line,
    Set<int> activeSet, {
    required String episodeUrl,
    required String episodeName,
    int? preferredIndex,
  }) {
    final cleanUrl = episodeUrl.trim();
    final cleanName = episodeName.trim();

    if (cleanUrl.isNotEmpty) {
      final urlMatches = <int>[
        for (int i = 0; i < line.episodes.length; i++)
          if (WatchHistoryEntry.matchesEpisodeUrl(cleanUrl, line.episodes[i].url)) i,
      ];
      if (urlMatches.isEmpty) return null;
      if (urlMatches.length == 1) {
        return activeSet.contains(urlMatches.first) ? urlMatches.first : null;
      }
      if (preferredIndex != null &&
          urlMatches.contains(preferredIndex) &&
          activeSet.contains(preferredIndex) &&
          (cleanName.isEmpty ||
              line.episodes[preferredIndex].name.trim() == cleanName)) {
        return preferredIndex;
      }
      if (cleanName.isNotEmpty) {
        final narrowed = urlMatches
            .where((i) => line.episodes[i].name.trim() == cleanName)
            .toList();
        if (narrowed.length == 1 && activeSet.contains(narrowed.first)) {
          return narrowed.first;
        }
      }
      return null;
    }

    if (cleanName.isNotEmpty) {
      final nameMatches = <int>[
        for (int i = 0; i < line.episodes.length; i++)
          if (line.episodes[i].name.trim() == cleanName) i,
      ];
      if (nameMatches.length == 1 && activeSet.contains(nameMatches.first)) {
        return nameMatches.first;
      }
      return null;
    }

    return null;
  }

  /// Resolves the confirmed actually-playing episode raw index within [line],
  /// matching strictly by stable line + file identity without guessing across
  /// duplicate-named lines or duplicate-named files.
  int? _resolvePlayedEpisodeIndexForLine(
    CmsLine line,
    int lineIdx,
    List<int> activeIndices,
    WatchHistoryEntry? bookmark, {
    CmsVideo? video,
  }) {
    final targetVideo = video ?? _video;
    final lines = targetVideo.lines;
    final activeSet = activeIndices.toSet();

    // 1. Prefer live confirmed playback from PlayerScreen in this Detail session
    final confirmed = _confirmedPlayback;
    if (confirmed != null &&
        confirmed.siteKey == _activeSite.key &&
        confirmed.videoId == _video.id) {
      final matchedLine = _matchLineIndexStrict(
        lines,
        lineId: confirmed.lineId,
        lineName: confirmed.lineName,
        episodeUrl: confirmed.episodeUrl,
        episodeName: confirmed.episodeName,
      );
      if (matchedLine != lineIdx) return null;
      return _matchEpisodeIndexStrict(
        line,
        activeSet,
        episodeUrl: confirmed.episodeUrl,
        episodeName: confirmed.episodeName,
        preferredIndex: confirmed.episodeIndex,
      );
    }

    // 2. Otherwise match persisted WatchHistory bookmark strictly by identity
    if (bookmark == null) return null;
    final target = _iosBookmarkTarget(targetVideo, bookmark);
    return target != null && target.$1 == lineIdx && activeSet.contains(target.$2)
        ? target.$2
        : null;
  }

  (int, int)? _iosBookmarkTarget(CmsVideo video, WatchHistoryEntry bookmark) =>
      WoggSource.supports(_activeSite)
          ? WoggSource.resolveCachedBookmarkTarget(_activeSite, video, bookmark)
          : resolveIosWatchHistoryTarget(video, bookmark);

  /// Resolves the season, pagination page, and page-local slot for the played
  /// episode on [lines[lineIdx]] so initial load / resume / sort toggle brings
  /// the exact circle and card into viewport automatically.
  ({int? inLineSeason, int page, int slotInPage, int rawIdx})?
      _resolveSeasonPageAndSlotForPlayedEpisode({
    required CmsVideo video,
    required int lineIdx,
    required WatchHistoryEntry? bookmark,
    bool? descendingOverride,
  }) {
    if (lineIdx < 0 || lineIdx >= video.lines.length) return null;
    final line = video.lines[lineIdx];
    final descending = descendingOverride ?? _descending;
    final inLineSeasons = CmsParser.extractInLineSeasons(line.episodes);
    final playedRawIdx = _resolvePlayedEpisodeIndexForLine(
      line,
      lineIdx,
      List.generate(line.episodes.length, (i) => i),
      bookmark,
      video: video,
    );
    if (playedRawIdx == null) return null;
    final resolvedSeason = inLineSeasons
        .where((season) => season.episodeIndexes.contains(playedRawIdx))
        .firstOrNull?.seasonNumber;
    final activeIndices = _activeEpisodeIndicesFor(line, seasonNumber: resolvedSeason);
    final posInActive = activeIndices.indexOf(playedRawIdx);
    if (posInActive < 0) return null;
    final total = activeIndices.length;
    final visualIdx = descending ? (total - 1 - posInActive) : posInActive;
    return (
      inLineSeason: resolvedSeason,
      page: visualIdx ~/ CmsParser.episodePageSize,
      slotInPage: visualIdx % CmsParser.episodePageSize,
      rawIdx: playedRawIdx,
    );
  }

  /// Resolves the temporary browsing episode raw index within [line] by
  /// strict line + episode identity.
  int? _resolveBrowsingEpisodeIndexForLine(
    CmsLine line,
    int lineIdx,
    List<int> activeIndices,
  ) {
    final b = _browsingEpisode;
    if (b == null) return null;
    final matchedLine = _matchLineIndexStrict(
      _video.lines,
      lineId: b.lineId,
      lineName: b.lineName,
      episodeUrl: b.episodeUrl,
      episodeName: b.episodeName,
    );
    if (matchedLine != lineIdx) return null;
    return _matchEpisodeIndexStrict(
      line,
      activeIndices.toSet(),
      episodeUrl: b.episodeUrl,
      episodeName: b.episodeName,
      preferredIndex: b.originalIndex,
    );
  }

  /// Scrolls ONLY the horizontal episode cards strip so the card at page-local
  /// [slotIdx] is cleanly visible, without triggering playback or vertical scroll.
  void _scrollEpisodeCardsToSlot(int slotIdx, {bool animate = true}) {
    if (!_previewCardsScrollController.hasClients) return;
    final pos = _previewCardsScrollController.position;
    final desired = (slotIdx * _kEpisodeCardStride)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((pos.pixels - desired).abs() < 1.0) return;
    _programmaticCardScrollGuard++;
    if (!animate) {
      _previewCardsScrollController.jumpTo(desired);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_programmaticCardScrollGuard > 0) _programmaticCardScrollGuard--;
      });
      return;
    }
    unawaited(
      _previewCardsScrollController
          .animateTo(
            desired,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
        if (_programmaticCardScrollGuard > 0) _programmaticCardScrollGuard--;
      }),
    );
  }

  /// Computes the exact horizontal offset inside `_quickEpisodesScrollController`
  /// to center [slotIdx] WITHOUT ever calling `Scrollable.ensureVisible` (which
  /// could scroll ancestor vertical scroll views).
  double? _exactHorizontalCircleOffset(int slotIdx) {
    if (!_quickEpisodesScrollController.hasClients) return null;
    final ctx = _circleSlotKeys[slotIdx]?.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    final ro = ctx.findRenderObject();
    if (ro == null || !ro.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return null;
    final pos = _quickEpisodesScrollController.position;
    return viewport
        .getOffsetToReveal(ro, 0.5)
        .offset
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
  }

  /// Ensures the top circle at page-local [slotIdx] is centered inside the
  /// horizontal quick-episode strip ONLY (never moving the outer vertical page).
  void _ensureEpisodeCircleSlotVisible(int slotIdx, {bool animate = true}) {
    if (!_quickEpisodesScrollController.hasClients) return;
    final pos = _quickEpisodesScrollController.position;
    final exact = _exactHorizontalCircleOffset(slotIdx);
    if (exact != null) {
      if ((pos.pixels - exact).abs() < 1.0) return;
      if (animate) {
        unawaited(
          _quickEpisodesScrollController.animateTo(
            exact,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _quickEpisodesScrollController.jumpTo(exact);
      }
      return;
    }
    final approx = (slotIdx * _kEpisodeCircleApproxStride -
            pos.viewportDimension * 0.45)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (animate) {
      unawaited(
        _quickEpisodesScrollController
            .animateTo(
              approx,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
          if (!mounted || !_quickEpisodesScrollController.hasClients) return;
          final refined = _exactHorizontalCircleOffset(slotIdx);
          if (refined != null &&
              (_quickEpisodesScrollController.position.pixels - refined).abs() >=
                  1.0) {
            unawaited(
              _quickEpisodesScrollController.animateTo(
                refined,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
              ),
            );
          }
        }),
      );
    } else {
      _quickEpisodesScrollController.jumpTo(approx);
      // After jumping to approximate offset and building the target circle,
      // refine horizontally to pixel-exact center in the very next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_quickEpisodesScrollController.hasClients) return;
        final refined = _exactHorizontalCircleOffset(slotIdx);
        if (refined != null &&
            (_quickEpisodesScrollController.position.pixels - refined).abs() >=
                1.0) {
          _quickEpisodesScrollController.jumpTo(refined);
        }
      });
    }
  }

  void _scheduleAlignEpisodeStripsToSlot(int slotInPage, {bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_quickEpisodesScrollController.hasClients ||
          !_previewCardsScrollController.hasClients) {
        // Retry once more after layout completes (e.g. first build after loading).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _ensureEpisodeCircleSlotVisible(slotInPage, animate: animate);
          _scrollEpisodeCardsToSlot(slotInPage, animate: animate);
        });
        return;
      }
      _ensureEpisodeCircleSlotVisible(slotInPage, animate: animate);
      _scrollEpisodeCardsToSlot(slotInPage, animate: animate);
    });
  }

  /// Called when the horizontal episode-cards strip finishes scrolling by user
  /// gesture: maps the primarily visible card back to its actual episode and
  /// ensures the matching top number circle stays visible.
  void _handleEpisodeCardsScrollSettled({
    required CmsLine line,
    required List<int> activeIndices,
    required int pageStart,
    required int pageLen,
  }) {
    if (!mounted ||
        !_isIosDetail ||
        _programmaticCardScrollGuard > 0 ||
        pageLen <= 0 ||
        !_previewCardsScrollController.hasClients) {
      return;
    }
    _pendingPostPopSync = false;
    final pos = _previewCardsScrollController.position;
    final int slotIdx;
    if (pos.pixels <= pos.minScrollExtent + 12.0) {
      slotIdx = 0;
    } else if (pos.maxScrollExtent - pos.pixels <= 12.0) {
      slotIdx = pageLen - 1;
    } else {
      slotIdx = ((pos.pixels + pos.viewportDimension * 0.25) /
              _kEpisodeCardStride)
          .floor()
          .clamp(0, pageLen - 1);
    }
    final total = activeIndices.length;
    final visualIdx = pageStart + slotIdx;
    if (visualIdx < 0 || visualIdx >= total) return;
    final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
    final originalIdx = activeIndices[posIdx];
    final ep = line.episodes[originalIdx];
    final nextBrowsing = (
      lineId: line.id,
      lineName: line.name,
      episodeUrl: ep.url,
      episodeName: ep.name,
      originalIndex: originalIdx,
    );
    if (_browsingEpisode?.episodeUrl != nextBrowsing.episodeUrl ||
        _browsingEpisode?.episodeName != nextBrowsing.episodeName ||
        _browsingEpisode?.lineName != nextBrowsing.lineName) {
      // Update only the localized episode circle / card border listeners without
      // triggering a full DetailScreen rebuild during horizontal scrolling.
      _browsingEpisode = nextBrowsing;
    }
    _ensureEpisodeCircleSlotVisible(slotIdx);
  }

  /// Synchronizes Detail page's active line, pagination range (including
  /// 50/51 & 100/101 boundaries), and two-row scroll visibility to the newly
  /// confirmed playing episode after returning from Player — while preserving
  /// the page's temporary [_descending] sort order.
  /// Returns `true` if a confirmed or bookmark change was applied.
  bool _syncAfterPlayerReturn({
    required WatchHistoryEntry? bookmarkBefore,
    required PlayerPlaybackConfirmation? confirmedBefore,
  }) {
    if (!mounted || _video.lines.isEmpty) return false;
    final bookmarkAfter = _findBookmark();
    final confirmedAfter = _confirmedPlayback;
    final confirmedChanged = confirmedAfter != null &&
        (confirmedBefore == null ||
            confirmedAfter.lineName != confirmedBefore.lineName ||
            confirmedAfter.episodeUrl != confirmedBefore.episodeUrl ||
            confirmedAfter.episodeName != confirmedBefore.episodeName ||
            confirmedAfter.episodeIndex != confirmedBefore.episodeIndex);
    final bookmarkChanged = bookmarkAfter != null &&
        (bookmarkBefore == null ||
            bookmarkAfter.line != bookmarkBefore.line ||
            bookmarkAfter.episode != bookmarkBefore.episode ||
            bookmarkAfter.index != bookmarkBefore.index ||
            bookmarkAfter.updated != bookmarkBefore.updated);

    if (!confirmedChanged && !bookmarkChanged) {
      // Playback failed or exited without starting -> preserve existing playing
      // marker, temporary sort, and browsing scroll untouched.
      setState(() {});
      return false;
    }
    if (bookmarkChanged && !confirmedChanged) {
      _confirmedPlayback = null;
    }

    // If playback happened on another line, switch to that line strictly by identity.
    var targetLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final effectiveConfirmed = _confirmedPlayback;
    final playedLineName =
        effectiveConfirmed?.lineName ?? bookmarkAfter?.line ?? '';
    final playedLineId =
        effectiveConfirmed?.lineId ?? bookmarkAfter?.lineId ?? '';
    final playedEpUrl =
        effectiveConfirmed?.episodeUrl ?? bookmarkAfter?.effectiveMediaId ?? '';
    final playedEpName =
        effectiveConfirmed?.episodeName ?? bookmarkAfter?.episode ?? '';
    if (playedLineId.trim().isNotEmpty ||
        playedEpUrl.trim().isNotEmpty ||
        playedLineName.trim().isNotEmpty) {
      final matchedLine = _matchLineIndexStrict(
        _video.lines,
        lineId: playedLineId,
        lineName: playedLineName,
        episodeUrl: playedEpUrl,
        episodeName: playedEpName,
      );
      if (matchedLine != null) {
        targetLineIdx = matchedLine;
      }
    }
    final line = _video.lines[targetLineIdx];
    var targetInLineSeason = _selectedInLineSeason;
    var activeIndices = _activeEpisodeIndicesFor(line);
    var playedRawIdx = _resolvePlayedEpisodeIndexForLine(
      line,
      targetLineIdx,
      activeIndices,
      bookmarkAfter,
    );
    if (playedRawIdx == null) {
      final inLineSeasons = CmsParser.extractInLineSeasons(line.episodes);
      if (inLineSeasons.length >= 2) {
        for (final season in inLineSeasons) {
          final candidate = _resolvePlayedEpisodeIndexForLine(
            line,
            targetLineIdx,
            season.episodeIndexes,
            bookmarkAfter,
          );
          if (candidate != null) {
            targetInLineSeason = season.seasonNumber;
            activeIndices = _activeEpisodeIndicesFor(
              line,
              seasonNumber: season.seasonNumber,
            );
            playedRawIdx = candidate;
            break;
          }
        }
      }
    }
    if (playedRawIdx == null) {
      setState(() {});
      return false;
    }

    final posInActive = activeIndices.indexOf(playedRawIdx);
    if (posInActive < 0) {
      setState(() {});
      return false;
    }
    final total = activeIndices.length;
    final visualIdx = _descending ? (total - 1 - posInActive) : posInActive;
    final targetPage = visualIdx ~/ CmsParser.episodePageSize;
    final slotInPage = visualIdx % CmsParser.episodePageSize;
    final playedEp = line.episodes[playedRawIdx];

    setState(() {
      _selectedLine = targetLineIdx;
      _selectedInLineSeason = targetInLineSeason;
      _selectedPage = targetPage;
      _browsingEpisode = (
        lineId: line.id,
        lineName: line.name,
        episodeUrl: playedEp.url,
        episodeName: playedEp.name,
        originalIndex: playedRawIdx!,
      );
    });
    _scheduleAlignEpisodeStripsToSlot(slotInPage, animate: false);
    return true;
  }

  Future<void> _openPlayerForOffer(
    AggregatedEpisodeOffer offer, {
    int? resumeMs,
  }) =>
      _openPlayer(
        offer.lineIndex,
        offer.episodeIndex,
        resumeMs: resumeMs,
        siteOverride: offer.source.site,
        videoOverride: offer.video,
      );

  Future<void> _openPlayer(
    int lineIdx,
    int epIdx, {
    int? resumeMs,
    CmsSite? siteOverride,
    CmsVideo? videoOverride,
  }) async {
    final targetSite = siteOverride ?? _activeSite;
    final targetVideo = videoOverride ?? _video;
    if ((videoOverride == null && _loading) || targetVideo.lines.isEmpty) return;
    final bookmarkBeforeOpen = _findBookmark();
    final confirmedBeforeOpen = _confirmedPlayback;
    final safeLine = lineIdx.clamp(0, targetVideo.lines.length - 1);
    final line = targetVideo.lines[safeLine];
    if (line.episodes.isEmpty) return;
    final safeEp = epIdx.clamp(0, line.episodes.length - 1);
    final targetEp = line.episodes[safeEp];
    final blockReason = _episodeUnavailableReason(
      targetEp,
      siteOverride: targetSite,
    );
    if (blockReason != null) {
      _toast(blockReason);
      return;
    }
    final provider = targetEp.cloudProvider;
    if (provider != null && provider != 'uc' &&
        !widget.storage.isNetdiskLoggedIn(provider)) {
      await showNetdiskAccountSheet(
        context,
        widget.storage,
        initialDriveKey: provider,
      );
      if (!mounted || !widget.storage.isNetdiskLoggedIn(provider)) return;
      if (siteOverride == null &&
          (!identical(_activeSite, targetSite) ||
              !identical(_video, targetVideo))) {
        _toast('剧集信息已更新，请重新选择要播放的文件');
        return;
      }
    }
    int effectiveResumeMs = resumeMs ?? 0;
    if (resumeMs == null) {
      final bm = _findBookmark(targetVideo);
      if (bm != null) {
        final ep = line.episodes[safeEp];
        final target = WoggSource.supports(targetSite)
            ? WoggSource.resolveCachedBookmarkTarget(targetSite, targetVideo, bm)
            : null;
        final matches = WoggSource.supports(targetSite)
            ? target?.$1 == safeLine && target?.$2 == safeEp
            : (_isIosDetail
                ? _resolvePlayedEpisodeIndexForLine(
                      line,
                      safeLine,
                      List<int>.generate(line.episodes.length, (i) => i),
                      bm,
                    ) ==
                    safeEp
                : (bm.line == line.name && bm.index == safeEp) ||
                    bm.episode == ep.name);
        if (matches) {
          effectiveResumeMs = bm.resumePosition;
        }
      }
    }
    if (!mounted) return;
    final altSources = List<WorkSourceRef>.unmodifiable(_aggregatedSources);
    final preloaded = Map<String, CmsVideo>.unmodifiable(
      _preloadedSourceVideoMap(),
    );
    Widget buildPlayer(BuildContext routeCtx) {
      final debugWithConfirm = widget.debugPlayerWithConfirmationBuilder;
      if (debugWithConfirm != null) {
        return debugWithConfirm(
          routeCtx,
          targetSite,
          targetVideo,
          safeLine,
          safeEp,
          effectiveResumeMs,
          _handlePlayerPlaybackConfirmed,
        );
      }
      final debugBuilder = widget.debugPlayerBuilder;
      if (debugBuilder != null) {
        return debugBuilder(
          routeCtx,
          targetSite,
          targetVideo,
          safeLine,
          safeEp,
          effectiveResumeMs,
        );
      }
      return PlayerScreen(
        site: targetSite,
        video: targetVideo,
        initialLineIndex: safeLine,
        initialEpisodeIndex: safeEp,
        initialPositionMs: effectiveResumeMs,
        storage: widget.storage,
        onPlaybackConfirmed: _handlePlayerPlaybackConfirmed,
        client: widget.client,
        alternativeSources: altSources,
        preloadedSourceDetails: preloaded,
      );
    }

    if (OhosRuntime.isOhos) {
      await Navigator.of(context).push(
        buildApplePageRoute<void>(builder: buildPlayer),
      );
    } else {
      final hasWindowsAppearance =
          isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null;
      final hasIndependentPosterCard =
          hasWindowsAppearance ||
          AppleViewportLayout.of(context).prefersWideDetail;
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final activeProgram = widget.debugTransitionShaderProgram ??
          PlayerEnterTransition.cachedProgram;

      ui.Image? transitionPoster;
      bool posterTransferred = false;
      try {
        if (hasIndependentPosterCard &&
            !isWindowsDesktopUi &&
            !reduceMotion &&
            activeProgram != null &&
            !PlayerEnterTransition.preferFastTransition &&
            !PlayerEnterTransition.shaderLoadFailed) {
          transitionPoster = await _obtainTransitionPosterImage();
          if (!mounted) return;
        }
        final GlobalKey? activePosterKey =
            hasIndependentPosterCard ? _transitionPosterKey : null;
        final ui.Image? passedPoster =
            activePosterKey != null ? transitionPoster : null;
        final bool passedOwnsPoster = passedPoster != null;
        if (passedOwnsPoster) {
          posterTransferred = true;
        }
        await pushPlayerRoute<void>(
          context: context,
          backdropBoundaryKey: _transitionBackdropKey,
          posterKey: activePosterKey,
          posterRadiusLogical: isWindowsDesktopUi ? 16.0 : 18.0,
          posterImage: passedPoster,
          ownsPoster: passedOwnsPoster,
          useFastWindowsMode: isWindowsDesktopUi,
          debugCapturer: widget.debugTransitionCapturer,
          debugShaderProgram: widget.debugTransitionShaderProgram,
          onModeResolved: widget.debugOnTransitionModeResolved,
          builder: buildPlayer,
        );
      } finally {
        if (!posterTransferred && transitionPoster != null) {
          transitionPoster.dispose();
        }
      }
    }
    if (mounted) {
      if (_isIosDetail) {
        _bookmarkBeforeLastPlayer = bookmarkBeforeOpen;
        _confirmedBeforeLastPlayer = confirmedBeforeOpen;
        _syncAfterPlayerReturn(
          bookmarkBefore: bookmarkBeforeOpen,
          confirmedBefore: confirmedBeforeOpen,
        );
        // Keep post-pop sync active for a deferred PlayerScreen.dispose() flush
        // (e.g. interactive swipe-back after auto-next); cleared on next manual tap/scroll.
        _bookmarkBeforeLastPlayer = _findBookmark();
        _confirmedBeforeLastPlayer = _confirmedPlayback;
        _pendingPostPopSync = true;
      } else {
        setState(() {});
      }
    }
  }

  List<int> _activeEpisodeIndicesFor(CmsLine line, {int? seasonNumber}) {
    if (_isIosDetail) {
      final scraped = _scrapeLine(line);
      final inLine = CmsParser.extractInLineSeasons(line.episodes);
      if (inLine.length >= 2) {
        final activeNum =
            seasonNumber ?? _selectedInLineSeason ?? inLine.first.seasonNumber;
        List<int> seasonIndices = inLine.first.episodeIndexes;
        for (final s in inLine) {
          if (s.seasonNumber == activeNum) {
            seasonIndices = s.episodeIndexes;
            break;
          }
        }
        final seasonSet = seasonIndices.toSet();
        final filtered = [
          for (final idx in scraped.visibleRawIndices)
            if (seasonSet.contains(idx)) idx,
        ];
        return filtered.isNotEmpty ? filtered : seasonIndices;
      }
      return scraped.visibleRawIndices;
    }
    final scrape = _scrapeResultForLine(line);
    final sortByScraped =
        _scrapeOverride?.sortByScrapedEpisode ?? scrape.sourceOrderScrambled;
    final hideSpecials = _scrapeOverride?.hideSpecials ?? false;
    final inLine = CmsParser.extractInLineSeasons(line.episodes);
    if (inLine.length >= 2) {
      final activeNum =
          seasonNumber ?? _selectedInLineSeason ?? inLine.first.seasonNumber;
      List<int> base = inLine.first.episodeIndexes;
      for (final s in inLine) {
        if (s.seasonNumber == activeNum) {
          base = s.episodeIndexes;
          break;
        }
      }
      var list = hideSpecials
          ? base.where((i) => !scrape.byOriginalIndex[i].isSpecial).toList()
          : List<int>.from(base);
      if (list.isEmpty) list = List<int>.from(base);
      if (sortByScraped) {
        list.sort((a, b) {
          final ea = scrape.byOriginalIndex[a];
          final eb = scrape.byOriginalIndex[b];
          if (ea.isSpecial != eb.isSpecial) return ea.isSpecial ? 1 : -1;
          final na = ea.resolvedEpisodeNumber;
          final nb = eb.resolvedEpisodeNumber;
          if (na != null && nb != null && na != nb) return na.compareTo(nb);
          return a.compareTo(b);
        });
      }
      return list;
    }
    return scrape.orderedIndices(
      sortByScraped: sortByScraped,
      hideSpecials: hideSpecials,
    );
  }

  void _playPrimaryAction(WatchHistoryEntry? bookmark) {
    if (_loading || _video.lines.isEmpty) return;
    final safeSelected = _selectedLine.clamp(0, _video.lines.length - 1);
    if (bookmark != null && (WoggSource.supports(_activeSite) || _isIosDetail)) {
      final target = _iosBookmarkTarget(_video, bookmark);
      if (target == null) {
        _toast('原观看文件或线路已变更，请在下方重新选择剧集');
        return;
      }
      if (target.$1 == safeSelected) {
        _openPlayer(target.$1, target.$2, resumeMs: bookmark.resumePosition);
        return;
      }
      // User explicitly switched to another line: start that line from its first episode.
      final indices = _activeEpisodeIndicesFor(_video.lines[safeSelected]);
      final firstEpIdx = indices.isNotEmpty ? indices.first : 0;
      _openPlayer(safeSelected, firstEpIdx, resumeMs: 0);
      return;
    }
    if (bookmark != null) {
      final lineIdx = _video.lines[safeSelected].name == bookmark.line
          ? safeSelected
          : (() {
              final foundLine =
                  _video.lines.indexWhere((l) => l.name == bookmark.line);
              return (foundLine < 0 ? safeSelected : foundLine)
                  .clamp(0, _video.lines.length - 1);
            })();
      final eps = _video.lines[lineIdx].episodes;
      final byNameIdx = eps.indexWhere((e) => e.name == bookmark.episode);
      final epIdx = (byNameIdx >= 0 ? byNameIdx : bookmark.index).clamp(
        0,
        eps.length - 1,
      );
      _openPlayer(
        lineIdx,
        epIdx,
        resumeMs: bookmark.resumePosition,
      );
    } else {
      final lineIdx = safeSelected;
      final indices = _activeEpisodeIndicesFor(_video.lines[lineIdx]);
      final firstEpIdx = indices.isNotEmpty ? indices.first : 0;
      _openPlayer(lineIdx, firstEpIdx, resumeMs: 0);
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: AppleColors.labelPrimary, fontSize: 14),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xF22C2C2E),
        elevation: 0,
        shape: const StadiumBorder(),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showSeasonPickerSheet() {
    if (_video.lines.isEmpty) return;
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final currentLine = _video.lines[safeLineIdx];
    final inLineSeasons = CmsParser.extractInLineSeasons(currentLine.episodes);
    final hasInLineSeasons = inLineSeasons.length >= 2;
    final activeInLineSeasonNum = hasInLineSeasons
        ? (_selectedInLineSeason ?? inLineSeasons.first.seasonNumber)
        : null;
    final curSeasonInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final totalSeasons = hasInLineSeasons
        ? inLineSeasons.length
        : _relatedSeasons.length;

    showIos27LiquidSheet<void>(
      context: context,
      title: totalSeasons > 1 ? '选择季数（共 $totalSeasons 季）' : '选择季数',
      builder: (ctx) {
        final palette = ApplePalette.of(ctx);
        final isDark = palette.isDark;
        final tileBg = isDark ? const Color(0xFF242429) : Colors.white;
        final tileBorder = isDark
            ? const Color(0x22FFFFFF)
            : Colors.black.withValues(alpha: 0.08);
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.rectangle_stack_fill,
                    color: AppleColors.systemBlue,
                    size: 15,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      totalSeasons > 1
                          ? '连续剧集选季 · 点击切换对应季'
                          : (_discoveringSeasons
                              ? '正在检索同系列其他季…'
                              : '当前仅检索到单季资源'),
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_discoveringSeasons)
                    const CupertinoActivityIndicator(radius: 7)
                  else
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(24, 24),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _discoveredFranchiseKey = '';
                        unawaited(_discoverRelatedSeasons(_video.title));
                        _toast('正在重新检索同系列季数…');
                      },
                      child: const Text(
                        '重新检索',
                        style: TextStyle(
                          color: AppleColors.systemBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (hasInLineSeasons)
              Column(
                children: [
                  for (int idx = 0; idx < inLineSeasons.length; idx++) ...[
                    if (idx > 0) const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final s = inLineSeasons[idx];
                        final isSelected =
                            s.seasonNumber == activeInLineSeasonNum;
                        return Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppleColors.systemBlue.withValues(
                                    alpha: isDark ? 0.24 : 0.12,
                                  )
                                : tileBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? AppleColors.systemBlue.withValues(
                                      alpha: 0.45,
                                    )
                                  : tileBorder,
                              width: 0.65,
                            ),
                          ),
                          child: AppleGroupedTile(
                            icon: CupertinoIcons.tv_fill,
                            iconBgColor: isSelected
                                ? AppleColors.systemBlue
                                : (isDark
                                    ? const Color(0xFF3A3A3F)
                                    : const Color(0xFF8E8E93)),
                            title: s.seasonLabel,
                            subtitle:
                                '共 ${s.episodeIndexes.length} 集 · ${currentLine.name}',
                            trailing: isSelected
                                ? const Icon(
                                    CupertinoIcons.checkmark_alt,
                                    color: AppleColors.systemBlue,
                                    size: 18,
                                  )
                                : Icon(
                                    CupertinoIcons.chevron_right,
                                    color: palette.labelTertiary,
                                    size: 15,
                                  ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _selectedInLineSeason = s.seasonNumber;
                                _selectedPage = 0;
                              });
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ],
              )
            else
              Column(
                children: [
                  for (int idx = 0; idx < _relatedSeasons.length; idx++) ...[
                    if (idx > 0) const SizedBox(height: 8),
                    Builder(
                      builder: (_) {
                        final opt = _relatedSeasons[idx];
                        final isCurrentSeason =
                            (opt.video.id == _video.id &&
                                    opt.site.key == _activeSite.key) ||
                                opt.seasonNumber == curSeasonInfo.seasonNumber;
                        final subParts = <String>[
                          opt.video.title,
                          if (opt.video.remarks.trim().isNotEmpty)
                            opt.video.remarks.trim(),
                          opt.site.name,
                        ];
                        return Container(
                          decoration: BoxDecoration(
                            color: isCurrentSeason
                                ? AppleColors.systemBlue.withValues(
                                    alpha: isDark ? 0.24 : 0.12,
                                  )
                                : tileBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isCurrentSeason
                                  ? AppleColors.systemBlue.withValues(
                                      alpha: 0.45,
                                    )
                                  : tileBorder,
                              width: 0.65,
                            ),
                          ),
                          child: AppleGroupedTile(
                            icon: CupertinoIcons.tv_fill,
                            iconBgColor: isCurrentSeason
                                ? AppleColors.systemBlue
                                : (isDark
                                    ? const Color(0xFF3A3A3F)
                                    : const Color(0xFF8E8E93)),
                            title: opt.seasonLabel,
                            subtitle: subParts.join(' · '),
                            trailing: isCurrentSeason
                                ? const Icon(
                                    CupertinoIcons.checkmark_alt,
                                    color: AppleColors.systemBlue,
                                    size: 18,
                                  )
                                : Icon(
                                    CupertinoIcons.chevron_right,
                                    color: palette.labelTertiary,
                                    size: 15,
                                  ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _switchToRelatedSeason(opt);
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
          ],
        );
      },
    );
  }

  void _showUnifiedEpisodeOffersSheet(
    AggregatedEpisodeSlot slot,
    WatchHistoryEntry? bookmark,
  ) {
    showIos27LiquidSheet<void>(
      context: context,
      title: '${slot.label} · 可用片源 (${slot.offers.length})',
      builder: (ctx) {
        final palette = ApplePalette.of(ctx);
        final isDark = palette.isDark;
        final tileBg = isDark ? const Color(0xFF242429) : Colors.white;
        final tileBorder = isDark
            ? const Color(0x22FFFFFF)
            : Colors.black.withValues(alpha: 0.08);
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            for (var i = 0; i < slot.offers.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              Builder(builder: (_) {
                final offer = slot.offers[i];
                final isCurrentSite = offer.source.site.key == _activeSite.key;
                final reason = _episodeUnavailableReason(
                  offer.episode,
                  siteOverride: offer.source.site,
                );
                final tile = Container(
                  key: ValueKey(
                    'unified-offer-${offer.source.site.key}-${offer.lineIndex}-${offer.episodeIndex}',
                  ),
                  decoration: BoxDecoration(
                    color: isCurrentSite
                        ? AppleColors.systemBlue.withValues(
                            alpha: isDark ? 0.22 : 0.10,
                          )
                        : tileBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isCurrentSite
                          ? AppleColors.systemBlue.withValues(alpha: 0.45)
                          : tileBorder,
                      width: 0.65,
                    ),
                  ),
                  child: AppleGroupedTile(
                    icon: CupertinoIcons.play_circle_fill,
                    iconBgColor: isCurrentSite
                        ? AppleColors.systemBlue
                        : (isDark
                            ? const Color(0xFF3A3A3F)
                            : const Color(0xFF8E8E93)),
                    title: offer.siteAndLineLabel,
                    subtitle: [
                      offer.episode.name,
                      if (isCurrentSite) '当前站点',
                      if (reason != null) reason,
                    ].join(' · '),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _openPlayerForOffer(offer);
                    },
                  ),
                );
                return reason != null ? Opacity(opacity: 0.52, child: tile) : tile;
              }),
            ],
          ],
        );
      },
    );
  }

  void _showSourcePickerSheet() {
    final otherSources = _aggregatedSources
        .where((s) =>
            s.siteIdentityKey !=
            '${_activeSite.subscriptionId}:${_activeSite.key}')
        .toList();
    if (_video.lines.isEmpty && otherSources.isEmpty) {
      if (!_loading) _searchOtherSources();
      return;
    }
    final capturedSiteKey = _activeSite.key;
    final capturedVideoId = _video.id;
    final capturedSiteName = _activeSite.name;
    final capturedLines = List<CmsLine>.of(_video.lines);
    final safeLineIdx = capturedLines.isEmpty
        ? 0
        : _selectedLine.clamp(0, capturedLines.length - 1);

    showIos27LiquidSheet<void>(
      context: context,
      title: otherSources.isNotEmpty
          ? '切换片源 (${otherSources.length + 1} 个站点)'
          : '切换播放源 (${capturedLines.length})',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) {
          final palette = ApplePalette.of(ctx);
          final isDark = palette.isDark;
          final tileBg = isDark ? const Color(0xFF242429) : Colors.white;
          final tileBorder = isDark
              ? const Color(0x22FFFFFF)
              : Colors.black.withValues(alpha: 0.08);
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.layers_alt_fill,
                      color: AppleColors.systemBlue,
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '当前站点：$capturedSiteName · 共 ${capturedLines.length} 条播放线路',
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!_activeSite.isEffectivelyPrivate)
                      GestureDetector(
                        key: const ValueKey(
                          'detail-open-drive-priority-btn',
                        ),
                        onTap: () async {
                          await showPlaybackSourcePrioritySheet(
                            ctx,
                            widget.storage,
                            onChanged: () {
                              if (!mounted) return;
                              if (_manualLineSelection == null &&
                                  _video.lines.isNotEmpty) {
                                setState(() {
                                  _selectedLine =
                                      _pickRecommendedPlayableLineIndex(
                                        _video.lines,
                                      );
                                });
                              }
                            },
                          );
                          if (ctx.mounted) updateSheet(() {});
                        },
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: AppleColors.systemBlue.withValues(
                              alpha: isDark ? 0.20 : 0.10,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.slider_horizontal_3,
                                size: 13,
                                color: AppleColors.systemBlue,
                              ),
                              SizedBox(width: 4),
                              Text(
                                '默认来源与盘序',
                                style: TextStyle(
                                  color: AppleColors.systemBlue,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              for (int i = 0; i < capturedLines.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Builder(
                  builder: (_) {
                    final line = capturedLines[i];
                    final selected = i == safeLineIdx;
                    final lineReason = _lineUnavailableReason(line);
                    final lineSpec = OhosRuntime.isOhos
                        ? ''
                        : MediaBadges.formatDotJoined(
                            _specBadgesForLineOnly(line),
                            maxBadges: 3,
                          );
                    final baseSubtitle = lineReason != null
                        ? '共 ${line.episodes.length} 集 · $lineReason'
                        : '共 ${line.episodes.length} 集 · $capturedSiteName';
                    final tile = Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? AppleColors.systemBlue.withValues(
                                alpha: isDark ? 0.24 : 0.12,
                              )
                            : tileBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? AppleColors.systemBlue.withValues(alpha: 0.45)
                              : tileBorder,
                          width: 0.65,
                        ),
                      ),
                      child: AppleGroupedTile(
                        icon: CupertinoIcons.layers_alt_fill,
                        iconBgColor: selected
                            ? AppleColors.systemBlue
                            : (isDark
                                ? const Color(0xFF3A3A3F)
                                : const Color(0xFF8E8E93)),
                        title: line.name,
                        subtitle: lineSpec.isEmpty
                            ? baseSubtitle
                            : '$baseSubtitle · $lineSpec',
                        trailing: _activeSite.isEffectivelyPrivate
                            ? null
                            : IconButton(
                                tooltip:
                                    widget.storage.preferredLineName ==
                                            line.name
                                        ? '取消默认播放线路'
                                        : '设为默认播放线路',
                                icon: Icon(
                                  widget.storage.preferredLineName == line.name
                                      ? Icons.star_rounded
                                      : Icons.star_border_rounded,
                                  color: widget.storage.preferredLineName ==
                                          line.name
                                      ? Colors.amber
                                      : palette.labelSecondary,
                                ),
                                onPressed: () async {
                                  await widget.storage.setPreferredLineName(
                                    widget.storage.preferredLineName ==
                                            line.name
                                        ? ''
                                        : line.name,
                                  );
                                  if (ctx.mounted) updateSheet(() {});
                                },
                              ),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          if (!mounted) return;
                          final snapshotLineIdentity = _captureLineIdentity(
                            capturedLines,
                            i,
                            siteKey: capturedSiteKey,
                            videoId: capturedVideoId,
                          );
                          final resolvedIdx = _matchLineIndexByIdentity(
                            _video.lines,
                            snapshotLineIdentity,
                          );
                          if (resolvedIdx == null) {
                            _toast('播放线路已变更或下架，请重新选择');
                            return;
                          }
                          setState(() => _selectLineManually(resolvedIdx));
                        },
                      ),
                    );
                    return lineReason != null
                        ? Opacity(opacity: 0.52, child: tile)
                        : tile;
                  },
                ),
              ],
              if (otherSources.isNotEmpty) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                  child: Row(
                    children: [
                      const Icon(
                        CupertinoIcons.arrow_2_squarepath,
                        color: AppleColors.systemBlue,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '其他已聚合站点 (${otherSources.length})',
                          style: TextStyle(
                            color: palette.labelSecondary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                for (var idx = 0; idx < otherSources.length; idx++) ...[
                  if (idx > 0) const SizedBox(height: 8),
                  Builder(builder: (_) {
                    final ref = otherSources[idx];
                    final hydrated = _aggregatedDetails[ref.identityKey];
                    final err = _aggregatedSourceErrors[ref.identityKey];
                    final subtitle = hydrated != null
                        ? '共 ${hydrated.lines.length} 条线路 · ${hydrated.lines.fold<int>(0, (sum, l) => sum + l.episodes.length)} 集'
                        : (err != null
                            ? '读取失败：$err'
                            : (_hydratingAggregatedSources
                                ? '正在后台加载该站点线路…'
                                : '点击切换至该站点'));
                    return Container(
                      key: ValueKey('detail-other-source-${ref.site.key}'),
                      decoration: BoxDecoration(
                        color: tileBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: tileBorder, width: 0.65),
                      ),
                      child: AppleGroupedTile(
                        icon: CupertinoIcons.globe,
                        iconBgColor: isDark
                            ? const Color(0xFF3A3A3F)
                            : const Color(0xFF8E8E93),
                        title: ref.sourceLabel,
                        subtitle: subtitle,
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _switchToAggregatedSource(ref);
                        },
                      ),
                    );
                  }),
                ],
              ],
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: tileBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: tileBorder, width: 0.65),
                ),
                child: AppleGroupedTile(
                  icon: CupertinoIcons.search,
                  iconBgColor: AppleColors.systemBlue,
                  title: '在其他片源搜索更多来源',
                  subtitle: '手动检索当前已启用的全部片源',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _searchOtherSources();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _searchOtherSources() async {
    final sites = widget.storage.loadSavedConfig()?.availableSites ?? const <CmsSite>[];
    final candidates = sites.where((s) => s.supported && s.key != _activeSite.key &&
        s.searchable && s.isEffectivelyPrivate == _activeSite.isEffectivelyPrivate).toList();
    final cleanedQuery = CspBridge.cleanNetdiskSearchTitle(_video.title);
    final query = cleanedQuery.isNotEmpty ? cleanedQuery : _video.title;
    final results = widget.client.searchAcrossSites(widget.storage.prioritizeSites(candidates), query);
    final pick = await showIos27LiquidSheet<(CmsSite, CmsVideo)>(
      context: context,
      title: '在其他片源搜索《$query》',
      builder: (_) => _OtherSourceResults(
        results: results,
      ),
    );
    if (pick == null || !mounted) return;
    await Navigator.of(context).push(buildApplePageRoute<void>(
      builder: (_) => DetailScreen(site: pick.$1, initialVideo: pick.$2,
        client: widget.client, storage: widget.storage),
    ));
  }

  void _showAllEpisodesGridSheet(WatchHistoryEntry? bookmark) {
    final unifiedSlots = _unifiedEpisodeSlots();
    if (isWindowsDesktopUi &&
        _hasAggregatedMultiOfferDetails &&
        unifiedSlots.isNotEmpty) {
      final orderedSlots =
          _descending ? unifiedSlots.reversed.toList() : unifiedSlots;
      final totalSlots = orderedSlots.length;
      String filterQuery = '';
      showIos27LiquidSheet<void>(
        context: context,
        title: '全部剧集 · 全部来源 ($totalSlots)',
        builder: (ctx) => StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final q = filterQuery.trim().toLowerCase();
            final filtered = q.isEmpty
                ? orderedSlots
                : orderedSlots.where((slot) {
                    final epNumStr = slot.episodeNumber?.toString() ?? '';
                    return slot.label.toLowerCase().contains(q) ||
                        epNumStr == q ||
                        slot.offers.any(
                          (o) =>
                              o.episode.name.toLowerCase().contains(q) ||
                              o.siteAndLineLabel.toLowerCase().contains(q),
                        );
                  }).toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (totalSlots >= 12)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: '输入集数或关键词快速定位（如 180）',
                        prefixIcon: const Icon(CupertinoIcons.search, size: 16),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (v) => setSheetState(() => filterQuery = v),
                    ),
                  ),
                Flexible(
                  child: GridView.builder(
                    key: const ValueKey('windows-all-episodes-unified-grid'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 164,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2.25,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, idx) {
                      final slot = filtered[idx];
                      final hasCurrentSite = slot.hasSiteKey(_activeSite.key);
                      final isBookmarked = bookmark != null &&
                          slot.offers.any(
                            (o) =>
                                o.source.site.key == bookmark.site &&
                                ((o.lineName == bookmark.line &&
                                        o.episodeIndex == bookmark.index) ||
                                    o.episode.name == bookmark.episode),
                          );
                      final badge = slot.distinctSiteCount > 1
                          ? '${slot.distinctSiteCount} 源'
                          : (!hasCurrentSite
                              ? '仅 ${slot.offers.first.source.site.name}'
                              : (slot.offers.length > 1
                                  ? '${slot.offers.length} 线'
                                  : (slot.offers.first.lineIndex != _selectedLine
                                      ? '仅 ${slot.offers.first.lineName}'
                                      : slot.offers.first.lineName)));
                      final palette = ApplePalette.of(ctx);
                      return InkWell(
                        key: ValueKey('all_unified_ep_card_${slot.slotKey}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _onUnifiedEpisodeSlotTap(slot, bookmark);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: isBookmarked
                                ? AppleColors.systemBlue.withValues(alpha: 0.22)
                                : (palette.isDark
                                    ? const Color(0xFF28282E)
                                    : Colors.white),
                            border: Border.all(
                              color: isBookmarked
                                  ? AppleColors.systemBlue
                                  : palette.separator,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                slot.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.labelPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                badge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.labelSecondary,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
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
      return;
    }
    if (_video.lines.isEmpty) return;
    final capturedSiteKey = _activeSite.key;
    final capturedVideoId = _video.id;
    final capturedLines = List<CmsLine>.of(_video.lines);
    final safeLineIdx = _selectedLine.clamp(0, capturedLines.length - 1);
    final line = capturedLines[safeLineIdx];
    final snapshotLineIdentity = _captureLineIdentity(
      capturedLines,
      safeLineIdx,
      siteKey: capturedSiteKey,
      videoId: capturedVideoId,
    );
    final scraped = _scrapeLine(line);
    final scrape = _scrapeResultForLine(line);
    final activeIndices = _activeEpisodeIndicesFor(line);
    final ordered =
        _descending ? activeIndices.reversed.toList() : activeIndices;
    final total = ordered.length;
    final playedEpIdx = _isIosDetail
        ? _resolvePlayedEpisodeIndexForLine(
            line,
            safeLineIdx,
            activeIndices,
            bookmark,
          )
        : null;
    final isMovieVersions = _isMultiVersionMovieLine(line);
    String filterQuery = '';
    showIos27LiquidSheet<void>(
      context: context,
      title: isMovieVersions
          ? '全部版本 · ${line.name} ($total)'
          : '全部剧集 · ${_currentSeasonLabel(line)} · ${line.name} ($total)',
      builder: (ctx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final q = filterQuery.trim().toLowerCase();
          final filtered = q.isEmpty
              ? ordered
              : ordered.where((origIdx) {
                  final ep = line.episodes[origIdx];
                  final info = scrape.byOriginalIndex[origIdx];
                  final epNumStr = info.resolvedEpisodeNumber?.toString() ?? '';
                  return ep.name.toLowerCase().contains(q) ||
                      info.displayLabel.toLowerCase().contains(q) ||
                      epNumStr == q;
                }).toList();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (total >= 12)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '输入集数或关键词快速定位（如 180）',
                      prefixIcon: const Icon(CupertinoIcons.search, size: 16),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onChanged: (v) => setSheetState(() => filterQuery = v),
                  ),
                ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 152,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.35,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, idx) {
                    final originalIdx = filtered[idx];
                    final ep = line.episodes[originalIdx];
                    final epInfo = scraped.infoForRawIndex(originalIdx);
                    final info = scrape.byOriginalIndex[originalIdx];
                    final unavailReason = _episodeUnavailableReason(ep);
                    final isUnavailable = unavailReason != null;
                    final isBookmarked = !isUnavailable &&
                        (_isIosDetail
                            ? (playedEpIdx != null && playedEpIdx == originalIdx)
                            : (bookmark != null &&
                                bookmark.line == line.name &&
                                bookmark.index == originalIdx));
                    final showScrapedSub = !_isIosDetail &&
                        info.resolvedEpisodeNumber != null &&
                        !info.isSpecial &&
                        ep.name.trim() != info.displayLabel &&
                        !ep.name.contains('第${info.resolvedEpisodeNumber}集');
                    final cellLabel = _isIosDetail && epInfo != null
                        ? epInfo.compactLabel(
                            isVariety: _isVarietyShow,
                            singleItemMovie: total <= 1,
                          )
                        : ep.name;
                    final cell = GestureDetector(
                      onTap: () {
                        if (unavailReason != null) {
                          unawaited(
                            showAppleNativeAlert(
                              ctx,
                              title: ep.name,
                              message: unavailReason,
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
                        if (!mounted) return;
                        final target = _resolveEpisodeTargetByIdentity(
                          snapshotLineIdentity: snapshotLineIdentity,
                          snapshotEpisode: ep,
                        );
                        if (target == null) {
                          _toast('剧集列表已更新或目标已下架，请重新选择');
                          return;
                        }
                        final (resolvedLineIdx, resolvedEpIdx) = target;
                        if (_selectedLine != resolvedLineIdx) {
                          setState(() => _selectedLine = resolvedLineIdx);
                        }
                        _openPlayer(resolvedLineIdx, resolvedEpIdx);
                      },
                      child: Builder(
                        builder: (cellCtx) {
                          final palette = ApplePalette.of(cellCtx);
                          final isDark = palette.isDark;
                          return Tooltip(
                            message: showScrapedSub
                                ? '${info.displayLabel} · ${ep.name}'
                                : cellLabel,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isBookmarked
                                    ? AppleColors.systemBlue
                                    : (isDark
                                        ? const Color(0xFF28282E)
                                        : Colors.white),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isBookmarked
                                      ? AppleColors.systemBlue
                                      : (isDark
                                          ? const Color(0x26FFFFFF)
                                          : Colors.black.withValues(alpha: 0.09)),
                                  width: isBookmarked ? 1.2 : 0.65,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: showScrapedSub
                                  ? Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          isUnavailable
                                              ? '${info.displayLabel} (不可解析)'
                                              : info.displayLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isBookmarked
                                                ? Colors.white
                                                : palette.labelPrimary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          ep.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isBookmarked
                                                ? Colors.white70
                                                : palette.labelSecondary,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      isUnavailable
                                          ? '$cellLabel (不可解析)'
                                          : cellLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isBookmarked
                                            ? Colors.white
                                            : palette.labelPrimary,
                                        fontSize: 13.5,
                                        fontWeight: isBookmarked
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                            ),
                          );
                        },
                      ),
                    );
                    return isUnavailable
                        ? Opacity(opacity: 0.48, child: cell)
                        : cell;
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDownloadSheet() {
    if (_activeSite.isEffectivelyPrivate) {
      _toast('隐私分组暂不支持离线下载');
      return;
    }
    if (_video.lines.isEmpty) {
      _toast('暂未获取到可下载的剧集资源');
      return;
    }
    final lineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[lineIdx];
    final service = DownloadService.instance;
    final selected = <int>{};
    showIos27LiquidSheet<void>(
      context: context,
      title: '下载 · ${line.name}',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final palette = ApplePalette.of(ctx);
          final isDark = palette.isDark;
          final total = line.episodes.length;
          final downloadable = <int>[
            for (int i = 0; i < total; i++)
              if (service.taskFor(_activeSite.key, _video.id, line.name, i) ==
                  null)
                i,
          ];
          final allSelected = downloadable.isNotEmpty &&
              downloadable.every(selected.contains);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 12, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        downloadable.isEmpty
                            ? '本线路的剧集都已在下载列表中'
                            : '选择要下载的剧集 · 已选 ${selected.length}',
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    if (downloadable.isNotEmpty)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(28, 28),
                        onPressed: () => setSheet(() {
                          if (allSelected) {
                            selected.clear();
                          } else {
                            selected.addAll(downloadable);
                          }
                        }),
                        child: Text(
                          allSelected ? '取消全选' : '全选',
                          style: const TextStyle(
                            color: AppleColors.systemBlue,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 124,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.4,
                  ),
                  itemCount: total,
                  itemBuilder: (context, i) {
                    final ep = line.episodes[i];
                    final task = service.taskFor(
                      _activeSite.key,
                      _video.id,
                      line.name,
                      i,
                    );
                    final exists = task != null;
                    final done = task?.status == DownloadStatus.completed;
                    final isSelected = selected.contains(i);
                    return GestureDetector(
                      onTap: exists
                          ? null
                          : () => setSheet(() {
                                if (isSelected) {
                                  selected.remove(i);
                                } else {
                                  selected.add(i);
                                }
                              }),
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: isSelected
                              ? AppleColors.systemBlue.withValues(
                                  alpha: isDark ? 0.28 : 0.14,
                                )
                              : (isDark
                                  ? const Color(0xFF28282E)
                                  : Colors.white),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(11),
                            side: BorderSide(
                              color: isSelected
                                  ? AppleColors.systemBlue
                                  : (isDark
                                      ? const Color(0x26FFFFFF)
                                      : Colors.black.withValues(alpha: 0.09)),
                              width: isSelected ? 1.2 : 0.65,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (exists) ...[
                                Icon(
                                  done
                                      ? CupertinoIcons.checkmark_circle_fill
                                      : CupertinoIcons.arrow_down_circle,
                                  size: 13,
                                  color: done
                                      ? AppleColors.systemGreen
                                      : palette.labelSecondary,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  ep.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: exists
                                        ? palette.labelTertiary
                                        : (isSelected && !isDark
                                            ? AppleColors.systemBlue
                                            : palette.labelPrimary),
                                    fontSize: 13.5,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Center(
                  child: AppleCapsuleButton(
                    label: selected.isEmpty
                        ? '请选择剧集'
                        : '开始下载（${selected.length} 集）',
                    icon: CupertinoIcons.arrow_down_circle_fill,
                    primary: true,
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            final list = selected.toList()..sort();
                            final added = service.enqueue(
                              site: _activeSite,
                              video: _video,
                              line: line,
                              episodeIndexes: list,
                              parses: widget.storage.loadSavedConfig()?.parses ?? const [],
                            );
                            Navigator.of(ctx).pop();
                            _toast(
                              added > 0
                                  ? '已加入下载队列 $added 集，可在「片库 › 离线下载」查看'
                                  : '所选剧集已在下载列表中',
                            );
                          },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget screen;
    if (isWindowsDesktopUi && WindowsAppearanceScope.maybeOf(context) != null) {
      screen = _buildWindowsDetail(context);
    } else {
      final wideLayout = _isMacosDetail
          ? MediaQuery.sizeOf(context).width >= 860
          : AppleViewportLayout.of(context).prefersWideDetail;
      screen = wideLayout
          ? _buildWideDesktopScreen(context)
          : _buildPortraitImmersiveScreen(context);
    }
    if (OhosRuntime.isOhos) return screen;
    final wrapped = isWindowsDesktopUi
        ? screen
        : AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: screen,
          );
    return RepaintBoundary(
      key: _transitionBackdropKey,
      child: wrapped,
    );
  }

  /// Portrait immersive layout:
  /// - True full-bleed poster from `top: 0` down to `77%` of screen height so there is
  ///   zero dead blank space at top or bottom and zero internal top container edge
  /// - Breathable 28% top status-bar scrim so artwork extends behind the clock & top buttons
  /// - Compact progressive frosted glass blur (`ShaderMask` + `BackdropFilter`) + ambient
  ///   color fusion strictly in the lower `58%..100%` text & play-button overlap zone
  Widget _buildPortraitImmersiveScreen(BuildContext context) {
    final targetBg = _resolveBaseAmbientColor();
    final bookmark = _findBookmark();
    final isMac = _isMacosDetail;
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final topPad = math.max(
      MediaQuery.paddingOf(context).top,
      isMac ? 36.0 : 0.0,
    );
    final viewport = AppleViewportLayout.of(context);
    final screenHeight = viewport.height;
    final double posterWindowHeight;
    final double foregroundHeroHeight;
    if (isMac) {
      posterWindowHeight = _macHeroHasLandscape
          ? (viewport.width * 9 / 16).clamp(320.0, 460.0)
          : (screenHeight * 0.64).clamp(430.0, 560.0);
      foregroundHeroHeight = _macHeroHasLandscape
          ? (posterWindowHeight * 0.92).clamp(300.0, 440.0)
          : (posterWindowHeight * 0.96).clamp(410.0, 540.0);
    } else if (viewport.isShortPortrait) {
      // iPhone Duo 5.4" outer cover (`466×678 pt`) & compact phones:
      // keep title, badges, synopsis, and Play CTA visible above the fold.
      posterWindowHeight = (screenHeight * 0.72).clamp(390.0, 540.0);
      foregroundHeroHeight = (posterWindowHeight * 0.68).clamp(280.0, 390.0);
    } else if (viewport.isExpandedPortrait) {
      // iPhone Duo 7.6" unfolded inner portrait (`669×951 pt`) & iPad portrait:
      // balance full-bleed cinema poster with immediate episode/cast access.
      posterWindowHeight = (screenHeight * 0.62).clamp(540.0, 640.0);
      foregroundHeroHeight = (posterWindowHeight * 0.72).clamp(390.0, 470.0);
    } else {
      posterWindowHeight = (screenHeight * 0.77).clamp(590.0, 740.0);
      foregroundHeroHeight = (posterWindowHeight * 0.74).clamp(430.0, 535.0);
    }
    final double portraitContentPad = viewport.isExpandedPortrait
        ? 28.0
        : (viewport.isCompactSplit ? 14.0 : 18.0);

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBg, end: targetBg),
      duration: Ios27ConcentricGeometry.isReduceMotion(context)
          ? Ios27ConcentricGeometry.reducedMotionDuration
          : Ios27Spring.smooth.nominalDuration,
      curve: Ios27Spring.smooth.curve,
      builder: (context, animatedBg, _) {
        final bgColor = animatedBg ?? targetBg;
        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Unified Solid Ambient Canvas Matching Poster Edge Color
              ColoredBox(color: bgColor),

              // 2. Full-Screen Backdrop Layer (true full-bleed from top: 0)
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: _scrollOffset,
                  builder: (context, offset, child) {
                    final progress = reduceMotion
                        ? 0.0
                        : (offset / 340.0).clamp(0.0, 1.0);
                    final blurSigma = reduceMotion ? 0.0 : progress * 9.5;
                    final scrollVeilAlpha = progress * 0.38;

                    Widget posterStack = Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: bgColor),
                        // Full-bleed poster starting at physical screen top (top: 0)
                        // with 100% clarity across the upper 62% and intrinsic alpha
                        // feathering in the lower text-overlap region
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: posterWindowHeight,
                          child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xFFFFFFFF),
                                Color(0xFFFFFFFF),
                                Color(0xBFFFFFFF),
                                Color(0x4DFFFFFF),
                                Color(0x00FFFFFF),
                                Color(0x00FFFFFF),
                              ],
                              stops: [0.0, 0.62, 0.78, 0.90, 0.98, 1.0],
                            ).createShader(rect),
                            child: child!,
                          ),
                        ),
                        // Ultra-light breathable top status-bar scrim (keeps poster
                        // visible right up to y = 0 while ensuring white clock legibility)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: topPad + 54,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  bgColor.withValues(alpha: 0.28),
                                  bgColor.withValues(alpha: 0.10),
                                  bgColor.withValues(alpha: 0.0),
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                        // Compact Progressive Frosted Glass Blur Transition strictly
                        // behind the lower title / synopsis / play button overlap zone.
                        // On iOS < 26, during iOS thermal throttling, or while the outer
                        // scroll ImageFiltered blur is active, skip stacking a nested
                        // ShaderMask + BackdropFilter saveLayer inside the outer blur.
                        Positioned(
                          top: posterWindowHeight * 0.58,
                          left: 0,
                          right: 0,
                          height: posterWindowHeight * 0.42,
                          child: (!kIsWeb &&
                                  !OhosRuntime.isOhos &&
                                  defaultTargetPlatform == TargetPlatform.iOS &&
                                  (!IosLiquidGlassBridge.isAvailable ||
                                      IosLiquidGlassBridge.thermalThrottled ||
                                      blurSigma > 0.5))
                              ? DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        bgColor.withValues(alpha: 0.0),
                                        bgColor.withValues(alpha: 0.48),
                                        bgColor.withValues(alpha: 0.88),
                                        bgColor,
                                      ],
                                      stops: const [0.0, 0.38, 0.76, 0.96],
                                    ),
                                  ),
                                )
                              : ShaderMask(
                                  blendMode: BlendMode.dstIn,
                                  shaderCallback: (rect) =>
                                      const LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Color(0x00FFFFFF),
                                          Color(0x8CFFFFFF),
                                          Color(0xFFFFFFFF),
                                          Color(0x00FFFFFF),
                                        ],
                                        stops: [0.0, 0.36, 0.84, 1.0],
                                      ).createShader(rect),
                                  child: ClipRect(
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(
                                        sigmaX: 6.5,
                                        sigmaY: 6.5,
                                        tileMode: TileMode.clamp,
                                      ),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              bgColor.withValues(alpha: 0.0),
                                              bgColor.withValues(alpha: 0.46),
                                              bgColor.withValues(alpha: 0.86),
                                              bgColor,
                                            ],
                                            stops: const [0.0, 0.38, 0.76, 0.96],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    );

                    final effectiveBlurSigma = (!kIsWeb &&
                            !OhosRuntime.isOhos &&
                            defaultTargetPlatform == TargetPlatform.iOS &&
                            !IosLiquidGlassBridge.isAvailable)
                        ? math.min(blurSigma, 18.0)
                        : blurSigma;
                    if (effectiveBlurSigma > 0.15) {
                      posterStack = ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: effectiveBlurSigma,
                          sigmaY: effectiveBlurSigma,
                          tileMode: TileMode.clamp,
                        ),
                        child: posterStack,
                      );
                    }

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        posterStack,
                        // Post-blur bottom lock gradient strictly in the lower overlap &
                        // episode list zone, guaranteeing zero bottom seam when scrolling
                        Positioned(
                          top: posterWindowHeight * 0.64,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  bgColor.withValues(alpha: 0.0),
                                  bgColor.withValues(alpha: 0.50),
                                  bgColor.withValues(alpha: 0.90),
                                  bgColor,
                                  bgColor,
                                ],
                                stops: const [0.0, 0.24, 0.42, 0.54, 1.0],
                              ),
                            ),
                          ),
                        ),
                        if (scrollVeilAlpha > 0.01)
                          Positioned.fill(
                            child: ColoredBox(
                              color: bgColor.withValues(alpha: scrollVeilAlpha),
                            ),
                          ),
                      ],
                    );
                  },
                  child: isMac
                      ? LandscapePosterImage(
                          key: const ValueKey('mac-detail-narrow-backdrop'),
                          url: _effectivePosterUrl,
                          title: _activeSite.isEffectivelyPrivate
                              ? ''
                              : _effectiveLookupTitle,
                          year: _activeSite.isEffectivelyPrivate
                              ? ''
                              : _effectiveLookupYear,
                          preferredBackdropUrl: _activeSite.isEffectivelyPrivate
                              ? ''
                              : _effectiveBackdropUrl,
                          preferredDoubanId: _activeSite.isEffectivelyPrivate
                              ? ''
                              : _effectiveDoubanId,
                          preferredDoubanIsTv: !_video.tag.contains('电影') &&
                              (_video.lines.isEmpty ||
                                  _video.lines.first.episodes.length > 1),
                          wantMotionComic: _effectiveWantMotionComic,
                          allowExternalLookup:
                              !_activeSite.isEffectivelyPrivate,
                          isPrivate: _activeSite.isEffectivelyPrivate,
                          blurPortraitFallback: true,
                          showRightFramedPortraitFallback: false,
                          alignment: const Alignment(0.0, -0.2),
                          onBytesLoaded: _updateAmbientFromBytes,
                          onLandscapeStatusChanged: (isLand) {
                            if (mounted && _macHeroHasLandscape != isLand) {
                              setState(() => _macHeroHasLandscape = isLand);
                            }
                          },
                          placeholder: _posterPlaceholder(bgColor),
                        )
                      : PosterImage(
                          url: _effectivePosterUrl,
                          title: _isPrivatePosterContext
                              ? ''
                              : _effectiveLookupTitle,
                          year: _isPrivatePosterContext
                              ? ''
                              : _effectiveLookupYear,
                          isPrivate: _isPrivatePosterContext,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0.0, -0.32),
                          highRes: !_isPrivatePosterContext,
                          strictHighRes: !_isPrivatePosterContext,
                          onBytesLoaded: _updateAmbientFromBytes,
                          placeholder: _posterPlaceholder(bgColor),
                        ),
                ),
              ),

              // 3. Main Scrollable Foreground Content
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleDetailScrollNotification,
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.only(bottom: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildPortraitHeroForeground(
                          context,
                          heroHeight: foregroundHeroHeight,
                        ),
                        Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: viewport.isExpandedPortrait
                                  ? 640.0
                                  : double.infinity,
                            ),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: portraitContentPad,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildPortraitSynopsis(),
                                  const SizedBox(height: 14),
                                  _buildPortraitActionRow(bookmark),
                                  if (bookmark != null) ...[
                                    const SizedBox(height: 10),
                                    _buildPortraitBookmarkProgress(bookmark),
                                  ],
                                  const SizedBox(height: 18),
                                  CastAvatarSection(
                                    title: _effectiveLookupTitle.isNotEmpty
                                        ? _effectiveLookupTitle
                                        : _video.title,
                                    actorRaw: _video.actor,
                                    year: _effectiveLookupYear,
                                    doubanId: _effectiveDoubanId,
                                    wantMotionComic: _effectiveWantMotionComic,
                                    allowExternalLookup:
                                        !_activeSite.isEffectivelyPrivate,
                                    forceDark: true,
                                    padding: EdgeInsets.zero,
                                  ),
                                  const SizedBox(height: 18),
                                  if (!_loading && _video.sourceWarnings.isNotEmpty)
                                    _buildSourceWarningsSection(),
                                  if (!_loading &&
                                      _activeSite.playbackHint.isNotEmpty &&
                                      _configuredParses.isEmpty)
                                    _buildPlaybackHintBanner(),
                                  if (_loading)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 32),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const CupertinoActivityIndicator(radius: 14),
                                            if (CuratedDiscoveryService.isCuratedSite(
                                                _activeSite)) ...[
                                              const SizedBox(height: 10),
                                              const Text(
                                                '正在您添加的片源中匹配播放资源…',
                                                style: TextStyle(
                                                  color: AppleColors.labelSecondary,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    )
                                  else if (_curatedUnavailableMessage != null)
                                    _buildCuratedUnavailableCard()
                                  else if (_error != null)
                                    _buildDetailError()
                                  else if (_video.lines.isEmpty)
                                    const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 20),
                                      child: Text(
                                        '当前片源未提供可播放剧集，请重试或手动切换片源',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: AppleColors.labelSecondary,
                                          fontSize: 14,
                                        ),
                                      ),
                                    )
                                  else
                                    _buildPortraitEpisodesSection(bookmark),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              _buildDetailPullRefreshPill(topPad),

              // 4. Floating Liquid Glass Top Navigation Bar (Back on Left, Source Picker + Download/Favorite on Right)
              Positioned(
                top: topPad + 8,
                left: viewport.isCompactSplit ? 12 : 16,
                right: viewport.isCompactSplit ? 12 : 16,
                child: Theme(
                  data: _isMacosDetail
                      ? Theme.of(context).copyWith(brightness: Brightness.dark)
                      : Theme.of(context),
                  child: Row(
                    children: [
                      _buildFloatingGlassCircleButton(
                        icon: CupertinoIcons.chevron_back,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _buildFloatingSourceButton(
                            maxWidth: viewport.isCompactSplit ? 112.0 : 168.0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildFloatingTopRightPill(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaybackHintBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: const ValueKey('detail-playback-hint-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x22FF9F0A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x45FF9F0A), width: 0.6),
        ),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.info_circle,
              size: 14,
              color: Color(0xFFFFD60A),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _activeSite.playbackHint,
                style: const TextStyle(
                  color: Color(0xFFFFD60A),
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceWarningsSection() {
    if (_video.lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          _video.sourceWarnings.join('\n'),
          style: const TextStyle(color: AppleColors.labelSecondary, fontSize: 13),
        ),
      );
    }
    final primaryWarnings = <String>[];
    final backupWarnings = <String>[];
    for (final warning in _video.sourceWarnings) {
      if (warning.startsWith('观看记录：') || warning.contains('目录返回不完整')) {
        primaryWarnings.add(warning);
      } else {
        backupWarnings.add(warning);
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (primaryWarnings.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: backupWarnings.isNotEmpty ? 6 : 0),
              child: Text(
                primaryWarnings.join('\n'),
                style: const TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          if (backupWarnings.isNotEmpty) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(
                () => _sourceWarningsExpanded = !_sourceWarningsExpanded,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.info_circle,
                      size: 14,
                      color: AppleColors.labelTertiary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '已加载 ${_video.lines.length} 条可用线路（另有 ${backupWarnings.length} 条备用分享已跳过）',
                        style: const TextStyle(
                          color: AppleColors.labelTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Icon(
                      _sourceWarningsExpanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 13,
                      color: AppleColors.labelTertiary,
                    ),
                  ],
                ),
              ),
            ),
            if (_sourceWarningsExpanded)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 20),
                child: Text(
                  backupWarnings.join('\n'),
                  style: const TextStyle(
                    color: AppleColors.labelTertiary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildFloatingGlassCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    String symbol = 'chevron.backward',
    String accessibilityLabel = '返回',
  }) {
    final fallback = Ios27Pressable(
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 20,
      onTap: onTap,
      child: LiquidGlass(
        width: 40,
        height: 40,
        borderRadius: 20,
        elevated: false,
        tint: const Color(0x5E1E1E22),
        child: Center(
          child: Icon(
            icon,
            color: AppleColors.labelPrimary,
            size: 20,
          ),
        ),
      ),
    );
    return IosNativeGlassButton(
      style: 'circle',
      symbol: symbol,
      symbolSize: 17,
      foregroundColor: Colors.white,
      forceDark: true,
      width: 40,
      height: 40,
      accessibilityLabel: accessibilityLabel,
      onTap: onTap,
      fallback: fallback,
    );
  }

  /// Top-right floating Liquid Glass source selector button (`选源`):
  /// Displays the active playback source/line name and opens `_showSourcePickerSheet`.
  Widget _buildFloatingSourceButton({double maxWidth = 168.0}) {
    final hasLines = _video.lines.isNotEmpty;
    final safeLineIdx = hasLines
        ? _selectedLine.clamp(0, _video.lines.length - 1)
        : 0;
    final activeLineName = hasLines
        ? _video.lines[safeLineIdx].name
        : (_loading ? '加载片源…' : _activeSite.name);

    final fallback = Ios27Pressable(
      key: const ValueKey('source_picker_button'),
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 999,
      onTap: _showSourcePickerSheet,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: LiquidGlass(
          height: 40,
          borderRadius: 999,
          elevated: false,
          tint: const Color(0x5E1E1E22),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.layers_alt_fill,
                color: AppleColors.labelPrimary,
                size: 15,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  activeLineName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.chevron_down,
                color: Color(0xCCFFFFFF),
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );

    return IosNativeGlassButton(
      style: 'capsule',
      symbol: 'square.3.layers.3d',
      trailingSymbol: 'chevron.down',
      label: activeLineName,
      symbolSize: 14,
      foregroundColor: Colors.white,
      forceDark: true,
      maxWidth: maxWidth,
      height: 40,
      accessibilityLabel: '切换片源 $activeLineName',
      onTap: _showSourcePickerSheet,
      fallback: fallback,
    );
  }

  /// Top-right floating Liquid Glass capsule:
  /// Left button = Netdisk QR Login (`网盘扫码`)
  /// Middle button = Offline Download (`离线缓存`)
  /// Right button = Favorite (`收藏`)
  Widget _buildFloatingTopRightPill() {
    final currentLine = _video.lines.isEmpty
        ? null
        : _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)];
    final driveKey = currentLine != null && currentLine.episodes.isNotEmpty
        ? currentLine.episodes.first.cloudProvider
        : null;

    void onOpenNetdisk() => showNetdiskAccountSheet(
          context,
          widget.storage,
          initialDriveKey: driveKey ??
              CspBridge.netdiskDriveKeyForLineName(currentLine?.name ?? ''),
          onChanged: () {
            if (mounted) setState(() {});
          },
        );

    Future<void> onToggleFavorite() async {
      final fav = await widget.storage.toggleFavorite(
        _activeSite,
        _video,
      );
      if (mounted) {
        setState(() => _isFavorite = fav);
        if (fav) {
          final isPrivPoster = _isPrivatePosterContext;
          final safeCachedBytes = _loadedPosterIdentity == _currentPosterIdentity
              ? _loadedPosterBytes
              : null;
          unawaited(
            FavoritePostcardFlightOverlay.show(
              context,
              title: _video.title,
              posterUrl: _effectivePosterUrl,
              year: _video.year,
              cachedBytes: safeCachedBytes,
              isPrivate: isPrivPoster,
            ),
          );
        } else {
          _toast('已从片库移除');
        }
      }
    }

    final fallback = LiquidGlass(
      height: 40,
      borderRadius: 999,
      elevated: false,
      tint: const Color(0x5E1E1E22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Ios27Pressable(
            key: const ValueKey('detail-netdisk-qr-button'),
            pressedScale: Ios27Spring.pressSwellScale,
            borderRadius: 999,
            onTap: onOpenNetdisk,
            child: const SizedBox(
              width: 38,
              height: 36,
              child: Center(
                child: Icon(
                  CupertinoIcons.qrcode_viewfinder,
                  color: AppleColors.labelPrimary,
                  size: 19,
                ),
              ),
            ),
          ),
          Container(
            width: 0.6,
            height: 18,
            color: const Color(0x36FFFFFF),
          ),
          Ios27Pressable(
            pressedScale: Ios27Spring.pressSwellScale,
            borderRadius: 999,
            onTap: _showDownloadSheet,
            child: const SizedBox(
              width: 38,
              height: 36,
              child: Center(
                child: Icon(
                  CupertinoIcons.arrow_down_to_line,
                  color: AppleColors.labelPrimary,
                  size: 19,
                ),
              ),
            ),
          ),
          Container(
            width: 0.6,
            height: 18,
            color: const Color(0x36FFFFFF),
          ),
          Ios27Pressable(
            pressedScale: Ios27Spring.pressSwellScale,
            borderRadius: 999,
            onTap: () => unawaited(onToggleFavorite()),
            child: SizedBox(
              width: 38,
              height: 36,
              child: Center(
                child: Icon(
                  _isFavorite
                      ? CupertinoIcons.heart_fill
                      : CupertinoIcons.heart,
                  color: _isFavorite
                      ? AppleColors.systemRed
                      : AppleColors.labelPrimary,
                  size: 19,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return IosNativeGlassPill(
      height: 40,
      forceDark: true,
      actions: [
        IosNativeGlassPillAction(
          symbol: 'qrcode.viewfinder',
          color: Colors.white,
          accessibilityLabel: '网盘扫码',
          onTap: onOpenNetdisk,
        ),
        IosNativeGlassPillAction(
          symbol: 'arrow.down.to.line',
          color: Colors.white,
          accessibilityLabel: '离线下载',
          onTap: _showDownloadSheet,
        ),
        IosNativeGlassPillAction(
          symbol: _isFavorite ? 'heart.fill' : 'heart',
          color: _isFavorite ? AppleColors.systemRed : Colors.white,
          accessibilityLabel: _isFavorite ? '取消收藏' : '收藏',
          onTap: () => unawaited(onToggleFavorite()),
        ),
      ],
      fallback: fallback,
    );
  }

  Widget _buildPortraitHeroForeground(
    BuildContext context, {
    required double heroHeight,
  }) {
    final safeLineIdx = _video.lines.isEmpty
        ? 0
        : _selectedLine.clamp(0, _video.lines.length - 1);
    final epCount = _video.lines.isEmpty
        ? 0
        : _video.lines[safeLineIdx].episodes.length;
    final pills = <String>[
      if (_effectiveLookupYear.trim().isNotEmpty) _effectiveLookupYear.trim(),
      if (_video.area.trim().isNotEmpty) _video.area.trim(),
      if (_video.tag.trim().isNotEmpty) _video.tag.trim(),
      if (_video.remarks.trim().isNotEmpty)
        _video.remarks.trim()
      else if (epCount > 1)
        '共$epCount集',
    ];
    final targetBg = _resolveBaseAmbientColor();

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: heroHeight),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            (_isMacosDetail && !_macHeroHasLandscape) ? 92 : 0,
            20,
            14,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_isMacosDetail && !_macHeroHasLandscape) ...[
                SizedBox(
                  key: const ValueKey('mac-detail-narrow-portrait-poster'),
                  width: 132,
                  child: _buildPosterCard(targetBg),
                ),
                const SizedBox(height: 14),
              ],
              Text(
                _video.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  height: 1.18,
                  shadows: [
                    Shadow(
                      color: Color(0xB3000000),
                      blurRadius: 18,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
              ),
              if (pills.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final tag in pills.take(4))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x38FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0x33FFFFFF),
                            width: 0.5,
                          ),
                        ),
                        child: Text(
                          tag,
                          style: const TextStyle(
                            color: Color(0xF2FFFFFF),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              _buildRatingsAndSiteWrap(alignment: WrapAlignment.center),
              if (!OhosRuntime.isOhos) ...[
                Builder(
                  builder: (_) {
                    final activeLine = _video.lines.isEmpty
                        ? null
                        : _video.lines[safeLineIdx];
                    final specBadges = _specBadgesForHero(activeLine);
                    if (specBadges.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: MediaBadgeRow(
                        badges: specBadges,
                        maxBadges: 5,
                        alignment: WrapAlignment.center,
                      ),
                    );
                  },
                ),
              ],
              if (_isMacosDetail && !_activeSite.isEffectivelyPrivate) ...[
                const SizedBox(height: 10),
                _buildMacScrapeBar(alignment: WrapAlignment.center),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<MediaBadge> _specBadgesForLineOnly(CmsLine? line) {
    if (OhosRuntime.isOhos || line == null) return const <MediaBadge>[];
    final firstEp = line.episodes.isNotEmpty ? line.episodes.first : null;
    return MediaBadges.extractBadgesFromSources(<String?>[
      line.name,
      firstEp?.name,
      firstEp?.url,
    ]);
  }

  List<MediaBadge> _specBadgesForHero(CmsLine? line) {
    if (OhosRuntime.isOhos) return const <MediaBadge>[];
    final lineBadges = _specBadgesForLineOnly(line);
    if (lineBadges.isNotEmpty) return lineBadges;
    return MediaBadges.extractBadges(_video.remarks);
  }

  double? _effectiveDoubanScore() {
    if (!_activeSite.isEffectivelyPrivate) {
      final boundRating = _scrapeOverride?.doubanScore;
      if (boundRating != null && boundRating >= 2.0 && boundRating <= 10.0) {
        return boundRating;
      }
    }
    final direct = _video.doubanScore;
    if (direct != null && direct >= 2.0 && direct <= 10.0) return direct;
    if (!_activeSite.isEffectivelyPrivate) {
      final resolved = _resolvedDoubanScore;
      if (resolved != null && resolved >= 2.0 && resolved <= 10.0) {
        return resolved;
      }
    }
    final textBlob = _activeSite.isEffectivelyPrivate
        ? '${_video.remarks} ${_video.description}'
        : '${_video.remarks} ${_video.description} $_externalSynopsis';
    return CmsParser.extractDoubanScoreFromText(textBlob);
  }

  int? _effectiveRtScore() {
    final direct = _video.rtScore;
    if (direct != null && direct >= 1 && direct <= 100) return direct;
    if (!_activeSite.isEffectivelyPrivate) {
      final resolved = _resolvedRtScore;
      if (resolved != null && resolved >= 1 && resolved <= 100) {
        return resolved;
      }
    }
    final textBlob = _activeSite.isEffectivelyPrivate
        ? '${_video.remarks} ${_video.description}'
        : '${_video.remarks} ${_video.description} $_externalSynopsis';
    return CmsParser.extractRtScoreFromText(textBlob);
  }

  Widget _buildRatingsAndSiteWrap({required WrapAlignment alignment}) {
    final doubanScore = _effectiveDoubanScore();
    final rtPercent = _effectiveRtScore();
    final siteName = _activeSite.name.trim();
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        if (doubanScore != null && doubanScore >= 2.0 && doubanScore <= 10.0)
          Container(
            key: const ValueKey('detail-douban-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x3800B51D),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x6634D399),
                width: 0.8,
              ),
            ),
            child: Text(
              '豆瓣 ★ ${doubanScore.toStringAsFixed(1)}',
              style: const TextStyle(
                color: Color(0xFF6EE7B7),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (rtPercent != null && rtPercent >= 1 && rtPercent <= 100)
          Container(
            key: const ValueKey('detail-rt-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x38FA320A),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x66FF6B4A),
                width: 0.8,
              ),
            ),
            child: Text(
              '烂番茄 $rtPercent%',
              style: const TextStyle(
                color: Color(0xFFFFB4A2),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (siteName.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x26FFFFFF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x38FFFFFF),
                width: 0.8,
              ),
            ),
            child: Text(
              siteName,
              style: const TextStyle(
                color: Color(0xE6FFFFFF),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPortraitSynopsis() {
    final desc = _effectiveSeriesSynopsis();
    final cast = _video.actor.trim().isNotEmpty
        ? '演职员：${_video.actor.trim()}'
        : '';
    if (desc.isEmpty && cast.isEmpty) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (desc.isNotEmpty)
            Text(
              desc,
              textAlign: TextAlign.center,
              maxLines: _synopsisExpanded ? 18 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xD9FFFFFF),
                fontSize: 13.5,
                height: 1.55,
              ),
            ),
          if (_synopsisExpanded && cast.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              cast,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0x99FFFFFF),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCuratedUnavailableCard() {
    return Container(
      key: const Key('curated-no-source-card'),
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_circle,
            color: AppleColors.systemOrange,
            size: 26,
          ),
          const SizedBox(height: 8),
          Text(
            _curatedUnavailableMessage ?? '暂无可播放资源',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 10),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            onPressed: _searchOtherSources,
            child: const Text(
              '手动检索其他片源',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitActionRow(WatchHistoryEntry? bookmark) {
    final hasLines = !_loading && _video.lines.any((l) => l.episodes.isNotEmpty);
    final curatedBlocked = _curatedUnavailableMessage != null && !hasLines;
    final safeLineIdx = hasLines ? _selectedLine.clamp(0, _video.lines.length - 1) : 0;
    final bool useStrictBookmark = _isIosDetail || WoggSource.supports(_activeSite);
    final (int, int)? strictTarget =
        hasLines && bookmark != null && useStrictBookmark
            ? _iosBookmarkTarget(_video, bookmark)
            : null;
    final bool bookmarkMissingOnStrict =
        hasLines && bookmark != null && useStrictBookmark && strictTarget == null;
    final WatchHistoryEntry? selectedBookmark = hasLines && bookmark != null
        ? (useStrictBookmark
            ? (strictTarget != null && strictTarget.$1 == safeLineIdx
                ? bookmark
                : null)
            : (bookmark.line == _video.lines[safeLineIdx].name ? bookmark : null))
        : null;
    String playLabel = CuratedDiscoveryService.isCuratedSite(_activeSite)
        ? '正在匹配已添加片源…'
        : '加载片源中…';
    if (curatedBlocked) {
      playLabel = '暂无片源资源 · 无法播放';
    } else if (!_loading && !hasLines) {
      playLabel = '搜索其他片源';
    } else if (bookmarkMissingOnStrict) {
      playLabel = '原文件已变更 · 重新选集';
    } else if (selectedBookmark != null) {
      final matchedEp = strictTarget != null
          ? _video.lines[strictTarget.$1].episodes[strictTarget.$2]
          : null;
      final epName = matchedEp?.name ?? selectedBookmark.episode;
      final epNum = (strictTarget?.$2 ?? selectedBookmark.index) + 1;
      final (cleanEp, _) = _parseEpisodeDisplay(epName, epNum);
      final resumeMs = selectedBookmark.resumePosition;
      playLabel = resumeMs > 0
          ? '播放 · $cleanEp · 续播 ${_formatBookmarkTime(resumeMs)}'
          : '播放 · $cleanEp';
    } else if (hasLines) {
      final line = _video.lines[safeLineIdx];
      final indices = _activeEpisodeIndicesFor(line);
      if (indices.isNotEmpty) {
        final firstEp = line.episodes[indices.first];
        final (cleanFirst, _) = _parseEpisodeDisplay(firstEp.name, 1);
        playLabel = '播放 · $cleanFirst';
      } else {
        playLabel = '立即播放';
      }
    }

    return Ios27Pressable(
      key: const Key('detail-primary-play-button'),
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 999,
      onTap: hasLines
          ? () => _playPrimaryAction(useStrictBookmark ? bookmark : selectedBookmark)
          : (_loading || curatedBlocked ? null : _searchOtherSources),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: hasLines
              ? const Color(0xF5FFFFFF)
              : const Color(0x38FFFFFF),
          borderRadius: BorderRadius.circular(999),
          boxShadow: hasLines
              ? const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (hasLines) ...[
              const Icon(
                CupertinoIcons.play_fill,
                color: Color(0xFF121215),
                size: 17,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                playLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasLines
                      ? const Color(0xFF121215)
                      : const Color(0xCCFFFFFF),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitBookmarkProgress(WatchHistoryEntry bookmark) {
    final ratio = bookmark.progressFraction.clamp(0.05, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              CupertinoIcons.play_circle_fill,
              color: Color(0xCCFFFFFF),
              size: 14,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                bookmark.position > 0
                    ? '已观看 [${bookmark.episode}] 至 ${_formatBookmarkTime(bookmark.position)} · 线路：${bookmark.line}'
                    : '已观看 [${bookmark.episode}] · 线路：${bookmark.line}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xCCFFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 3.5,
            backgroundColor: const Color(0x26FFFFFF),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xF2FFFFFF)),
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitEpisodesSection(WatchHistoryEntry? bookmark) {
    final safeLineIdx = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[safeLineIdx];
    final isMovieVersions = _isMultiVersionMovieLine(line);
    final scraped = _scrapeLine(line);
    final inLineSeasons = CmsParser.extractInLineSeasons(line.episodes);
    final hasInLineSeasons = inLineSeasons.length >= 2;
    final activeIndices = _activeEpisodeIndicesFor(line);
    final total = activeIndices.length;
    final pageCount =
        (total + CmsParser.episodePageSize - 1) ~/ CmsParser.episodePageSize;
    final safePage = _selectedPage.clamp(0, pageCount > 0 ? pageCount - 1 : 0);
    final start = safePage * CmsParser.episodePageSize;
    final end = (start + CmsParser.episodePageSize).clamp(0, total);
    final int? currentActiveEpIdx = _isIosDetail
        ? _resolvePlayedEpisodeIndexForLine(
            line,
            safeLineIdx,
            activeIndices,
            bookmark,
          )
        : ((bookmark != null && bookmark.line == line.name)
            ? bookmark.index.clamp(0, line.episodes.length - 1)
            : (activeIndices.isNotEmpty ? activeIndices.first : 0));
    final seasonLabel = _currentSeasonLabel(line);
    final totalSeasons =
        hasInLineSeasons ? inLineSeasons.length : _relatedSeasons.length;
    final curSeasonInfo = CmsParser.parseSeriesSeasonInfo(_video.title);
    final activeInLineSeasonNum = hasInLineSeasons
        ? (_selectedInLineSeason ?? inLineSeasons.first.seasonNumber)
        : null;

    // Check if any episode in the current range has an authentic plot summary
    bool anyHasSummary = false;
    if (!isMovieVersions) {
      for (int idx = 0; idx < (end - start); idx++) {
        final visualIdx = start + idx;
        final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
        final originalIdx = activeIndices[posIdx];
        final ep = line.episodes[originalIdx];
        final epInfo = scraped.infoForRawIndex(originalIdx);
        final epNum = epInfo?.effectiveEpisodeNumber ?? (posIdx + 1);
        final (cleanTitle, _) = _parseEpisodeDisplay(ep.name, epNum);
        if (_resolveAuthenticEpisodeSummary(
          epNum,
          cleanTitle,
          scrapedInfo: epInfo,
        ).isNotEmpty) {
          anyHasSummary = true;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Dedicated Season Selector Header + Sort + All Episodes Grid trigger
        Row(
          children: [
            Flexible(
              child: GestureDetector(
                key: const ValueKey('season_picker_button'),
                onTap: _showSeasonPickerSheet,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        seasonLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (totalSeasons > 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x2EFFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '共$totalSeasons季',
                          style: const TextStyle(
                            color: Color(0xF2FFFFFF),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ] else if (_discoveringSeasons) ...[
                      const SizedBox(width: 6),
                      const CupertinoActivityIndicator(radius: 6.5),
                    ],
                    const SizedBox(width: 5),
                    const Icon(
                      CupertinoIcons.chevron_down,
                      color: Color(0xCCFFFFFF),
                      size: 15,
                    ),
                  ],
                ),
              ),
            ),
            if (!isMovieVersions) ...[
              const SizedBox(width: 5),
              GestureDetector(
                key: const ValueKey('detail_episode_scrape_button'),
                onTap: _openEpisodeScrapeSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _episodeScrapeOverride.enabled ||
                            !_episodeScrapeOverride.isDefault
                        ? const Color(0x400A84FF)
                        : const Color(0x24FFFFFF),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _episodeScrapeOverride.enabled ||
                              !_episodeScrapeOverride.isDefault
                          ? const Color(0x9964B5FF)
                          : const Color(0x30FFFFFF),
                      width: 0.6,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.sparkles,
                        color: _episodeScrapeOverride.enabled ||
                                !_episodeScrapeOverride.isDefault
                            ? const Color(0xFF8CC8FF)
                            : const Color(0xE6FFFFFF),
                        size: 12,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '刮削',
                        style: TextStyle(
                          color: _episodeScrapeOverride.enabled ||
                                  !_episodeScrapeOverride.isDefault
                              ? Colors.white
                              : const Color(0xE6FFFFFF),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_isIosDetail &&
                !_activeSite.isEffectivelyPrivate &&
                AiService.instance.isLabUnlocked) ...[
              const SizedBox(width: 5),
              GestureDetector(
                key: const ValueKey('detail-ai-lab-button'),
                onTap: () {
                  final epNum = (currentActiveEpIdx != null
                          ? currentActiveEpIdx + 1
                          : 1) +
                      _episodeScrapeOverride.episodeOffset;
                  unawaited(
                    showIosDetailAiLabSheet(
                      context,
                      title: _effectiveLookupTitle,
                      year: _effectiveLookupYear,
                      overview: _video.description,
                      genreOrRemarks: '${_video.tag} ${_video.remarks}'.trim(),
                      currentEpisodeNumber: epNum < 1 ? 1 : epNum,
                      currentLineEpisodes: line.episodes,
                      isMultiVersionMovie: isMovieVersions,
                      onApplyEpisodeOverride: (override, summary) async {
                        await widget.storage.setEpisodeScrapeOverride(
                          siteKey: _activeSite.key,
                          videoId: _video.id,
                          videoTitle: _video.title,
                          override: override,
                        );
                        if (!mounted) return;
                        setState(() {
                          _episodeScrapeOverride = override;
                          _selectedPage = 0;
                        });
                        _toast('AI 智能编排已生效：$summary');
                      },
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x388B5CF6),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0x88A78BFA),
                      width: 0.6,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.sparkles,
                        color: Color(0xFFD8B4FE),
                        size: 12,
                      ),
                      SizedBox(width: 3),
                      Text(
                        'AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(width: 5),
            GestureDetector(
              key: const ValueKey('detail-episode-sort-toggle'),
              onTap: () {
                final next = !_descending;
                if (!_isIosDetail) {
                  widget.storage.setEpisodesDescending(next);
                  setState(() {
                    _descending = next;
                    _selectedPage = 0;
                  });
                  return;
                }
                // Preserve the active browsing or playing episode across sort
                // inversion: compute its target season, 50-item page, and
                // page-local slot so both top circles and bottom cards land on
                // the episode immediately without manual pagination/scrolling.
                var nextSeason = _selectedInLineSeason;
                var nextPage = 0;
                var nextSlot = 0;
                final liveBrowsingIdx = _resolveBrowsingEpisodeIndexForLine(
                  line,
                  safeLineIdx,
                  activeIndices,
                );
                final anchorRawIdx = liveBrowsingIdx ?? currentActiveEpIdx;
                if (anchorRawIdx != null) {
                  final posInActive = activeIndices.indexOf(anchorRawIdx);
                  if (posInActive >= 0 && total > 0) {
                    final visualIdx =
                        next ? (total - 1 - posInActive) : posInActive;
                    nextPage = visualIdx ~/ CmsParser.episodePageSize;
                    nextSlot = visualIdx % CmsParser.episodePageSize;
                  }
                } else {
                  final resolved = _resolveSeasonPageAndSlotForPlayedEpisode(
                    video: _video,
                    lineIdx: safeLineIdx,
                    bookmark: bookmark,
                    descendingOverride: next,
                  );
                  if (resolved != null) {
                    nextSeason = resolved.inLineSeason;
                    nextPage = resolved.page;
                    nextSlot = resolved.slotInPage;
                  }
                }
                setState(() {
                  _descending = next;
                  _selectedInLineSeason = nextSeason;
                  _selectedPage = nextPage;
                });
                _scheduleAlignEpisodeStripsToSlot(nextSlot, animate: false);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x30FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _descending
                          ? CupertinoIcons.arrow_down
                          : CupertinoIcons.arrow_up,
                      color: const Color(0xE6FFFFFF),
                      size: 12,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _descending ? '倒序' : '正序',
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_isMacosDetail && !_activeSite.isEffectivelyPrivate) ...[
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: (_scrapeOverride?.hasEpisodeCalibration ?? false)
                    ? '集数已校准'
                    : '集数校准',
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    key: const ValueKey('mac-episodes-calibrate-btn'),
                    borderRadius: BorderRadius.circular(999),
                    focusColor: const Color(0x664C9AFF),
                    hoverColor: const Color(0x33FFFFFF),
                    onTap: () => _openSeriesScrapeSheet(initialTab: 1),
                    child: Ink(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: (_scrapeOverride?.hasEpisodeCalibration ?? false)
                            ? const Color(0x474C9AFF)
                            : const Color(0x24FFFFFF),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color:
                              (_scrapeOverride?.hasEpisodeCalibration ?? false)
                                  ? const Color(0x994C9AFF)
                                  : const Color(0x30FFFFFF),
                          width: 0.6,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.slider_horizontal_3,
                            color: (_scrapeOverride?.hasEpisodeCalibration ??
                                    false)
                                ? const Color(0xFF93C5FD)
                                : const Color(0xE6FFFFFF),
                            size: 12,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            (_scrapeOverride?.hasEpisodeCalibration ?? false)
                                ? '集数已校准'
                                : '集数校准',
                            style: TextStyle(
                              color: (_scrapeOverride?.hasEpisodeCalibration ??
                                      false)
                                  ? Colors.white
                                  : const Color(0xE6FFFFFF),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            SizedBox(width: _isIosDetail ? 5 : 8),
            GestureDetector(
              onTap: () => _showAllEpisodesGridSheet(bookmark),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x24FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x30FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.square_grid_2x2_fill,
                      color: Color(0xE6FFFFFF),
                      size: 12,
                    ),
                    const SizedBox(width: 3.5),
                    Text(
                      MediaQuery.sizeOf(context).width < 360
                          ? '全部($total)'
                          : (isMovieVersions ? '全部版本 ($total)' : '全部剧集 ($total)'),
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        // 1b. Direct Multi-Season Selector Strip (visible whenever >= 2 seasons exist)
        if (totalSeasons > 1) ...[
          const SizedBox(height: 11),
          SizedBox(
            height: 32,
            child: DesktopHorizontalScroller(
              controller: _seasonsScrollController,
              child: ListView.separated(
                controller: _seasonsScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: totalSeasons,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, sIdx) {
                if (hasInLineSeasons) {
                  final s = inLineSeasons[sIdx];
                  final isSelected = s.seasonNumber == activeInLineSeasonNum;
                  return Ios27Pressable(
                    key: ValueKey('season_pill_inline_${s.seasonNumber}'),
                    pressedScale: Ios27Spring.pressSwellScale,
                    borderRadius: 999,
                    onTap: () {
                      setState(() {
                        _selectedInLineSeason = s.seasonNumber;
                        _selectedPage = 0;
                      });
                    },
                    child: AnimatedContainer(
                      duration: Ios27ConcentricGeometry.isReduceMotion(ctx)
                          ? Ios27ConcentricGeometry.reducedMotionDuration
                          : Ios27Spring.snappy.nominalDuration,
                      curve: Ios27Spring.snappy.curve,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.white
                            : const Color(0x24FFFFFF),
                        borderRadius: BorderRadius.circular(999),
                        border: isSelected
                            ? null
                            : Border.all(
                                color: const Color(0x30FFFFFF),
                                width: 0.5,
                              ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${s.seasonLabel} (${s.episodeIndexes.length})',
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF121215)
                              : const Color(0xE6FFFFFF),
                          fontSize: 12.5,
                          fontWeight:
                              isSelected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }
                final opt = _relatedSeasons[sIdx];
                final isSelected = (opt.video.id == _video.id &&
                        opt.site.key == _activeSite.key) ||
                    opt.seasonNumber == curSeasonInfo.seasonNumber;
                return Ios27Pressable(
                  key: ValueKey('season_pill_${opt.seasonNumber}'),
                  pressedScale: Ios27Spring.pressSwellScale,
                  borderRadius: 999,
                  onTap: () => _switchToRelatedSeason(opt),
                  child: AnimatedContainer(
                    duration: Ios27ConcentricGeometry.isReduceMotion(ctx)
                        ? Ios27ConcentricGeometry.reducedMotionDuration
                        : Ios27Spring.snappy.nominalDuration,
                    curve: Ios27Spring.snappy.curve,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isSelected ? Colors.white : const Color(0x24FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                      border: isSelected
                          ? null
                          : Border.all(
                              color: const Color(0x30FFFFFF),
                              width: 0.5,
                            ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      opt.seasonLabel,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF121215)
                            : const Color(0xE6FFFFFF),
                        fontSize: 12.5,
                        fontWeight:
                            isSelected ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
        if (_lineUnavailableReason(line) case final lineReason?) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('detail-line-unavailable-banner'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x26FF9F0A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x4DFF9F0A), width: 0.6),
            ),
            child: Text(
              lineReason,
              style: const TextStyle(
                color: Color(0xFFFFD60A),
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 2. Quick Episode Number Strip (12 13 14 [15] 16 17 ...)
        SizedBox(
          key: const ValueKey('detail-quick-episodes-strip'),
          height: _isIosDetail ? 38 : 30,
          child: DesktopHorizontalScroller(
            controller: _quickEpisodesScrollController,
            child: ListView.separated(
              key: ValueKey(
                'detail-quick-episodes-list-$safeLineIdx-$safePage-$_descending',
              ),
              controller: _quickEpisodesScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              itemCount: end - start,
              separatorBuilder: (_, __) =>
                  SizedBox(width: _isIosDetail ? _kEpisodeCircleGap : 7),
              itemBuilder: (ctx, idx) {
              final visualIdx = start + idx;
              final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
              final originalIdx = activeIndices[posIdx];
              final ep = line.episodes[originalIdx];
              final epInfo = scraped.infoForRawIndex(originalIdx);
              final epScrape =
                  _scrapeResultForLine(line).byOriginalIndex[originalIdx];
              final pillLabel = isMovieVersions
                  ? (epInfo?.movieVersionLabel ?? '版本${posIdx + 1}')
                  : (epScrape.isSpecial
                        ? epScrape.displayLabel
                        : '${epScrape.resolvedEpisodeNumber ?? (posIdx + 1)}');
              final unavailReason = _episodeUnavailableReason(ep);
              final isUnavailable = unavailReason != null;
              final isCurrent = !isUnavailable &&
                  currentActiveEpIdx != null &&
                  originalIdx == currentActiveEpIdx;
              final labelText = isMovieVersions
                  ? (epInfo?.movieVersionLabel ?? '版本${posIdx + 1}')
                  : (epInfo?.shortPillLabel ?? '${posIdx + 1}');

              Widget buildCircleBox(BuildContext boxCtx, bool isBrowsingOnly) {
                final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(boxCtx);
                return AnimatedContainer(
                  key: ValueKey('ep_circle_box_${safeLineIdx}_$originalIdx'),
                  duration: reduceMotion
                      ? Ios27ConcentricGeometry.reducedMotionDuration
                      : Ios27Spring.snappy.nominalDuration,
                  curve: reduceMotion ? Curves.linear : Ios27Spring.snappy.curve,
                  constraints: BoxConstraints(
                    minWidth: _isIosDetail ? _kEpisodeCircleMinWidth : 34,
                    minHeight: _isIosDetail ? 34 : 30,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? Colors.white
                        : (isBrowsingOnly
                            ? const Color(0x36FFFFFF)
                            : const Color(0x24FFFFFF)),
                    borderRadius: BorderRadius.circular(999),
                    border: isCurrent
                        ? null
                        : Border.all(
                            color: isBrowsingOnly
                                ? Colors.white
                                : const Color(0x28FFFFFF),
                            width: isBrowsingOnly ? 1.8 : 0.6,
                          ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _isIosDetail ? labelText : pillLabel,
                    style: TextStyle(
                      color: isCurrent
                          ? const Color(0xFF121215)
                          : (isBrowsingOnly
                              ? Colors.white
                              : const Color(0xD9FFFFFF)),
                      fontSize: 12.5,
                      fontWeight: (isCurrent || isBrowsingOnly)
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                );
              }

              final Widget pill;
              if (_isIosDetail) {
                final slotKey = _circleSlotKeys.putIfAbsent(idx, GlobalKey.new);
                pill = KeyedSubtree(
                  key: slotKey,
                  child: ValueListenableBuilder(
                    valueListenable: _browsingEpisodeNotifier,
                    builder: (boxCtx, _, __) {
                      final liveBrowsingIdx = _resolveBrowsingEpisodeIndexForLine(
                        line,
                        safeLineIdx,
                        activeIndices,
                      );
                      final isBrowsingOnly = !isCurrent &&
                          liveBrowsingIdx != null &&
                          originalIdx == liveBrowsingIdx;
                      return Semantics(
                        button: true,
                        selected: isCurrent,
                        label: isCurrent
                            ? '第$labelText集，正在播放'
                            : (isBrowsingOnly
                                ? '第$labelText集，当前预览'
                                : '定位到第$labelText集卡片'),
                        child: GestureDetector(
                          key: ValueKey('ep_circle_${safeLineIdx}_$originalIdx'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _pendingPostPopSync = false;
                            _browsingEpisode = (
                              lineId: line.id,
                              lineName: line.name,
                              episodeUrl: ep.url,
                              episodeName: ep.name,
                              originalIndex: originalIdx,
                            );
                            _scrollEpisodeCardsToSlot(idx);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: buildCircleBox(boxCtx, isBrowsingOnly),
                          ),
                        ),
                      );
                    },
                  ),
                );
              } else {
                pill = Ios27Pressable(
                  key: ValueKey('ep_circle_${safeLineIdx}_$originalIdx'),
                  pressedScale: Ios27Spring.pressSwellScale,
                  borderRadius: 999,
                  onTap: () => _openPlayer(safeLineIdx, originalIdx),
                  child: buildCircleBox(ctx, false),
                );
              }
              return isUnavailable ? Opacity(opacity: 0.45, child: pill) : pill;
            },
          ),
        ),
      ),
      const SizedBox(height: 14),

        // 3. Horizontal 16:9 Landscape Episode Preview Cards with Authentic Scene Stills
        //    and Authentic Per-Episode Plot Synopsis
        SizedBox(
          key: const ValueKey('detail-episode-cards-strip'),
          height: anyHasSummary ? 222 : 186,
          child: DesktopHorizontalScroller(
            controller: _previewCardsScrollController,
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (notification) {
                if (notification.metrics.axis == Axis.horizontal) {
                  _handleEpisodeCardsScrollSettled(
                    line: line,
                    activeIndices: activeIndices,
                    pageStart: start,
                    pageLen: end - start,
                  );
                }
                return false;
              },
              child: ListView.separated(
                key: ValueKey(
                  'detail-episode-cards-list-$safeLineIdx-$safePage-$_descending',
                ),
                controller: _previewCardsScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                itemCount: end - start,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: _kEpisodeCardGap),
                itemBuilder: (ctx, idx) {
              final visualIdx = start + idx;
              final posIdx = _descending ? (total - 1 - visualIdx) : visualIdx;
              final originalIdx = activeIndices[posIdx];
              final ep = line.episodes[originalIdx];
              final epInfo = scraped.infoForRawIndex(originalIdx);
              final epNum = epInfo?.effectiveEpisodeNumber ?? (posIdx + 1);
              final epScrape =
                  _scrapeResultForLine(line).byOriginalIndex[originalIdx];
              final resolvedEpNum = epScrape.resolvedEpisodeNumber;
              final realEpNum = resolvedEpNum ?? (posIdx + 1);
              final unavailReason = _episodeUnavailableReason(ep);
              final isUnavailable = unavailReason != null;
              final isCurrent = !isUnavailable &&
                  currentActiveEpIdx != null &&
                  originalIdx == currentActiveEpIdx;
              final (cleanTitle, parsedBadge) =
                  _parseEpisodeDisplay(
                    ep.name,
                    _isIosDetail ? epNum : realEpNum,
                  );
              final specBadge = isUnavailable
                  ? '不可解析'
                  : (_isIosDetail
                      ? (parsedBadge ?? epInfo?.qualityBadge)
                      : parsedBadge);
              final unitLabel = isMovieVersions
                  ? '片源版本'
                  : (_isIosDetail
                        ? ((epInfo != null && epInfo.isSpecial)
                              ? (epInfo.specialTag ?? '特辑')
                              : (_isVarietyShow ? '第$epNum期' : '第$epNum集'))
                        : (epScrape.needsConfirmation
                              ? '待确认'
                              : (epScrape.isSpecial
                                    ? epScrape.displayLabel
                                    : (epScrape.seasonNumber != null &&
                                            epScrape.seasonNumber! > 0 &&
                                            resolvedEpNum != null
                                        ? '第${epScrape.seasonNumber}季 第$resolvedEpNum集'
                                        : (_isVarietyShow
                                            ? '第$realEpNum期'
                                            : '第$realEpNum集')))));
              final subMeta = isUnavailable
                  ? unavailReason
                  : [
                      if (_effectiveLookupYear.trim().isNotEmpty)
                        _effectiveLookupYear.trim(),
                      unitLabel,
                      if (specBadge != null) specBadge,
                    ].join(' · ');
              final headline = isMovieVersions
                  ? (cleanTitle.trim().isNotEmpty
                        ? cleanTitle.trim()
                        : (epInfo?.movieVersionLabel ?? '正片版本 ${posIdx + 1}'))
                  : (_isIosDetail
                        ? _formatEpisodeCardHeadline(
                            cleanTitle,
                            epNum,
                            scrapedInfo: epInfo,
                          )
                        : (epScrape.needsConfirmation
                              ? (ep.name.trim().isNotEmpty
                                    ? ep.name.trim()
                                    : '待确认')
                              : _formatEpisodeCardHeadline(
                                  cleanTitle,
                                  realEpNum,
                                )));
              final epDesc = isMovieVersions
                  ? ''
                  : (_isIosDetail
                        ? _resolveAuthenticEpisodeSummary(
                            epNum,
                            cleanTitle,
                            scrapedInfo: epInfo,
                          )
                        : (epScrape.needsConfirmation
                              ? ''
                              : _resolveAuthenticEpisodeSummary(
                                  realEpNum,
                                  cleanTitle,
                                )));

              final card = RepaintBoundary(
                child: GestureDetector(
                  key: ValueKey('ep_card_${safeLineIdx}_$originalIdx'),
                  onTap: () => _openPlayer(safeLineIdx, originalIdx),
                child: SizedBox(
                  width: 226,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x4D000000),
                              blurRadius: 12,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        child: SizedBox(
                          height: 126,
                          width: 226,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                EpisodeStillImage(
                                  seriesTitle: _activeSite.isEffectivelyPrivate
                                      ? ''
                                      : (_isIosDetail
                                            ? _effectiveScrapeTitle
                                            : _effectiveLookupTitle),
                                  year: _activeSite.isEffectivelyPrivate
                                      ? ''
                                      : (_isIosDetail
                                            ? _video.year
                                            : _effectiveLookupYear),
                                  episodeIndex: _isIosDetail
                                      ? math.max(0, epNum - 1)
                                      : posIdx,
                                  realEpisodeNumber:
                                      _isIosDetail ? epNum : realEpNum,
                                  wantMotionComic: _effectiveWantMotionComic,
                                  fallbackPosterUrl: _isIosDetail
                                      ? _video.poster
                                      : _effectivePosterUrl,
                                  isPrivate: _activeSite.isEffectivelyPrivate,
                                  placeholder: _posterPlaceholder(
                                    _resolveBaseAmbientColor(),
                                  ),
                                ),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x14000000),
                                        Color(0x84000000),
                                      ],
                                    ),
                                  ),
                                ),
                                if (specBadge != null)
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xB3121215),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: const Color(0x40FFFFFF),
                                          width: 0.5,
                                        ),
                                      ),
                                      child: Text(
                                        specBadge,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  left: 9,
                                  bottom: 8,
                                  right: 9,
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isCurrent
                                              ? Colors.white
                                              : const Color(0xA6121215),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              CupertinoIcons.play_fill,
                                              size: 10,
                                              color: isCurrent
                                                  ? const Color(0xFF121215)
                                                  : Colors.white,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              isMovieVersions
                                                  ? (epInfo?.movieVersionLabel ??
                                                      '版本 ${posIdx + 1}')
                                                  : (_isIosDetail
                                                        ? (epInfo?.badgeLabel ??
                                                            'E${(posIdx + 1).toString().padLeft(2, '0')}')
                                                        : (epScrape.needsConfirmation
                                                            ? '待确认'
                                                            : (epScrape.isSpecial
                                                                ? epScrape.displayLabel
                                                                : (epScrape.seasonNumber !=
                                                                            null &&
                                                                        epScrape.seasonNumber! >
                                                                            0 &&
                                                                        resolvedEpNum !=
                                                                            null
                                                                    ? epScrape
                                                                        .formattedSeasonEpisode
                                                                    : 'E${realEpNum.toString().padLeft(2, '0')}')))),
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? const Color(0xFF121215)
                                                    : Colors.white,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      Flexible(
                                        child: Text(
                                          line.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xD9FFFFFF),
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Foreground rounded border overlay (localized rebuild via ValueListenableBuilder)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: ValueListenableBuilder(
                                      valueListenable: _browsingEpisodeNotifier,
                                      builder: (_, __, ___) {
                                        final liveBrowsingIdx = _isIosDetail
                                            ? _resolveBrowsingEpisodeIndexForLine(
                                                line,
                                                safeLineIdx,
                                                activeIndices,
                                              )
                                            : null;
                                        final liveBrowsing = _isIosDetail &&
                                            !isCurrent &&
                                            liveBrowsingIdx != null &&
                                            originalIdx == liveBrowsingIdx;
                                        return DecoratedBox(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(14),
                                            border: Border.all(
                                              color: isCurrent
                                                  ? Colors.white
                                                  : (liveBrowsing
                                                      ? const Color(0xB3FFFFFF)
                                                      : const Color(0x33FFFFFF)),
                                              width: isCurrent
                                                  ? 2.0
                                                  : (liveBrowsing ? 1.5 : 0.7),
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
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subMeta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0x99FFFFFF),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (epDesc.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          epDesc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xB3FFFFFF),
                            fontSize: 11.5,
                            height: 1.34,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ),
              );
              return isUnavailable ? Opacity(opacity: 0.48, child: card) : card;
            },
          ),
        ),
        ),
      ),

        // 4. Range Capsules (1 · 50, 51 · 100 ...; reversed when descending)
        if (pageCount > 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 34,
            child: DesktopHorizontalScroller(
              controller: _pageRangeScrollController,
              child: ListView.separated(
                controller: _pageRangeScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: pageCount,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, p) {
                final pStart = p * CmsParser.episodePageSize + 1;
                final pEnd =
                    ((p + 1) * CmsParser.episodePageSize).clamp(1, total);
                final rangeLabel = _descending
                    ? '${total - pStart + 1} · ${math.max(1, total - pEnd + 1)}'
                    : '$pStart · $pEnd';
                final selected = p == safePage;
                return GestureDetector(
                  key: ValueKey('ep_page_pill_$p'),
                  onTap: () {
                    setState(() => _selectedPage = p);
                    if (_isIosDetail) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (_quickEpisodesScrollController.hasClients) {
                          _quickEpisodesScrollController.jumpTo(0.0);
                        }
                        if (_previewCardsScrollController.hasClients) {
                          _programmaticCardScrollGuard++;
                          _previewCardsScrollController.jumpTo(0.0);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_programmaticCardScrollGuard > 0) {
                              _programmaticCardScrollGuard--;
                            }
                          });
                        }
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : const Color(0x24FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      rangeLabel,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFF121215)
                            : const Color(0xD9FFFFFF),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
      ],
    );
  }

  /// Wide desktop / iPad / phone landscape immersive cinema showcase layout:
  /// - Full-screen `Positioned.fill` backdrop (zero internal 66%-width vertical edge
  ///   or `heroStageHeight` horizontal edge!)
  /// - Left-to-right and top-to-bottom solid-color gradients placed ON TOP OF the
  ///   blurred backdrop so the backdrop melts seamlessly into `bgColor`
  Widget _buildWideDesktopScreen(BuildContext context) {
    final targetBg = _resolveBaseAmbientColor();
    final bookmark = _findBookmark();
    final size = MediaQuery.sizeOf(context);
    final safePad = MediaQuery.paddingOf(context);
    final isMac = _isMacosDetail;
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final isLightMode = !ApplePalette.isDarkOf(context);
    final topPad = math.max(
      safePad.top,
      isMac ? 36.0 : 0.0,
    );
    final horizontalPad = (size.width * 0.045).clamp(24.0, 56.0);
    final compactWideH = size.height < 520;
    final heroStageHeight = compactWideH
        ? (size.height * 0.68).clamp(290.0, 360.0)
        : (size.height * 0.58).clamp(380.0, 500.0);
    final posterCardW = compactWideH
        ? (heroStageHeight * 0.43).clamp(132.0, 176.0)
        : (heroStageHeight * 0.48).clamp(168.0, 224.0);
    final showFramedPortraitCard = !isMac || !_macHeroHasLandscape;

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: targetBg, end: targetBg),
      duration: reduceMotion
          ? Ios27ConcentricGeometry.reducedMotionDuration
          : Ios27Spring.smooth.nominalDuration,
      curve: Ios27Spring.smooth.curve,
      builder: (context, animatedBg, _) {
        final bgColor = animatedBg ?? targetBg;
        return Scaffold(
          backgroundColor: bgColor,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Unified Solid Ambient Canvas Matching Poster Edge Color
              ColoredBox(color: bgColor),

              // 2. Full-Screen Widescreen Backdrop (`Positioned.fill` with `TileMode.clamp`
              //    eliminates vertical/horizontal seams and right-edge blur streaks)
              Positioned.fill(
                child: isWindowsDesktopUi
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          RepaintBoundary(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: 2.2,
                                    sigmaY: 2.2,
                                    tileMode: TileMode.clamp,
                                  ),
                                  child: PosterImage(
                                    url: _effectivePosterUrl,
                                    title: _isPrivatePosterContext
                                        ? ''
                                        : _effectiveLookupTitle,
                                    year: _isPrivatePosterContext
                                        ? ''
                                        : _effectiveLookupYear,
                                    isPrivate: _isPrivatePosterContext,
                                    fit: BoxFit.cover,
                                    alignment: const Alignment(0.35, -0.2),
                                    forBackdrop: true,
                                    onBytesLoaded: _updateAmbientFromBytes,
                                    placeholder: _posterPlaceholder(bgColor),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        bgColor,
                                        bgColor.withValues(alpha: 0.94),
                                        bgColor.withValues(alpha: 0.46),
                                        bgColor.withValues(alpha: 0.14),
                                        bgColor.withValues(alpha: 0.05),
                                      ],
                                      stops: const [0.0, 0.24, 0.46, 0.72, 1.0],
                                    ),
                                  ),
                                ),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        bgColor.withValues(alpha: 0.56),
                                        bgColor.withValues(alpha: 0.04),
                                        bgColor.withValues(alpha: 0.32),
                                        bgColor.withValues(alpha: 0.90),
                                        bgColor,
                                      ],
                                      stops: const [0.0, 0.18, 0.58, 0.80, 1.0],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ValueListenableBuilder<double>(
                            valueListenable: _scrollOffset,
                            builder: (context, offset, _) {
                              final veil = reduceMotion
                                  ? 0.0
                                  : (offset / 320.0).clamp(0.0, 1.0) * 0.52;
                              if (veil <= 0.01) return const SizedBox.shrink();
                              return ColoredBox(
                                color: bgColor.withValues(alpha: veil),
                              );
                            },
                          ),
                        ],
                      )
                    : ValueListenableBuilder<double>(
                        valueListenable: _scrollOffset,
                        builder: (context, offset, child) {
                          final progress = reduceMotion
                              ? 0.0
                              : (offset / 320.0).clamp(0.0, 1.0);
                          final baseBlur =
                              (isMac && _macHeroHasLandscape) ? 0.0 : 1.6;
                          final blurSigma =
                              reduceMotion ? baseBlur : (baseBlur + progress * 7.5);
                          final scrollVeilAlpha = progress * 0.36;

                          final Widget backdropImage = blurSigma > 0.15
                              ? ImageFiltered(
                                  imageFilter: ImageFilter.blur(
                                    sigmaX: blurSigma,
                                    sigmaY: blurSigma,
                                    tileMode: TileMode.clamp,
                                  ),
                                  child: child!,
                                )
                              : child!;

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              backdropImage,
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: isMac && _macHeroHasLandscape
                                        ? [
                                            bgColor.withValues(alpha: 0.92),
                                            bgColor.withValues(alpha: 0.68),
                                            bgColor.withValues(alpha: 0.24),
                                            bgColor.withValues(alpha: 0.06),
                                            Colors.transparent,
                                          ]
                                        : [
                                            bgColor,
                                            bgColor.withValues(alpha: 0.94),
                                            bgColor.withValues(alpha: 0.46),
                                            bgColor.withValues(alpha: 0.14),
                                            bgColor.withValues(alpha: 0.05),
                                          ],
                                    stops: const [0.0, 0.24, 0.46, 0.72, 1.0],
                                  ),
                                ),
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      bgColor.withValues(
                                        alpha: (isMac && isLightMode) ? 0.32 : 0.56,
                                      ),
                                      bgColor.withValues(alpha: 0.04),
                                      bgColor.withValues(alpha: 0.32),
                                      bgColor.withValues(alpha: 0.90),
                                      bgColor,
                                    ],
                                    stops: const [0.0, 0.18, 0.58, 0.80, 1.0],
                                  ),
                                ),
                              ),
                              if (scrollVeilAlpha > 0.01)
                                Positioned.fill(
                                  child: ColoredBox(
                                    color: bgColor.withValues(
                                      alpha: scrollVeilAlpha,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                        child: isMac
                            ? LandscapePosterImage(
                                key: const ValueKey('mac-detail-backdrop'),
                                url: _effectivePosterUrl,
                                title: _activeSite.isEffectivelyPrivate
                                    ? ''
                                    : _effectiveLookupTitle,
                                year: _activeSite.isEffectivelyPrivate
                                    ? ''
                                    : _effectiveLookupYear,
                                preferredBackdropUrl:
                                    _activeSite.isEffectivelyPrivate
                                        ? ''
                                        : _effectiveBackdropUrl,
                                preferredDoubanId:
                                    _activeSite.isEffectivelyPrivate
                                        ? ''
                                        : _effectiveDoubanId,
                                preferredDoubanIsTv: !_video.tag.contains('电影') &&
                                    (_video.lines.isEmpty ||
                                        _video.lines.first.episodes.length > 1),
                                wantMotionComic: _effectiveWantMotionComic,
                                allowExternalLookup:
                                    !_activeSite.isEffectivelyPrivate,
                                isPrivate: _activeSite.isEffectivelyPrivate,
                                blurPortraitFallback: true,
                                showRightFramedPortraitFallback: false,
                                alignment: const Alignment(0.25, -0.2),
                                onBytesLoaded: _updateAmbientFromBytes,
                                onLandscapeStatusChanged: (isLand) {
                                  if (mounted &&
                                      _macHeroHasLandscape != isLand) {
                                    setState(
                                      () => _macHeroHasLandscape = isLand,
                                    );
                                  }
                                },
                                placeholder: _posterPlaceholder(bgColor),
                              )
                            : PosterImage(
                                url: _effectivePosterUrl,
                                title: _isPrivatePosterContext
                                    ? ''
                                    : _effectiveLookupTitle,
                                year: _isPrivatePosterContext
                                    ? ''
                                    : _effectiveLookupYear,
                                isPrivate: _isPrivatePosterContext,
                                fit: BoxFit.cover,
                                alignment: const Alignment(0.35, -0.2),
                                forBackdrop: true,
                                onBytesLoaded: _updateAmbientFromBytes,
                                placeholder: _posterPlaceholder(bgColor),
                              ),
                      ),
              ),

              // 3. Main Scrollable Widescreen Foreground Content
              MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleDetailScrollNotification,
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.only(bottom: 44),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: heroStageHeight + topPad,
                          ),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              horizontalPad + safePad.left,
                              topPad + 58,
                              horizontalPad + safePad.right,
                              18,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (showFramedPortraitCard) ...[
                                  SizedBox(
                                    key: const ValueKey(
                                      'mac-detail-portrait-poster-card',
                                    ),
                                    width: posterCardW,
                                    child: _buildPosterCard(bgColor),
                                  ),
                                  SizedBox(width: compactWideH ? 20 : 28),
                                ],
                                Expanded(
                                  child: _buildWideHeroShowcaseColumn(bookmark),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: horizontalPad),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              CastAvatarSection(
                                title: _effectiveLookupTitle.isNotEmpty
                                    ? _effectiveLookupTitle
                                    : _video.title,
                                actorRaw: _video.actor,
                                year: _effectiveLookupYear,
                                doubanId: _effectiveDoubanId,
                                wantMotionComic: _effectiveWantMotionComic,
                                allowExternalLookup:
                                    !_activeSite.isEffectivelyPrivate,
                                forceDark: true,
                                padding: EdgeInsets.zero,
                              ),
                              const SizedBox(height: 18),
                              if (!_loading && _video.sourceWarnings.isNotEmpty)
                                _buildSourceWarningsSection(),
                              if (!_loading &&
                                  _activeSite.playbackHint.isNotEmpty &&
                                  _configuredParses.isEmpty)
                                _buildPlaybackHintBanner(),
                              if (_loading)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 32),
                                  child: Center(
                                    child:
                                        CupertinoActivityIndicator(radius: 14),
                                  ),
                                )
                              else if (_curatedUnavailableMessage != null)
                                _buildCuratedUnavailableCard()
                              else if (_error != null)
                                _buildDetailError()
                              else if (_video.lines.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Text(
                                    '当前片源未提供可播放剧集，请重试或手动切换片源',
                                    style: TextStyle(
                                      color: AppleColors.labelSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                )
                              else
                                _buildPortraitEpisodesSection(bookmark),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              _buildDetailPullRefreshPill(topPad),

              // 4. Floating Liquid Glass Top Navigation Bar (Back on Left, Source Picker + Download/Favorite on Right)
              Positioned(
                top: topPad + 10,
                left: horizontalPad + safePad.left,
                right: horizontalPad + safePad.right,
                child: Theme(
                  data: _isMacosDetail
                      ? Theme.of(context).copyWith(brightness: Brightness.dark)
                      : Theme.of(context),
                  child: Row(
                    children: [
                      _buildFloatingGlassCircleButton(
                        icon: CupertinoIcons.chevron_back,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      _buildFloatingSourceButton(),
                      const SizedBox(width: 10),
                      _buildFloatingTopRightPill(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPosterCard(Color bgColor) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        key: _transitionPosterKey,
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterImage(
                url: _effectivePosterUrl,
                title: _isPrivatePosterContext
                    ? ''
                    : _effectiveLookupTitle,
                year: _isPrivatePosterContext
                    ? ''
                    : _effectiveLookupYear,
                isPrivate: _isPrivatePosterContext,
                highRes: !_isPrivatePosterContext,
                strictHighRes: !_isPrivatePosterContext,
                onBytesLoaded: _onPosterCardBytesLoaded,
                placeholder: _posterPlaceholder(bgColor),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0x4DFFFFFF),
                        width: 0.8,
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

  Widget _posterPlaceholder(Color bgColor) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(bgColor, const Color(0xFF283448), 0.35)!,
            bgColor,
          ],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film,
        color: AppleColors.labelTertiary,
        size: 38,
      ),
    );
  }

  Widget _buildWideHeroShowcaseColumn(WatchHistoryEntry? bookmark) {
    final safeLineIdx = _video.lines.isEmpty
        ? 0
        : _selectedLine.clamp(0, _video.lines.length - 1);
    final epCount = _video.lines.isEmpty
        ? 0
        : _video.lines[safeLineIdx].episodes.length;
    final pills = <String>[
      if (_effectiveLookupYear.trim().isNotEmpty) _effectiveLookupYear.trim(),
      if (_video.area.trim().isNotEmpty) _video.area.trim(),
      if (_video.tag.trim().isNotEmpty) _video.tag.trim(),
      if (_video.remarks.trim().isNotEmpty)
        _video.remarks.trim()
      else if (epCount > 1)
        '共$epCount集',
    ];
    final desc = _effectiveSeriesSynopsis();
    final cast = _video.actor.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            height: 1.15,
            shadows: [
              Shadow(
                color: Color(0xB3000000),
                blurRadius: 18,
                offset: Offset(0, 4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tag in pills.take(4))
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x38FFFFFF),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  tag,
                  style: const TextStyle(
                    color: Color(0xF2FFFFFF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _buildRatingsAndSiteWrap(alignment: WrapAlignment.start),
        if (!OhosRuntime.isOhos) ...[
          Builder(
            builder: (_) {
              final activeLine = _video.lines.isEmpty
                  ? null
                  : _video
                      .lines[_selectedLine.clamp(0, _video.lines.length - 1)];
              final specBadges = _specBadgesForHero(activeLine);
              if (specBadges.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: MediaBadgeRow(
                  badges: specBadges,
                  maxBadges: 5,
                  alignment: WrapAlignment.start,
                ),
              );
            },
          ),
        ],
        if (_isMacosDetail && !_activeSite.isEffectivelyPrivate) ...[
          const SizedBox(height: 10),
          _buildMacScrapeBar(alignment: WrapAlignment.start),
        ],
        if (desc.isNotEmpty || cast.isNotEmpty) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (desc.isNotEmpty)
                    Text(
                      desc,
                      maxLines: _synopsisExpanded ? 8 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xE0FFFFFF),
                        fontSize: 13.5,
                        height: 1.52,
                      ),
                    ),
                  if (cast.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '演职员：$cast',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xA6FFFFFF),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _buildPortraitActionRow(bookmark),
        ),
        if (bookmark != null) ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _buildPortraitBookmarkProgress(bookmark),
          ),
        ],
      ],
    );
  }

  /// macOS series scrape & episode calibration toolbar (hidden for private sources).
  Widget _buildMacScrapeBar({required WrapAlignment alignment}) {
    final ov = _scrapeOverride;
    final hasWorkBinding = ov?.hasWorkBinding ?? false;
    final hasEpCalib = ov?.hasEpisodeCalibration ?? false;
    final calibrated = hasWorkBinding || hasEpCalib;
    final statusParts = <String>[];
    if (hasWorkBinding) {
      final t = ov!.matchedTitle.trim();
      final y = ov.matchedYear.trim();
      if (t.isNotEmpty) {
        statusParts.add(y.isNotEmpty ? '$t ($y)' : t);
      }
      if (ov.isMotionComic) {
        statusParts.add('动态漫画');
      }
    }
    if (hasEpCalib) {
      if (ov!.episodeOffset != 0) {
        final sign = ov.episodeOffset > 0 ? '+' : '';
        statusParts.add('偏移 $sign${ov.episodeOffset}');
      }
      if (ov.hideSpecials) {
        statusParts.add('隐藏特别篇');
      }
      final manualCount =
          ov.episodeCalibrations.length + ov.episodeNumberOverrides.length;
      if (manualCount > 0) {
        statusParts.add('手动 $manualCount 集');
      }
    }

    Widget pill({
      required Key key,
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(999),
            focusColor: const Color(0x664C9AFF),
            hoverColor: const Color(0x33FFFFFF),
            onTap: onTap,
            child: Ink(
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0x524C9AFF)
                    : const Color(0x2BFFFFFF),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? const Color(0xB37BB4FF)
                      : const Color(0x3DFFFFFF),
                  width: 0.7,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 13,
                    color: selected ? const Color(0xFFBFE0FF) : Colors.white,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(
      alignment: alignment,
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        pill(
          key: const ValueKey('mac-detail-scrape-btn'),
          icon: CupertinoIcons.sparkles,
          label: calibrated ? '刮削匹配 · 已校准' : '刮削匹配',
          selected: calibrated,
          onTap: () => _openSeriesScrapeSheet(initialTab: 0),
        ),
        pill(
          key: const ValueKey('mac-detail-calibrate-btn'),
          icon: CupertinoIcons.slider_horizontal_3,
          label: hasEpCalib ? '集数已校准' : '集数校准',
          selected: hasEpCalib,
          onTap: () => _openSeriesScrapeSheet(initialTab: 1),
        ),
        if (statusParts.isNotEmpty)
          Container(
            key: const ValueKey('mac-detail-scrape-status-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
            decoration: BoxDecoration(
              color: const Color(0x381D4ED8),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x8060A5FA),
                width: 0.65,
              ),
            ),
            child: Text(
              statusParts.join(' · '),
              style: const TextStyle(
                color: Color(0xFFE0F2FE),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

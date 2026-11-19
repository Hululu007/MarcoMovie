import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors, Material, MaterialType;
import 'package:flutter/services.dart';

import '../core/cms_client.dart';
import '../core/csp_bridge.dart';
import '../core/models.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'desktop_horizontal_scroller.dart';
import 'ios_liquid_glass.dart';
import 'poster_image.dart';
import 'source_verification_dialog.dart';

/// A single matched video entry from one source inside an [AggregatedSearchGroup].
class SearchSourceMatch {
  final CmsSite site;
  final CmsVideo video;
  final String siteKey;
  final String sourceLabel;
  final bool isNetdisk;
  final bool isPluginOrGateway;

  const SearchSourceMatch({
    required this.site,
    required this.video,
    required this.siteKey,
    required this.sourceLabel,
    required this.isNetdisk,
    required this.isPluginOrGateway,
  });
}

/// Smartly merged cross-source search result representing one distinct movie/series
/// matched across one or more sources.
class AggregatedSearchGroup {
  final String normalizedKey;
  final String displayTitle;
  final String poster;
  final String remarks;
  final String year;
  final String area;
  final String actor;
  final String tag;
  final double? doubanScore;
  final int? rtScore;
  final List<SearchSourceMatch> matches;

  const AggregatedSearchGroup({
    required this.normalizedKey,
    required this.displayTitle,
    required this.poster,
    required this.remarks,
    required this.year,
    required this.area,
    required this.actor,
    required this.tag,
    required this.doubanScore,
    required this.rtScore,
    required this.matches,
  });

  SearchSourceMatch get primaryMatch => matches.first;
}

final RegExp _searchEpisodeSuffixPattern = RegExp(
  r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
);
final RegExp _searchQualityTokenPattern = RegExp(
  r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|DV|REMUX)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _searchAudioTailPattern = RegExp(
  r'[\s\-_]*(?:国语|粤语|中字|双语|超清|蓝光|原盘|未删减版?|导演剪辑版?|完整版|纯享版)\s*$',
);
final RegExp _searchKeyStripPattern = RegExp(
  r'''[\s\-_—–:：,，.。!！?？'"“”‘’()（）\[\]【】《》<>~/\\|]+''',
);

/// Cleans noisy quality/episode/channel tags from a raw search title while
/// preserving sequel digits (`庆余年2`, `斗罗大陆第二季`) and distinct spin-offs
/// (`兰香如故·花胜秋宴`).
String cleanSearchDisplayTitle(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  var s = CspBridge.cleanNetdiskSearchTitle(trimmed);
  s = s
      .replaceAll(_searchEpisodeSuffixPattern, '')
      .replaceAll(_searchQualityTokenPattern, '')
      .replaceAll(_searchAudioTailPattern, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.isEmpty ? trimmed : s;
}

/// Converts a display/raw title into a canonical grouping key.
/// Preserves sequel numbers and `·` middle-dot spin-off qualifiers so distinct
/// titles are never merged erroneously.
String normalizeSearchGroupTitle(String raw) {
  final cleaned = cleanSearchDisplayTitle(raw);
  if (cleaned.isEmpty) return '';
  final buf = StringBuffer();
  for (final rune in cleaned.runes) {
    // Convert full-width ASCII (`！`..`～`) to standard half-width ASCII.
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buf.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buf.write(' ');
    } else if (rune == 0x30FB || rune == 0x2022 || rune == 0x2219) {
      buf.write('·');
    } else {
      buf.writeCharCode(rune);
    }
  }
  final normalized = buf
      .toString()
      .toLowerCase()
      .replaceAll(_searchKeyStripPattern, '')
      .trim();
  return normalized.isEmpty ? cleaned.toLowerCase() : normalized;
}

bool _isLikelyNetdiskSource(CmsSite site) {
  if (CspBridge.isNetdiskSite(site)) return true;
  final name = site.name.toLowerCase();
  return name.contains('4k') ||
      name.contains('夸克') ||
      name.contains('网盘') ||
      name.contains('云盘') ||
      name.contains('盘') ||
      name.contains('115') ||
      name.contains('uc');
}

bool _isUsableSearchPoster(String url) {
  final u = url.trim().toLowerCase();
  if (u.isEmpty) return false;
  if (u.startsWith('emby://')) return true;
  if (!u.startsWith('http://') && !u.startsWith('https://')) return false;
  return !u.contains('nopic') &&
      !u.contains('no_pic') &&
      !u.contains('default.jpg') &&
      !u.contains('placeholder') &&
      !u.contains('/personage/') &&
      !u.contains('/avatar/');
}

int _remarksRichness(String remarks) {
  final r = remarks.trim();
  if (r.isEmpty) return 0;
  var score = 1;
  final lower = r.toLowerCase();
  if (lower.contains('4k') || lower.contains('2160') || lower.contains('hdr')) {
    score += 4;
  }
  if (r.contains('全') || r.contains('完结') || r.contains('更新')) {
    score += 3;
  }
  if (lower.contains('1080') || lower.contains('hd') || lower.contains('bd')) {
    score += 2;
  }
  return score;
}

class _GroupBucket {
  final String normalizedKey;
  final int firstSeenIndex;
  final List<SearchSourceMatch> matches = <SearchSourceMatch>[];
  final Set<String> seenIdentities = <String>{};

  _GroupBucket({
    required this.normalizedKey,
    required this.firstSeenIndex,
  });
}

/// Aggregates flat cross-site search results into distinct cinema groups,
/// deduplicating per-source duplicates, picking the richest metadata/poster,
/// and ranking exact matches and multi-source hits first.
List<AggregatedSearchGroup> aggregateSearchResults({
  required List<(CmsSite, CmsVideo)> results,
  required String query,
  required String Function(CmsSite site) sourceLabelOf,
  String preferredSiteKey = '',
}) {
  if (results.isEmpty) return const <AggregatedSearchGroup>[];

  final buckets = <String, _GroupBucket>{};
  for (var i = 0; i < results.length; i++) {
    final (site, video) = results[i];
    final key = normalizeSearchGroupTitle(video.title);
    final effectiveKey = key.isNotEmpty
        ? key
        : '${site.subscriptionId}:${site.key}:${video.id}:$i';
    final bucket = buckets.putIfAbsent(
      effectiveKey,
      () => _GroupBucket(normalizedKey: effectiveKey, firstSeenIndex: i),
    );
    final siteKey = '${site.subscriptionId}:${site.key}';
    final dedupeId =
        '$siteKey::${video.id.isNotEmpty ? video.id : video.title.trim()}';
    if (!bucket.seenIdentities.add(dedupeId)) continue;
    bucket.matches.add(
      SearchSourceMatch(
        site: site,
        video: video,
        siteKey: siteKey,
        sourceLabel: sourceLabelOf(site),
        isNetdisk: _isLikelyNetdiskSource(site),
        isPluginOrGateway: site.usesAdapterPack || site.usesSpiderGateway,
      ),
    );
  }

  final normQuery = normalizeSearchGroupTitle(query);
  final scoredGroups = <(int tier, int sourceCount, int order, AggregatedSearchGroup group)>[];

  for (final bucket in buckets.values) {
    final matches = List<SearchSourceMatch>.of(bucket.matches);
    matches.sort((a, b) {
      int priority(SearchSourceMatch m) {
        var score = 0;
        if (preferredSiteKey.isNotEmpty && m.siteKey == preferredSiteKey) {
          score += 1000;
        }
        if (m.isNetdisk) score += 120;
        if (!m.isPluginOrGateway) score += 30;
        if (_isUsableSearchPoster(m.video.poster)) score += 20;
        score += _remarksRichness(m.video.remarks);
        return score;
      }

      return priority(b).compareTo(priority(a));
    });

    // Pick cleanest display title.
    var bestTitle = '';
    for (final m in matches) {
      final cleaned = cleanSearchDisplayTitle(m.video.title);
      if (cleaned.isEmpty) continue;
      if (bestTitle.isEmpty ||
          (cleaned.length < bestTitle.length && cleaned.length >= 2)) {
        bestTitle = cleaned;
      }
    }
    if (bestTitle.isEmpty) {
      bestTitle = matches.first.video.title.trim();
    }

    var bestPoster = '';
    var bestRemarks = '';
    var bestRemarksScore = -1;
    var bestYear = '';
    var bestArea = '';
    var bestActor = '';
    var bestTag = '';
    double? bestDouban;
    int? bestRt;

    for (final m in matches) {
      final v = m.video;
      if (bestPoster.isEmpty && _isUsableSearchPoster(v.poster)) {
        bestPoster = v.poster.trim();
      }
      final rScore = _remarksRichness(v.remarks);
      if (v.remarks.trim().isNotEmpty && rScore > bestRemarksScore) {
        bestRemarks = v.remarks.trim();
        bestRemarksScore = rScore;
      }
      if (bestYear.isEmpty && v.year.trim().isNotEmpty) {
        bestYear = v.year.trim();
      }
      if (bestArea.isEmpty && v.area.trim().isNotEmpty) {
        bestArea = v.area.trim();
      }
      if (bestActor.isEmpty && v.actor.trim().isNotEmpty) {
        bestActor = v.actor.trim();
      }
      if (bestTag.isEmpty && v.tag.trim().isNotEmpty) {
        bestTag = v.tag.trim();
      }
      if (bestDouban == null && v.doubanScore != null && v.doubanScore! > 0) {
        bestDouban = v.doubanScore;
      }
      if (bestRt == null && v.rtScore != null && v.rtScore! > 0) {
        bestRt = v.rtScore;
      }
    }
    if (bestPoster.isEmpty) {
      for (final m in matches) {
        if (m.video.poster.trim().isNotEmpty) {
          bestPoster = m.video.poster.trim();
          break;
        }
      }
    }

    var tier = 3;
    if (normQuery.isNotEmpty) {
      if (bucket.normalizedKey == normQuery) {
        tier = 0;
      } else if (bucket.normalizedKey.startsWith(normQuery)) {
        tier = 1;
      } else if (bucket.normalizedKey.contains(normQuery)) {
        tier = 2;
      }
    }

    final group = AggregatedSearchGroup(
      normalizedKey: bucket.normalizedKey,
      displayTitle: bestTitle,
      poster: bestPoster,
      remarks: bestRemarks,
      year: bestYear,
      area: bestArea,
      actor: bestActor,
      tag: bestTag,
      doubanScore: bestDouban,
      rtScore: bestRt,
      matches: List<SearchSourceMatch>.unmodifiable(matches),
    );
    scoredGroups.add((tier, matches.length, bucket.firstSeenIndex, group));
  }

  scoredGroups.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
    return a.$3.compareTo(b.$3);
  });

  return [for (final entry in scoredGroups) entry.$4];
}

/// Snapshot of live search state supplied by [AdaptiveShell].
class GlobalSearchSnapshot {
  final bool isPrivate;
  final bool searching;
  final bool searchPerformed;
  final String searchKeyword;
  final String siteFilterKey;
  final int searchEpoch;
  final List<(CmsSite, CmsVideo)> results;
  final Map<String, String> notices;
  final Map<String, CmsSite> verificationSites;
  final List<CmsSite> visibleSupportedSites;
  final CmsSite? activeSite;
  final List<CmsVideo> homeHotVideos;

  const GlobalSearchSnapshot({
    required this.isPrivate,
    required this.searching,
    required this.searchPerformed,
    required this.searchKeyword,
    required this.siteFilterKey,
    required this.searchEpoch,
    required this.results,
    required this.notices,
    required this.verificationSites,
    required this.visibleSupportedSites,
    required this.activeSite,
    required this.homeHotVideos,
  });
}

/// Builds the iOS 26 translucent full-screen search overlay route (smooth fade
/// + subtle lift, matching Apple Music / Photos / Safari 26 search presentation,
/// while preserving `ModalRoute.isCurrent` handoff for [IosNativeRouteGate]).
Route<T> buildIosSearchOverlayRoute<T>({
  required WidgetBuilder builder,
}) {
  return _IosSearchOverlayRoute<T>(builder: builder);
}

class _IosSearchOverlayRoute<T> extends PopupRoute<T> {
  final WidgetBuilder builder;

  _IosSearchOverlayRoute({required this.builder});

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => '全站搜索';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: child,
    );
  }
}

/// Flagship iOS 26 Liquid Glass Full-Screen Cinema Search (`B + A + C`):
/// - **B**: Bottom floating translucent Liquid Glass search capsule (tracks
///   keyboard insets smoothly) + native iOS 26 circular glass close button.
/// - **A**: Apple TV full-screen cinema dark canvas with ambient glow, wrapping
///   frosted recent search chips, zero-state 3-column Home hot picks, and a
///   full-width horizontal source filter strip (replacing the cramped sidebar).
/// - **C**: Native iOS 26 segmented switcher between **智能聚合** (cross-source
///   merged cinema cards with 1-tap source pills) and **全部海报** (full-width
///   3-column poster grid).
class IosGlobalSearchPage extends StatefulWidget {
  final TextEditingController controller;
  final StorageService storage;
  final CmsClient client;
  final ValueListenable<int> stateRevision;
  final GlobalSearchSnapshot Function() readSnapshot;
  final String Function(CmsSite site) sourceLabelOf;
  final ValueChanged<String> onSearch;
  final VoidCallback onResetSearch;
  final ValueChanged<String> onSiteFilterChanged;
  final Future<void> Function(CmsSite site) onRetryVerifiedSearch;
  final void Function(CmsSite site, CmsVideo video) onOpenVideoDetail;
  final Widget Function(
    CmsSite site,
    CmsVideo video, {
    String? badge,
    VoidCallback? onTap,
  }) buildVideoCard;

  const IosGlobalSearchPage({
    super.key,
    required this.controller,
    required this.storage,
    required this.client,
    required this.stateRevision,
    required this.readSnapshot,
    required this.sourceLabelOf,
    required this.onSearch,
    required this.onResetSearch,
    required this.onSiteFilterChanged,
    required this.onRetryVerifiedSearch,
    required this.onOpenVideoDetail,
    required this.buildVideoCard,
  });

  @override
  State<IosGlobalSearchPage> createState() => _IosGlobalSearchPageState();
}

class _IosGlobalSearchPageState extends State<IosGlobalSearchPage> {
  final ScrollController _siteFilterScrollCtrl = ScrollController();
  final ScrollController _noticeScrollCtrl = ScrollController();
  final Set<String> _expandedGroupKeys = <String>{};

  /// `0` = 智能聚合 (Smart Aggregated Cinema Cards), `1` = 全部海报 (Poster Grid).
  int _viewMode = 0;

  @override
  void initState() {
    super.initState();
    widget.stateRevision.addListener(_onRevisionChanged);
  }

  @override
  void didUpdateWidget(covariant IosGlobalSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stateRevision != widget.stateRevision) {
      oldWidget.stateRevision.removeListener(_onRevisionChanged);
      widget.stateRevision.addListener(_onRevisionChanged);
    }
  }

  void _onRevisionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.stateRevision.removeListener(_onRevisionChanged);
    _siteFilterScrollCtrl.dispose();
    _noticeScrollCtrl.dispose();
    super.dispose();
  }

  void _submitQuery(String raw) {
    final kw = raw.trim();
    if (kw.isEmpty) return;
    _expandedGroupKeys.clear();
    widget.onSearch(kw);
    if (mounted) setState(() {});
  }

  void _handleClearHistory(bool isPrivate) {
    if (widget.storage.getSearchHistory(forPrivate: isPrivate).isEmpty) return;
    HapticFeedback.selectionClick();
    widget.storage.clearSearchHistory(forPrivate: isPrivate).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _handleRemoveHistoryItem(String keyword, bool isPrivate) {
    HapticFeedback.selectionClick();
    widget.storage
        .removeSearchKeyword(keyword, forPrivate: isPrivate)
        .then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openDetail(CmsSite site, CmsVideo video) {
    FocusScope.of(context).unfocus();
    widget.onOpenVideoDetail(site, video);
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.readSnapshot();
    final isPriv = snap.isPrivate;
    final history = widget.storage.getSearchHistory(forPrivate: isPriv);
    final size = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
    final compactLandscape = size.height < 460;
    final wide = size.width >= 680;
    final accentColor =
        isPriv ? const Color(0xFFA78BFA) : AppleColors.systemBlue;

    // Tally hits per source for the horizontal filter strip.
    final siteCounts = <String, int>{};
    final siteByKey = <String, CmsSite>{};
    for (final (site, _) in snap.results) {
      final k = '${site.subscriptionId}:${site.key}';
      siteByKey[k] = site;
      siteCounts[k] = (siteCounts[k] ?? 0) + 1;
    }
    var activeSiteFilterKey = snap.siteFilterKey;
    if (activeSiteFilterKey.isNotEmpty &&
        !siteByKey.containsKey(activeSiteFilterKey)) {
      final matchInSupported = snap.visibleSupportedSites
          .where((s) => '${s.subscriptionId}:${s.key}' == activeSiteFilterKey);
      if (matchInSupported.isNotEmpty) {
        siteByKey[activeSiteFilterKey] = matchInSupported.first;
      } else {
        activeSiteFilterKey = '';
      }
    }
    final hitSiteEntries = siteByKey.entries.toList()
      ..sort((a, b) {
        final ca = siteCounts[a.key] ?? 0;
        final cb = siteCounts[b.key] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return widget
            .sourceLabelOf(a.value)
            .compareTo(widget.sourceLabelOf(b.value));
      });

    final filteredResults = activeSiteFilterKey.isEmpty
        ? snap.results
        : snap.results
            .where(
              (r) => '${r.$1.subscriptionId}:${r.$1.key}' == activeSiteFilterKey,
            )
            .toList(growable: false);

    final preferredSiteKey = snap.activeSite == null
        ? ''
        : '${snap.activeSite!.subscriptionId}:${snap.activeSite!.key}';
    final aggregatedGroups = aggregateSearchResults(
      results: filteredResults,
      query: snap.searchKeyword,
      sourceLabelOf: widget.sourceLabelOf,
      preferredSiteKey: preferredSiteKey,
    );

    final showZeroState =
        !snap.searchPerformed && snap.results.isEmpty && !snap.searching;
    final showResultsToolbar = snap.searchPerformed && snap.results.isNotEmpty;

    final double barHeight = compactLandscape ? 46.0 : 54.0;
    final double barBottomGap = viewInsetsBottom > 0
        ? viewInsetsBottom + (compactLandscape ? 6.0 : 10.0)
        : math.max(safePadding.bottom, 10.0) + (compactLandscape ? 4.0 : 10.0);
    final double contentBottomReserve =
        barHeight + barBottomGap + (compactLandscape ? 10.0 : 18.0);

    final hotVideos = _eligibleHotVideos(snap);
    final availableSiteCount =
        snap.visibleSupportedSites.where((s) => s.supported).length;

    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF07070A),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Full-bleed cinema ambient background glow (A).
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -1.05),
                    radius: 1.15,
                    colors: isPriv
                        ? const [
                            Color(0x369B7BFF),
                            Color(0x146E4AE0),
                            Color(0xFF07070A),
                          ]
                        : const [
                            Color(0x2AE89B5B),
                            Color(0x142A68C8),
                            Color(0xFF07070A),
                          ],
                    stops: const [0.0, 0.42, 1.0],
                  ),
                ),
              ),
            ),

            // Main vertical layout.
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide ? 880 : double.infinity,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTopHeader(
                      context: context,
                      snap: snap,
                      isPriv: isPriv,
                      compactLandscape: compactLandscape,
                      safeTop: safePadding.top,
                      availableSiteCount: availableSiteCount,
                      hitSourceCount: siteCounts.length,
                      aggregatedCount: aggregatedGroups.length,
                      historyNotEmpty: history.isNotEmpty,
                      accentColor: accentColor,
                    ),

                    if (snap.searching)
                      _buildSearchingBar(accentColor: accentColor),

                    if (showResultsToolbar)
                      _buildResultsToolbar(
                        context: context,
                        snap: snap,
                        compactLandscape: compactLandscape,
                        activeSiteFilterKey: activeSiteFilterKey,
                        hitSiteEntries: hitSiteEntries,
                        siteCounts: siteCounts,
                        accentColor: accentColor,
                      ),

                    if (snap.notices.isNotEmpty)
                      _buildSourceNoticesBox(
                        snap: snap,
                        compactLandscape: compactLandscape,
                      ),

                    Expanded(
                      child: showZeroState
                          ? _buildZeroStateBody(
                              context: context,
                              snap: snap,
                              isPriv: isPriv,
                              wide: wide,
                              compactLandscape: compactLandscape,
                              history: history,
                              hotVideos: hotVideos,
                              accentColor: accentColor,
                              bottomPadding: contentBottomReserve,
                            )
                          : (filteredResults.isEmpty && snap.searching)
                              ? _buildSearchingSkeleton(
                                  bottomPadding: contentBottomReserve,
                                )
                              : filteredResults.isEmpty
                                  ? _buildEmptyState(
                                      snap: snap,
                                      activeSiteFilterKey: activeSiteFilterKey,
                                      bottomPadding: contentBottomReserve,
                                    )
                                  : _viewMode == 0
                                      ? _buildAggregatedList(
                                          groups: aggregatedGroups,
                                          isPriv: isPriv,
                                          accentColor: accentColor,
                                          bottomPadding: contentBottomReserve,
                                        )
                                      : _buildPosterGrid(
                                          results: filteredResults,
                                          wide: wide,
                                          bottomPadding: contentBottomReserve,
                                        ),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom fade scrim so posters melt organically behind the Liquid Glass bar.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: barHeight + barBottomGap + (compactLandscape ? 14 : 28),
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x0007070A),
                        Color(0xBF07070A),
                        Color(0xF507070A),
                      ],
                      stops: [0.0, 0.52, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // Bottom floating iOS 26 Liquid Glass Search Bar + circular X button (B).
            Positioned(
              left: 0,
              right: 0,
              bottom: barBottomGap,
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: wide ? 640 : double.infinity,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: _buildFloatingGlassSearchBar(
                      context: context,
                      barHeight: barHeight,
                      compactLandscape: compactLandscape,
                      accentColor: accentColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<CmsVideo> _eligibleHotVideos(GlobalSearchSnapshot snap) {
    final site = snap.activeSite;
    if (site == null || !site.supported) return const <CmsVideo>[];
    if (site.isEffectivelyPrivate != snap.isPrivate) return const <CmsVideo>[];
    return snap.homeHotVideos
        .where((v) => !v.id.startsWith('netdisk_qr:') && v.title.trim().isNotEmpty)
        .take(12)
        .toList(growable: false);
  }

  Widget _buildTopHeader({
    required BuildContext context,
    required GlobalSearchSnapshot snap,
    required bool isPriv,
    required bool compactLandscape,
    required double safeTop,
    required int availableSiteCount,
    required int hitSourceCount,
    required int aggregatedCount,
    required bool historyNotEmpty,
    required Color accentColor,
  }) {
    final String subtitle;
    if (snap.searching) {
      subtitle = snap.results.isEmpty
          ? '正在并发检索 $availableSiteCount 个片源…'
          : '检索中 · 已找到 ${snap.results.length} 条结果 ($hitSourceCount 个片源)';
    } else if (snap.searchPerformed && snap.results.isNotEmpty) {
      subtitle = _viewMode == 0
          ? '聚合 $aggregatedCount 部影片 · 来自 $hitSourceCount 个片源'
          : '共 ${snap.results.length} 条结果 · 来自 $hitSourceCount 个片源';
    } else if (snap.searchPerformed) {
      subtitle = '已完成 $availableSiteCount 个片源检索';
    } else {
      subtitle = '并发检索 $availableSiteCount 个可用片源';
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        safeTop + (compactLandscape ? 6 : 12),
        14,
        compactLandscape ? 4 : 8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: compactLandscape
                ? Row(
                    children: [
                      if (isPriv) ...[
                        Icon(
                          CupertinoIcons.lock_fill,
                          size: 13,
                          color: accentColor,
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        isPriv ? '隐私空间搜索' : '全站搜索',
                        style: const TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (isPriv) ...[
                            Container(
                              padding: const EdgeInsets.all(4),
                              margin: const EdgeInsets.only(right: 7),
                              decoration: BoxDecoration(
                                color: accentColor.withValues(alpha: 0.2),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: accentColor.withValues(alpha: 0.45),
                                  width: 0.6,
                                ),
                              ),
                              child: Icon(
                                CupertinoIcons.lock_fill,
                                size: 12,
                                color: accentColor,
                              ),
                            ),
                          ],
                          Text(
                            isPriv ? '隐私空间搜索' : '全站搜索',
                            style: const TextStyle(
                              color: AppleColors.labelPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (snap.searching) ...[
                            const CupertinoActivityIndicator(radius: 6.5),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppleColors.labelSecondary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          if (historyNotEmpty)
            ApplePressableScale(
              pressedScale: 0.94,
              onTap: () => _handleClearHistory(isPriv),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compactLandscape ? 9 : 11,
                  vertical: compactLandscape ? 4 : 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x38282830),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x28FFFFFF),
                    width: 0.6,
                  ),
                ),
                child: const Text(
                  '清空历史',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchingBar({required Color accentColor}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 2.2,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accentColor.withValues(alpha: 0.12),
                accentColor.withValues(alpha: 0.85),
                accentColor.withValues(alpha: 0.12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResultsToolbar({
    required BuildContext context,
    required GlobalSearchSnapshot snap,
    required bool compactLandscape,
    required String activeSiteFilterKey,
    required List<MapEntry<String, CmsSite>> hitSiteEntries,
    required Map<String, int> siteCounts,
    required Color accentColor,
  }) {
    const segments = <String>['智能聚合', '全部海报'];
    return Padding(
      padding: EdgeInsets.only(bottom: compactLandscape ? 6 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: IosNativeSegmentedControl(
              key: const ValueKey('search-view-mode-segmented'),
              segments: segments,
              selectedIndex: _viewMode,
              height: compactLandscape ? 30 : 34,
              onChanged: (idx) {
                HapticFeedback.selectionClick();
                setState(() => _viewMode = idx);
              },
              fallback: _buildFallbackModeSegmented(
                segments: segments,
                compact: compactLandscape,
                accentColor: accentColor,
              ),
            ),
          ),
          if (hitSiteEntries.isNotEmpty) ...[
            SizedBox(height: compactLandscape ? 6 : 9),
            SizedBox(
              key: const ValueKey('search-site-filter-bar'),
              height: compactLandscape ? 30 : 33,
              child: AppleEdgeFade(
                fadeWidth: 16,
                child: DesktopHorizontalScroller(
                  controller: _siteFilterScrollCtrl,
                  child: ListView.separated(
                    controller: _siteFilterScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: hitSiteEntries.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 7),
                    itemBuilder: (ctx, idx) {
                      final isAll = idx == 0;
                      final key = isAll ? '' : hitSiteEntries[idx - 1].key;
                      final site = isAll ? null : hitSiteEntries[idx - 1].value;
                      final count = isAll
                          ? snap.results.length
                          : (siteCounts[key] ?? 0);
                      final selected = activeSiteFilterKey == key;
                      final titleText =
                          isAll ? '全部' : widget.sourceLabelOf(site!);
                      return ApplePressableScale(
                        pressedScale: 0.94,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          final nextKey = (selected && !isAll) ? '' : key;
                          widget.onSiteFilterChanged(nextKey);
                          if (mounted) setState(() {});
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            gradient: selected
                                ? LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      accentColor.withValues(alpha: 0.95),
                                      accentColor,
                                    ],
                                  )
                                : null,
                            color: selected ? null : const Color(0x4D22222A),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: selected
                                  ? const Color(0x88FFFFFF)
                                  : const Color(0x28FFFFFF),
                              width: 0.65,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                titleText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : AppleColors.labelPrimary,
                                  fontSize: 12,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  height: 1.1,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5.5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0x3DFFFFFF)
                                      : accentColor.withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '$count',
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : accentColor.withValues(alpha: 0.95),
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    height: 1.05,
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
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFallbackModeSegmented({
    required List<String> segments,
    required bool compact,
    required Color accentColor,
  }) {
    return Container(
      height: compact ? 30 : 34,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: const Color(0x6622222A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x28FFFFFF), width: 0.65),
      ),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: GestureDetector(
                key: ValueKey(i == 0 ? 'search-mode-aggregated' : 'search-mode-grid'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _viewMode = i);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _viewMode == i
                        ? const Color(0x4AFFFFFF)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: _viewMode == i
                        ? Border.all(
                            color: const Color(0x45FFFFFF),
                            width: 0.55,
                          )
                        : null,
                  ),
                  child: Text(
                    segments[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _viewMode == i
                          ? Colors.white
                          : AppleColors.labelSecondary,
                      fontSize: compact ? 12 : 13,
                      fontWeight:
                          _viewMode == i ? FontWeight.w600 : FontWeight.w500,
                      letterSpacing: -0.15,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceNoticesBox({
    required GlobalSearchSnapshot snap,
    required bool compactLandscape,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, compactLandscape ? 6 : 10),
      child: Container(
        key: const ValueKey('search-source-notices-box'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0x521C1C22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0x2CFFFFFF),
            width: 0.6,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 54.0),
          child: CupertinoScrollbar(
            controller: _noticeScrollCtrl,
            child: SingleChildScrollView(
              controller: _noticeScrollCtrl,
              primary: false,
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snap.notices.values.join('\n'),
                    key: const ValueKey('search-source-notices'),
                    style: const TextStyle(
                      color: AppleColors.labelSecondary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  for (final site in snap.verificationSites.values)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            site.name,
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SourceVerificationButton(
                            key: ValueKey(
                              '${snap.searchEpoch}:${site.subscriptionId}:${site.key}',
                            ),
                            client: widget.client,
                            site: site,
                            onVerified: () => widget.onRetryVerifiedSearch(site),
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
    );
  }

  Widget _buildZeroStateBody({
    required BuildContext context,
    required GlobalSearchSnapshot snap,
    required bool isPriv,
    required bool wide,
    required bool compactLandscape,
    required List<String> history,
    required List<CmsVideo> hotVideos,
    required Color accentColor,
    required double bottomPadding,
  }) {
    if (history.isEmpty && hotVideos.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, bottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compactLandscape ? 54 : 68,
                height: compactLandscape ? 54 : 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accentColor.withValues(alpha: 0.24),
                      const Color(0x22FFFFFF),
                    ],
                  ),
                  border: Border.all(
                    color: const Color(0x36FFFFFF),
                    width: 0.8,
                  ),
                ),
                child: Icon(
                  isPriv ? CupertinoIcons.lock_fill : CupertinoIcons.search,
                  color: Colors.white.withValues(alpha: 0.85),
                  size: compactLandscape ? 24 : 30,
                ),
              ),
              SizedBox(height: compactLandscape ? 10 : 16),
              const Text(
                '全站片源一键直达',
                style: TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '输入片名、演员或导演，自动并发检索并聚合多条片源',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        if (history.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        CupertinoIcons.clock,
                        size: 14,
                        color: AppleColors.labelSecondary,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '最近搜索',
                        style: TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final kw in history)
                        _buildHistoryChip(kw: kw, isPriv: isPriv),
                    ],
                  ),
                ],
              ),
            ),
          ),

        if (hotVideos.isNotEmpty && snap.activeSite != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                history.isEmpty ? 8 : 4,
                16,
                12,
              ),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.flame_fill,
                    size: 15,
                    color: Color(0xFFFF9F0A),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '本源热播',
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.25,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.sourceLabelOf(snap.activeSite!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid(
              gridDelegate: wide
                  ? const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 158,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.56,
                    )
                  : const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.56,
                    ),
              delegate: SliverChildBuilderDelegate(
                (ctx, index) {
                  final video = hotVideos[index];
                  final site = snap.activeSite!;
                  return widget.buildVideoCard(
                    site,
                    video,
                    onTap: () => _openDetail(site, video),
                  );
                },
                childCount: hotVideos.length,
              ),
            ),
          ),
        ],

        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
  }

  Widget _buildHistoryChip({required String kw, required bool isPriv}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x5222222A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0x28FFFFFF),
          width: 0.65,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ApplePressableScale(
            pressedScale: 0.94,
            onTap: () {
              widget.controller.text = kw;
              widget.controller.selection = TextSelection.fromPosition(
                TextPosition(offset: kw.length),
              );
              _submitQuery(kw);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Text(
                kw,
                style: const TextStyle(
                  color: AppleColors.labelPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                ),
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _handleRemoveHistoryItem(kw, isPriv),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(4, 6, 9, 6),
              child: Icon(
                CupertinoIcons.xmark,
                size: 11,
                color: AppleColors.labelTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingSkeleton({required double bottomPadding}) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, i) {
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x5518181E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x1CFFFFFF), width: 0.6),
          ),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 100,
                decoration: BoxDecoration(
                  color: const Color(0x382A2A34),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 16,
                      width: 140,
                      decoration: BoxDecoration(
                        color: const Color(0x402E2E38),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      height: 12,
                      width: 190,
                      decoration: BoxDecoration(
                        color: const Color(0x302A2A34),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Container(
                          height: 24,
                          width: 74,
                          decoration: BoxDecoration(
                            color: const Color(0x322A2A34),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          height: 24,
                          width: 68,
                          decoration: BoxDecoration(
                            color: const Color(0x282A2A34),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState({
    required GlobalSearchSnapshot snap,
    required String activeSiteFilterKey,
    required double bottomPadding,
  }) {
    final bool hasUnfilteredHits =
        activeSiteFilterKey.isNotEmpty && snap.results.isNotEmpty;
    final String message = !snap.searchPerformed
        ? '输入关键词，并发检索全部已启用片源'
        : hasUnfilteredHits
            ? '当前所选线路暂无匹配影片'
            : snap.notices.isEmpty
                ? '没有找到匹配影片'
                : '本次搜索未返回影片，请查看上方片源提示';

    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.fromLTRB(24, 8, 24, bottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.search,
              color: AppleColors.labelTertiary,
              size: 40,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 14,
              ),
            ),
            if (hasUnfilteredHits) ...[
              const SizedBox(height: 12),
              AppleCapsuleButton(
                label: '查看全部线路 (${snap.results.length})',
                compact: true,
                onPressed: () {
                  widget.onSiteFilterChanged('');
                  if (mounted) setState(() {});
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAggregatedList({
    required List<AggregatedSearchGroup> groups,
    required bool isPriv,
    required Color accentColor,
    required double bottomPadding,
  }) {
    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(16, 4, 16, bottomPadding),
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, index) {
        final group = groups[index];
        final expanded = _expandedGroupKeys.contains(group.normalizedKey);
        return _AggregatedSearchCard(
          group: group,
          isPrivate: isPriv,
          accentColor: accentColor,
          expanded: expanded,
          onToggleExpand: () {
            setState(() {
              if (expanded) {
                _expandedGroupKeys.remove(group.normalizedKey);
              } else {
                _expandedGroupKeys.add(group.normalizedKey);
              }
            });
          },
          onOpenMatch: (match) => _openDetail(match.site, match.video),
        );
      },
    );
  }

  Widget _buildPosterGrid({
    required List<(CmsSite, CmsVideo)> results,
    required bool wide,
    required double bottomPadding,
  }) {
    return GridView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(16, 4, 16, bottomPadding),
      gridDelegate: wide
          ? const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 158,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 0.56,
            )
          : const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 14,
              crossAxisSpacing: 10,
              childAspectRatio: 0.56,
            ),
      itemCount: results.length,
      itemBuilder: (ctx, i) {
        final (site, video) = results[i];
        return widget.buildVideoCard(
          site,
          video,
          badge: widget.sourceLabelOf(site),
          onTap: () => _openDetail(site, video),
        );
      },
    );
  }

  Widget _buildFloatingGlassSearchBar({
    required BuildContext context,
    required double barHeight,
    required bool compactLandscape,
    required Color accentColor,
  }) {
    final searchCapsule = ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          key: const ValueKey('search-floating-glass-capsule'),
          height: barHeight,
          padding: EdgeInsets.fromLTRB(
            compactLandscape ? 10 : 12,
            0,
            compactLandscape ? 6 : 8,
            0,
          ),
          decoration: BoxDecoration(
            color: const Color(0xC21D1D24),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: const Color(0x42FFFFFF),
              width: 0.8,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 22,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: AppleSearchField(
                  controller: widget.controller,
                  autofocus: true,
                  borderless: true,
                  placeholder: '搜索片名、演员或导演…',
                  onSuffixTap: () {
                    widget.controller.clear();
                    widget.onResetSearch();
                    if (mounted) setState(() {});
                  },
                  onSubmitted: _submitQuery,
                ),
              ),
              const SizedBox(width: 6),
              ApplePressableScale(
                pressedScale: 0.93,
                onTap: () => _submitQuery(widget.controller.text),
                child: Container(
                  height: compactLandscape ? 32 : 36,
                  padding: EdgeInsets.symmetric(
                    horizontal: compactLandscape ? 13 : 15,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accentColor.withValues(alpha: 0.95),
                        accentColor,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0x55FFFFFF),
                      width: 0.6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accentColor.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Text(
                    '搜索',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compactLandscape ? 12.5 : 13.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final closeFallback = ApplePressableScale(
      pressedScale: 0.92,
      onTap: () => Navigator.of(context).maybePop(),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(
            width: barHeight,
            height: barHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xC21D1D24),
              border: Border.all(
                color: const Color(0x42FFFFFF),
                width: 0.8,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 20,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Icon(
              CupertinoIcons.xmark,
              color: Colors.white,
              size: compactLandscape ? 17 : 19,
            ),
          ),
        ),
      ),
    );

    return Row(
      children: [
        Expanded(child: searchCapsule),
        const SizedBox(width: 10),
        IosNativeGlassButton(
          key: const ValueKey('search-close-button'),
          style: 'circle',
          symbol: 'xmark',
          symbolSize: compactLandscape ? 16 : 18,
          width: barHeight,
          height: barHeight,
          accessibilityLabel: '关闭搜索',
          onTap: () => Navigator.of(context).maybePop(),
          fallback: closeFallback,
        ),
      ],
    );
  }
}

class _AggregatedSearchCard extends StatelessWidget {
  final AggregatedSearchGroup group;
  final bool isPrivate;
  final Color accentColor;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<SearchSourceMatch> onOpenMatch;

  static const int _initialVisiblePills = 6;

  const _AggregatedSearchCard({
    required this.group,
    required this.isPrivate,
    required this.accentColor,
    required this.expanded,
    required this.onToggleExpand,
    required this.onOpenMatch,
  });

  @override
  Widget build(BuildContext context) {
    final primary = group.primaryMatch;
    final metaParts = <String>[
      if (group.year.isNotEmpty) group.year,
      if (group.area.isNotEmpty) group.area,
      if (group.tag.isNotEmpty) group.tag,
    ];
    final hasExtra = group.matches.length > _initialVisiblePills;
    final visibleMatches = (expanded || !hasExtra)
        ? group.matches
        : group.matches.take(_initialVisiblePills).toList(growable: false);
    final hiddenCount = group.matches.length - visibleMatches.length;

    return RepaintBoundary(
      child: AppleSmoothClipCard(
        borderRadius: 20,
        backgroundColor: const Color(0xCC16161C),
        rimStrength: 0.72,
        boxShadow: const [
          BoxShadow(
            color: Color(0x3D000000),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ApplePressableScale(
              pressedScale: 0.985,
              pressedOpacity: 0.92,
              onTap: () => onOpenMatch(primary),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPosterThumbnail(primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppleColors.labelPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              height: 1.22,
                            ),
                          ),
                          if (metaParts.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              metaParts.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppleColors.labelSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (group.actor.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              group.actor,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppleColors.labelTertiary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                          const SizedBox(height: 9),
                          Wrap(
                            spacing: 6,
                            runSpacing: 5,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: group.matches.length > 1
                                      ? accentColor.withValues(alpha: 0.22)
                                      : const Color(0x362C2C34),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: group.matches.length > 1
                                        ? accentColor.withValues(alpha: 0.5)
                                        : const Color(0x28FFFFFF),
                                    width: 0.6,
                                  ),
                                ),
                                child: Text(
                                  group.matches.length > 1
                                      ? '共 ${group.matches.length} 个片源'
                                      : '1 个片源',
                                  style: TextStyle(
                                    color: group.matches.length > 1
                                        ? Colors.white
                                        : AppleColors.labelSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                              if (group.remarks.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7.5,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0x362A2A32),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(0x22FFFFFF),
                                      width: 0.55,
                                    ),
                                  ),
                                  child: Text(
                                    group.remarks,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppleColors.labelSecondary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 4, left: 4),
                      child: Icon(
                        CupertinoIcons.chevron_right,
                        size: 14,
                        color: AppleColors.labelTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Container(
              height: 0.5,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              color: const Color(0x1CFFFFFF),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final match in visibleMatches)
                    _buildSourcePill(match),
                  if (hiddenCount > 0)
                    ApplePressableScale(
                      pressedScale: 0.94,
                      onTap: onToggleExpand,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x36282832),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0x28FFFFFF),
                            width: 0.6,
                          ),
                        ),
                        child: Text(
                          '+$hiddenCount 更多',
                          style: const TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                        ),
                      ),
                    )
                  else if (expanded && hasExtra)
                    ApplePressableScale(
                      pressedScale: 0.94,
                      onTap: onToggleExpand,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x36282832),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0x28FFFFFF),
                            width: 0.6,
                          ),
                        ),
                        child: const Text(
                          '收起',
                          style: TextStyle(
                            color: AppleColors.labelSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPosterThumbnail(SearchSourceMatch primary) {
    return SizedBox(
      width: 74,
      height: 104,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PosterImage(
              url: group.poster,
              title: isPrivate ? '' : group.displayTitle,
              year: isPrivate ? '' : group.year,
              placeholder: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF262630), Color(0xFF17171D)],
                  ),
                ),
                child: Center(
                  child: Icon(
                    CupertinoIcons.film,
                    color: AppleColors.labelTertiary,
                    size: 22,
                  ),
                ),
              ),
            ),
            if (group.doubanScore != null && group.doubanScore! > 0)
              Positioned(
                top: 5,
                left: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB80E0E12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0x45FFD60A),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.star_fill,
                        size: 9,
                        color: Color(0xFFFFD60A),
                      ),
                      const SizedBox(width: 2.5),
                      Text(
                        group.doubanScore!.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Color(0xFFFFD60A),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourcePill(SearchSourceMatch match) {
    final Color bgColor;
    final Color borderColor;
    final Color iconColor;
    final IconData? icon;

    if (match.isNetdisk) {
      bgColor = const Color(0x2830D158);
      borderColor = const Color(0x5230D158);
      iconColor = const Color(0xFF5CE083);
      icon = CupertinoIcons.cloud_fill;
    } else if (match.isPluginOrGateway) {
      bgColor = const Color(0x28A78BFA);
      borderColor = const Color(0x52A78BFA);
      iconColor = const Color(0xFFC4B5FD);
      icon = CupertinoIcons.cube_box_fill;
    } else {
      bgColor = const Color(0x40262630);
      borderColor = const Color(0x28FFFFFF);
      iconColor = AppleColors.labelSecondary;
      icon = null;
    }

    return ApplePressableScale(
      pressedScale: 0.93,
      onTap: () => onOpenMatch(match),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor, width: 0.6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 11, color: iconColor),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  match.sourceLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'container_metadata_reader.dart';
import 'models.dart';

/// Broad media work form used to prevent cross-medium mismatches (especially
/// separating `动态漫画 / 动态漫` from regular 3D/2D `动漫 / 动画` and live-action
/// dramas, plus rejecting audio books, recaps, and games).
enum MediaWorkForm {
  standard,
  motionComic,
  audioBook,
  recap,
  game,
}

/// Confidence/resolution state for a single episode item.
enum EpisodeRecognitionStatus {
  /// Explicitly confirmed by the user (highest priority).
  confirmed,

  /// Cleanly recognized from structured source metadata, internal container
  /// tags, or explicit filename/directory markers without conflict.
  autoMatched,

  /// Recognized as trailer / preview / SP / OVA / episode 0 special.
  special,

  /// Insufficient evidence (e.g. only `1080p` or empty name) or conflicting
  /// evidence across sources/tags/filenames. Must display `待确认` and never
  /// auto-bind using list position.
  needsConfirmation,
}

/// User-confirmed manual calibration record keyed by stable file/item identity.
class EpisodeManualCalibration {
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isSpecial;
  final String workTitle;
  final String danmuBoundEpisodeId;
  final String danmuSourceOrigin;
  final String danmuAnimeId;
  final String danmuAnimeTitle;
  final String danmuEpisodeTitle;
  final int updatedAtMs;

  const EpisodeManualCalibration({
    this.seasonNumber,
    this.episodeNumber,
    this.isSpecial = false,
    this.workTitle = '',
    this.danmuBoundEpisodeId = '',
    this.danmuSourceOrigin = '',
    this.danmuAnimeId = '',
    this.danmuAnimeTitle = '',
    this.danmuEpisodeTitle = '',
    this.updatedAtMs = 0,
  });

  bool get hasEpisodeOverride =>
      isSpecial || (episodeNumber != null && episodeNumber! > 0);

  bool get hasDanmuBinding => danmuBoundEpisodeId.trim().isNotEmpty;

  bool get isEmpty =>
      !isSpecial &&
      (episodeNumber == null || episodeNumber! <= 0) &&
      (seasonNumber == null || seasonNumber! <= 0) &&
      workTitle.trim().isEmpty &&
      danmuBoundEpisodeId.trim().isEmpty;

  EpisodeManualCalibration copyWith({
    int? seasonNumber,
    bool clearSeasonNumber = false,
    int? episodeNumber,
    bool clearEpisodeNumber = false,
    bool? isSpecial,
    String? workTitle,
    String? danmuBoundEpisodeId,
    String? danmuSourceOrigin,
    String? danmuAnimeId,
    String? danmuAnimeTitle,
    String? danmuEpisodeTitle,
    bool clearDanmuBinding = false,
    int? updatedAtMs,
  }) {
    return EpisodeManualCalibration(
      seasonNumber:
          clearSeasonNumber ? null : (seasonNumber ?? this.seasonNumber),
      episodeNumber:
          clearEpisodeNumber ? null : (episodeNumber ?? this.episodeNumber),
      isSpecial: isSpecial ?? this.isSpecial,
      workTitle: workTitle ?? this.workTitle,
      danmuBoundEpisodeId: clearDanmuBinding
          ? ''
          : (danmuBoundEpisodeId ?? this.danmuBoundEpisodeId),
      danmuSourceOrigin: clearDanmuBinding
          ? ''
          : (danmuSourceOrigin ?? this.danmuSourceOrigin),
      danmuAnimeId:
          clearDanmuBinding ? '' : (danmuAnimeId ?? this.danmuAnimeId),
      danmuAnimeTitle:
          clearDanmuBinding ? '' : (danmuAnimeTitle ?? this.danmuAnimeTitle),
      danmuEpisodeTitle: clearDanmuBinding
          ? ''
          : (danmuEpisodeTitle ?? this.danmuEpisodeTitle),
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        if (seasonNumber != null && seasonNumber! > 0)
          'seasonNumber': seasonNumber,
        if (episodeNumber != null && episodeNumber! > 0)
          'episodeNumber': episodeNumber,
        if (isSpecial) 'isSpecial': true,
        if (workTitle.trim().isNotEmpty) 'workTitle': workTitle.trim(),
        if (danmuBoundEpisodeId.trim().isNotEmpty)
          'danmuBoundEpisodeId': danmuBoundEpisodeId.trim(),
        if (danmuSourceOrigin.trim().isNotEmpty)
          'danmuSourceOrigin': danmuSourceOrigin.trim(),
        if (danmuAnimeId.trim().isNotEmpty) 'danmuAnimeId': danmuAnimeId.trim(),
        if (danmuAnimeTitle.trim().isNotEmpty)
          'danmuAnimeTitle': danmuAnimeTitle.trim(),
        if (danmuEpisodeTitle.trim().isNotEmpty)
          'danmuEpisodeTitle': danmuEpisodeTitle.trim(),
        if (updatedAtMs > 0) 'updatedAtMs': updatedAtMs,
      };

  factory EpisodeManualCalibration.fromJson(Map<String, dynamic> json) {
    final s = (json['seasonNumber'] as num?)?.toInt() ??
        int.tryParse((json['seasonNumber'] ?? '').toString());
    final e = (json['episodeNumber'] as num?)?.toInt() ??
        int.tryParse((json['episodeNumber'] ?? '').toString());
    return EpisodeManualCalibration(
      seasonNumber: s != null && s > 0 ? s : null,
      episodeNumber: e != null && e > 0 ? e : null,
      isSpecial: json['isSpecial'] == true,
      workTitle: (json['workTitle'] ?? '').toString().trim(),
      danmuBoundEpisodeId:
          (json['danmuBoundEpisodeId'] ?? '').toString().trim(),
      danmuSourceOrigin: (json['danmuSourceOrigin'] ?? '').toString().trim(),
      danmuAnimeId: (json['danmuAnimeId'] ?? '').toString().trim(),
      danmuAnimeTitle: (json['danmuAnimeTitle'] ?? '').toString().trim(),
      danmuEpisodeTitle: (json['danmuEpisodeTitle'] ?? '').toString().trim(),
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Result of scraping an individual episode filename/label within a [CmsLine].
class ScrapedEpisodeInfo {
  final int originalIndex;
  final String rawName;
  final String originalFileName;
  final String stableKey;
  final int? seasonNumber;
  final int? rawEpisodeNumber;
  final int? endEpisodeNumber;
  final int? effectiveEpisodeNumber;
  final bool isSpecial;
  final String specialTag;
  final String partTag;
  final String dateKey;
  final String qualityTag;
  final String displayLabel;
  final double confidence;
  final bool hasManualOverride;
  final EpisodeRecognitionStatus status;
  final String evidenceSource;
  final List<String> evidenceDetails;
  final bool hasConflict;
  final String recognizedWorkTitle;
  final int? suggestedSeasonNumber;
  final int? suggestedEpisodeNumber;

  const ScrapedEpisodeInfo({
    required this.originalIndex,
    required this.rawName,
    this.originalFileName = '',
    this.stableKey = '',
    this.seasonNumber,
    this.rawEpisodeNumber,
    this.endEpisodeNumber,
    this.effectiveEpisodeNumber,
    this.isSpecial = false,
    this.specialTag = '',
    this.partTag = '',
    this.dateKey = '',
    this.qualityTag = '',
    required this.displayLabel,
    this.confidence = 0.0,
    this.hasManualOverride = false,
    this.status = EpisodeRecognitionStatus.autoMatched,
    this.evidenceSource = '',
    this.evidenceDetails = const <String>[],
    this.hasConflict = false,
    this.recognizedWorkTitle = '',
    this.suggestedSeasonNumber,
    this.suggestedEpisodeNumber,
  });

  bool get needsConfirmation =>
      status == EpisodeRecognitionStatus.needsConfirmation;

  /// Effective 1-based episode number used for episode metadata lookup & danmu.
  /// Strictly `null` for specials and `待确认` items so list positions never
  /// masquerade as confirmed episode numbers.
  int? get resolvedEpisodeNumber => (isSpecial || needsConfirmation)
      ? null
      : (effectiveEpisodeNumber ?? rawEpisodeNumber);

  /// Human-readable suffix for split parts (`上`/`下`/`中`/`Part N`).
  String get partDisplaySuffix {
    switch (partTag) {
      case 'part1':
        return '（上）';
      case 'part2':
        return '（下）';
      case 'part_mid':
        return '（中）';
      case 'final':
        return '（终）';
      default:
        if (partTag.startsWith('part') && partTag.length > 4) {
          return ' Part${partTag.substring(4)}';
        }
        return '';
    }
  }

  /// Canonical short season/episode badge (`S02E10`, `第 10 集`, `预告`, `待确认`).
  String get formattedSeasonEpisode {
    if (needsConfirmation) return '待确认';
    if (isSpecial) return displayLabel;
    final ep = resolvedEpisodeNumber;
    if (ep == null || ep <= 0) return '待确认';
    if (seasonNumber != null && seasonNumber! > 0) {
      final s = seasonNumber!.toString().padLeft(2, '0');
      final e = ep.toString().padLeft(2, '0');
      return 'S${s}E$e';
    }
    return '第 $ep 集';
  }

  /// Human-readable Chinese summary (`第2季 第10集 (S02E10)` / `第 10 集` / `待确认`).
  String get readableSeasonEpisodeZh {
    if (needsConfirmation) return '待确认';
    if (isSpecial) return displayLabel;
    final ep = resolvedEpisodeNumber;
    if (ep == null || ep <= 0) return '待确认';
    if (seasonNumber != null && seasonNumber! > 0) {
      return '第$seasonNumber季 第$ep集 ($formattedSeasonEpisode)';
    }
    return '第 $ep 集';
  }

  ScrapedEpisodeInfo withSuggestions({
    int? suggestedSeasonNumber,
    int? suggestedEpisodeNumber,
  }) {
    return ScrapedEpisodeInfo(
      originalIndex: originalIndex,
      rawName: rawName,
      originalFileName: originalFileName,
      stableKey: stableKey,
      seasonNumber: seasonNumber,
      rawEpisodeNumber: rawEpisodeNumber,
      endEpisodeNumber: endEpisodeNumber,
      effectiveEpisodeNumber: effectiveEpisodeNumber,
      isSpecial: isSpecial,
      specialTag: specialTag,
      partTag: partTag,
      dateKey: dateKey,
      qualityTag: qualityTag,
      displayLabel: displayLabel,
      confidence: confidence,
      hasManualOverride: hasManualOverride,
      status: status,
      evidenceSource: evidenceSource,
      evidenceDetails: evidenceDetails,
      hasConflict: hasConflict,
      recognizedWorkTitle: recognizedWorkTitle,
      suggestedSeasonNumber:
          suggestedSeasonNumber ?? this.suggestedSeasonNumber,
      suggestedEpisodeNumber:
          suggestedEpisodeNumber ?? this.suggestedEpisodeNumber,
    );
  }
}

/// Line-level episode scrape report with natural numeric ordering & diagnostics.
class LineEpisodeScrapeResult {
  final List<ScrapedEpisodeInfo> byOriginalIndex;
  final List<int> sortedRegularIndices;
  final List<int> specialIndices;
  final List<int> unparsedIndices;
  final bool sourceOrderScrambled;
  final int regularCount;
  final int specialCount;
  final int? minEpisodeNumber;
  final int? maxEpisodeNumber;

  const LineEpisodeScrapeResult({
    required this.byOriginalIndex,
    required this.sortedRegularIndices,
    required this.specialIndices,
    required this.unparsedIndices,
    required this.sourceOrderScrambled,
    required this.regularCount,
    required this.specialCount,
    this.minEpisodeNumber,
    this.maxEpisodeNumber,
  });

  bool get hasMissingNumbers =>
      minEpisodeNumber != null &&
      maxEpisodeNumber != null &&
      regularCount >= 2 &&
      (maxEpisodeNumber! - minEpisodeNumber! + 1) > regularCount;

  ScrapedEpisodeInfo? infoForOriginalIndex(int index) {
    if (index < 0 || index >= byOriginalIndex.length) return null;
    return byOriginalIndex[index];
  }

  /// Returns ordered indices into `line.episodes` according to [sortByScraped]
  /// and [hideSpecials]. Never mutates `line.episodes`.
  List<int> orderedIndices({
    required bool sortByScraped,
    bool hideSpecials = false,
  }) {
    if (byOriginalIndex.isEmpty) return const [];
    if (sortByScraped && regularCount >= 2) {
      return <int>[
        ...sortedRegularIndices,
        ...unparsedIndices,
        if (!hideSpecials) ...specialIndices,
      ];
    }
    if (hideSpecials && specialCount > 0 && regularCount > 0) {
      return <int>[
        for (final info in byOriginalIndex)
          if (!info.isSpecial) info.originalIndex,
      ];
    }
    return List<int>.generate(
      byOriginalIndex.length,
      (i) => i,
      growable: false,
    );
  }
}

/// Outcome of matching the currently playing episode from one [CmsLine] to
/// another [CmsLine]. Progress should only be inherited when [kind] is
/// [CrossLineEpisodeMatchKind.matched].
enum CrossLineEpisodeMatchKind {
  matched,
  unmatched,
  ambiguous,
}

/// Structured result returned by [SeriesScraper.matchEpisodeAcrossLines].
class CrossLineEpisodeMatch {
  final CrossLineEpisodeMatchKind kind;
  final int? episodeIndex;
  final String reason;

  const CrossLineEpisodeMatch.matched(int index, {this.reason = ''})
      : kind = CrossLineEpisodeMatchKind.matched,
        episodeIndex = index;

  const CrossLineEpisodeMatch.unmatched({this.reason = ''})
      : kind = CrossLineEpisodeMatchKind.unmatched,
        episodeIndex = null;

  const CrossLineEpisodeMatch.ambiguous({this.reason = ''})
      : kind = CrossLineEpisodeMatchKind.ambiguous,
        episodeIndex = null;

  bool get isMatched =>
      kind == CrossLineEpisodeMatchKind.matched && episodeIndex != null;
}

/// Search candidate returned by in-series manual scraping (Douban / Bangumi /
/// Bilibili PGC) so the user can inspect and bind the exact official work.
class SeriesScrapeCandidate {
  final String source; // 'douban' | 'bangumi' | 'bilibili'
  final String subjectId;
  final String title;
  final String subtitle;
  final String year;
  final bool isTv;
  final bool isMotionComic;
  final String mediaBadge; // e.g. '动漫' | '动态漫画' | '剧集' | '电影'
  final String posterUrl;
  final String backdropUrl;
  final String synopsis;
  final double? rating;
  final int? episodeCount;

  const SeriesScrapeCandidate({
    required this.source,
    required this.subjectId,
    required this.title,
    this.subtitle = '',
    this.year = '',
    this.isTv = true,
    this.isMotionComic = false,
    this.mediaBadge = '',
    this.posterUrl = '',
    this.backdropUrl = '',
    this.synopsis = '',
    this.rating,
    this.episodeCount,
  });

  SeriesScrapeCandidate copyWith({
    String? title,
    String? subtitle,
    String? year,
    bool? isTv,
    bool? isMotionComic,
    String? mediaBadge,
    String? posterUrl,
    String? backdropUrl,
    String? synopsis,
    double? rating,
    int? episodeCount,
  }) {
    return SeriesScrapeCandidate(
      source: source,
      subjectId: subjectId,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      year: year ?? this.year,
      isTv: isTv ?? this.isTv,
      isMotionComic: isMotionComic ?? this.isMotionComic,
      mediaBadge: mediaBadge ?? this.mediaBadge,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      synopsis: synopsis ?? this.synopsis,
      rating: rating ?? this.rating,
      episodeCount: episodeCount ?? this.episodeCount,
    );
  }
}

/// Persisted per-series manual scrape binding & episode calibration override.
class SeriesScrapeOverride {
  final String matchedTitle;
  final String matchedYear;
  final String source; // 'douban' | 'bangumi' | 'bilibili' | 'custom' | ''
  final String subjectId;
  final bool isTv;
  final bool isMotionComic;
  final String posterUrl;
  final String backdropUrl;
  final String synopsis;
  final double? doubanScore;
  final int episodeOffset;
  final bool? sortByScrapedEpisode;
  final bool hideSpecials;
  final String danmuTitleOverride;
  final String danmuAnimeId;
  final String danmuOrigin;
  final Map<String, int> episodeNumberOverrides;
  final Map<String, EpisodeManualCalibration> episodeCalibrations;
  final int updatedAtMs;

  const SeriesScrapeOverride({
    this.matchedTitle = '',
    this.matchedYear = '',
    this.source = '',
    this.subjectId = '',
    this.isTv = true,
    this.isMotionComic = false,
    this.posterUrl = '',
    this.backdropUrl = '',
    this.synopsis = '',
    this.doubanScore,
    this.episodeOffset = 0,
    this.sortByScrapedEpisode,
    this.hideSpecials = false,
    this.danmuTitleOverride = '',
    this.danmuAnimeId = '',
    this.danmuOrigin = '',
    this.episodeNumberOverrides = const {},
    this.episodeCalibrations = const {},
    this.updatedAtMs = 0,
  });

  bool get hasWorkBinding =>
      matchedTitle.trim().isNotEmpty ||
      subjectId.trim().isNotEmpty ||
      posterUrl.trim().isNotEmpty ||
      backdropUrl.trim().isNotEmpty;

  bool get hasEpisodeCalibration =>
      episodeOffset != 0 ||
      sortByScrapedEpisode != null ||
      hideSpecials ||
      episodeNumberOverrides.isNotEmpty ||
      episodeCalibrations.isNotEmpty ||
      danmuTitleOverride.trim().isNotEmpty ||
      danmuAnimeId.trim().isNotEmpty;

  bool get isEmpty => !hasWorkBinding && !hasEpisodeCalibration;

  String get effectiveDanmuTitle {
    if (danmuTitleOverride.trim().isNotEmpty) return danmuTitleOverride.trim();
    if (matchedTitle.trim().isNotEmpty) return matchedTitle.trim();
    return '';
  }

  String get doubanId => source == 'douban' ? subjectId.trim() : '';

  SeriesScrapeOverride copyWith({
    String? matchedTitle,
    String? matchedYear,
    String? source,
    String? subjectId,
    bool? isTv,
    bool? isMotionComic,
    String? posterUrl,
    String? backdropUrl,
    String? synopsis,
    double? doubanScore,
    bool clearDoubanScore = false,
    int? episodeOffset,
    bool? sortByScrapedEpisode,
    bool clearSortByScrapedEpisode = false,
    bool? hideSpecials,
    String? danmuTitleOverride,
    String? danmuAnimeId,
    String? danmuOrigin,
    Map<String, int>? episodeNumberOverrides,
    Map<String, EpisodeManualCalibration>? episodeCalibrations,
    int? updatedAtMs,
  }) {
    return SeriesScrapeOverride(
      matchedTitle: matchedTitle ?? this.matchedTitle,
      matchedYear: matchedYear ?? this.matchedYear,
      source: source ?? this.source,
      subjectId: subjectId ?? this.subjectId,
      isTv: isTv ?? this.isTv,
      isMotionComic: isMotionComic ?? this.isMotionComic,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      synopsis: synopsis ?? this.synopsis,
      doubanScore:
          clearDoubanScore ? null : (doubanScore ?? this.doubanScore),
      episodeOffset: episodeOffset ?? this.episodeOffset,
      sortByScrapedEpisode: clearSortByScrapedEpisode
          ? null
          : (sortByScrapedEpisode ?? this.sortByScrapedEpisode),
      hideSpecials: hideSpecials ?? this.hideSpecials,
      danmuTitleOverride: danmuTitleOverride ?? this.danmuTitleOverride,
      danmuAnimeId: danmuAnimeId ?? this.danmuAnimeId,
      danmuOrigin: danmuOrigin ?? this.danmuOrigin,
      episodeNumberOverrides:
          episodeNumberOverrides ?? this.episodeNumberOverrides,
      episodeCalibrations: episodeCalibrations ?? this.episodeCalibrations,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'matchedTitle': matchedTitle,
        'matchedYear': matchedYear,
        'source': source,
        'subjectId': subjectId,
        'isTv': isTv,
        'isMotionComic': isMotionComic,
        'posterUrl': posterUrl,
        'backdropUrl': backdropUrl,
        'synopsis': synopsis,
        if (doubanScore != null) 'doubanScore': doubanScore,
        'episodeOffset': episodeOffset,
        if (sortByScrapedEpisode != null)
          'sortByScrapedEpisode': sortByScrapedEpisode,
        'hideSpecials': hideSpecials,
        'danmuTitleOverride': danmuTitleOverride,
        'danmuAnimeId': danmuAnimeId,
        'danmuOrigin': danmuOrigin,
        if (episodeNumberOverrides.isNotEmpty)
          'episodeNumberOverrides': episodeNumberOverrides,
        if (episodeCalibrations.isNotEmpty)
          'episodeCalibrations': {
            for (final entry in episodeCalibrations.entries)
              entry.key: entry.value.toJson(),
          },
        'updatedAtMs': updatedAtMs,
      };

  factory SeriesScrapeOverride.fromJson(Map<String, dynamic> json) {
    final rawOverrides = json['episodeNumberOverrides'];
    final epOverrides = <String, int>{};
    if (rawOverrides is Map) {
      for (final entry in rawOverrides.entries) {
        final k = entry.key.toString();
        final v = entry.value is num
            ? (entry.value as num).toInt()
            : int.tryParse(entry.value.toString());
        if (k.isNotEmpty && v != null && v > 0) {
          epOverrides[k] = v;
        }
      }
    }
    final rawCalibs = json['episodeCalibrations'];
    final epCalibs = <String, EpisodeManualCalibration>{};
    if (rawCalibs is Map) {
      for (final entry in rawCalibs.entries) {
        final k = entry.key.toString().trim();
        final v = entry.value;
        if (k.isNotEmpty && v is Map) {
          final parsed = EpisodeManualCalibration.fromJson(
            Map<String, dynamic>.from(v),
          );
          if (!parsed.isEmpty) {
            epCalibs[k] = parsed;
          }
        }
      }
    }
    final rawScore = json['doubanScore'];
    final score = rawScore is num
        ? rawScore.toDouble()
        : (rawScore != null ? double.tryParse(rawScore.toString()) : null);
    return SeriesScrapeOverride(
      matchedTitle: (json['matchedTitle'] ?? '').toString().trim(),
      matchedYear: (json['matchedYear'] ?? '').toString().trim(),
      source: (json['source'] ?? '').toString().trim(),
      subjectId: (json['subjectId'] ?? '').toString().trim(),
      isTv: json['isTv'] != false,
      isMotionComic: json['isMotionComic'] == true,
      posterUrl: (json['posterUrl'] ?? '').toString().trim(),
      backdropUrl: (json['backdropUrl'] ?? '').toString().trim(),
      synopsis: (json['synopsis'] ?? '').toString().trim(),
      doubanScore: score,
      episodeOffset: (json['episodeOffset'] as num?)?.toInt() ?? 0,
      sortByScrapedEpisode: json['sortByScrapedEpisode'] is bool
          ? json['sortByScrapedEpisode'] as bool
          : null,
      hideSpecials: json['hideSpecials'] == true,
      danmuTitleOverride: (json['danmuTitleOverride'] ?? '').toString().trim(),
      danmuAnimeId: (json['danmuAnimeId'] ?? '').toString().trim(),
      danmuOrigin: (json['danmuOrigin'] ?? '').toString().trim(),
      episodeNumberOverrides: epOverrides,
      episodeCalibrations: epCalibs,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Unified series-identity classifier, episode-number scraper, and interactive
/// multi-source scraper (Douban Rexxar / Bangumi / Bilibili PGC).
class SeriesScraper {
  SeriesScraper._();

  static const String _mobileUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _biliCookie =
      'buvid3=58D32EBE-894C-69EE-AE53-607BE1EC3CC597728infoc; b_nut=1793900397';

  static final math.Random _rng = math.Random();
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 20)
    ..maxConnectionsPerHost = 10
    ..autoUncompress = true;

  static final RegExp _motionComicRe = RegExp(
    r'动态漫画|动态漫|漫动画|有声漫画|有声漫|条漫|沙雕动画|动画漫画|国产动态漫',
    caseSensitive: false,
  );
  static final RegExp _audioBookRe = RegExp(
    r'[\(（\[【·\s](?:音频|有声书|有声小说|广播剧|多人有声剧)[\)）\]】\s$]|（音频）|\(音频\)',
    caseSensitive: false,
  );
  static final RegExp _recapRe = RegExp(
    r'(?:^|[\s_·\-—:：\(（\[【])(?:解说|速看|剧情解析|合集解说|深度解说|一口气看完)',
    caseSensitive: false,
  );
  static final RegExp _gameRe = RegExp(
    r'手游网|游戏下载|全集下载|端游|网游|手游攻略|客户端下载|官方手游',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------------
  // 1. Work-Form Classification & Roman/Season/Year Title Normalization
  // ---------------------------------------------------------------------------

  /// Detects whether [rawTitle] (and optional [extraContext] like `tag`,
  /// `remarks`, `subtitle`, or `abstract`) refers to a dynamic comic
  /// (`动态漫画` / `动态漫`), audio book, recap, game, or standard film/TV/anime.
  static MediaWorkForm detectWorkForm(
    String rawTitle, {
    String extraContext = '',
  }) {
    final combined = '$rawTitle $extraContext';
    if (_motionComicRe.hasMatch(combined)) {
      return MediaWorkForm.motionComic;
    }
    if (_audioBookRe.hasMatch(combined)) {
      return MediaWorkForm.audioBook;
    }
    if (_recapRe.hasMatch(rawTitle)) {
      return MediaWorkForm.recap;
    }
    if (_gameRe.hasMatch(combined)) {
      return MediaWorkForm.game;
    }
    return MediaWorkForm.standard;
  }

  /// Shorthand checking if the raw title / metadata explicitly indicates a
  /// motion comic (`动态漫画` / `动态漫` / `漫动画`).
  static bool isMotionComicText(
    String rawTitle, {
    String extraContext = '',
  }) =>
      detectWorkForm(rawTitle, extraContext: extraContext) ==
      MediaWorkForm.motionComic;

  /// Checks whether a candidate work form is compatible with the target work
  /// form. Dynamic comics (`动态漫画`) NEVER match regular anime/dramas and vice
  /// versa; audio books / recaps / games never match standard works.
  static bool isCompatibleWorkForm({
    required bool targetIsMotionComic,
    required String candidateTitle,
    String candidateContext = '',
  }) {
    final candForm = detectWorkForm(
      candidateTitle,
      extraContext: candidateContext,
    );
    if (targetIsMotionComic) {
      return candForm == MediaWorkForm.motionComic;
    }
    return candForm == MediaWorkForm.standard;
  }

  /// Normalizes Roman numerals used as sequel markers (`斗罗大陆Ⅱ绝世唐门` /
  /// `斗罗大陆II绝世唐门` / `庆余年Ⅱ` -> `斗罗大陆2绝世唐门` / `庆余年2`) without
  /// mangling English words like `VIP` or `AI`.
  static String normalizeSequelNumerals(String raw) {
    var s = raw
        .replaceAll('Ⅰ', '1')
        .replaceAll('Ⅱ', '2')
        .replaceAll('Ⅲ', '3')
        .replaceAll('Ⅳ', '4')
        .replaceAll('Ⅴ', '5')
        .replaceAll('Ⅵ', '6')
        .replaceAll('Ⅶ', '7')
        .replaceAll('Ⅷ', '8')
        .replaceAll('Ⅸ', '9')
        .replaceAll('Ⅹ', '10');
    // ASCII Roman numerals adjacent to CJK characters or at trailing sequel position.
    s = s.replaceAllMapped(
      RegExp(
        r'(?<=[\u4e00-\u9fff\s·:：\-—])(III|II|IV|VI|V)(?=$|[\u4e00-\u9fff\s·:：\-—\(（\[【])',
      ),
      (m) => switch (m.group(1)) {
        'II' => '2',
        'III' => '3',
        'IV' => '4',
        'V' => '5',
        'VI' => '6',
        _ => m.group(0)!,
      },
    );
    return s;
  }

  /// Cleans a series title for comparison while normalizing sequel Roman
  /// numerals and stripping broadcast suffixes (`年番1`, `动态漫画`, quality tags,
  /// trailing year). Call [isMotionComicText] BEFORE calling this.
  static String normalizeWorkCoreTitle(String rawTitle) {
    var s = rawTitle
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'_360百科.*$|-360百科.*$|_百度百科.*$'), '')
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(_motionComicRe, '')
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:年番\s*[0-9一二三四五六七八九十]*|第[0-9一二三四五六七八九十百零〇]+[季部集期篇章话])',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'(?:^|[\s·\-—:：_]+)(?:Season[\s._\-]*0*\d{1,2}|[Ss]0*\d{1,2})(?=$|[\s·\-—:：_\(（\[【])',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|TC|TS)(?![A-Za-z0-9])',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:臻彩|杜比视界|杜比|高码|原盘|国粤双语|国语|粤语|中字|双语|超清|高清|蓝光|未删减版?|完整版?|抢先版?)\s*$',
          ),
          '',
        )
        .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
        .trim();
    s = normalizeSequelNumerals(s);
    return s
        .replaceAll(RegExp(r'[《》〈〉「」『』"“”\x27‘’：:·—\-\s_!！?？,，.。]'), '')
        .toLowerCase();
  }

  /// Extracts a clean display/search title suitable for Danmu & external APIs,
  /// preserving spaces/colons and stripping resolution/edition clutter.
  static String cleanSearchTitle(String rawTitle) {
    return rawTitle
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .replaceAll(_motionComicRe, '')
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|TC|TS)(?![A-Za-z0-9])',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'[\s·\-—:：]*(?:臻彩|杜比视界|杜比|高码|原盘|国粤双语|国语|粤语|中字|双语|超清|高清|蓝光|未删减版?|完整版?|抢先版?)\s*$',
          ),
          '',
        )
        .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // ---------------------------------------------------------------------------
  // 2. In-Series Episode Number & Special Scraper
  // ---------------------------------------------------------------------------

  static final RegExp _specialKeywordRe = RegExp(
    r'(?:预告|抢先看|片花|花絮|特辑|特典|彩蛋|幕后|采访|访谈|宣发|宣传片|定档|先导片?|总集篇|精编|纯享|加更|合集说明|群聊|二维码|广告|'
    r'番外|特别篇|剧场版|小剧场|片头曲|片尾曲|主题曲|'
    r'(?<![A-Za-z])(?:SP|OVA|OAD|PV|CM|OP|ED|MV|OST|NCOP|NCED|Trailer|Preview|Teaser|Extras?|Bonus|Making|Behind)(?![A-Za-z]))',
    caseSensitive: false,
  );

  static final RegExp _seasonOnlyRe = RegExp(
    r'(?:第\s*0*([0-9一二三四五六七八九十两兩]{1,4})\s*[季部]|(?:^|[^A-Za-z0-9])(?:season\s*0*(\d{1,2})|[Ss]0*(\d{1,2})(?![0-9A-Za-z])))',
    caseSensitive: false,
  );

  /// Extracts an explicit season number from [text] (e.g. `S02E05`, `Season 2`,
  /// `第2季`, `第二季`), or `null` when none is present.
  static int? extractSeasonNumber(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final normalized = normalizeSequelNumerals(trimmed);
    final seMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])[Ss]0*(\d{1,2})[\s._\-]*[Ee][Pp]?0*\d{1,4}(?![0-9])',
    ).firstMatch(normalized);
    if (seMatch != null) {
      final n = int.tryParse(seMatch.group(1)!);
      if (n != null && n > 0 && n <= 99) return n;
    }
    final m = _seasonOnlyRe.firstMatch(normalized);
    if (m != null) {
      final raw = m.group(1) ?? m.group(2) ?? m.group(3);
      if (raw != null) {
        final n = _parseChineseInt(raw.replaceAll('兩', '两'));
        if (n != null && n > 0 && n <= 99) return n;
      }
    }
    return null;
  }

  static final RegExp _techNoiseRe = RegExp(
    r'\[\s*\d+(?:\.\d+)?\s*[KMGT]?B\s*\]|'
    r'\(\s*\d+(?:\.\d+)?\s*[KMGT]?B\s*\)|'
    r'(?<![A-Za-z0-9])(?:'
    r'4K|8K|2K|UHD|FHD|HD|BD|BluRay|Blu-?Ray|WEB-?DL|WEBRip|BDRip|HDRip|DVDRip|REMUX|'
    r'2160[pP]|1440[pP]|1080[pPiI]|720[pP]|576[pP]|480[pP]|360[pP]|'
    r'(?:24|25|30|50|60|120)\s*(?:fps|帧|Hz)|'
    r'(?:8|10|12)\s*bit|'
    r'[HxXx]\.?26[45]|HEVC|AVC|AV1|VP9|MPEG[24]|'
    r'HDR10\+?|HDR|SDR|DoVi|DV|Dolby|Atmos|DDP\s*5\.1|DD\s*5\.1|DTS(?:-?HD)?|AAC\s*2\.0|FLAC|AC3|5\.1|7\.1|2\.0|'
    r'60帧|120帧|高帧率|高码率?|臻彩|杜比视界|杜比|原盘|蓝光|超清|高清|国粤双语|国语|粤语|中字|双语|简繁|内封|内嵌|无水印|官中'
    r')(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static String _extractQualityTag(String rawName) {
    final upper = rawName.toUpperCase();
    final parts = <String>[];
    if (upper.contains('4K') || upper.contains('2160P')) {
      parts.add('4K');
    } else if (upper.contains('1080P')) {
      parts.add('1080P');
    } else if (upper.contains('720P')) {
      parts.add('720P');
    }
    if (upper.contains('DOVI') ||
        upper.contains('杜比视界') ||
        RegExp(r'(?<![A-Z])DV(?![A-Z])').hasMatch(upper)) {
      parts.add('杜比');
    } else if (upper.contains('HDR')) {
      parts.add('HDR');
    }
    if (RegExp(r'60\s*(?:FPS|帧)', caseSensitive: false).hasMatch(rawName)) {
      parts.add('60帧');
    }
    final sizeMatch = RegExp(
      r'[\[\(]\s*(\d+(?:\.\d+)?\s*[GM]B)\s*[\]\)]',
      caseSensitive: false,
    ).firstMatch(rawName);
    if (sizeMatch != null && parts.isEmpty) {
      parts.add(sizeMatch.group(1)!.toUpperCase());
    }
    return parts.take(2).join(' · ');
  }

  static String _stripFileExtension(String raw) {
    return raw
        .replaceAll(
          RegExp(
            r'\.(?:mp4|mkv|ts|m2ts|flv|avi|mov|rmvb|wmv|webm|m3u8|iso)$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  static int? _parseChineseInt(String token) {
    final trimmed = token.trim();
    final arabic = int.tryParse(trimmed);
    if (arabic != null) return arabic;
    const digits = <String, int>{
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    int total = 0;
    int current = 0;
    bool seen = false;
    for (int i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];
      if (digits.containsKey(ch)) {
        current = digits[ch]!;
        seen = true;
      } else if (ch == '十') {
        total += (current == 0 ? 1 : current) * 10;
        current = 0;
        seen = true;
      } else if (ch == '百') {
        total += (current == 0 ? 1 : current) * 100;
        current = 0;
        seen = true;
      } else if (ch == '千') {
        total += (current == 0 ? 1 : current) * 1000;
        current = 0;
        seen = true;
      } else {
        return null;
      }
    }
    if (!seen) return null;
    return total + current;
  }

  static String _stripSeriesTitleFromEpisode(
    String cleanedName,
    String seriesTitle,
  ) {
    var text = normalizeSequelNumerals(cleanedName);
    final cleanSeries = cleanSearchTitle(seriesTitle);
    if (cleanSeries.isEmpty) return text;

    final candidates = <String>{
      seriesTitle.trim(),
      cleanSeries,
      normalizeSequelNumerals(cleanSeries),
      cleanSeries.replaceAll(RegExp(r'[\s:：·\-—_]+'), ''),
      normalizeSequelNumerals(cleanSeries)
          .replaceAll(RegExp(r'[\s:：·\-—_]+'), ''),
    }..removeWhere((s) => s.length < 2);

    final sorted = candidates.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final c in sorted) {
      final escaped = RegExp.escape(c);
      final stripped = text.replaceAll(
        RegExp(escaped, caseSensitive: false),
        ' ',
      );
      if (stripped.trim().isNotEmpty) {
        text = stripped;
      }
    }
    // Also strip individual CJK title segments separated by colons/spaces when
    // length >= 3 (e.g. `斗罗大陆2：绝世唐门` -> `斗罗大陆2`, `绝世唐门`).
    for (final part in cleanSeries.split(RegExp(r'[:：·\-—\s]+'))) {
      final p = part.trim();
      if (p.length >= 3) {
        final stripped = text.replaceAll(
          RegExp(RegExp.escape(p), caseSensitive: false),
          ' ',
        );
        if (stripped.trim().isNotEmpty) {
          text = stripped;
        }
      }
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const Set<String> _volatileQueryParams = <String>{
    'token',
    'sign',
    'sig',
    'auth',
    'expires',
    'exp',
    'timestamp',
    'ts',
    't',
    'key',
    'signature',
    'api_key',
    'playsessionid',
    'x-amz-signature',
    'x-amz-credential',
    'x-amz-date',
    'x-amz-expires',
    'x-amz-security-token',
  };

  /// Derives a stable file or item identifier for [episode] so manual episode
  /// calibrations follow the true underlying file/item across line reorders,
  /// renames, restarts, and volatile auth query tokens.
  static String stableEpisodeKey(CmsEpisode episode) {
    final rawUrl = episode.url.trim();
    if (rawUrl.startsWith('mmemby://play?')) {
      final uri = Uri.tryParse(rawUrl);
      final id = (uri?.queryParameters['id'] ?? '').trim();
      if (id.isNotEmpty) return 'emby:$id';
    }
    final sourceId = episode.sourceItemId.trim();
    if (sourceId.isNotEmpty) {
      if (episode.playbackSession.containsKey('ItemId')) {
        return 'emby:$sourceId';
      }
      return 'item:$sourceId';
    }
    final sessionItemId = (episode.playbackSession['ItemId'] ?? '').toString().trim();
    if (sessionItemId.isNotEmpty) {
      return 'emby:$sessionItemId';
    }
    if (episode.isLocalFile) {
      final localPath =
          ContainerMetadataReader.resolveLocalFilePath(rawUrl) ?? rawUrl;
      return 'file:${localPath.replaceAll('\\', '/')}';
    }
    if (rawUrl.isNotEmpty) {
      final uri = Uri.tryParse(rawUrl);
      if (uri != null && uri.hasScheme) {
        final scheme = uri.scheme.toLowerCase();
        final host = uri.host.toLowerCase();
        final port = uri.hasPort ? ':${uri.port}' : '';
        final path = uri.path;
        final kept = <String>[];
        final keys = uri.queryParameters.keys.toList()..sort();
        for (final k in keys) {
          final lk = k.toLowerCase();
          if (_volatileQueryParams.contains(lk)) continue;
          final v = uri.queryParameters[k] ?? '';
          if (v.isNotEmpty) kept.add('$k=$v');
        }
        final q = kept.isEmpty ? '' : '?${kept.join('&')}';
        return 'url:$scheme://$host$port$path$q';
      }
      return 'url:$rawUrl';
    }
    return 'name:${episode.name.trim()}';
  }

  static String _formatEpisodeDisplayLabel(
    int? seasonNumber,
    int episodeNumber,
    int? endEpisodeNumber,
  ) {
    if (seasonNumber != null && seasonNumber > 0) {
      final s = seasonNumber.toString().padLeft(2, '0');
      final e = episodeNumber.toString().padLeft(2, '0');
      if (endEpisodeNumber != null && endEpisodeNumber > episodeNumber) {
        final endStr = endEpisodeNumber.toString().padLeft(2, '0');
        return 'S${s}E$e–E$endStr';
      }
      return 'S${s}E$e';
    }
    if (endEpisodeNumber != null && endEpisodeNumber > episodeNumber) {
      return '第 $episodeNumber–$endEpisodeNumber 集';
    }
    return '第 $episodeNumber 集';
  }

  static String _parentDirectoryOfPath(String rawPath) {
    final norm = rawPath.trim().replaceAll('\\', '/');
    if (norm.isEmpty) return '';
    final slash = norm.lastIndexOf('/');
    return slash > 0 ? norm.substring(0, slash) : '';
  }

  static String _basenameOfPath(String rawPath) {
    final norm = rawPath.trim().replaceAll('\\', '/');
    if (norm.isEmpty) return '';
    final slash = norm.lastIndexOf('/');
    return slash >= 0 ? norm.substring(slash + 1).trim() : norm;
  }

  static String _extractOriginalFileName(CmsEpisode episode) {
    if (episode.originalFileName.trim().isNotEmpty) {
      return episode.originalFileName.trim();
    }
    for (final k in const ['fileName', 'filename', 'name']) {
      final v = episode.playbackSession[k];
      if (v is String && v.trim().isNotEmpty) {
        return v.trim();
      }
    }
    final sessionPath = episode.playbackSession['path'];
    if (sessionPath is String && sessionPath.trim().isNotEmpty) {
      final base = _basenameOfPath(sessionPath);
      if (base.isNotEmpty) return base;
    }
    if (episode.isLocalFile) {
      final local =
          ContainerMetadataReader.resolveLocalFilePath(episode.url) ??
              episode.url.trim();
      final base = _basenameOfPath(local);
      if (base.isNotEmpty) return base;
    }
    final uri = Uri.tryParse(episode.url.trim());
    if (uri != null) {
      final qName = (uri.queryParameters['name'] ?? '').trim();
      if (qName.isNotEmpty) return qName;
      final qPath = (uri.queryParameters['path'] ?? '').trim();
      if (qPath.isNotEmpty) {
        final base = _basenameOfPath(qPath);
        if (base.isNotEmpty) return base;
      }
      if (episode.nameIsGenerated && uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.last.trim();
        if (last.isNotEmpty) return last;
      }
    }
    if (!episode.nameIsGenerated && episode.name.trim().isNotEmpty) {
      return episode.name.trim();
    }
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last.trim();
      if (last.isNotEmpty) return last;
    }
    return '';
  }

  static String _extractDirectoryPath(CmsEpisode episode) {
    if (episode.directoryPath.trim().isNotEmpty) {
      return episode.directoryPath.trim();
    }
    for (final k in const ['dir', 'directory', 'folder', 'parentPath']) {
      final v = episode.playbackSession[k];
      if (v is String && v.trim().isNotEmpty) {
        return v.trim();
      }
    }
    final sessionPath = episode.playbackSession['path'];
    if (sessionPath is String && sessionPath.trim().isNotEmpty) {
      final dir = _parentDirectoryOfPath(sessionPath);
      if (dir.isNotEmpty) return dir;
    }
    if (episode.isLocalFile) {
      final local =
          ContainerMetadataReader.resolveLocalFilePath(episode.url) ??
              episode.url.trim();
      return _parentDirectoryOfPath(local);
    }
    final uri = Uri.tryParse(episode.url.trim());
    if (uri != null) {
      final qDir = (uri.queryParameters['dir'] ?? '').trim();
      if (qDir.isNotEmpty) return qDir;
      final qPath = (uri.queryParameters['path'] ?? '').trim();
      if (qPath.isNotEmpty) {
        final dir = _parentDirectoryOfPath(qPath);
        if (dir.isNotEmpty) return dir;
      }
      if (uri.pathSegments.length > 1) {
        return uri.pathSegments
            .sublist(0, uri.pathSegments.length - 1)
            .join('/');
      }
    }
    return '';
  }

  static int? _extractDirectorySeason(String dirPath) {
    final raw = dirPath.trim();
    if (raw.isEmpty) return null;
    final segments = raw.replaceAll('\\', '/').split('/');
    // Inspect deepest parent directories first so `/Shows/Season 2/` wins over root names.
    for (int i = segments.length - 1; i >= 0; i--) {
      final seg = segments[i].trim();
      if (seg.isEmpty) continue;
      final enMatch = RegExp(
        r'(?:^|[\s._\-\[\(【（])(?:Season[\s._\-]*0*(\d{1,2})|[Ss]0*(\d{1,2}))(?=$|[\s._\-\]\)】）])',
        caseSensitive: false,
      ).firstMatch(seg);
      if (enMatch != null) {
        final n = int.tryParse(enMatch.group(1) ?? enMatch.group(2) ?? '');
        if (n != null && n > 0 && n <= 99) return n;
      }
      final cnMatch = RegExp(
        r'第\s*([0-9一二三四五六七八九十两]+)\s*[季部]',
      ).firstMatch(seg);
      if (cnMatch != null) {
        final n = _parseChineseInt(cnMatch.group(1)!);
        if (n != null && n > 0 && n <= 99) return n;
      }
    }
    return null;
  }

  static ({
    int? season,
    int? ep,
    int? endEp,
    bool isSpecial,
    String specialTag,
    String cleanSpecialLabel,
    double confidence,
    bool hasExplicitMarker,
    bool isVarietyDate,
    String varietyLabel,
  }) _parseNameSignals(
    String rawName, {
    String seriesTitle = '',
    Set<int> constantNumbers = const {},
    String sharedPrefix = '',
  }) {
    final trimmed = rawName.trim();
    final work = _stripFileExtension(trimmed);
    var withoutSeries = _stripSeriesTitleFromEpisode(work, seriesTitle);
    if (sharedPrefix.length >= 2 &&
        withoutSeries.startsWith(sharedPrefix) &&
        withoutSeries.length > sharedPrefix.length) {
      withoutSeries = withoutSeries.substring(sharedPrefix.length).trim();
    }

    // Extract explicit season number and full calendar date (`2026-03-15` / `20260315`).
    int? seasonNum = extractSeasonNumber(withoutSeries);
    final dateKey = extractFullDateKey(withoutSeries);

    // 2. Detect explicit specials / trailers / previews / SP / OVA / extras / 特典.
    final specialMatch = _specialKeywordRe.firstMatch(withoutSeries);
    if (specialMatch != null) {
      final matchedToken = specialMatch.group(0)!.trim();
      final spNumMatch = RegExp(
        '(?:${RegExp.escape(matchedToken)})\\s*[-_.]?\\s*0*(\\d{1,3})',
        caseSensitive: false,
      ).firstMatch(withoutSeries);
      final spTag = spNumMatch != null
          ? '$matchedToken${spNumMatch.group(1)}'
          : matchedToken;
      final cleanLabel = withoutSeries
          .replaceAll(_techNoiseRe, '')
          .replaceAll(RegExp(r'[\[\(【（]\s*[\]\)】）]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return (
        season: seasonNum,
        ep: null,
        endEp: null,
        isSpecial: true,
        specialTag: spTag,
        cleanSpecialLabel: cleanLabel.isNotEmpty ? cleanLabel : spTag,
        confidence: 0.95,
        hasExplicitMarker: true,
        isVarietyDate: false,
        varietyLabel: '',
      );
    }

    // 3. Extract explicit season number if present (`S02E05`, `第2季`).
    if (seasonNum == null) {
      final cnSeason = RegExp(
        r'第\s*([0-9一二三四五六七八九十两]+)\s*[季部]',
      ).firstMatch(withoutSeries);
      if (cnSeason != null) {
        final n = _parseChineseInt(cnSeason.group(1)!);
        if (n != null && n > 0 && n <= 99) seasonNum = n;
      }
    }
    if (seasonNum == null) {
      final enSeason = RegExp(
        r'(?:^|[^A-Za-z0-9])Season[\s._\-]*0*(\d{1,2})(?![0-9])',
        caseSensitive: false,
      ).firstMatch(withoutSeries);
      if (enSeason != null) {
        final n = int.tryParse(enSeason.group(1)!);
        if (n != null && n > 0 && n <= 99) seasonNum = n;
      }
    }

    int? rawEp;
    int? endEp;
    double confidence = 0.0;
    bool explicitMarker = false;

    // Pattern A: SxxExx / Sxx.Exx / Sxx-EPxx (highest precision)
    final seMatch = RegExp(
      r'(?:^|[^A-Za-z0-9])[Ss]0*(\d{1,2})[\s._\-]*[Ee][Pp]?0*(\d{1,4})(?:\s*[-~]\s*[Ee]?[Pp]?0*(\d{1,4}))?(?![0-9])',
    ).firstMatch(withoutSeries);
    if (seMatch != null) {
      seasonNum = int.tryParse(seMatch.group(1)!) ?? seasonNum;
      rawEp = int.tryParse(seMatch.group(2)!);
      if (seMatch.group(3) != null) {
        endEp = int.tryParse(seMatch.group(3)!);
      }
      confidence = 1.0;
      explicitMarker = true;
    }

    // Pattern B: Chinese explicit `第180集` / `第01-02集` / `第12话` / `第一百八十集`
    if (rawEp == null) {
      final cnEpMatch = RegExp(
        r'第\s*0*([0-9一二三四五六七八九十百千万两〇零]{1,6})\s*(?:[-~至到]\s*0*([0-9]{1,4})\s*)?[集话話回章]',
      ).firstMatch(withoutSeries);
      if (cnEpMatch != null) {
        rawEp = _parseChineseInt(cnEpMatch.group(1)!);
        if (cnEpMatch.group(2) != null) {
          endEp = int.tryParse(cnEpMatch.group(2)!);
        }
        confidence = 0.98;
        explicitMarker = true;
      }
    }

    // Pattern D (elevated before loose numeric stripping): full calendar date
    // episodes (`2026-03-15期`, `2026.03.15期`, `2026-03-15`, `20260315期`) or
    // explicit `第X期` variety issues. Keep full date as primary identity so
    // day-of-month `15` is never mistaken for Episode 15.
    if (rawEp == null &&
        (dateKey.isNotEmpty || RegExp(r'第\s*\d+\s*期').hasMatch(withoutSeries))) {
      final cleanVariety = withoutSeries
          .replaceAll(_techNoiseRe, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return (
        season: seasonNum,
        ep: null,
        endEp: null,
        isSpecial: false,
        specialTag: '',
        cleanSpecialLabel: '',
        confidence: dateKey.isNotEmpty ? 0.85 : 0.7,
        hasExplicitMarker: false,
        isVarietyDate: true,
        varietyLabel: cleanVariety.isNotEmpty ? cleanVariety : trimmed,
      );
    }

    // Strip technical noise, release years & part numbers before looser numeric patterns.
    final denoised = withoutSeries
        .replaceAll(_techNoiseRe, ' ')
        .replaceAll(_partMarkerRe, ' ')
        // Remove standalone 4-digit years (1950-2039) when bounded.
        .replaceAll(
          RegExp(r'(?<![0-9])(?:19[5-9]\d|20[0-3]\d)(?![0-9])'),
          ' ',
        )
        .replaceAll(RegExp(r'第\s*[0-9一二三四五六七八九十两]+\s*[季部]'), ' ')
        .replaceAll(
          RegExp(r'(?<![A-Za-z0-9])Season[\s._\-]*0*\d{1,2}(?![A-Za-z0-9])',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'(?<![A-Za-z0-9])[Ss]0*\d{1,2}(?![A-Za-z0-9])'), ' ')
        .replaceAll(RegExp(r'\b\d{3,4}\s*[xX×]\s*\d{3,4}\b'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Pattern C: Explicit `EP180` / `E180` / `E01-E02`
    if (rawEp == null) {
      final epPrefixMatch = RegExp(
        r'(?:^|[\s._\-\[\(【（])(?:EP|Ep|ep|E)\s*0*(\d{1,4})(?:\s*[-~]\s*(?:EP|Ep|ep|E)?0*(\d{1,4}))?(?![0-9A-Za-z])',
      ).firstMatch(denoised);
      if (epPrefixMatch != null) {
        rawEp = int.tryParse(epPrefixMatch.group(1)!);
        if (epPrefixMatch.group(2) != null) {
          endEp = int.tryParse(epPrefixMatch.group(2)!);
        }
        confidence = 0.95;
        explicitMarker = true;
      }
    }

    // Pattern E: Bracketed episode number (`[180]`, `【05】`, `(12完)`)
    if (rawEp == null) {
      final bracketMatches = RegExp(
        r'[\[\(【（]\s*0*(\d{1,4})\s*(?:[-~]\s*0*(\d{1,4})\s*)?(?:集|话|完|完结|END|v\d)?\s*[\]\)】）]',
        caseSensitive: false,
      ).allMatches(denoised);
      for (final m in bracketMatches) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= 0 && n <= 3000 && !constantNumbers.contains(n)) {
          rawEp = n;
          if (m.group(2) != null) endEp = int.tryParse(m.group(2)!);
          confidence = 0.90;
          explicitMarker = true;
          break;
        }
      }
    }

    // Pattern F: Delimited or standalone episode number (`180 4K.mp4`, `01.mp4`)
    if (rawEp == null) {
      final numMatches = RegExp(
        r'(?<![0-9A-Za-z])0*(\d{1,4})(?:\s*[-~]\s*0*(\d{1,4}))?(?![0-9A-Za-z])',
      ).allMatches(denoised).toList();
      final filtered = <({int n, int? end, int pos})>[];
      for (final m in numMatches) {
        final n = int.tryParse(m.group(1)!);
        if (n == null || n < 0 || n > 3000) continue;
        if (constantNumbers.contains(n)) continue;
        final e = m.group(2) != null ? int.tryParse(m.group(2)!) : null;
        filtered.add((n: n, end: e, pos: m.start));
      }
      if (filtered.isNotEmpty) {
        final picked = filtered.last;
        rawEp = picked.n;
        endEp = picked.end;
        confidence =
            RegExp(r'^0*\d{1,4}(?:\s*[-~]\s*0*\d{1,4})?$').hasMatch(denoised)
                ? 0.92
                : 0.82;
      }
    }

    if (rawEp == 0) {
      return (
        season: seasonNum,
        ep: 0,
        endEp: null,
        isSpecial: true,
        specialTag: '第0集',
        cleanSpecialLabel: '第 0 集',
        confidence: confidence,
        hasExplicitMarker: true,
        isVarietyDate: false,
        varietyLabel: '',
      );
    }

    return (
      season: seasonNum,
      ep: rawEp,
      endEp: endEp,
      isSpecial: false,
      specialTag: '',
      cleanSpecialLabel: '',
      confidence: confidence,
      hasExplicitMarker: explicitMarker || seasonNum != null,
      isVarietyDate: false,
      varietyLabel: '',
    );
  }

  static int? _parseTagPositiveInt(Map<String, String> tags, List<String> keys) {
    for (final k in keys) {
      final raw = tags[k]?.trim();
      if (raw == null || raw.isEmpty) continue;
      final m = RegExp(r'^0*(\d{1,4})(?:/\d+)?$').firstMatch(raw);
      if (m != null) {
        final v = int.tryParse(m.group(1)!);
        if (v != null && v >= 0) return v;
      }
    }
    return null;
  }

  static ({
    int? season,
    int? ep,
    int? endEp,
    bool isSpecial,
    String specialTag,
    String workTitle,
    String summary,
    bool hasConflict,
    List<String> conflictReasons,
  }) _parseContainerTagEvidence(
    Map<String, String> tags, {
    String seriesTitle = '',
  }) {
    if (tags.isEmpty) {
      return (
        season: null,
        ep: null,
        endEp: null,
        isSpecial: false,
        specialTag: '',
        workTitle: '',
        summary: '',
        hasConflict: false,
        conflictReasons: const <String>[],
      );
    }
    final norm = <String, String>{
      for (final e in tags.entries) e.key.trim().toLowerCase(): e.value.trim(),
    };
    int? season = _parseTagPositiveInt(
      norm,
      const ['season_number', 'season', 'tvsn'],
    );
    int? ep = _parseTagPositiveInt(
      norm,
      const ['episode_sort', 'episode_number', 'episode', 'tves', 'track'],
    );
    int? endEp;
    bool isSpecial = false;
    String specialTag = '';
    bool hasConflict = false;
    final conflictReasons = <String>[];
    final workTitle = (norm['show'] ?? norm['series'] ?? norm['tvsh'] ?? '').trim();

    final textSources = <({String key, String value})>[
      if ((norm['episode_id'] ?? '').isNotEmpty)
        (key: 'episode_id', value: norm['episode_id']!),
      if ((norm['tven'] ?? '').isNotEmpty) (key: 'tven', value: norm['tven']!),
      if ((norm['title'] ?? '').isNotEmpty)
        (key: 'title', value: norm['title']!),
      if ((norm['comment'] ?? '').isNotEmpty)
        (key: 'comment', value: norm['comment']!),
    ];
    String matchedText = '';
    for (final src in textSources) {
      final txt = src.value;
      final parsed = _parseNameSignals(txt, seriesTitle: seriesTitle);
      final strongMarker = parsed.hasExplicitMarker || parsed.confidence >= 0.90;
      if (parsed.isSpecial) {
        if (ep != null && ep > 0) {
          hasConflict = true;
          conflictReasons.add(
            '文件内部标签 ${src.key}（「$txt」）标记为特别篇/预告，但 EPISODE 标签为第 $ep 集',
          );
        } else if (!isSpecial) {
          isSpecial = true;
          specialTag = parsed.specialTag;
          if (matchedText.isEmpty) matchedText = txt;
        }
        continue;
      }
      if (parsed.season != null && parsed.season! > 0) {
        if (season != null && season > 0 && season != parsed.season) {
          hasConflict = true;
          conflictReasons.add(
            '文件内部标签季号冲突：标签写 S${season.toString().padLeft(2, '0')}，${src.key}（「$txt」）写 S${parsed.season!.toString().padLeft(2, '0')}',
          );
        } else if (season == null) {
          season = parsed.season;
          if (matchedText.isEmpty) matchedText = txt;
        }
      }
      if (parsed.ep != null && parsed.ep! > 0) {
        if (ep != null && ep > 0 && ep != parsed.ep && strongMarker) {
          hasConflict = true;
          conflictReasons.add(
            '文件内部标签集号冲突：EPISODE 写第 $ep 集，${src.key}（「$txt」）写第 ${parsed.ep} 集',
          );
        } else if (isSpecial && strongMarker) {
          hasConflict = true;
          conflictReasons.add(
            '文件内部标签正片/特别篇冲突：${src.key}（「$txt」）写第 ${parsed.ep} 集',
          );
        } else if (ep == null) {
          ep = parsed.ep;
          endEp = parsed.endEp;
          if (matchedText.isEmpty) matchedText = txt;
        }
      }
    }

    if (season == 0) {
      if (ep != null && ep > 0) {
        hasConflict = true;
        conflictReasons.add('文件内部标签季号为 0（特别篇），但集号为第 $ep 集');
      } else {
        isSpecial = true;
        specialTag = specialTag.isNotEmpty ? specialTag : 'SP';
      }
    }

    final summaryParts = <String>[];
    if (season != null && season > 0 && ep != null && ep > 0) {
      summaryParts.add(_formatEpisodeDisplayLabel(season, ep, endEp));
    } else if (ep != null && ep > 0) {
      summaryParts.add('第 $ep 集');
    } else if (season != null && season > 0) {
      summaryParts.add('第 $season 季');
    } else if (isSpecial) {
      summaryParts.add(specialTag.isNotEmpty ? specialTag : '特别篇');
    }
    if (matchedText.isNotEmpty &&
        (summaryParts.isEmpty || !summaryParts.first.contains(matchedText))) {
      summaryParts.add('「$matchedText」');
    }
    return (
      season: season != null && season > 0 ? season : null,
      ep: ep != null && ep > 0 ? ep : null,
      endEp: endEp,
      isSpecial: isSpecial,
      specialTag: specialTag,
      workTitle: workTitle,
      summary: summaryParts.join(' '),
      hasConflict: hasConflict,
      conflictReasons: List<String>.unmodifiable(conflictReasons),
    );
  }

  /// Scrapes a single [CmsEpisode] using strict evidence priority:
  /// 1. User-confirmed calibration (keyed by stable file/item ID, or legacy name override)
  /// 2. Structured source metadata (e.g. Emby Season/Episode/ItemId) & internal file container tags
  /// 3. Original filename & directory explicit season/episode markers
  /// Conflicts or insufficient evidence (e.g. `1080p` / empty name) explicitly yield `待确认`.
  static ScrapedEpisodeInfo scrapeEpisode(
    CmsEpisode episode, {
    int originalIndex = 0,
    String seriesTitle = '',
    int episodeOffset = 0,
    EpisodeManualCalibration? manualCalibration,
    int? legacyManualEpisodeOverride,
    Map<String, String> runtimeContainerTags = const {},
    Set<int> constantNumbers = const {},
    String sharedPrefix = '',
  }) {
    final stableKey = stableEpisodeKey(episode);
    final origFileName = _extractOriginalFileName(episode);
    final dirPath = _extractDirectoryPath(episode);
    final qualityTag = _extractQualityTag(
      origFileName.isNotEmpty ? origFileName : episode.name,
    );

    // 1. Priority 1: User-confirmed calibration always wins.
    if (manualCalibration != null && !manualCalibration.isEmpty) {
      if (manualCalibration.isSpecial) {
        return ScrapedEpisodeInfo(
          originalIndex: originalIndex,
          rawName: episode.name,
          originalFileName: origFileName,
          stableKey: stableKey,
          seasonNumber: manualCalibration.seasonNumber,
          isSpecial: true,
          specialTag: '特别篇',
          qualityTag: qualityTag,
          displayLabel: '特别篇',
          confidence: 1.0,
          hasManualOverride: true,
          status: EpisodeRecognitionStatus.special,
          evidenceSource: '用户已确认',
          evidenceDetails: <String>[
            '用户已确认为特别篇/预告',
            if (origFileName.isNotEmpty) '原文件名：$origFileName',
          ],
          recognizedWorkTitle: manualCalibration.workTitle.isNotEmpty
              ? manualCalibration.workTitle
              : seriesTitle,
        );
      }
      if (manualCalibration.episodeNumber != null &&
          manualCalibration.episodeNumber! > 0) {
        final epNum = manualCalibration.episodeNumber!;
        final season = manualCalibration.seasonNumber;
        final label = _formatEpisodeDisplayLabel(season, epNum, null);
        return ScrapedEpisodeInfo(
          originalIndex: originalIndex,
          rawName: episode.name,
          originalFileName: origFileName,
          stableKey: stableKey,
          seasonNumber: season,
          rawEpisodeNumber: epNum,
          effectiveEpisodeNumber: epNum,
          isSpecial: false,
          qualityTag: qualityTag,
          displayLabel: label,
          confidence: 1.0,
          hasManualOverride: true,
          status: EpisodeRecognitionStatus.confirmed,
          evidenceSource: '用户已确认',
          evidenceDetails: <String>[
            '用户已确认：$label',
            if (origFileName.isNotEmpty) '原文件名：$origFileName',
          ],
          recognizedWorkTitle: manualCalibration.workTitle.isNotEmpty
              ? manualCalibration.workTitle
              : seriesTitle,
        );
      }
    }
    if (legacyManualEpisodeOverride != null &&
        legacyManualEpisodeOverride > 0) {
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: episode.name,
        originalFileName: origFileName,
        stableKey: stableKey,
        rawEpisodeNumber: legacyManualEpisodeOverride,
        effectiveEpisodeNumber: legacyManualEpisodeOverride,
        isSpecial: false,
        qualityTag: qualityTag,
        displayLabel: '第 $legacyManualEpisodeOverride 集',
        confidence: 1.0,
        hasManualOverride: true,
        status: EpisodeRecognitionStatus.confirmed,
        evidenceSource: '用户已确认',
        evidenceDetails: <String>[
          '用户已确认：第 $legacyManualEpisodeOverride 集',
          if (origFileName.isNotEmpty) '原文件名：$origFileName',
        ],
        recognizedWorkTitle: seriesTitle,
      );
    }

    // 2. Gather Priority 2A (source structured metadata) & Priority 2B (container tags).
    final bool hasStructured = episode.sourceSeasonNumber != null ||
        episode.sourceEpisodeNumber != null;
    final bool structuredIsEmby = episode.url.startsWith('mmemby://') ||
        episode.sourceItemId.isNotEmpty ||
        episode.playbackSession.containsKey('ItemId');
    final bool structuredSpecial = hasStructured &&
        (episode.sourceSeasonNumber == 0 || episode.sourceEpisodeNumber == 0);
    final int? structuredSeason = (episode.sourceSeasonNumber != null &&
            episode.sourceSeasonNumber! > 0)
        ? episode.sourceSeasonNumber
        : null;
    final int? structuredEp = (episode.sourceEpisodeNumber != null &&
            episode.sourceEpisodeNumber! > 0)
        ? episode.sourceEpisodeNumber
        : null;

    final mergedTags = <String, String>{};
    if (episode.isLocalFile) {
      mergedTags.addAll(ContainerMetadataCache.probeLocalFileSync(episode.url));
    }
    mergedTags.addAll(ContainerMetadataCache.getByStableKey(stableKey));
    if (runtimeContainerTags.isNotEmpty) {
      mergedTags.addAll(runtimeContainerTags);
    }
    if (episode.containerTags.isNotEmpty) {
      mergedTags.addAll(episode.containerTags);
    }
    final tagEv = _parseContainerTagEvidence(
      mergedTags,
      seriesTitle: seriesTitle,
    );
    final bool hasTagEvidence = tagEv.season != null ||
        tagEv.ep != null ||
        tagEv.isSpecial ||
        tagEv.hasConflict;

    // 3. Gather Priority 3 (display name, original filename, and directory
    // signals parsed independently so conflicting CMS labels vs real filenames
    // are explicitly surfaced for user calibration instead of silently picking
    // the wrong episode).
    // Never parse app-generated display labels (`episode.nameIsGenerated == true`,
    // e.g. `第 1 集` synthesized for an unnamed CMS entry) as episode evidence.
    final int? dirSeason = _extractDirectorySeason(dirPath);
    final String trimmedLabel = episode.name.trim();
    final bool hasNonGeneratedLabel =
        !episode.nameIsGenerated && trimmedLabel.isNotEmpty;
    final labelSig = hasNonGeneratedLabel
        ? _parseNameSignals(
            trimmedLabel,
            seriesTitle: seriesTitle,
            constantNumbers: constantNumbers,
            sharedPrefix: sharedPrefix,
          )
        : null;
    final bool hasDistinctOrigFile = origFileName.isNotEmpty &&
        (!hasNonGeneratedLabel || origFileName != trimmedLabel);
    final origFileSig = hasDistinctOrigFile
        ? _parseNameSignals(
            origFileName,
            seriesTitle: seriesTitle,
            constantNumbers: constantNumbers,
            sharedPrefix: sharedPrefix,
          )
        : null;

    bool labelOrigConflict = false;
    final labelOrigConflictReasons = <String>[];
    if (labelSig != null && origFileSig != null) {
      final labelExplicit = labelSig.isSpecial || labelSig.hasExplicitMarker;
      final origExplicit = origFileSig.isSpecial || origFileSig.hasExplicitMarker;
      if (labelExplicit && origExplicit) {
        if (labelSig.isSpecial != origFileSig.isSpecial &&
            (labelSig.ep != null || origFileSig.ep != null)) {
          labelOrigConflict = true;
          labelOrigConflictReasons.add(
            '片源显示名（「$trimmedLabel」）与原文件名（「$origFileName」）的正片/特别篇标记冲突',
          );
        }
        if (labelSig.season != null &&
            origFileSig.season != null &&
            labelSig.season != origFileSig.season) {
          labelOrigConflict = true;
          labelOrigConflictReasons.add(
            '片源显示名季号(S${labelSig.season!.toString().padLeft(2, '0')})与原文件名季号(S${origFileSig.season!.toString().padLeft(2, '0')})冲突',
          );
        }
        if (labelSig.ep != null &&
            origFileSig.ep != null &&
            labelSig.ep != origFileSig.ep) {
          labelOrigConflict = true;
          labelOrigConflictReasons.add(
            '片源显示名集号(E${labelSig.ep!.toString().padLeft(2, '0')})与原文件名集号(E${origFileSig.ep!.toString().padLeft(2, '0')})冲突',
          );
        }
      }
    }

    final bool labelHasSignal = labelSig != null &&
        (labelSig.isSpecial ||
            labelSig.ep != null ||
            labelSig.season != null ||
            labelSig.isVarietyDate);
    final bool origHasSignal = origFileSig != null &&
        (origFileSig.isSpecial ||
            origFileSig.ep != null ||
            origFileSig.season != null ||
            origFileSig.isVarietyDate);

    final fileSig = labelHasSignal
        ? (origFileSig != null && !labelOrigConflict
            ? (
                season: labelSig.season ?? origFileSig.season,
                ep: labelSig.ep ?? origFileSig.ep,
                endEp: labelSig.endEp ?? origFileSig.endEp,
                isSpecial: labelSig.isSpecial,
                specialTag: labelSig.specialTag,
                cleanSpecialLabel: labelSig.cleanSpecialLabel,
                confidence: math.max(labelSig.confidence, origFileSig.confidence),
                hasExplicitMarker:
                    labelSig.hasExplicitMarker || origFileSig.hasExplicitMarker,
                isVarietyDate: labelSig.isVarietyDate,
                varietyLabel: labelSig.varietyLabel,
              )
            : labelSig)
        : (origFileSig ??
            _parseNameSignals(
              '',
              seriesTitle: seriesTitle,
              constantNumbers: constantNumbers,
              sharedPrefix: sharedPrefix,
            ));

    final details = <String>[];
    if (origFileName.isNotEmpty) {
      details.add('原文件名：$origFileName');
    } else {
      details.add('片源未提供集名与文件名');
    }
    if (hasStructured) {
      final srcLabel = structuredIsEmby ? 'Emby 结构化季集' : '片源结构化季集';
      final itemPart = episode.sourceItemId.isNotEmpty
          ? ' (ID: ${episode.sourceItemId})'
          : '';
      if (structuredSpecial) {
        details.add('$srcLabel：特别篇$itemPart');
      } else {
        final sStr = structuredSeason != null ? 'S${structuredSeason.toString().padLeft(2, '0')}' : '';
        final eStr = structuredEp != null ? 'E${structuredEp.toString().padLeft(2, '0')}' : '';
        details.add('$srcLabel：$sStr$eStr$itemPart');
      }
    }
    if (hasTagEvidence) {
      details.add('文件内部标签：${tagEv.summary}');
    }
    if (dirSeason != null) {
      details.add('目录标记：第 $dirSeason 季');
    }
    if (labelSig != null && hasDistinctOrigFile && labelHasSignal && origHasSignal) {
      if (labelSig.isSpecial) {
        details.add('显示名特别篇标记：${labelSig.specialTag}');
      } else if (labelSig.ep != null && labelSig.ep! > 0) {
        details.add(
          '显示名标记：${_formatEpisodeDisplayLabel(labelSig.season, labelSig.ep!, labelSig.endEp)}',
        );
      }
      if (origFileSig.isSpecial) {
        details.add('文件名特别篇标记：${origFileSig.specialTag}');
      } else if (origFileSig.ep != null && origFileSig.ep! > 0) {
        details.add(
          '文件名标记：${_formatEpisodeDisplayLabel(origFileSig.season, origFileSig.ep!, origFileSig.endEp)}',
        );
      }
    } else if (fileSig.isSpecial) {
      details.add('文件名特别篇标记：${fileSig.specialTag}');
    } else if (fileSig.ep != null && fileSig.ep! > 0) {
      final fLabel = _formatEpisodeDisplayLabel(
        fileSig.season,
        fileSig.ep!,
        fileSig.endEp,
      );
      details.add('文件名标记：$fLabel');
    } else if (fileSig.season != null) {
      details.add('文件名季标记：第 ${fileSig.season} 季');
    }

    // 4. Conflict detection across explicit independent evidences.
    bool conflict = tagEv.hasConflict || (!hasStructured && !hasTagEvidence && labelOrigConflict);
    final conflictReasons = <String>[
      ...tagEv.conflictReasons,
      if (!hasStructured && !hasTagEvidence) ...labelOrigConflictReasons,
    ];

    // 4a. Structured source vs Container tags
    if (hasStructured && hasTagEvidence) {
      if (structuredSpecial != tagEv.isSpecial &&
          (structuredEp != null || tagEv.ep != null)) {
        conflict = true;
        conflictReasons.add('片源结构化信息与文件内部标签的正片/特别篇属性冲突');
      }
      if (structuredSeason != null &&
          tagEv.season != null &&
          structuredSeason != tagEv.season) {
        conflict = true;
        conflictReasons.add(
          '片源季号(S${structuredSeason.toString().padLeft(2, '0')})与文件内部标签季号(S${tagEv.season!.toString().padLeft(2, '0')})冲突',
        );
      }
      if (structuredEp != null &&
          tagEv.ep != null &&
          structuredEp != tagEv.ep) {
        conflict = true;
        conflictReasons.add(
          '片源集号(E${structuredEp.toString().padLeft(2, '0')})与文件内部标签集号(E${tagEv.ep!.toString().padLeft(2, '0')})冲突',
        );
      }
    }

    final int? p2Season = structuredSeason ?? tagEv.season;
    final int? p2Ep = structuredEp ?? tagEv.ep;
    final bool p2Special = structuredSpecial || (!hasStructured && tagEv.isSpecial);
    final bool hasP2 = hasStructured || hasTagEvidence;

    // 4b. Priority 2 (structured/tags) vs explicit Priority 3 (filename/directory)
    if (hasP2) {
      if (fileSig.hasExplicitMarker) {
        if (fileSig.isSpecial != p2Special &&
            (p2Ep != null || fileSig.ep != null)) {
          conflict = true;
          conflictReasons.add('文件内部/片源标注与原文件名的正片/预告标记冲突');
        }
        if (p2Season != null &&
            fileSig.season != null &&
            p2Season != fileSig.season) {
          conflict = true;
          conflictReasons.add(
            '标注季号(S${p2Season.toString().padLeft(2, '0')})与原文件名季号(S${fileSig.season!.toString().padLeft(2, '0')})冲突',
          );
        }
        if (p2Ep != null && fileSig.ep != null && p2Ep != fileSig.ep) {
          conflict = true;
          conflictReasons.add(
            '标注集号(E${p2Ep.toString().padLeft(2, '0')})与原文件名集号(E${fileSig.ep!.toString().padLeft(2, '0')})冲突',
          );
        }
      }
      if (p2Season != null && dirSeason != null && p2Season != dirSeason) {
        conflict = true;
        conflictReasons.add(
          '标注季号(S${p2Season.toString().padLeft(2, '0')})与目录季号(S${dirSeason.toString().padLeft(2, '0')})冲突',
        );
      }
    } else {
      // 4c. Directory season vs explicit display-name or original-filename season
      if (dirSeason != null &&
          fileSig.season != null &&
          dirSeason != fileSig.season) {
        conflict = true;
        conflictReasons.add(
          '目录季号(S${dirSeason.toString().padLeft(2, '0')})与原文件名季号(S${fileSig.season!.toString().padLeft(2, '0')})冲突',
        );
      }
      if (dirSeason != null &&
          origFileSig != null &&
          origFileSig.season != null &&
          origFileSig.season != fileSig.season &&
          dirSeason != origFileSig.season) {
        conflict = true;
        conflictReasons.add(
          '目录季号(S${dirSeason.toString().padLeft(2, '0')})与原文件名季号(S${origFileSig.season!.toString().padLeft(2, '0')})冲突',
        );
      }
    }

    final recognizedWork =
        (manualCalibration != null && manualCalibration.workTitle.trim().isNotEmpty)
            ? manualCalibration.workTitle.trim()
            : (tagEv.workTitle.isNotEmpty ? tagEv.workTitle : seriesTitle);

    if (conflict) {
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: episode.name,
        originalFileName: origFileName,
        stableKey: stableKey,
        seasonNumber: p2Season ?? fileSig.season ?? dirSeason,
        qualityTag: qualityTag,
        displayLabel: '待确认',
        confidence: 0.0,
        status: EpisodeRecognitionStatus.needsConfirmation,
        evidenceSource: '多证据冲突 · 待确认',
        evidenceDetails: <String>[...conflictReasons, ...details],
        hasConflict: true,
        recognizedWorkTitle: recognizedWork,
      );
    }

    // 5. Commit Priority 2 (Structured source / Container tags).
    if (hasP2) {
      if (p2Special) {
        final label = tagEv.specialTag.isNotEmpty ? tagEv.specialTag : '特别篇';
        return ScrapedEpisodeInfo(
          originalIndex: originalIndex,
          rawName: episode.name,
          originalFileName: origFileName,
          stableKey: stableKey,
          isSpecial: true,
          specialTag: label,
          qualityTag: qualityTag,
          displayLabel: label,
          confidence: 0.98,
          status: EpisodeRecognitionStatus.special,
          evidenceSource: hasStructured
              ? (structuredIsEmby ? 'Emby 结构化季集' : '片源结构化季集')
              : '文件内部标签',
          evidenceDetails: details,
          recognizedWorkTitle: recognizedWork,
        );
      }
      final combinedSeason = p2Season ?? fileSig.season ?? dirSeason;
      final combinedEp = p2Ep ?? fileSig.ep;
      if (combinedEp != null && combinedEp > 0) {
        final effective = math.max(1, combinedEp + episodeOffset);
        final endRaw = tagEv.endEp ?? fileSig.endEp;
        final effectiveEnd =
            (endRaw != null && endRaw > combinedEp) ? (endRaw + episodeOffset) : null;
        final label =
            _formatEpisodeDisplayLabel(combinedSeason, effective, effectiveEnd);
        final srcBasis = hasStructured
            ? (structuredIsEmby ? 'Emby 结构化季集' : '片源结构化季集')
            : (p2Season != null
                ? '文件内部标签'
                : (dirSeason != null ? '文件内部标签 + 目录标记' : '文件内部标签'));
        return ScrapedEpisodeInfo(
          originalIndex: originalIndex,
          rawName: episode.name,
          originalFileName: origFileName,
          stableKey: stableKey,
          seasonNumber: combinedSeason,
          rawEpisodeNumber: combinedEp,
          endEpisodeNumber: endRaw,
          effectiveEpisodeNumber: effective,
          isSpecial: false,
          qualityTag: qualityTag,
          displayLabel: label,
          confidence: 0.99,
          status: EpisodeRecognitionStatus.autoMatched,
          evidenceSource: srcBasis,
          evidenceDetails: details,
          recognizedWorkTitle: recognizedWork,
        );
      }
    }

    // 6. Commit Priority 3 (Original filename & directory markers).
    final partTag = extractEpisodePartTag(episode.name);
    final dateKey = extractFullDateKey(episode.name);
    if (fileSig.isSpecial) {
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: episode.name,
        originalFileName: origFileName,
        stableKey: stableKey,
        seasonNumber: fileSig.season ?? dirSeason,
        rawEpisodeNumber: fileSig.ep,
        isSpecial: true,
        specialTag: fileSig.specialTag,
        partTag: partTag,
        dateKey: dateKey,
        qualityTag: qualityTag,
        displayLabel: fileSig.cleanSpecialLabel,
        confidence: fileSig.confidence,
        status: EpisodeRecognitionStatus.special,
        evidenceSource: '原文件名特别篇标记',
        evidenceDetails: details,
        recognizedWorkTitle: recognizedWork,
      );
    }

    if (fileSig.isVarietyDate) {
      return ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: episode.name,
        originalFileName: origFileName,
        stableKey: stableKey,
        seasonNumber: fileSig.season ?? dirSeason,
        partTag: partTag,
        dateKey: dateKey,
        qualityTag: qualityTag,
        displayLabel: fileSig.varietyLabel,
        confidence: fileSig.confidence,
        status: EpisodeRecognitionStatus.autoMatched,
        evidenceSource: '原文件名期数标记',
        evidenceDetails: details,
        recognizedWorkTitle: recognizedWork,
      );
    }

    if (fileSig.ep != null && fileSig.ep! > 0) {
      final combinedSeason = fileSig.season ?? dirSeason;
      final effective = math.max(1, fileSig.ep! + episodeOffset);
      final effectiveEnd = (fileSig.endEp != null && fileSig.endEp! > fileSig.ep!)
          ? (fileSig.endEp! + episodeOffset)
          : null;
      final label =
          _formatEpisodeDisplayLabel(combinedSeason, effective, effectiveEnd);
      final basis = (dirSeason != null && fileSig.season == null)
          ? '目录与原文件名标记'
          : '原文件名标记';
      final info = ScrapedEpisodeInfo(
        originalIndex: originalIndex,
        rawName: episode.name,
        originalFileName: origFileName,
        stableKey: stableKey,
        seasonNumber: combinedSeason,
        rawEpisodeNumber: fileSig.ep,
        endEpisodeNumber: fileSig.endEp,
        effectiveEpisodeNumber: effective,
        isSpecial: false,
        partTag: partTag,
        dateKey: dateKey,
        qualityTag: qualityTag,
        displayLabel: label,
        confidence: fileSig.confidence,
        status: EpisodeRecognitionStatus.autoMatched,
        evidenceSource: basis,
        evidenceDetails: details,
        recognizedWorkTitle: recognizedWork,
      );
      if (partTag.isEmpty) return info;
      return ScrapedEpisodeInfo(
        originalIndex: info.originalIndex,
        rawName: info.rawName,
        originalFileName: info.originalFileName,
        stableKey: info.stableKey,
        seasonNumber: info.seasonNumber,
        rawEpisodeNumber: info.rawEpisodeNumber,
        endEpisodeNumber: info.endEpisodeNumber,
        effectiveEpisodeNumber: info.effectiveEpisodeNumber,
        isSpecial: false,
        partTag: partTag,
        dateKey: dateKey,
        qualityTag: qualityTag,
        displayLabel: '$label${info.partDisplaySuffix}',
        confidence: fileSig.confidence,
        status: EpisodeRecognitionStatus.autoMatched,
        evidenceSource: basis,
        evidenceDetails: details,
        recognizedWorkTitle: recognizedWork,
      );
    }

    // 7. Insufficient evidence (e.g. only `1080p`, empty name, opaque `clip-X.mkv` without tags).
    return ScrapedEpisodeInfo(
      originalIndex: originalIndex,
      rawName: episode.name,
      originalFileName: origFileName,
      stableKey: stableKey,
      seasonNumber: fileSig.season ?? dirSeason,
      partTag: partTag,
      dateKey: dateKey,
      qualityTag: qualityTag,
      displayLabel: '待确认',
      confidence: 0.0,
      status: EpisodeRecognitionStatus.needsConfirmation,
      evidenceSource: '信息不足 · 待确认',
      evidenceDetails: details,
      recognizedWorkTitle: recognizedWork,
    );
  }

  /// Scrapes a single episode filename/label into structured season, episode
  /// number, special classification, and clean display label.
  static ScrapedEpisodeInfo scrapeEpisodeName(
    String rawName, {
    int originalIndex = 0,
    String seriesTitle = '',
    int episodeOffset = 0,
    int? manualEpisodeOverride,
    Set<int> constantNumbers = const {},
    String sharedPrefix = '',
  }) {
    return scrapeEpisode(
      CmsEpisode(name: rawName, url: ''),
      originalIndex: originalIndex,
      seriesTitle: seriesTitle,
      episodeOffset: episodeOffset,
      legacyManualEpisodeOverride: manualEpisodeOverride,
      constantNumbers: constantNumbers,
      sharedPrefix: sharedPrefix,
    );
  }

  /// Scrapes every episode in [episodes] together, detecting shared prefixes,
  /// constant series/release numbers (so e.g. `2` in `斗罗大陆2` is never mistaken
  /// for Episode 2), specials/trailers, container tags, Emby/source structured
  /// season/episode metadata, conflicts, and lexicographically scrambled order.
  static LineEpisodeScrapeResult scrapeLineEpisodes(
    List<CmsEpisode> episodes, {
    String seriesTitle = '',
    int episodeOffset = 0,
    Map<String, int> manualOverrides = const {},
    Map<String, EpisodeManualCalibration> episodeCalibrations = const {},
    Map<String, Map<String, String>> runtimeContainerTags = const {},
  }) {
    if (episodes.isEmpty) {
      return const LineEpisodeScrapeResult(
        byOriginalIndex: [],
        sortedRegularIndices: [],
        specialIndices: [],
        unparsedIndices: [],
        sourceOrderScrambled: false,
        regularCount: 0,
        specialCount: 0,
      );
    }

    // 1. Find shared prefix and numbers that appear in >= 80% of filenames
    // (e.g. franchise number `2` in `斗罗大陆2_01.mp4`, `斗罗大陆2_02.mp4`, ...).
    final strippedNames = episodes
        .map((e) {
          final basis = e.nameIsGenerated
              ? _extractOriginalFileName(e)
              : (e.name.trim().isNotEmpty
                  ? e.name.trim()
                  : _extractOriginalFileName(e));
          return _stripSeriesTitleFromEpisode(
            _stripFileExtension(basis),
            seriesTitle,
          );
        })
        .toList(growable: false);

    String sharedPrefix = '';
    if (strippedNames.length >= 3) {
      var prefix = strippedNames.first;
      for (int i = 1; i < strippedNames.length && prefix.isNotEmpty; i++) {
        final cur = strippedNames[i];
        int j = 0;
        final limit = math.min(prefix.length, cur.length);
        while (j < limit && prefix.codeUnitAt(j) == cur.codeUnitAt(j)) {
          j++;
        }
        prefix = prefix.substring(0, j);
      }
      // Trim trailing digits from sharedPrefix so `E0` in `E01..E09` isn't stripped!
      prefix = prefix.replaceAll(RegExp(r'(?:[Ss]\d*[Ee]?|[Ee][Pp]?|\d+)$'), '');
      if (prefix.trim().length >= 2) {
        sharedPrefix = prefix;
      }
    }

    final constantNumbers = <int>{};
    if (episodes.length >= 4) {
      final numFreq = <int, int>{};
      for (final raw in strippedNames) {
        final denoised = raw.replaceAll(_techNoiseRe, ' ');
        final uniqueNums = <int>{};
        for (final m in RegExp(r'(?<![0-9])\d{1,4}(?![0-9])').allMatches(denoised)) {
          final n = int.tryParse(m.group(0)!);
          if (n != null) uniqueNums.add(n);
        }
        for (final n in uniqueNums) {
          numFreq[n] = (numFreq[n] ?? 0) + 1;
        }
      }
      final threshold = (episodes.length * 0.8).ceil();
      for (final entry in numFreq.entries) {
        if (entry.value >= threshold) {
          constantNumbers.add(entry.key);
        }
      }
    }

    // 2. Scrape each episode with strict evidence priority.
    final scraped = <ScrapedEpisodeInfo>[];
    final regularInfos = <ScrapedEpisodeInfo>[];
    final specialIndices = <int>[];
    final unparsedIndices = <int>[];

    for (int i = 0; i < episodes.length; i++) {
      final ep = episodes[i];
      final stableKey = stableEpisodeKey(ep);
      final cal = episodeCalibrations[stableKey];
      final legacyManual = manualOverrides[ep.name];
      final runtimeTags = runtimeContainerTags[stableKey] ?? const <String, String>{};
      final info = scrapeEpisode(
        ep,
        originalIndex: i,
        seriesTitle: seriesTitle,
        episodeOffset: episodeOffset,
        manualCalibration: cal,
        legacyManualEpisodeOverride: legacyManual,
        runtimeContainerTags: runtimeTags,
        constantNumbers: constantNumbers,
        sharedPrefix: sharedPrefix,
      );
      scraped.add(info);
      if (info.isSpecial) {
        specialIndices.add(i);
      } else if (info.resolvedEpisodeNumber != null) {
        regularInfos.add(info);
      } else {
        unparsedIndices.add(i);
      }
    }

    // 2b. Attach auxiliary suggestions ONLY (list position / neighbor episodes)
    // to `待确认` items for user-assisted selection; NEVER promote to resolved.
    if (unparsedIndices.isNotEmpty) {
      int? dominantSeason;
      final seasonCounts = <int, int>{};
      for (final r in regularInfos) {
        if (r.seasonNumber != null && r.seasonNumber! > 0) {
          seasonCounts[r.seasonNumber!] = (seasonCounts[r.seasonNumber!] ?? 0) + 1;
        }
      }
      int bestSeasonCount = 0;
      for (final e in seasonCounts.entries) {
        if (e.value > bestSeasonCount) {
          bestSeasonCount = e.value;
          dominantSeason = e.key;
        }
      }
      for (final idx in unparsedIndices) {
        final cur = scraped[idx];
        int? suggestedEp;
        int? suggestedSeason = cur.seasonNumber ?? dominantSeason;
        // Prefer neighbor-derived suggestion when immediate neighbor is resolved.
        if (idx > 0 && scraped[idx - 1].resolvedEpisodeNumber != null) {
          suggestedEp = scraped[idx - 1].resolvedEpisodeNumber! + 1;
          suggestedSeason ??= scraped[idx - 1].seasonNumber;
        } else if (idx + 1 < scraped.length &&
            scraped[idx + 1].resolvedEpisodeNumber != null &&
            scraped[idx + 1].resolvedEpisodeNumber! > 1) {
          suggestedEp = scraped[idx + 1].resolvedEpisodeNumber! - 1;
          suggestedSeason ??= scraped[idx + 1].seasonNumber;
        } else {
          suggestedEp = math.max(1, idx + 1 + episodeOffset);
        }
        scraped[idx] = cur.withSuggestions(
          suggestedSeasonNumber: suggestedSeason,
          suggestedEpisodeNumber: suggestedEp,
        );
      }
    }

    // 3. Detect if the source order is scrambled (e.g. lexicographical
    // `1, 10, 100, 11, 2` or mixed specials in front of Episode 1).
    bool scrambled = false;
    if (regularInfos.length >= 2) {
      int ascSteps = 0;
      int descSteps = 0;
      for (int i = 1; i < regularInfos.length; i++) {
        final prev = regularInfos[i - 1];
        final cur = regularInfos[i];
        final prevKey = (prev.seasonNumber ?? 0) * 100000 +
            (prev.effectiveEpisodeNumber ?? 0);
        final curKey = (cur.seasonNumber ?? 0) * 100000 +
            (cur.effectiveEpisodeNumber ?? 0);
        if (curKey > prevKey) ascSteps++;
        if (curKey < prevKey) descSteps++;
      }
      final isCleanAsc = descSteps == 0;
      final isCleanDesc = ascSteps == 0;
      if (!isCleanAsc && !isCleanDesc) {
        scrambled = true;
      } else if (isCleanDesc && regularInfos.length >= 3) {
        scrambled = true;
      }
    }
    if (!scrambled &&
        specialIndices.isNotEmpty &&
        regularInfos.isNotEmpty &&
        specialIndices.first < regularInfos.last.originalIndex) {
      scrambled = true;
    }

    final sortedRegular = List<ScrapedEpisodeInfo>.from(regularInfos)
      ..sort((a, b) {
        final sCmp = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
        if (sCmp != 0) return sCmp;
        final eCmp = (a.effectiveEpisodeNumber ?? 0)
            .compareTo(b.effectiveEpisodeNumber ?? 0);
        if (eCmp != 0) return eCmp;
        return a.originalIndex.compareTo(b.originalIndex);
      });

    int? minEp;
    int? maxEp;
    for (final r in sortedRegular) {
      final n = r.effectiveEpisodeNumber;
      if (n != null) {
        minEp = minEp == null ? n : math.min(minEp, n);
        maxEp = maxEp == null ? n : math.max(maxEp, n);
      }
    }

    return LineEpisodeScrapeResult(
      byOriginalIndex: List<ScrapedEpisodeInfo>.unmodifiable(scraped),
      sortedRegularIndices: List<int>.unmodifiable(
        sortedRegular.map((e) => e.originalIndex),
      ),
      specialIndices: List<int>.unmodifiable(specialIndices),
      unparsedIndices: List<int>.unmodifiable(unparsedIndices),
      sourceOrderScrambled: scrambled,
      regularCount: regularInfos.length,
      specialCount: specialIndices.length,
      minEpisodeNumber: minEp,
      maxEpisodeNumber: maxEp,
    );
  }

  static final RegExp _derivativeWorkMarkerRe = RegExp(
    r'外传|番外|前传|后传|后篇|剧场版|特别篇|总集篇|电影版|'
    r'(?<![A-Za-z])(?:OVA|OAD|SP|Movie|Spin-?off|Side\s*Story|Gaiden|Another\s*Story|Extra)(?![A-Za-z])',
    caseSensitive: false,
  );

  /// Returns true ONLY when [titleA] and [titleB] identify the same work
  /// (after normalizing season/year/quality clutter and Roman sequel numerals).
  ///
  /// Substring containment (e.g. `山中之花` vs `山中之花外传`) is NEVER treated as
  /// equivalent, even when season and episode numbers match.
  static bool areWorkTitlesEquivalent(
    String titleA,
    String titleB, {
    int? seasonNumber,
  }) {
    final derivA = _derivativeWorkMarkerRe.hasMatch(titleA);
    final derivB = _derivativeWorkMarkerRe.hasMatch(titleB);
    if (derivA != derivB) return false;
    final coreA = normalizeWorkCoreTitle(titleA);
    final coreB = normalizeWorkCoreTitle(titleB);
    if (coreA.isEmpty || coreB.isEmpty) return false;
    if (coreA == coreB) return true;
    // Allow ONLY an exact trailing sequel numeral matching the SAME confirmed
    // season > 1 (e.g. `山中之花` + S02 vs `山中之花2` / `山中之花Ⅱ`).
    if (seasonNumber != null && seasonNumber > 1) {
      final s = seasonNumber.toString();
      if (coreA == '$coreB$s' || coreB == '$coreA$s') {
        return true;
      }
    }
    return false;
  }

  /// Returns true if [a] and [b] agree on work identity (or at least one side
  /// lacks a recognized work title). Prevents line switches from jumping into
  /// a different series or spin-off that happens to share the same `S02E10`.
  static bool areWorkTitlesCompatible(
    ScrapedEpisodeInfo a,
    ScrapedEpisodeInfo b,
  ) {
    final rawA = a.recognizedWorkTitle.trim();
    final rawB = b.recognizedWorkTitle.trim();
    final coreA = normalizeWorkCoreTitle(rawA);
    final coreB = normalizeWorkCoreTitle(rawB);
    if (coreA.isEmpty || coreB.isEmpty) return true;
    final commonSeason = (a.seasonNumber != null &&
            b.seasonNumber != null &&
            a.seasonNumber == b.seasonNumber)
        ? a.seasonNumber
        : (a.seasonNumber ?? b.seasonNumber);
    return areWorkTitlesEquivalent(rawA, rawB, seasonNumber: commonSeason);
  }

  /// Matches the currently playing episode from [sourceInfo] onto [targetScrape]
  /// when switching playback lines so scrambled lines keep the exact same
  /// `(recognizedWorkTitle, seasonNumber, resolvedEpisodeNumber)` or stable
  /// identity without jumping into another work or a trailer/special.
  static int? matchEpisodeIndexInScrapedLine(
    ScrapedEpisodeInfo sourceInfo,
    LineEpisodeScrapeResult targetScrape,
  ) {
    if (targetScrape.byOriginalIndex.isEmpty) return null;
    // 1. Exact stable key match (e.g., same Emby item / file ID across lines).
    if (sourceInfo.stableKey.isNotEmpty) {
      for (final cand in targetScrape.byOriginalIndex) {
        if (cand.stableKey == sourceInfo.stableKey &&
            areWorkTitlesCompatible(sourceInfo, cand)) {
          return cand.originalIndex;
        }
      }
    }
    // 2. Exact (work, seasonNumber, resolvedEpisodeNumber) match.
    final srcEp = sourceInfo.resolvedEpisodeNumber;
    if (srcEp != null && srcEp > 0 && !sourceInfo.isSpecial) {
      final srcSeason = sourceInfo.seasonNumber;
      final srcCore = normalizeWorkCoreTitle(sourceInfo.recognizedWorkTitle);
      if (srcSeason != null && srcSeason > 0) {
        int? compatFallback;
        for (final cand in targetScrape.byOriginalIndex) {
          if (cand.isSpecial ||
              cand.seasonNumber != srcSeason ||
              cand.resolvedEpisodeNumber != srcEp) {
            continue;
          }
          if (!areWorkTitlesCompatible(sourceInfo, cand)) continue;
          final candCore = normalizeWorkCoreTitle(cand.recognizedWorkTitle);
          if (srcCore.isNotEmpty && candCore == srcCore) {
            return cand.originalIndex;
          }
          compatFallback ??= cand.originalIndex;
        }
        if (compatFallback != null) return compatFallback;
      }
      // Match by episode number when target line does not carry season tags
      // (avoid cross-season and cross-work mismatch!).
      int? epCompatFallback;
      for (final cand in targetScrape.byOriginalIndex) {
        if (cand.isSpecial || cand.resolvedEpisodeNumber != srcEp) continue;
        if (!(srcSeason == null ||
            cand.seasonNumber == null ||
            cand.seasonNumber == srcSeason)) {
          continue;
        }
        if (!areWorkTitlesCompatible(sourceInfo, cand)) continue;
        final candCore = normalizeWorkCoreTitle(cand.recognizedWorkTitle);
        if (srcCore.isNotEmpty && candCore == srcCore) {
          return cand.originalIndex;
        }
        epCompatFallback ??= cand.originalIndex;
      }
      if (epCompatFallback != null) return epCompatFallback;
    }
    return null;
  }

  static final RegExp _delimitedFullDateRe = RegExp(
    r'(?<!\d)((?:19|20)\d{2})[.\-/年_](0?[1-9]|1[0-2])[.\-/月_](0?[1-9]|[12]\d|3[01])(?:\s*[日期])?(?!\d)',
  );

  static final RegExp _compactFullDateRe = RegExp(
    r'(?<!\d)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?![0-9])',
  );

  static final RegExp _partMarkerRe = RegExp(
    r'(?:上集|中集|下集|前篇|中篇|后篇|上篇|下篇|上部|中部|下部|上卷|中卷|下卷|完结篇|终篇|最终篇|[（(\[【]\s*[上中下]\s*[)）\]】]|(?<![A-Za-z0-9])(?:part|pt|disc|cd)\.?\s*(?:0*\d+|III|II|I)(?![A-Za-z0-9]))',
    caseSensitive: false,
  );

  static final RegExp _singleMovieFeatureNoiseRe = RegExp(
    r'(?:正片|完整版?|未删减版?|抢先版?|蓝光|原盘|超清|高清|标清|枪版|国语|粤语|英语|日语|韩语|中字|双语|中英双字|国粤双语|臻彩|杜比视界|杜比|高码|修复版?|独播|电影|全片|TC|TS|HD|BD|DVD|4K|2K|8K|1080[pP]|2160[pP]|720[pP]|HDR10\+?|HDR|SDR)',
    caseSensitive: false,
  );

  /// Extracts a normalized 8-digit calendar date (`YYYYMMDD`) whenever an
  /// episode label includes a full date (`2026-03-15期`, `2026.03.15期`,
  /// `2026-03-15`, `20260315期`). Returns `''` when absent.
  static String extractFullDateKey(String rawName) {
    final m1 = _delimitedFullDateRe.firstMatch(rawName);
    if (m1 != null) {
      final y = m1.group(1)!;
      final mo = m1.group(2)!.padLeft(2, '0');
      final d = m1.group(3)!.padLeft(2, '0');
      return '$y$mo$d';
    }
    final m2 = _compactFullDateRe.firstMatch(rawName);
    if (m2 != null) {
      return '${m2.group(1)!}${m2.group(2)!}${m2.group(3)!}';
    }
    return '';
  }

  /// Extracts a normalized split-part tag (`part1`, `part2`, `part_mid`,
  /// `part3`..`part9`, `final`) shared between Detail episode aggregation and
  /// Player cross-line/cross-site matching. Returns `''` when absent.
  static String extractEpisodePartTag(String rawName) {
    final s = rawName.trim();
    if (s.isEmpty) return '';
    final enNum = RegExp(
      r'(?<![A-Za-z0-9])(?:part|pt|disc|cd)\.?\s*0*([1-9])(?![A-Za-z0-9])',
      caseSensitive: false,
    ).firstMatch(s);
    if (enNum != null) {
      return 'part${enNum.group(1)!}';
    }
    final enRoman = RegExp(
      r'(?<![A-Za-z0-9])(?:part|pt)\.?\s*(III|II|I)(?![A-Za-z0-9])',
      caseSensitive: false,
    ).firstMatch(s);
    if (enRoman != null) {
      return switch (enRoman.group(1)!.toUpperCase()) {
        'I' => 'part1',
        'II' => 'part2',
        'III' => 'part3',
        _ => '',
      };
    }
    if (RegExp(
      r'(?:上篇|上部|上卷|上集|前篇|前部|[（(\[【]\s*上\s*[)）\]】]|(?<=[集话話回期章节\d])\s*上(?:\s*$|[（(\[【\s._\-]))',
    ).hasMatch(s)) {
      return 'part1';
    }
    if (RegExp(
      r'(?:下篇|下部|下卷|下集|后篇|后部|[（(\[【]\s*下\s*[)）\]】]|(?<=[集话話回期章节\d])\s*下(?:\s*$|[（(\[【\s._\-]))',
    ).hasMatch(s)) {
      return 'part2';
    }
    if (RegExp(
      r'(?:中篇|中部|中卷|中集|[（(\[【]\s*中\s*[)）\]】]|(?<=[集话話回期章节\d])\s*中(?:\s*$|[（(\[【\s._\-]))',
    ).hasMatch(s)) {
      return 'part_mid';
    }
    if (RegExp(r'(?:完结篇|终篇|最终篇)').hasMatch(s)) {
      return 'final';
    }
    return '';
  }

  static String? _extractVarietyDateKey(String rawName) {
    final key = extractFullDateKey(rawName);
    return key.isNotEmpty ? key : null;
  }

  static ({String category, int? number})? _extractSpecialIdentity(
    ScrapedEpisodeInfo info,
    String seriesTitle,
  ) {
    if (!info.isSpecial) return null;
    final stripped = _stripSeriesTitleFromEpisode(
      _stripFileExtension(info.rawName.trim()),
      seriesTitle,
    );
    final lower = stripped.toLowerCase();
    String category = '';
    if (info.specialTag == '第0集' ||
        RegExp(r'第\s*0+\s*[集话話回]|(?<![a-z0-9])ep?\.?\s*0+(?![0-9])')
            .hasMatch(lower)) {
      return (category: 'ep0', number: 0);
    }
    if (lower.contains('特典') ||
        RegExp(r'(?<![a-z])(?:bonus|extras?)(?![a-z])').hasMatch(lower)) {
      category = 'bonus';
    } else if (lower.contains('预告') ||
        lower.contains('先导') ||
        lower.contains('抢先看') ||
        lower.contains('定档') ||
        RegExp(r'(?<![a-z])(?:trailer|preview|teaser)(?![a-z])')
            .hasMatch(lower)) {
      category = 'preview';
    } else if (lower.contains('番外')) {
      category = 'spinoff';
    } else if (lower.contains('特别篇') ||
        RegExp(r'(?<![a-z])sp(?![a-z])').hasMatch(lower)) {
      category = 'special';
    } else if (RegExp(r'(?<![a-z])ova(?![a-z])').hasMatch(lower)) {
      category = 'ova';
    } else if (RegExp(r'(?<![a-z])oad(?![a-z])').hasMatch(lower)) {
      category = 'oad';
    } else if (RegExp(r'(?<![a-z])pv(?![a-z])').hasMatch(lower)) {
      category = 'pv';
    } else if (lower.contains('花絮') ||
        lower.contains('幕后') ||
        lower.contains('片花') ||
        RegExp(r'(?<![a-z])(?:making|behind)(?![a-z])').hasMatch(lower)) {
      category = 'bts';
    } else if (lower.contains('彩蛋')) {
      category = 'easter_egg';
    } else if (lower.contains('总集篇') || lower.contains('精编')) {
      category = 'recap';
    } else if (lower.contains('剧场版')) {
      category = 'movie';
    } else if (lower.contains('小剧场')) {
      category = 'mini';
    } else if (lower.contains('片头曲') ||
        RegExp(r'(?<![a-z])(?:ncop|op)(?![a-z])').hasMatch(lower)) {
      category = 'op';
    } else if (lower.contains('片尾曲') ||
        RegExp(r'(?<![a-z])(?:nced|ed)(?![a-z])').hasMatch(lower)) {
      category = 'ed';
    } else if (lower.contains('特辑')) {
      category = 'featurette';
    } else {
      category = info.specialTag.trim().toLowerCase();
    }
    if (category.isEmpty) return null;

    final denoised = stripped
        .replaceAll(_techNoiseRe, ' ')
        .replaceAll(RegExp(r'(?<![0-9])(?:19[5-9]\d|20[0-3]\d)(?![0-9])'), ' ')
        .replaceAll(RegExp(r'第\s*[0-9一二三四五六七八九十两]+\s*[季部]'), ' ')
        .replaceAll(RegExp(r'(?<![A-Za-z0-9])[Ss]0*\d{1,2}(?![A-Za-z0-9])'), ' ');
    final numMatches = RegExp(r'(?<![0-9])0*(\d{1,3})(?![0-9])')
        .allMatches(denoised)
        .map((m) => int.tryParse(m.group(1)!))
        .whereType<int>()
        .toList();
    final int? spNum = numMatches.length == 1 ? numMatches.single : null;
    return (category: category, number: spNum);
  }

  static bool _looksLikeSingleFeatureLabel(String rawName, String seriesTitle) {
    final trimmed = _stripFileExtension(rawName.trim());
    if (trimmed.isEmpty) return true;
    if (_partMarkerRe.hasMatch(trimmed)) return false;
    final stripped = _stripSeriesTitleFromEpisode(trimmed, seriesTitle)
        .replaceAll(_techNoiseRe, ' ')
        .replaceAll(_singleMovieFeatureNoiseRe, ' ')
        .replaceAll(RegExp(r'[\s_\-·:：()（）\[\]【】.]+'), '');
    return stripped.isEmpty;
  }

  /// Matches the episode at [fromEpisodeIndex] in [fromLine] against
  /// [targetLine] using scraped identity (unique URL / unique exact name /
  /// `(season, episodeNumber)` / special identity / variety date / single-item
  /// feature movie).
  ///
  /// Never guesses by raw array index. Returns [CrossLineEpisodeMatch.ambiguous]
  /// or [CrossLineEpisodeMatch.unmatched] whenever a unique identity match
  /// cannot be proven, so callers can let the user pick the episode manually
  /// without silently inheriting playback progress to the wrong item.
  static CrossLineEpisodeMatch matchEpisodeAcrossLines({
    required CmsLine fromLine,
    required int fromEpisodeIndex,
    required CmsLine targetLine,
    String seriesTitle = '',
    SeriesScrapeOverride? override,
  }) {
    if (fromLine.episodes.isEmpty ||
        targetLine.episodes.isEmpty ||
        fromEpisodeIndex < 0 ||
        fromEpisodeIndex >= fromLine.episodes.length) {
      return const CrossLineEpisodeMatch.unmatched(reason: '线路剧集为空');
    }
    if (identical(fromLine, targetLine)) {
      return CrossLineEpisodeMatch.matched(
        fromEpisodeIndex,
        reason: '同线路同集',
      );
    }

    final epOffset = override?.episodeOffset ?? 0;
    final manualOverrides =
        override?.episodeNumberOverrides ?? const <String, int>{};
    final fromScraped = scrapeLineEpisodes(
      fromLine.episodes,
      seriesTitle: seriesTitle,
      episodeOffset: epOffset,
      manualOverrides: manualOverrides,
    );
    final targetScraped = scrapeLineEpisodes(
      targetLine.episodes,
      seriesTitle: seriesTitle,
      episodeOffset: epOffset,
      manualOverrides: manualOverrides,
    );

    final srcEp = fromLine.episodes[fromEpisodeIndex];
    final srcInfo = fromScraped.infoForOriginalIndex(fromEpisodeIndex);
    if (srcInfo == null) {
      return const CrossLineEpisodeMatch.unmatched(reason: '未找到原剧集');
    }

    final seriesSeason = extractSeasonNumber(seriesTitle);
    final fromExplicitSeasons = <int>{
      for (final info in fromScraped.byOriginalIndex)
        if (!info.isSpecial && info.seasonNumber != null) info.seasonNumber!,
    };
    final targetExplicitSeasons = <int>{
      for (final info in targetScraped.byOriginalIndex)
        if (!info.isSpecial && info.seasonNumber != null) info.seasonNumber!,
    };
    final fromMultiSeason = fromExplicitSeasons.length >= 2;
    final targetMultiSeason = targetExplicitSeasons.length >= 2;
    final unionExplicitSeasons = <int>{
      ...fromExplicitSeasons,
      ...targetExplicitSeasons,
    };
    final eitherMultiSeason =
        fromMultiSeason || targetMultiSeason || unionExplicitSeasons.length >= 2;

    int? effectiveSeasonFor(
      ScrapedEpisodeInfo info, {
      required bool ownLineHasMultiSeason,
    }) {
      if (info.seasonNumber != null) return info.seasonNumber;
      if (seriesSeason != null && !ownLineHasMultiSeason) return seriesSeason;
      if (!eitherMultiSeason) return 1;
      return null;
    }

    bool seasonsCompatible(ScrapedEpisodeInfo a, ScrapedEpisodeInfo b) {
      if (a.isSpecial || b.isSpecial) {
        if (a.seasonNumber != null &&
            b.seasonNumber != null &&
            a.seasonNumber != b.seasonNumber) {
          return false;
        }
        return true;
      }
      if (a.seasonNumber != null &&
          b.seasonNumber != null &&
          a.seasonNumber != b.seasonNumber) {
        return false;
      }
      final sa = effectiveSeasonFor(a, ownLineHasMultiSeason: fromMultiSeason);
      final sb =
          effectiveSeasonFor(b, ownLineHasMultiSeason: targetMultiSeason);
      return sa != null && sb != null && sa == sb;
    }

    bool partsAndDatesCompatible(ScrapedEpisodeInfo a, ScrapedEpisodeInfo b) =>
        a.partTag == b.partTag && a.dateKey == b.dateKey;

    // 1. Unique non-empty URL identity match.
    final srcUrl = srcEp.url.trim();
    if (srcUrl.isNotEmpty) {
      final srcUrlCount =
          fromLine.episodes.where((e) => e.url.trim() == srcUrl).length;
      if (srcUrlCount == 1) {
        final targetUrlMatches = <int>[
          for (var i = 0; i < targetLine.episodes.length; i++)
            if (targetLine.episodes[i].url.trim() == srcUrl) i,
        ];
        if (targetUrlMatches.length == 1) {
          final idx = targetUrlMatches.single;
          final candInfo = targetScraped.infoForOriginalIndex(idx);
          if (candInfo != null &&
              candInfo.isSpecial == srcInfo.isSpecial &&
              partsAndDatesCompatible(srcInfo, candInfo) &&
              seasonsCompatible(srcInfo, candInfo)) {
            return CrossLineEpisodeMatch.matched(idx, reason: '地址唯一匹配');
          }
        } else if (targetUrlMatches.length > 1) {
          return const CrossLineEpisodeMatch.ambiguous(reason: '目标线路存在多个相同地址');
        }
      }
    }

    // 2. Exact trimmed name match when unique in both lines and consistent in
    // special/season/part/date classification.
    final trimmedName = srcEp.name.trim().toLowerCase();
    if (trimmedName.isNotEmpty) {
      final srcNameCount = fromLine.episodes
          .where((e) => e.name.trim().toLowerCase() == trimmedName)
          .length;
      final targetNameMatches = <int>[
        for (var i = 0; i < targetLine.episodes.length; i++)
          if (targetLine.episodes[i].name.trim().toLowerCase() == trimmedName) i,
      ];
      if (srcNameCount == 1 && targetNameMatches.length == 1) {
        final idx = targetNameMatches.single;
        final candInfo = targetScraped.infoForOriginalIndex(idx);
        if (candInfo != null &&
            candInfo.isSpecial == srcInfo.isSpecial &&
            partsAndDatesCompatible(srcInfo, candInfo) &&
            (srcInfo.isSpecial ||
                srcInfo.resolvedEpisodeNumber == null ||
                seasonsCompatible(srcInfo, candInfo))) {
          return CrossLineEpisodeMatch.matched(idx, reason: '名称唯一匹配');
        }
      } else if (targetNameMatches.length > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '目标线路存在多个同名剧集');
      }
    }

    // 3. Regular episode scraped `(season, episodeNumber, endEpisodeNumber, partTag, dateKey)`.
    if (!srcInfo.isSpecial && srcInfo.resolvedEpisodeNumber != null) {
      final srcNum = srcInfo.resolvedEpisodeNumber!;
      final srcEnd = srcInfo.endEpisodeNumber;
      final srcSeason = effectiveSeasonFor(
        srcInfo,
        ownLineHasMultiSeason: fromMultiSeason,
      );

      // Ensure source episode identity itself is unique within fromLine.
      final sameInSource = fromScraped.byOriginalIndex.where((item) {
        if (item.isSpecial ||
            item.resolvedEpisodeNumber != srcNum ||
            item.endEpisodeNumber != srcEnd ||
            !partsAndDatesCompatible(srcInfo, item)) {
          return false;
        }
        final itemSeason = effectiveSeasonFor(
          item,
          ownLineHasMultiSeason: fromMultiSeason,
        );
        return srcSeason != null && itemSeason == srcSeason;
      }).length;
      if (sameInSource > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '当前线路存在重复集号');
      }

      final strictMatches = <int>[];
      final sameNumAnySeason = <int>[];
      for (final cand in targetScraped.byOriginalIndex) {
        if (cand.isSpecial) continue;
        if (cand.resolvedEpisodeNumber != srcNum) continue;
        if (cand.endEpisodeNumber != srcEnd) continue;
        if (!partsAndDatesCompatible(srcInfo, cand)) continue;
        sameNumAnySeason.add(cand.originalIndex);
        final candSeason = effectiveSeasonFor(
          cand,
          ownLineHasMultiSeason: targetMultiSeason,
        );
        if (srcSeason != null &&
            candSeason != null &&
            srcSeason == candSeason) {
          strictMatches.add(cand.originalIndex);
        }
      }
      if (strictMatches.length == 1) {
        return CrossLineEpisodeMatch.matched(
          strictMatches.single,
          reason: '集号唯一匹配',
        );
      }
      if (strictMatches.length > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '目标线路存在多个同季同集号');
      }
      if (sameNumAnySeason.length > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '跨季同集号无法唯一确定');
      }
      return const CrossLineEpisodeMatch.unmatched(reason: '目标线路未找到同季同集正片');
    }

    // 4. Special / Bonus / Trailer identity (never cross-matches regular episodes).
    if (srcInfo.isSpecial) {
      final srcKey = _extractSpecialIdentity(srcInfo, seriesTitle);
      if (srcKey == null) {
        return const CrossLineEpisodeMatch.unmatched(reason: '特典/特别篇无法唯一识别');
      }
      final sameSpecialInSource = fromScraped.byOriginalIndex.where((item) {
        if (!item.isSpecial) return false;
        final k = _extractSpecialIdentity(item, seriesTitle);
        return k == srcKey &&
            item.seasonNumber == srcInfo.seasonNumber &&
            partsAndDatesCompatible(srcInfo, item);
      }).length;
      if (sameSpecialInSource > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '当前线路存在多个同类特典');
      }
      final matches = <int>[];
      for (final cand in targetScraped.byOriginalIndex) {
        if (!cand.isSpecial) continue;
        if (!partsAndDatesCompatible(srcInfo, cand)) continue;
        if (srcInfo.seasonNumber != null &&
            cand.seasonNumber != null &&
            srcInfo.seasonNumber != cand.seasonNumber) {
          continue;
        }
        final candKey = _extractSpecialIdentity(cand, seriesTitle);
        if (candKey == srcKey) {
          matches.add(cand.originalIndex);
        }
      }
      if (matches.length == 1) {
        return CrossLineEpisodeMatch.matched(
          matches.single,
          reason: '特典唯一匹配',
        );
      }
      if (matches.length > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '目标线路存在多个同类特典');
      }
      return const CrossLineEpisodeMatch.unmatched(reason: '目标线路未找到对应特典/预告');
    }

    // 5. Full calendar date issue (`2026-03-15期`, `2026.03.15`, `20260315期`)
    // preserving part markers (`上篇`/`下篇`).
    final srcDate = srcInfo.dateKey.isNotEmpty
        ? srcInfo.dateKey
        : (_extractVarietyDateKey(srcEp.name) ?? '');
    if (srcDate.isNotEmpty) {
      final srcDateCount = fromScraped.byOriginalIndex.where((item) {
        final d = item.dateKey.isNotEmpty
            ? item.dateKey
            : (_extractVarietyDateKey(item.rawName) ?? '');
        return !item.isSpecial && d == srcDate && item.partTag == srcInfo.partTag;
      }).length;
      final targetDateMatches = <int>[
        for (var i = 0; i < targetLine.episodes.length; i++)
          if (!targetScraped.byOriginalIndex[i].isSpecial &&
              (targetScraped.byOriginalIndex[i].dateKey.isNotEmpty
                      ? targetScraped.byOriginalIndex[i].dateKey
                      : (_extractVarietyDateKey(targetLine.episodes[i].name) ??
                          '')) ==
                  srcDate &&
              targetScraped.byOriginalIndex[i].partTag == srcInfo.partTag)
            i,
      ];
      if (srcDateCount == 1 && targetDateMatches.length == 1) {
        return CrossLineEpisodeMatch.matched(
          targetDateMatches.single,
          reason: '期号日期唯一匹配',
        );
      }
      if (targetDateMatches.length > 1) {
        return const CrossLineEpisodeMatch.ambiguous(reason: '目标线路存在多个同期节目');
      }
      return const CrossLineEpisodeMatch.unmatched(reason: '目标线路未找到同日期同分段期数');
    }

    // 6. Single-item feature movie edition labels (e.g. `HD中字` <-> `蓝光4K`).
    if (fromLine.episodes.length == 1 && targetLine.episodes.length == 1) {
      final candInfo = targetScraped.byOriginalIndex.first;
      if (!candInfo.isSpecial &&
          candInfo.resolvedEpisodeNumber == null &&
          srcInfo.partTag.isEmpty &&
          candInfo.partTag.isEmpty &&
          srcInfo.dateKey.isEmpty &&
          candInfo.dateKey.isEmpty &&
          _looksLikeSingleFeatureLabel(srcEp.name, seriesTitle) &&
          _looksLikeSingleFeatureLabel(
            targetLine.episodes.first.name,
            seriesTitle,
          )) {
        return const CrossLineEpisodeMatch.matched(0, reason: '单集影片匹配');
      }
    }

    return const CrossLineEpisodeMatch.unmatched(reason: '无法唯一匹配目标剧集');
  }

  /// Returns `true` ONLY when [targetEpisodeIndex] in [targetLine] is
  /// unambiguously the same episode as [fromEpisodeIndex] in [fromLine].
  static bool isSameEpisodeAcrossLines({
    required CmsLine fromLine,
    required int fromEpisodeIndex,
    required CmsLine targetLine,
    required int targetEpisodeIndex,
    String seriesTitle = '',
    SeriesScrapeOverride? override,
  }) {
    if (fromLine.episodes.isEmpty ||
        targetLine.episodes.isEmpty ||
        fromEpisodeIndex < 0 ||
        fromEpisodeIndex >= fromLine.episodes.length ||
        targetEpisodeIndex < 0 ||
        targetEpisodeIndex >= targetLine.episodes.length) {
      return false;
    }
    if (identical(fromLine, targetLine)) {
      return fromEpisodeIndex == targetEpisodeIndex;
    }
    final match = matchEpisodeAcrossLines(
      fromLine: fromLine,
      fromEpisodeIndex: fromEpisodeIndex,
      targetLine: targetLine,
      seriesTitle: seriesTitle,
      override: override,
    );
    return match.isMatched && match.episodeIndex == targetEpisodeIndex;
  }

  // ---------------------------------------------------------------------------
  // 3. Interactive Multi-Source Series Scraping (Douban / Bangumi / Bilibili)
  // ---------------------------------------------------------------------------

  static String _randomBid() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final sb = StringBuffer();
    for (int i = 0; i < 11; i++) {
      sb.write(chars[_rng.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  static String _upgradeCoverUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return '';
    if (u.startsWith('//')) u = 'https:$u';
    if (u.contains('doubanio.com')) {
      u = u
          .replaceFirst('img9.doubanio.com', 'img3.doubanio.com')
          .replaceFirst('/s_ratio_poster/', '/l_ratio_poster/')
          .replaceFirst('/m_ratio_poster/', '/l_ratio_poster/');
      // Strip Rexxar `qnmob3-sign` small h/120 resize when unsigned, or normalize.
      if (u.contains('qnmob3-sign.doubanio.com') &&
          u.contains('/view/photo/large/public/')) {
        final match = RegExp(r'/view/photo/large/public/(p\d+\.[a-z]+)')
            .firstMatch(u);
        if (match != null) {
          u = 'https://img3.doubanio.com/view/photo/l_ratio_poster/public/${match.group(1)}';
        }
      }
      if (u.endsWith('.webp')) {
        u = '${u.substring(0, u.length - 5)}.jpg';
      }
    } else if (u.contains('lain.bgm.tv/pic/cover/')) {
      u = u.replaceFirst('http://', 'https://').replaceFirst(
            RegExp(r'/pic/cover/[csgm]/'),
            '/pic/cover/l/',
          );
    } else if (u.contains('hdslb.com') || u.contains('biliimg.com')) {
      if (u.startsWith('http://')) {
        u = u.replaceFirst('http://', 'https://');
      }
      final atIdx = u.indexOf('@');
      if (atIdx > 0) u = u.substring(0, atIdx);
    }
    return u;
  }

  static Future<String?> _getText(
    Uri uri, {
    required Map<String, String> headers,
    Duration timeout = const Duration(milliseconds: 3500),
  }) async {
    HttpClientRequest? req;
    try {
      req = await _client.getUrl(uri).timeout(timeout);
      headers.forEach(req.headers.set);
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return await utf8.decoder.bind(resp).join().timeout(timeout);
      }
      await resp.drain<void>();
    } catch (_) {
      try {
        req?.abort();
      } catch (_) {}
    }
    return null;
  }

  /// Searches Douban Rexxar (`search/weixin`), Bangumi (`api.bgm.tv`), and
  /// Bilibili PGC (`media_bangumi` / `media_ft`) for interactive in-series
  /// scraping. [filter] may be `'all'`, `'standard'`, `'motion_comic'`, or
  /// `'movie'`.
  static Future<List<SeriesScrapeCandidate>> searchCandidates(
    String keyword, {
    String filter = 'all',
  }) async {
    final q = keyword.trim();
    if (q.isEmpty) return const [];
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return const [];
    }

    final doubanList = <SeriesScrapeCandidate>[];
    final bangumiList = <SeriesScrapeCandidate>[];
    final biliList = <SeriesScrapeCandidate>[];
    final bidCookie = 'bid=${_randomBid()}';

    await Future.wait([
      // 1. Douban Rexxar weixin search
      () async {
        final body = await _getText(
          Uri.https('m.douban.com', '/rexxar/api/v2/search/weixin', {
            'q': q,
            'count': '12',
          }),
          headers: {
            'User-Agent': _mobileUa,
            'Referer': 'https://m.douban.com/',
            'Cookie': bidCookie,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          if (decoded is! Map) return;
          final subjects = decoded['subjects'];
          final items =
              (subjects is Map ? subjects['items'] : null) ?? decoded['items'];
          if (items is! List) return;
          for (final entry in items.whereType<Map>()) {
            final target = entry['target'] is Map
                ? Map<String, dynamic>.from(entry['target'] as Map)
                : Map<String, dynamic>.from(entry);
            final type =
                (entry['target_type'] ?? target['type'] ?? '')
                    .toString()
                    .toLowerCase();
            if (type != 'movie' && type != 'tv') continue;
            final id = (target['id'] ?? '').toString().trim();
            final title = (target['title'] ?? '').toString().trim();
            if (id.isEmpty || title.isEmpty) continue;
            final year = (target['year'] ?? '').toString().trim();
            final cardSub = (target['card_subtitle'] ?? '').toString().trim();
            final isMc = isMotionComicText(title, extraContext: cardSub);
            final isAnime = cardSub.contains('动画') || cardSub.contains('动漫');
            final badge = isMc
                ? '动态漫画'
                : (isAnime ? '动漫' : (type == 'tv' ? '剧集' : '电影'));
            final ratingMap = target['rating'];
            final rawRating =
                ratingMap is Map ? ratingMap['value'] : target['rating'];
            final rating = rawRating is num
                ? rawRating.toDouble()
                : double.tryParse('$rawRating');
            final pic = target['pic'];
            final rawCover = (target['cover_url'] ??
                    (pic is Map ? (pic['large'] ?? pic['normal'] ?? '') : ''))
                .toString()
                .trim();
            doubanList.add(
              SeriesScrapeCandidate(
                source: 'douban',
                subjectId: id,
                title: title,
                subtitle: cardSub,
                year: year,
                isTv: type == 'tv',
                isMotionComic: isMc,
                mediaBadge: badge,
                posterUrl: _upgradeCoverUrl(rawCover),
                rating:
                    (rating != null && rating >= 2.0 && rating <= 10.0)
                        ? rating
                        : null,
              ),
            );
          }
        } catch (_) {}
      }(),

      // 2. Bangumi Open API (great for anime & donghua)
      () async {
        final body = await _getText(
          Uri.parse(
            'https://api.bgm.tv/search/subject/${Uri.encodeComponent(q)}?responseGroup=large',
          ),
          headers: {
            'User-Agent': _desktopUa,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          final list = decoded is Map ? decoded['list'] : null;
          if (list is! List) return;
          for (final item in list.whereType<Map>().take(10)) {
            final t = item['type'];
            if (t != 2 && t != 6) continue;
            final id = (item['id'] ?? '').toString().trim();
            final nameCn = (item['name_cn'] ?? '').toString().trim();
            final name = (item['name'] ?? '').toString().trim();
            final title = nameCn.isNotEmpty ? nameCn : name;
            if (id.isEmpty || title.isEmpty) continue;
            final airDate = (item['air_date'] ?? '').toString().trim();
            final yMatch = RegExp(r'^((?:19|20)\d{2})').firstMatch(airDate);
            final year = yMatch?.group(1) ?? '';
            final summary = (item['summary'] ?? '').toString().trim();
            final isMc = isMotionComicText(
              '$nameCn $name',
              extraContext: summary,
            );
            final badge = isMc ? '动态漫画' : (t == 2 ? '动漫' : '剧集');
            final images = item['images'];
            final cover = images is Map
                ? (images['large'] ?? images['common'] ?? '').toString().trim()
                : '';
            final eps = (item['eps_count'] ?? item['eps']) as num?;
            final ratingMap = item['rating'];
            final rawScore = ratingMap is Map ? ratingMap['score'] : null;
            final score = rawScore is num ? rawScore.toDouble() : null;
            bangumiList.add(
              SeriesScrapeCandidate(
                source: 'bangumi',
                subjectId: id,
                title: title,
                subtitle: [
                  if (name.isNotEmpty && name != title) name,
                  if (eps != null && eps.toInt() > 0) '共 ${eps.toInt()} 集',
                  'Bangumi',
                ].join(' · '),
                year: year,
                isTv: true,
                isMotionComic: isMc,
                mediaBadge: badge,
                posterUrl: _upgradeCoverUrl(cover),
                synopsis: summary,
                rating: (score != null && score >= 2.0 && score <= 10.0)
                    ? score
                    : null,
                episodeCount: eps?.toInt(),
              ),
            );
          }
        } catch (_) {}
      }(),

      // 3. Bilibili PGC (`media_bangumi` + `media_ft`)
      () async {
        for (final stype in const ['media_bangumi', 'media_ft']) {
          final body = await _getText(
            Uri.parse(
              'https://api.bilibili.com/x/web-interface/search/type?search_type=$stype&keyword=${Uri.encodeQueryComponent(q)}',
            ),
            headers: {
              'User-Agent': _desktopUa,
              'Referer': 'https://search.bilibili.com/',
              'Cookie': _biliCookie,
              'Accept': 'application/json',
            },
          );
          if (body == null) continue;
          try {
            final decoded = jsonDecode(body);
            final list = decoded is Map && decoded['data'] is Map
                ? decoded['data']['result']
                : null;
            if (list is! List) continue;
            for (final item in list.whereType<Map>().take(6)) {
              final sid =
                  (item['season_id'] ?? item['media_id'] ?? '').toString().trim();
              final title = (item['title'] ?? '')
                  .toString()
                  .replaceAll(RegExp(r'<[^>]+>'), '')
                  .trim();
              if (sid.isEmpty || title.isEmpty) continue;
              final desc = (item['desc'] ?? '').toString().trim();
              final styles = (item['styles'] ?? '').toString().trim();
              final isMc = isMotionComicText(title, extraContext: '$styles $desc');
              String year = '';
              if (item['pubtime'] is num && (item['pubtime'] as num).toInt() > 0) {
                year = DateTime.fromMillisecondsSinceEpoch(
                  (item['pubtime'] as num).toInt() * 1000,
                ).year.toString();
              }
              final cover = _upgradeCoverUrl((item['cover'] ?? '').toString());
              final backdrop = _upgradeCoverUrl(
                (item['horizontal_cover_16_9'] ??
                        item['horizontal_cover_16_10'] ??
                        '')
                    .toString(),
              );
              final eps = item['eps'];
              biliList.add(
                SeriesScrapeCandidate(
                  source: 'bilibili',
                  subjectId: sid,
                  title: title,
                  subtitle: [
                    if (styles.isNotEmpty) styles,
                    'B站官方',
                  ].join(' · '),
                  year: year,
                  isTv: stype == 'media_bangumi' ||
                      (eps is List && eps.length > 1),
                  isMotionComic: isMc,
                  mediaBadge: isMc
                      ? '动态漫画'
                      : (stype == 'media_bangumi' ? '动漫' : '影视'),
                  posterUrl: cover,
                  backdropUrl: backdrop,
                  synopsis: desc,
                  episodeCount: eps is List ? eps.length : null,
                ),
              );
            }
          } catch (_) {}
        }
      }(),
    ]);

    final combined = <SeriesScrapeCandidate>[
      ...doubanList,
      ...biliList,
      ...bangumiList,
    ];

    return combined.where((c) {
      return switch (filter) {
        'motion_comic' => c.isMotionComic,
        'standard' => !c.isMotionComic,
        'movie' => !c.isTv && !c.isMotionComic,
        _ => true,
      };
    }).toList(growable: false);
  }

  /// Enriches a user-selected [SeriesScrapeCandidate] with official high-res
  /// landscape backdrop, synopsis, and rating (e.g. from Douban Rexxar detail &
  /// `photos?type=S`) before persisting it as a [SeriesScrapeOverride].
  static Future<SeriesScrapeCandidate> hydrateCandidate(
    SeriesScrapeCandidate candidate,
  ) async {
    if (Platform.environment.containsKey('FLUTTER_TEST') ||
        candidate.source != 'douban' ||
        candidate.subjectId.isEmpty) {
      return candidate;
    }
    final bidCookie = 'bid=${_randomBid()}';
    final kind = candidate.isTv ? 'tv' : 'movie';
    var enriched = candidate;

    await Future.wait([
      // Official detail (intro, rating, high-res cover)
      () async {
        final body = await _getText(
          Uri.parse(
            'https://m.douban.com/rexxar/api/v2/$kind/${candidate.subjectId}',
          ),
          headers: {
            'User-Agent': _mobileUa,
            'Referer': 'https://m.douban.com/movie/subject/${candidate.subjectId}/',
            'Cookie': bidCookie,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          if (decoded is! Map) return;
          final intro = (decoded['intro'] ?? '').toString().trim();
          final pic = decoded['pic'];
          final rawCover = (pic is Map
                  ? (pic['large'] ?? pic['normal'] ?? '')
                  : (decoded['cover_url'] ?? ''))
              .toString()
              .trim();
          final ratingMap = decoded['rating'];
          final rawVal = ratingMap is Map ? ratingMap['value'] : null;
          final score = rawVal is num
              ? rawVal.toDouble()
              : double.tryParse('$rawVal');
          final epCount = (decoded['episodes_count'] as num?)?.toInt();
          enriched = enriched.copyWith(
            synopsis: intro.isNotEmpty ? intro : enriched.synopsis,
            posterUrl: rawCover.isNotEmpty
                ? _upgradeCoverUrl(rawCover)
                : enriched.posterUrl,
            rating: (score != null && score >= 2.0 && score <= 10.0)
                ? score
                : enriched.rating,
            episodeCount: epCount ?? enriched.episodeCount,
          );
        } catch (_) {}
      }(),

      // Official wide landscape still (`photos?type=S`)
      () async {
        final body = await _getText(
          Uri.parse(
            'https://m.douban.com/rexxar/api/v2/$kind/${candidate.subjectId}/photos?type=S&start=0&count=8',
          ),
          headers: {
            'User-Agent': _mobileUa,
            'Referer': 'https://m.douban.com/movie/subject/${candidate.subjectId}/',
            'Cookie': bidCookie,
            'Accept': 'application/json',
          },
        );
        if (body == null) return;
        try {
          final decoded = jsonDecode(body);
          final photos = decoded is Map ? decoded['photos'] : null;
          if (photos is! List) return;
          String bestUrl = '';
          int bestArea = 0;
          for (final p in photos.whereType<Map>()) {
            final img = p['image'];
            if (img is! Map) continue;
            final large = img['large'] ?? img['normal'];
            if (large is! Map) continue;
            final w = (large['width'] as num?)?.toInt() ?? 0;
            final h = (large['height'] as num?)?.toInt() ?? 0;
            final u = _upgradeCoverUrl((large['url'] ?? '').toString());
            if (u.isEmpty) continue;
            if (w > h && w >= 640 && (w / math.max(1, h)) <= 2.65) {
              final area = w * h;
              if (area > bestArea) {
                bestArea = area;
                bestUrl = u;
              }
            }
          }
          if (bestUrl.isNotEmpty) {
            enriched = enriched.copyWith(backdropUrl: bestUrl);
          }
        } catch (_) {}
      }(),
    ]);

    return enriched;
  }
}

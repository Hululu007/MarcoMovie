// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'cms_parser.dart';
import 'csp_bridge.dart';
import 'models.dart';
import 'series_scraper.dart';

/// Broad media category used to prevent erroneous cross-medium merging during
/// cross-site work aggregation (for example: anime vs live-action drama,
/// motion comic vs 3D anime, movie vs TV series, variety vs drama).
enum AggregatedWorkType {
  animation,
  motionComic,
  liveAction,
  movie,
  variety,
  documentary,
  unknown,
}

/// Canonical work identity extracted from a [CmsVideo] for cross-site grouping.
class WorkIdentity {
  final String displayTitle;
  final String baseTitle;
  final String normalizedBaseTitle;
  final int? year;
  final int? seasonNumber;
  final String partMarker;
  final AggregatedWorkType workType;
  final bool explicitTypeInTitle;

  const WorkIdentity({
    required this.displayTitle,
    required this.baseTitle,
    required this.normalizedBaseTitle,
    required this.year,
    required this.seasonNumber,
    required this.partMarker,
    required this.workType,
    required this.explicitTypeInTitle,
  });

  int get effectiveSeason => seasonNumber ?? 1;

  WorkIdentity refineWith(WorkIdentity other) {
    return WorkIdentity(
      displayTitle: displayTitle.isNotEmpty ? displayTitle : other.displayTitle,
      baseTitle: baseTitle.isNotEmpty ? baseTitle : other.baseTitle,
      normalizedBaseTitle: normalizedBaseTitle,
      year: year ?? other.year,
      seasonNumber: seasonNumber ?? other.seasonNumber,
      partMarker: partMarker.isNotEmpty ? partMarker : other.partMarker,
      workType: workType != AggregatedWorkType.unknown
          ? workType
          : other.workType,
      explicitTypeInTitle: explicitTypeInTitle || other.explicitTypeInTitle,
    );
  }
}

/// Preserves one concrete site's reference inside an [AggregatedWorkGroup].
class WorkSourceRef {
  final String subscriptionId;
  final CmsSite site;
  final String videoId;
  final CmsVideo video;
  final String sourceLabel;

  WorkSourceRef({
    String? subscriptionId,
    required this.site,
    String? videoId,
    required this.video,
    String? sourceLabel,
  })  : subscriptionId = subscriptionId ?? site.subscriptionId,
        videoId = videoId ?? video.id,
        sourceLabel = (sourceLabel ?? site.name).trim().isNotEmpty
            ? (sourceLabel ?? site.name).trim()
            : site.key;

  String get siteIdentityKey => '$subscriptionId:${site.key}';
  String get identityKey => '$subscriptionId:${site.key}:$videoId';
}

/// Aggregated cross-site work card shared between search Grid & List views,
/// Detail page multi-source hydration, and Player cross-site source switching.
class AggregatedWorkGroup {
  final String groupKey;
  final String cardKeySuffix;
  final WorkIdentity identity;
  final String displayTitle;
  final String poster;
  final String year;
  final String area;
  final String remarks;
  final String actor;
  final String tag;
  final double? doubanScore;
  final int? rtScore;
  final List<WorkSourceRef> sources;

  const AggregatedWorkGroup({
    required this.groupKey,
    required this.cardKeySuffix,
    required this.identity,
    required this.displayTitle,
    required this.poster,
    required this.year,
    required this.area,
    required this.remarks,
    required this.actor,
    required this.tag,
    required this.doubanScore,
    required this.rtScore,
    required this.sources,
  });

  WorkSourceRef get primarySource => sources.first;
  int get sourceCount => sources.length;

  String get sourceBadgeText =>
      sourceCount > 1 ? '$sourceCount 个来源' : primarySource.sourceLabel;

  /// Returns a view of this group filtered/re-anchored to a specific site key
  /// (`subscriptionId:siteKey`) while keeping all sibling [sources] intact so
  /// Detail & Player still know every alternative source.
  AggregatedWorkGroup? anchoredToSiteKey(String siteIdentityKey) {
    final idx = sources.indexWhere((s) => s.siteIdentityKey == siteIdentityKey);
    if (idx < 0) return null;
    if (idx == 0) return this;
    final reordered = <WorkSourceRef>[
      sources[idx],
      for (var i = 0; i < sources.length; i++)
        if (i != idx) sources[i],
    ];
    final primary = reordered.first;
    return AggregatedWorkGroup(
      groupKey: groupKey,
      cardKeySuffix:
          '${primary.subscriptionId}-${primary.site.key}-${primary.videoId}',
      identity: identity,
      displayTitle: displayTitle,
      poster: _isUsablePoster(primary.video.poster)
          ? primary.video.poster
          : poster,
      year: year,
      area: area,
      remarks: primary.video.remarks.trim().isNotEmpty
          ? primary.video.remarks.trim()
          : remarks,
      actor: actor,
      tag: tag,
      doubanScore: doubanScore,
      rtScore: rtScore,
      sources: reordered,
    );
  }
}

/// Hydrated detail payload for one [WorkSourceRef].
class WorkSourceDetail {
  final WorkSourceRef source;
  final CmsVideo video;

  const WorkSourceDetail({
    required this.source,
    required this.video,
  });

  List<CmsLine> get lines => video.lines;
}

/// One playable `(site, video, line, episode)` offer providing an episode slot.
class AggregatedEpisodeOffer {
  final WorkSourceRef source;
  final CmsVideo video;
  final int lineIndex;
  final String lineName;
  final int episodeIndex;
  final CmsEpisode episode;
  final ScrapedEpisodeInfo scrapedInfo;

  const AggregatedEpisodeOffer({
    required this.source,
    required this.video,
    required this.lineIndex,
    required this.lineName,
    required this.episodeIndex,
    required this.episode,
    required this.scrapedInfo,
  });

  String get siteAndLineLabel => '${source.site.name} · $lineName';
  String get offerKey =>
      '${source.site.key}:$lineIndex:$episodeIndex:${episode.url.trim()}';
}

/// One deduplicated episode entry on the Detail page backed by one or more
/// `站点 · 线路` [offers] across aggregated sources.
class AggregatedEpisodeSlot {
  final String slotKey;
  final String label;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isSpecial;
  final List<AggregatedEpisodeOffer> offers;

  const AggregatedEpisodeSlot({
    required this.slotKey,
    required this.label,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.isSpecial,
    required this.offers,
  });

  int get offerCount => offers.length;

  int get distinctSiteCount {
    final keys = <String>{};
    for (final offer in offers) {
      keys.add(offer.source.siteIdentityKey);
    }
    return keys.length;
  }

  bool hasSiteKey(String siteKey) =>
      offers.any((o) => o.source.site.key == siteKey);

  AggregatedEpisodeOffer preferredOffer({
    String? preferredSiteKey,
    String? preferredLineName,
  }) {
    if (preferredSiteKey != null && preferredSiteKey.isNotEmpty) {
      if (preferredLineName != null && preferredLineName.isNotEmpty) {
        for (final offer in offers) {
          if (offer.source.site.key == preferredSiteKey &&
              offer.lineName == preferredLineName) {
            return offer;
          }
        }
      }
      for (final offer in offers) {
        if (offer.source.site.key == preferredSiteKey) {
          return offer;
        }
      }
    }
    return offers.first;
  }
}

final RegExp _episodeSuffixPattern = RegExp(
  r'[\s·\-—:：]*(?:更新至|更至|更新到|连载至|全\s*\d+\s*[集期话篇章]|共\s*\d+\s*[集期话篇章]|已完结|完结).*$',
);
final RegExp _qualityTokenPattern = RegExp(
  r'(?<![A-Za-z0-9])(?:4K|2160[pP]|1080[pP]|720[pP]|HD|BD|HDR|SDR|DV|REMUX)(?![A-Za-z0-9])',
  caseSensitive: false,
);
final RegExp _audioTailPattern = RegExp(
  r'[\s\-_]*(?:国语|粤语|中字|双语|超清|蓝光|原盘|未删减版?|导演剪辑版?|完整版|纯享版|高码版?|臻彩)\s*$',
);
final RegExp _emptyBracketsPattern = RegExp(
  r'\s*(?:\(\s*\)|（\s*）|\[\s*\]|【\s*】)\s*',
);
final RegExp _keyStripPattern = RegExp(
  r'''[\s\-_—–:：,，.。!！?？'"“”‘’()（）\[\]【】《》<>~/\\|]+''',
);
final RegExp _fourDigitYearPattern = RegExp(r'(?<!\d)(19\d{2}|20[0-3]\d)(?!\d)');
final RegExp _leadingYearEditionPattern = RegExp(
  r'^\s*(?:[（(\[【]\s*)?(19\d{2}|20[0-3]\d)\s*(?:年版?|版)(?:\s*[)）\]】])?\s*',
);
final RegExp _bracketedYearPattern = RegExp(
  r'\s*[（(\[【]\s*(19\d{2}|20[0-3]\d)\s*(?:年版?|年|版)?\s*[)）\]】]\s*',
);
final RegExp _trailingYearPattern = RegExp(
  r'[\s\-—:：·]+(19\d{2}|20[0-3]\d)\s*(?:年版?|年|版)?\s*$',
);
final RegExp _part1Pattern = RegExp(
  r'(?:\s*[（(\[【·\-—:：]\s*(?:上篇|上部|上卷|前篇|前部|上|Part\s*1|Part\s*I)\s*[)）\]】]?\s*$|[\s·\-—:：]+(?:上篇|上部|上卷|前篇|前部|Part\s*1|Part\s*I)\s*$|(?<=[\u4e00-\u9fa5])(?:上篇|上部|前篇|前部)\s*$)',
  caseSensitive: false,
);
final RegExp _part2Pattern = RegExp(
  r'(?:\s*[（(\[【·\-—:：]\s*(?:下篇|下部|下卷|后篇|后部|下|Part\s*2|Part\s*II)\s*[)）\]】]?\s*$|[\s·\-—:：]+(?:下篇|下部|下卷|后篇|后部|Part\s*2|Part\s*II)\s*$|(?<=[\u4e00-\u9fa5])(?:下篇|下部|后篇|后部)\s*$)',
  caseSensitive: false,
);
final RegExp _partMidPattern = RegExp(
  r'(?:\s*[（(\[【·\-—:：]\s*(?:中篇|中部|中卷|中)\s*[)）\]】]?\s*$|[\s·\-—:：]+(?:中篇|中部|中卷)\s*$|(?<=[\u4e00-\u9fa5])(?:中篇|中部)\s*$)',
);
final RegExp _partNumPattern = RegExp(
  r'(?:\s*[（(\[【·\-—:：]\s*Part\s*([3-9])\s*[)）\]】]?\s*$|[\s·\-—:：]+Part\s*([3-9])\s*$)',
  caseSensitive: false,
);
final RegExp _partFinalPattern = RegExp(
  r'(?:\s*[（(\[【·\-—:：]\s*(?:完结篇|终篇|最终篇)\s*[)）\]】]?\s*$|[\s·\-—:：]+(?:完结篇|终篇|最终篇)\s*$)',
);
final RegExp _cnSeasonEndPattern = RegExp(
  r'^(.+?)\s*(?:[（(\[【·:：\-—]\s*)?第\s*([一二三四五六七八九十百零〇两\d]+)\s*[季部辑](?:\s*[)）\]】])?\s*$',
);
final RegExp _cnSeasonMidPattern = RegExp(
  r'^([\u4e00-\u9fa5A-Za-z0-9·]+?)\s*第\s*([一二三四五六七八九十百零〇两\d]+)\s*[季部](?:\s+|[:：·\-—])(.*)$',
);
final RegExp _enSeasonEndPattern = RegExp(
  r'^(.+?)\s*(?:[（(\[【·:：\-—]\s*)?(?:Season\s*0*(\d{1,2})|[Ss]0*(\d{1,2}))(?:\s*[)）\]】])?\s*$',
  caseSensitive: false,
);
final RegExp _trailingSequelPattern = RegExp(
  r'^([\u4e00-\u9fa5]{2,18})\s*([1-9]|1\d)\s*$',
);
final RegExp _genericSingleMovieEpPattern = RegExp(
  r'^(?:正片|全集|完整版|未删减版?|蓝光|超清|高清|标清|国语|粤语|中字|双语|hd|bd|tc|ts|cam|1080p|720p|4k|2160p|hd中字|bd中字|hd国语|bd国语|hd高清|超清中字|蓝光中字)$',
  caseSensitive: false,
);

bool _isUsablePoster(String url) {
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

class _WorkBucket {
  WorkIdentity identity;
  final int firstSeenIndex;
  final List<WorkSourceRef> sources = <WorkSourceRef>[];
  final Set<String> seenIdentityKeys = <String>{};

  _WorkBucket({
    required this.identity,
    required this.firstSeenIndex,
  });
}

/// Core algorithms for cross-site work identity extraction, search grouping,
/// and multi-source episode deduplication.
class WorkAggregation {
  const WorkAggregation._();

  static String cleanDisplayTitle(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    var s = CspBridge.cleanNetdiskSearchTitle(trimmed);
    s = s
        .replaceAll(_episodeSuffixPattern, '')
        .replaceAll(_qualityTokenPattern, '')
        .replaceAll(_audioTailPattern, '')
        .replaceAll(_emptyBracketsPattern, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isEmpty ? trimmed : s;
  }

  static String normalizeTextKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final buf = StringBuffer();
    for (final rune in trimmed.runes) {
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
        .replaceAll(_keyStripPattern, '')
        .trim();
    return normalized.isEmpty ? trimmed.toLowerCase() : normalized;
  }

  static int? _parseYear(String raw) {
    final m = _fourDigitYearPattern.firstMatch(raw);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    if (y == null || y < 1900 || y > 2039) return null;
    return y;
  }

  static ({AggregatedWorkType type, String stripped, bool explicitInTitle})
      _extractTypeFromTitle(String title) {
    final patterns = <(RegExp, AggregatedWorkType)>[
      (
        RegExp(
          r'(?:[（(\[【·\-—:：\s]*(?:动态漫画版?|动态漫版?|动态漫)[)）\]】]*)',
        ),
        AggregatedWorkType.motionComic,
      ),
      (
        RegExp(
          r'(?:[（(\[【·\-—:：\s]*(?:动画电影|动画版|动漫版|动画剧集|TV动画|电视动画|番剧版?)[)）\]】]*)',
          caseSensitive: false,
        ),
        AggregatedWorkType.animation,
      ),
      (
        RegExp(
          r'(?:[（(\[【·\-—:：\s]*(?:真人版|真人剧版?|真人电影|电视剧版|剧版)[)）\]】]*)',
        ),
        AggregatedWorkType.liveAction,
      ),
      (
        RegExp(r'(?:[（(\[【·\-—:：\s]*(?:电影版|剧场版电影)[)）\]】]*)'),
        AggregatedWorkType.movie,
      ),
      (
        RegExp(r'(?:[（(\[【·\-—:：\s]*(?:纪录片版?|记录片版?)[)）\]】]*)'),
        AggregatedWorkType.documentary,
      ),
      (
        RegExp(r'(?:[（(\[【·\-—:：\s]*(?:综艺版|真人秀)[)）\]】]*)'),
        AggregatedWorkType.variety,
      ),
    ];
    for (final (pattern, type) in patterns) {
      if (pattern.hasMatch(title)) {
        final next = title
            .replaceAll(pattern, ' ')
            .replaceAll(_emptyBracketsPattern, ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return (
          type: type,
          stripped: next.isNotEmpty ? next : title,
          explicitInTitle: true,
        );
      }
    }
    return (
      type: AggregatedWorkType.unknown,
      stripped: title,
      explicitInTitle: false,
    );
  }

  static AggregatedWorkType _classifyMetaType(String tag, String remarks) {
    final text = '$tag $remarks'.toLowerCase();
    if (text.trim().isEmpty) return AggregatedWorkType.unknown;
    if (text.contains('动态漫') || text.contains('动态漫画')) {
      return AggregatedWorkType.motionComic;
    }
    if (text.contains('动漫') ||
        text.contains('动画') ||
        text.contains('番剧') ||
        text.contains('国漫') ||
        text.contains('日漫') ||
        text.contains('美漫') ||
        text.contains('anime')) {
      return AggregatedWorkType.animation;
    }
    if (text.contains('综艺') ||
        text.contains('真人秀') ||
        text.contains('脱口秀') ||
        text.contains('晚会') ||
        text.contains('选秀')) {
      return AggregatedWorkType.variety;
    }
    if (text.contains('纪录片') ||
        text.contains('记录片') ||
        text.contains('documentary')) {
      return AggregatedWorkType.documentary;
    }
    if (text.contains('电影') ||
        text.contains('剧情片') ||
        text.contains('动作片') ||
        text.contains('喜剧片') ||
        text.contains('科幻片') ||
        text.contains('恐怖片') ||
        text.contains('爱情片') ||
        text.contains('战争片') ||
        text.contains('悬疑片') ||
        text.contains('犯罪片') ||
        text.contains('奇幻片') ||
        text.contains('灾难片') ||
        text.contains('惊悚片') ||
        text.contains('院线')) {
      return AggregatedWorkType.movie;
    }
    if (text.contains('真人') ||
        text.contains('电视剧') ||
        text.contains('国产剧') ||
        text.contains('大陆剧') ||
        text.contains('内地剧') ||
        text.contains('美剧') ||
        text.contains('欧美剧') ||
        text.contains('日剧') ||
        text.contains('韩剧') ||
        text.contains('港剧') ||
        text.contains('台剧') ||
        text.contains('泰剧') ||
        text.contains('海外剧') ||
        text.contains('连续剧') ||
        text.contains('网剧') ||
        text.contains('短剧') ||
        text.contains('剧集')) {
      return AggregatedWorkType.liveAction;
    }
    return AggregatedWorkType.unknown;
  }

  /// Extracts normalized title, year, season, part marker, and work type so
  /// remakes, different seasons, `上篇`/`下篇`, and animation vs live-action
  /// remain strictly separated.
  static WorkIdentity extractIdentity(CmsVideo video, {CmsSite? site}) {
    final display = cleanDisplayTitle(video.title);
    var working = display;

    // 1. Explicit medium / work type in title (e.g. `三体 真人版` vs `三体 动画版`)
    final titleType = _extractTypeFromTitle(working);
    working = titleType.stripped;
    var workType = titleType.type;
    final explicitTypeInTitle = titleType.explicitInTitle;
    if (workType == AggregatedWorkType.unknown) {
      workType = _classifyMetaType(video.tag, video.remarks);
    }

    // 2. Explicit part markers (`上篇`/`下篇`, `上部`/`下部`, `前篇`/`后篇`, `Part 1/2`)
    var partMarker = '';
    if (_part1Pattern.hasMatch(working)) {
      partMarker = 'part1';
      working = working.replaceFirst(_part1Pattern, '').trim();
    } else if (_part2Pattern.hasMatch(working)) {
      partMarker = 'part2';
      working = working.replaceFirst(_part2Pattern, '').trim();
    } else if (_partMidPattern.hasMatch(working)) {
      partMarker = 'part_mid';
      working = working.replaceFirst(_partMidPattern, '').trim();
    } else if (_partFinalPattern.hasMatch(working)) {
      partMarker = 'final';
      working = working.replaceFirst(_partFinalPattern, '').trim();
    } else {
      final pNum = _partNumPattern.firstMatch(working);
      if (pNum != null) {
        final d = pNum.group(1) ?? pNum.group(2) ?? '';
        if (d.isNotEmpty) {
          partMarker = 'part$d';
          working = working.replaceFirst(_partNumPattern, '').trim();
        }
      }
    }

    // 3. Explicit year from `video.year` or edition/bracketed/trailing year in title.
    var year = _parseYear(video.year);
    final leadingYear = _leadingYearEditionPattern.firstMatch(working);
    if (leadingYear != null) {
      final remainder = working.substring(leadingYear.end).trim();
      if (remainder.isNotEmpty) {
        year ??= int.tryParse(leadingYear.group(1)!);
        working = remainder;
      }
    }
    final bracketYear = _bracketedYearPattern.firstMatch(working);
    if (bracketYear != null) {
      final remainder = working
          .replaceFirst(_bracketedYearPattern, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (remainder.isNotEmpty && !RegExp(r'^\d+$').hasMatch(remainder)) {
        year ??= int.tryParse(bracketYear.group(1)!);
        working = remainder;
      }
    }
    final trailingYear = _trailingYearPattern.firstMatch(working);
    if (trailingYear != null) {
      final remainder = working.substring(0, trailingYear.start).trim();
      if (remainder.isNotEmpty && !RegExp(r'^\d+$').hasMatch(remainder)) {
        year ??= int.tryParse(trailingYear.group(1)!);
        working = remainder;
      }
    }

    // 4. Season / sequel number (`第X季/部/辑`, `Season X`, `S0X`, `庆余年2`)
    int? seasonNumber;
    final cnEnd = _cnSeasonEndPattern.firstMatch(working);
    if (cnEnd != null) {
      final base = cnEnd.group(1)!.trim();
      final num = CmsParser.parseChineseNumber(cnEnd.group(2)!);
      if (base.isNotEmpty && num > 0) {
        working = base;
        seasonNumber = num;
      }
    } else {
      final cnMid = _cnSeasonMidPattern.firstMatch(working);
      if (cnMid != null) {
        final base = cnMid.group(1)!.trim();
        final num = CmsParser.parseChineseNumber(cnMid.group(2)!);
        if (base.isNotEmpty && num > 0) {
          working = base;
          seasonNumber = num;
        }
      } else {
        final enEnd = _enSeasonEndPattern.firstMatch(working);
        if (enEnd != null) {
          final base = enEnd.group(1)!.trim();
          final num = int.tryParse(enEnd.group(2) ?? enEnd.group(3) ?? '');
          if (base.isNotEmpty && num != null && num > 0) {
            working = base;
            seasonNumber = num;
          }
        } else {
          final seqEnd = _trailingSequelPattern.firstMatch(working);
          if (seqEnd != null) {
            final base = seqEnd.group(1)!.trim();
            final num = int.tryParse(seqEnd.group(2)!);
            if (base.isNotEmpty && num != null && num > 0) {
              working = base;
              seasonNumber = num;
            }
          }
        }
      }
    }

    working = working
        .replaceAll(_emptyBracketsPattern, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (working.isEmpty) {
      working = display.isNotEmpty ? display : video.title.trim();
    }

    return WorkIdentity(
      displayTitle: display.isNotEmpty ? display : video.title.trim(),
      baseTitle: working,
      normalizedBaseTitle: normalizeTextKey(working),
      year: year,
      seasonNumber: seasonNumber,
      partMarker: partMarker,
      workType: workType,
      explicitTypeInTitle: explicitTypeInTitle,
    );
  }

  /// Validates whether two [WorkIdentity] values refer to the exact same work
  /// and season across sites.
  static bool isSameWorkIdentity(WorkIdentity a, WorkIdentity b) {
    if (a.normalizedBaseTitle.isEmpty ||
        a.normalizedBaseTitle != b.normalizedBaseTitle) {
      return false;
    }
    // `上篇` / `下篇` / `Part 1` / `Part 2` never merge.
    if (a.partMarker != b.partMarker) {
      return false;
    }
    // Unmarked and Season 1 are compatible; Season 2+ never merges with S1.
    if (a.effectiveSeason != b.effectiveSeason) {
      return false;
    }
    // Distinct explicit years never merge (protects same-title remakes).
    if (a.year != null && b.year != null && a.year != b.year) {
      return false;
    }
    // Distinct work mediums/types never merge (animation vs live-action, etc.).
    if (a.workType != AggregatedWorkType.unknown &&
        b.workType != AggregatedWorkType.unknown &&
        a.workType != b.workType) {
      return false;
    }
    // If one title explicitly names a medium (e.g. `三体 动画版`) and the other
    // has unknown work type (untagged `三体`), keep them separate rather than
    // guessing whether the untagged entry is the anime or live-action version.
    if ((a.explicitTypeInTitle && b.workType == AggregatedWorkType.unknown) ||
        (b.explicitTypeInTitle && a.workType == AggregatedWorkType.unknown)) {
      return false;
    }
    return true;
  }

  static String searchKeywordFor(CmsVideo video) {
    final id = extractIdentity(video);
    return id.baseTitle.isNotEmpty ? id.baseTitle : video.title.trim();
  }

  /// Groups multi-site search results into deduplicated [AggregatedWorkGroup]
  /// cards shared identically between poster grid and list views.
  static List<AggregatedWorkGroup> aggregateSearchResults({
    required List<(CmsSite, CmsVideo)> results,
    String query = '',
    String Function(CmsSite site)? sourceLabelOf,
    String? preferredSiteKey,
  }) {
    if (results.isEmpty) return const [];

    final normalizedQuery = normalizeTextKey(query);
    final entries = <({
      int index,
      WorkSourceRef ref,
      WorkIdentity identity,
    })>[];
    for (var i = 0; i < results.length; i++) {
      final (site, video) = results[i];
      final label = (sourceLabelOf?.call(site) ?? site.name).trim();
      final ref = WorkSourceRef(
        subscriptionId: site.subscriptionId,
        site: site,
        videoId: video.id,
        video: video,
        sourceLabel: label.isNotEmpty ? label : site.key,
      );
      entries.add((
        index: i,
        ref: ref,
        identity: extractIdentity(video, site: site),
      ));
    }

    // Bucket explicit-year/explicit-type items first so that a yearless or
    // untagged sibling never prematurely locks a bucket before explicit peers
    // establish distinct remake/medium partitions.
    final orderedForBucketing = List.of(entries)
      ..sort((a, b) {
        final aSpec = (a.identity.year != null ? 2 : 0) +
            (a.identity.workType != AggregatedWorkType.unknown ? 1 : 0);
        final bSpec = (b.identity.year != null ? 2 : 0) +
            (b.identity.workType != AggregatedWorkType.unknown ? 1 : 0);
        if (aSpec != bSpec) return bSpec.compareTo(aSpec);
        return a.index.compareTo(b.index);
      });

    final buckets = <_WorkBucket>[];
    for (final entry in orderedForBucketing) {
      final compatible = <_WorkBucket>[
        for (final bucket in buckets)
          if (isSameWorkIdentity(bucket.identity, entry.identity)) bucket,
      ];
      _WorkBucket? target;
      if (compatible.length == 1) {
        target = compatible.first;
      } else if (compatible.length > 1) {
        // Disambiguate only if a unique compatible bucket matches exact year
        // and work type; otherwise keep ambiguous yearless items separate so we
        // never attach to the wrong remake.
        final exact = compatible
            .where((b) =>
                b.identity.year == entry.identity.year &&
                b.identity.workType == entry.identity.workType)
            .toList();
        if (exact.length == 1) {
          target = exact.first;
        }
      }
      if (target == null) {
        target = _WorkBucket(
          identity: entry.identity,
          firstSeenIndex: entry.index,
        );
        buckets.add(target);
      } else {
        target.identity = target.identity.refineWith(entry.identity);
      }
      if (target.seenIdentityKeys.add(entry.ref.identityKey)) {
        target.sources.add(entry.ref);
      }
    }

    final scored = <({AggregatedWorkGroup group, int score, int firstSeen})>[];
    for (final bucket in buckets) {
      final sources = List<WorkSourceRef>.from(bucket.sources);
      sources.sort((a, b) {
        if (preferredSiteKey != null && preferredSiteKey.isNotEmpty) {
          final aPref = a.siteIdentityKey == preferredSiteKey ||
              a.site.key == preferredSiteKey;
          final bPref = b.siteIdentityKey == preferredSiteKey ||
              b.site.key == preferredSiteKey;
          if (aPref != bPref) return aPref ? -1 : 1;
        }
        final aPoster = _isUsablePoster(a.video.poster) ? 1 : 0;
        final bPoster = _isUsablePoster(b.video.poster) ? 1 : 0;
        if (aPoster != bPoster) return bPoster.compareTo(aPoster);
        final aMeta = _remarksRichness(a.video.remarks) +
            (a.video.year.trim().isNotEmpty ? 1 : 0);
        final bMeta = _remarksRichness(b.video.remarks) +
            (b.video.year.trim().isNotEmpty ? 1 : 0);
        if (aMeta != bMeta) return bMeta.compareTo(aMeta);
        return 0;
      });

      final primary = sources.first;
      var bestPoster = '';
      var bestYear = bucket.identity.year?.toString() ?? '';
      var bestArea = '';
      var bestActor = '';
      var bestTag = '';
      var bestRemarks = '';
      var bestRemarksScore = -1;
      double? bestDouban;
      int? bestRt;
      var bestDisplayTitle = bucket.identity.displayTitle;

      for (final ref in sources) {
        final v = ref.video;
        if (bestPoster.isEmpty && _isUsablePoster(v.poster)) {
          bestPoster = v.poster.trim();
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
        final rs = _remarksRichness(v.remarks);
        if (rs > bestRemarksScore) {
          bestRemarksScore = rs;
          bestRemarks = v.remarks.trim();
        }
        if (v.doubanScore != null &&
            (bestDouban == null || v.doubanScore! > bestDouban)) {
          bestDouban = v.doubanScore;
        }
        if (v.rtScore != null && (bestRt == null || v.rtScore! > bestRt)) {
          bestRt = v.rtScore;
        }
        final clean = cleanDisplayTitle(v.title);
        if (clean.isNotEmpty &&
            (bestDisplayTitle.isEmpty ||
                (clean.length < bestDisplayTitle.length &&
                    extractIdentity(v, site: ref.site).normalizedBaseTitle ==
                        bucket.identity.normalizedBaseTitle))) {
          bestDisplayTitle = clean;
        }
      }
      if (bestPoster.isEmpty) {
        bestPoster = primary.video.poster.trim();
      }
      if (bestDisplayTitle.isEmpty) {
        bestDisplayTitle = primary.video.title.trim();
      }

      final gKey = [
        bucket.identity.normalizedBaseTitle,
        's${bucket.identity.effectiveSeason}',
        if (bucket.identity.partMarker.isNotEmpty) bucket.identity.partMarker,
        if (bucket.identity.year != null) 'y${bucket.identity.year}',
        if (bucket.identity.workType != AggregatedWorkType.unknown)
          bucket.identity.workType.name,
      ].join('|');

      final group = AggregatedWorkGroup(
        groupKey: gKey,
        cardKeySuffix:
            '${primary.subscriptionId}-${primary.site.key}-${primary.videoId}',
        identity: bucket.identity,
        displayTitle: bestDisplayTitle,
        poster: bestPoster,
        year: bestYear,
        area: bestArea,
        remarks: bestRemarks,
        actor: bestActor,
        tag: bestTag,
        doubanScore: bestDouban,
        rtScore: bestRt,
        sources: sources,
      );

      var rank = 0;
      if (normalizedQuery.isNotEmpty) {
        final normTitle = normalizeTextKey(bestDisplayTitle);
        final normBase = bucket.identity.normalizedBaseTitle;
        if (normTitle == normalizedQuery || normBase == normalizedQuery) {
          rank += 500;
        } else if (normTitle.startsWith(normalizedQuery) ||
            normBase.startsWith(normalizedQuery)) {
          rank += 300;
        } else if (normTitle.contains(normalizedQuery) ||
            normBase.contains(normalizedQuery)) {
          rank += 150;
        }
      }
      rank += (sources.length.clamp(1, 20)) * 20;
      if (_isUsablePoster(bestPoster)) rank += 15;

      scored.add((
        group: group,
        score: rank,
        firstSeen: bucket.firstSeenIndex,
      ));
    }

    scored.sort((a, b) {
      if (normalizedQuery.isNotEmpty && a.score != b.score) {
        return b.score.compareTo(a.score);
      }
      if (a.group.sourceCount != b.group.sourceCount) {
        return b.group.sourceCount.compareTo(a.group.sourceCount);
      }
      return a.firstSeen.compareTo(b.firstSeen);
    });

    return [for (final item in scored) item.group];
  }

  /// Merges episodes across all hydrated [details] (including single-site
  /// multi-line and cross-site sources) so every logical episode appears ONCE
  /// on the Detail page and in "全部剧集", preserving explicit season numbers,
  /// split-part markers (`上`/`下`/`Part 1/2`), and full calendar dates.
  static List<AggregatedEpisodeSlot> buildUnifiedEpisodes({
    required List<WorkSourceDetail> details,
    String seriesTitle = '',
  }) {
    if (details.isEmpty) return const [];

    // Pass 1: Scrape every line across all sources/lines first so explicit
    // season disambiguation is globally consistent across single-season and
    // mixed-season lines (`S02E02` always maps to `ep_s2_2`).
    final scrapedEntries = <({
      WorkSourceDetail detail,
      int lineIndex,
      CmsLine line,
      LineEpisodeScrapeResult scraped,
    })>[];
    final allExplicitSeasons = <int>{};

    for (final detail in details) {
      final effectiveTitle = detail.video.title.trim().isNotEmpty
          ? detail.video.title
          : seriesTitle;
      for (var lineIdx = 0; lineIdx < detail.video.lines.length; lineIdx++) {
        final line = detail.video.lines[lineIdx];
        if (line.episodes.isEmpty) continue;
        final scraped = SeriesScraper.scrapeLineEpisodes(
          line.episodes,
          seriesTitle: effectiveTitle,
        );
        scrapedEntries.add((
          detail: detail,
          lineIndex: lineIdx,
          line: line,
          scraped: scraped,
        ));
        for (final info in scraped.byOriginalIndex) {
          if (!info.isSpecial && info.seasonNumber != null) {
            allExplicitSeasons.add(info.seasonNumber!);
          }
        }
      }
    }

    final hasMultiSeasonAcrossSources = allExplicitSeasons.length >= 2 ||
        allExplicitSeasons.any((s) => s >= 2);

    final slotOrder = <String>[];
    final slotMeta = <String, ({
      String label,
      int? seasonNumber,
      int? episodeNumber,
      String partTag,
      String dateKey,
      bool isSpecial,
    })>{};
    final slotOffers = <String, List<AggregatedEpisodeOffer>>{};
    final seenOffers = <String>{};

    for (final entry in scrapedEntries) {
      final detail = entry.detail;
      final lineIdx = entry.lineIndex;
      final line = entry.line;
      final scraped = entry.scraped;

      for (var epIdx = 0; epIdx < line.episodes.length; epIdx++) {
        final ep = line.episodes[epIdx];
        final info = scraped.byOriginalIndex[epIdx];
        final offer = AggregatedEpisodeOffer(
          source: detail.source,
          video: detail.video,
          lineIndex: lineIdx,
          lineName: line.name,
          episodeIndex: epIdx,
          episode: ep,
          scrapedInfo: info,
        );
        if (!seenOffers.add(offer.offerKey)) continue;

        final partKeySuffix =
            info.partTag.isNotEmpty ? '_p_${info.partTag}' : '';
        final partLabelSuffix = info.partDisplaySuffix;

        String slotKey;
        String label;
        int? slotSeason;
        int? slotEpNum;
        final isSpecial = info.isSpecial;

        if (!isSpecial && info.resolvedEpisodeNumber != null) {
          slotEpNum = info.resolvedEpisodeNumber!;
          final explicitSeason = info.seasonNumber;
          if (explicitSeason != null &&
              (explicitSeason >= 2 || hasMultiSeasonAcrossSources)) {
            slotSeason = explicitSeason;
          }
          final endSuffix = info.endEpisodeNumber != null &&
                  info.endEpisodeNumber! > slotEpNum
              ? '_to_${info.endEpisodeNumber}'
              : '';
          final dateSuffix =
              info.dateKey.isNotEmpty ? '_d_${info.dateKey}' : '';
          slotKey = slotSeason != null
              ? 'ep_s${slotSeason}_$slotEpNum$endSuffix$dateSuffix$partKeySuffix'
              : 'ep_$slotEpNum$endSuffix$dateSuffix$partKeySuffix';
          final baseEpLabel = slotSeason != null
              ? 'S${slotSeason.toString().padLeft(2, '0')}E${slotEpNum.toString().padLeft(2, '0')}'
              : (info.endEpisodeNumber != null &&
                      info.endEpisodeNumber! > slotEpNum
                  ? '第 $slotEpNum–${info.endEpisodeNumber} 集'
                  : '第 $slotEpNum 集');
          label = '$baseEpLabel$partLabelSuffix';
        } else if (!isSpecial && info.dateKey.isNotEmpty) {
          slotKey = 'date_${info.dateKey}$partKeySuffix';
          final d = info.dateKey;
          final formattedDate = d.length == 8
              ? '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)}'
              : d;
          label = '$formattedDate期$partLabelSuffix';
        } else if (isSpecial) {
          final cleanSp = ep.name
              .replaceAll(_qualityTokenPattern, '')
              .replaceAll(_audioTailPattern, '')
              .trim();
          final normSp = normalizeTextKey(
            cleanSp.isNotEmpty ? cleanSp : info.displayLabel,
          );
          final spSeasonPrefix =
              info.seasonNumber != null ? 's${info.seasonNumber}_' : '';
          slotKey =
              'sp_$spSeasonPrefix${normSp.isNotEmpty ? normSp : epIdx}$partKeySuffix';
          label = cleanSp.isNotEmpty ? cleanSp : info.displayLabel;
        } else {
          final rawTrim = ep.name.trim();
          final normRaw = normalizeTextKey(rawTrim);
          if (line.episodes.length == 1 &&
              info.partTag.isEmpty &&
              _genericSingleMovieEpPattern.hasMatch(normRaw)) {
            slotKey = 'movie_main';
            label = '正片';
          } else {
            slotKey =
                'raw_${normRaw.isNotEmpty ? normRaw : epIdx}$partKeySuffix';
            label = rawTrim.isNotEmpty ? rawTrim : '第 ${epIdx + 1} 集';
          }
        }

        if (!slotOffers.containsKey(slotKey)) {
          slotOrder.add(slotKey);
          slotOffers[slotKey] = <AggregatedEpisodeOffer>[];
          slotMeta[slotKey] = (
            label: label,
            seasonNumber: slotSeason,
            episodeNumber: slotEpNum,
            partTag: info.partTag,
            dateKey: info.dateKey,
            isSpecial: isSpecial,
          );
        }
        slotOffers[slotKey]!.add(offer);
      }
    }

    final slots = <AggregatedEpisodeSlot>[
      for (final key in slotOrder)
        AggregatedEpisodeSlot(
          slotKey: key,
          label: slotMeta[key]!.label,
          seasonNumber: slotMeta[key]!.seasonNumber,
          episodeNumber: slotMeta[key]!.episodeNumber,
          isSpecial: slotMeta[key]!.isSpecial,
          offers: List.unmodifiable(slotOffers[key]!),
        ),
    ];

    final indexByKey = <String, int>{
      for (var i = 0; i < slotOrder.length; i++) slotOrder[i]: i,
    };

    int partOrder(String tag) => switch (tag) {
          '' => 0,
          'part1' => 1,
          'part_mid' => 2,
          'part2' => 3,
          'final' => 99,
          _ => int.tryParse(tag.replaceFirst('part', '')) ?? 50,
        };

    slots.sort((a, b) {
      int groupRank(AggregatedEpisodeSlot s) {
        if (!s.isSpecial && s.episodeNumber != null) return 0;
        if (!s.isSpecial) return 1;
        return 2;
      }

      final ra = groupRank(a);
      final rb = groupRank(b);
      if (ra != rb) return ra.compareTo(rb);
      final ma = slotMeta[a.slotKey]!;
      final mb = slotMeta[b.slotKey]!;
      if (ra == 0) {
        final sa = a.seasonNumber ?? 1;
        final sb = b.seasonNumber ?? 1;
        if (sa != sb) return sa.compareTo(sb);
        final na = a.episodeNumber!;
        final nb = b.episodeNumber!;
        if (na != nb) return na.compareTo(nb);
        final pa = partOrder(ma.partTag);
        final pb = partOrder(mb.partTag);
        if (pa != pb) return pa.compareTo(pb);
      } else if (ra == 1 && ma.dateKey.isNotEmpty && mb.dateKey.isNotEmpty) {
        final dc = ma.dateKey.compareTo(mb.dateKey);
        if (dc != 0) return dc;
        final pa = partOrder(ma.partTag);
        final pb = partOrder(mb.partTag);
        if (pa != pb) return pa.compareTo(pb);
      }
      return (indexByKey[a.slotKey] ?? 0).compareTo(indexByKey[b.slotKey] ?? 0);
    });

    return slots;
  }
}

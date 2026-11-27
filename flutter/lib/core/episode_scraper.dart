// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'models.dart';

/// User-configurable per-series episode scraping & alignment settings.
///
/// Used both for cleaning/sorting episode lists in Detail & Player screens
/// and for supplying the real episode number + match title to Danmaku matching.
class EpisodeScrapeOverride {
  final String customTitle;
  final int episodeOffset;
  final bool sortByEpisodeNumber;
  final bool hideSpecials;
  final bool enabled;
  final Map<int, int> manualEpisodeMap;

  const EpisodeScrapeOverride({
    this.customTitle = '',
    this.episodeOffset = 0,
    this.sortByEpisodeNumber = false,
    this.hideSpecials = false,
    this.enabled = false,
    this.manualEpisodeMap = const <int, int>{},
  });

  bool get isDefault =>
      customTitle.trim().isEmpty &&
      episodeOffset == 0 &&
      !sortByEpisodeNumber &&
      !hideSpecials &&
      !enabled &&
      manualEpisodeMap.isEmpty;

  EpisodeScrapeOverride copyWith({
    String? customTitle,
    int? episodeOffset,
    bool? sortByEpisodeNumber,
    bool? hideSpecials,
    bool? enabled,
    Map<int, int>? manualEpisodeMap,
  }) {
    return EpisodeScrapeOverride(
      customTitle: customTitle ?? this.customTitle,
      episodeOffset: episodeOffset ?? this.episodeOffset,
      sortByEpisodeNumber: sortByEpisodeNumber ?? this.sortByEpisodeNumber,
      hideSpecials: hideSpecials ?? this.hideSpecials,
      enabled: enabled ?? this.enabled,
      manualEpisodeMap: manualEpisodeMap ?? this.manualEpisodeMap,
    );
  }

  Map<String, dynamic> toJson() => {
    if (customTitle.trim().isNotEmpty) 'customTitle': customTitle.trim(),
    if (episodeOffset != 0) 'episodeOffset': episodeOffset,
    if (sortByEpisodeNumber) 'sortByEpisodeNumber': true,
    if (hideSpecials) 'hideSpecials': true,
    if (enabled) 'enabled': true,
    if (manualEpisodeMap.isNotEmpty)
      'manualEpisodeMap': {
        for (final e in manualEpisodeMap.entries) '${e.key}': e.value,
      },
  };

  factory EpisodeScrapeOverride.fromJson(Map<String, dynamic>? map) {
    if (map == null) return const EpisodeScrapeOverride();
    final rawManual = map['manualEpisodeMap'];
    final manual = <int, int>{};
    if (rawManual is Map) {
      for (final e in rawManual.entries) {
        final k = int.tryParse(e.key.toString());
        final v = e.value is num
            ? (e.value as num).toInt()
            : int.tryParse(e.value.toString());
        if (k != null && k >= 0 && v != null && v > 0) {
          manual[k] = v;
        }
      }
    }
    final offsetRaw = map['episodeOffset'];
    final offset = offsetRaw is num
        ? offsetRaw.toInt().clamp(-500, 500)
        : (int.tryParse(offsetRaw?.toString() ?? '') ?? 0).clamp(-500, 500);
    return EpisodeScrapeOverride(
      customTitle: (map['customTitle'] ?? '').toString().trim(),
      episodeOffset: offset,
      sortByEpisodeNumber: map['sortByEpisodeNumber'] == true,
      hideSpecials: map['hideSpecials'] == true,
      enabled: map['enabled'] == true,
      manualEpisodeMap: manual,
    );
  }
}

/// Parsed & scraped result for a single episode item in a playback line.
class ScrapedEpisodeInfo {
  final int rawIndex;
  final String rawName;
  final int? seasonNumber;
  final int? parsedEpisodeNumber;
  final int effectiveEpisodeNumber;
  final bool isSpecial;
  final String? specialTag;
  final String? qualityBadge;
  final String cleanSubtitle;

  const ScrapedEpisodeInfo({
    required this.rawIndex,
    required this.rawName,
    required this.seasonNumber,
    required this.parsedEpisodeNumber,
    required this.effectiveEpisodeNumber,
    required this.isSpecial,
    required this.specialTag,
    required this.qualityBadge,
    required this.cleanSubtitle,
  });

  /// Short label suitable for compact episode pills (`1`, `12`, `预告`).
  String get shortPillLabel {
    if (isSpecial) return specialTag ?? '特辑';
    return '$effectiveEpisodeNumber';
  }

  /// Compact badge label for episode thumbnails (`E01`, `S02E05`, `预告`).
  String get badgeLabel {
    if (isSpecial) return specialTag ?? '特辑';
    final ep = effectiveEpisodeNumber.toString().padLeft(2, '0');
    if (seasonNumber != null && seasonNumber! > 1) {
      return 'S${seasonNumber!.toString().padLeft(2, '0')}E$ep';
    }
    return 'E$ep';
  }

  /// Concise episode label for picker grids (`第 5 集`, `S02E05`, `预告 · ...`).
  String compactLabel({
    bool isVariety = false,
    bool singleItemMovie = false,
    bool multiVersionMovie = false,
  }) {
    if (multiVersionMovie) {
      return movieVersionLabel;
    }
    if (singleItemMovie) {
      if (cleanSubtitle.isNotEmpty) return cleanSubtitle;
      if (qualityBadge != null) return '正片 ($qualityBadge)';
      return '正片';
    }
    if (isSpecial) {
      final tag = specialTag ?? '特辑';
      if (cleanSubtitle.isNotEmpty && cleanSubtitle != tag) {
        return '$tag · $cleanSubtitle';
      }
      return tag;
    }
    final unit = isVariety ? '期' : '集';
    if (seasonNumber != null && seasonNumber! > 1) {
      final epStr = effectiveEpisodeNumber.toString().padLeft(2, '0');
      return 'S${seasonNumber!.toString().padLeft(2, '0')}E$epStr';
    }
    return '第 $effectiveEpisodeNumber $unit';
  }

  /// Human-readable resource edition label for movies with multiple files or
  /// encodes (e.g. `4K 杜比视界`, `1080P · 国语版`, `花絮 · 制作特辑`), never
  /// synthesizing fake `第 1 集 / 第 2 集` episode numbers.
  String get movieVersionLabel {
    if (isSpecial) {
      final tag = specialTag ?? '特辑';
      if (cleanSubtitle.isNotEmpty && cleanSubtitle != tag) {
        return '$tag · $cleanSubtitle';
      }
      return tag;
    }
    final raw = rawName.trim();
    final badges = <String>[];
    final upper = raw.toUpperCase();
    if (upper.contains('REMUX') || raw.contains('原盘')) {
      badges.add('原盘 Remux');
    } else if (upper.contains('2160P') || upper.contains('4K')) {
      badges.add('4K');
    } else if (upper.contains('1080P') || raw.contains('超清') || raw.contains('蓝光')) {
      badges.add('1080P');
    } else if (upper.contains('720P')) {
      badges.add('720P');
    }
    if (raw.contains('杜比') ||
        RegExp(r'\b(?:DV|DoVi|Dolby)\b', caseSensitive: false).hasMatch(raw)) {
      badges.add('杜比视界');
    } else if (upper.contains('HDR')) {
      badges.add('HDR');
    }
    if (raw.contains('国语') || raw.contains('国配')) {
      badges.add('国语');
    } else if (raw.contains('粤语')) {
      badges.add('粤语');
    } else if (raw.contains('原声') || raw.contains('英语')) {
      badges.add('原声');
    }
    if (raw.contains('导演剪辑') || upper.contains('DIRECTOR')) {
      badges.add('导演剪辑版');
    } else if (raw.contains('加长') || upper.contains('EXTENDED')) {
      badges.add('加长版');
    } else if (upper.contains('IMAX')) {
      badges.add('IMAX版');
    }
    if (badges.isNotEmpty) {
      return badges.take(3).join(' · ');
    }
    if (cleanSubtitle.isNotEmpty) {
      return cleanSubtitle;
    }
    final base = raw
        .split(RegExp(r'[/\\]+'))
        .last
        .replaceFirst(
          RegExp(r'\.(?:mp4|mkv|ts|flv|avi|mov|m4v|m3u8|iso)$', caseSensitive: false),
          '',
        )
        .trim();
    if (base.isNotEmpty && base.length <= 24) {
      return base;
    }
    return '正片源 ${rawIndex + 1}';
  }

  /// Episode title hint sent to Danmaku providers alongside [effectiveEpisodeNumber].
  String get danmuEpisodeTitle {
    if (isSpecial) return rawName.trim();
    if (seasonNumber != null && seasonNumber! > 0) {
      return 'S${seasonNumber!.toString().padLeft(2, '0')}'
          'E${effectiveEpisodeNumber.toString().padLeft(2, '0')}';
    }
    return '第$effectiveEpisodeNumber集';
  }
}

/// Aggregated scraping result for all episodes of one playback line.
class ScrapedLineResult {
  final List<ScrapedEpisodeInfo> items;
  final List<int> visibleRawIndices;
  final int recognizedCount;
  final int specialCount;
  final bool hasOrderOrNumberMismatch;

  const ScrapedLineResult({
    required this.items,
    required this.visibleRawIndices,
    required this.recognizedCount,
    required this.specialCount,
    required this.hasOrderOrNumberMismatch,
  });

  ScrapedEpisodeInfo? infoForRawIndex(int rawIndex) {
    if (rawIndex < 0 || rawIndex >= items.length) return null;
    return items[rawIndex];
  }
}

/// Pure, deterministic in-series episode parser & scraper.
///
/// Accurately extracts real season/episode numbers and special tags from noisy
/// netdisk / CMS filenames while filtering out years, resolutions, codecs,
/// audio specs, file sizes, and dates.
class EpisodeScraper {
  const EpisodeScraper._();

  static final RegExp _extRe = RegExp(
    r'\.(?:mp4|mkv|ts|flv|avi|mov|wmv|webm|rmvb|rm|m4v|mpg|mpeg|m2ts|mts|m3u8|iso|strm)$',
    caseSensitive: false,
  );
  static final RegExp _fileSizeRe = RegExp(
    r'[\[\(（【]?\s*\d+(?:\.\d+)?\s*(?:TB|GB|MB|KB|TiB|GiB|MiB|KiB|[GM]B?)\s*[\]\)）】]?',
    caseSensitive: false,
  );
  static final RegExp _date8Re = RegExp(
    r'(?<!\d)(?:19|20)\d{2}[-._/]?(?:0[1-9]|1[0-2])[-._/]?(?:0[1-9]|[12]\d|3[01])(?!\d)',
  );
  static final RegExp _yearRe = RegExp(r'(?<!\d)(?:19\d{2}|20[0-3]\d)(?!\d)');
  static final RegExp _techTokenRe = RegExp(
    r'(?:^|(?<=[\s._\-\[\(\/【（]))'
    r'(?:2160[pPiI]?|1440[pPiI]?|1080[pPiI]?|720[pPiI]?|576[pPiI]?|480[pPiI]?|360[pPiI]?|'
    r'[48][kK]|UHD|FHD|HD|SD|SDR|HDR10\+?|HDR|HLG|DV|DoVi|'
    r'x26[45]|H\.?26[45]|HEVC|AVC|AV1|VP9|MPEG[24]|'
    r'(?:8|10|12)\s*bit|(?:24|25|30|50|60|120)\s*fps|'
    r'DDP?\s*\d*(?:\.\d+)?|AC-?3|EAC-?3|AAC\d*(?:\.\d+)?|DTS(?:-?HD)?(?:\s*MA)?|'
    r'TrueHD|Atmos|FLAC|MP3|Opus|LPCM|5\.1|7\.1|2\.0|'
    r'WEB-?DL|WEBRip|Blu-?Ray|BDRip|BRRip|Remux|HDRip|DVDRip|HDTV|'
    r'NF|Netflix|DSNP|AMZN|HMAX|ATVP|iQIYI|YOUKU|WeTV|Viki|Baha|CCTV\d*)'
    r'(?=$|[\s._\-\]\)\/】）])',
    caseSensitive: false,
  );
  static final RegExp _qualityMapRe = RegExp(
    r'(杜比视界|Dolby\s*Vision|\bDV\b|\b4K\b|2160[pP]|HDR10\+?|HDR|原盘|Remux|1080[pP]|720[pP]|蓝光|Blu-?Ray)',
    caseSensitive: false,
  );

  static final List<(RegExp, String)> _specialPatterns = <(RegExp, String)>[
    (RegExp(r'(?:预告|先导片?|片花|定档|终极预告|\bTrailer\b|\bTeaser\b|\bPreview\b|\bPV\d*\b|\bCM\d*\b)', caseSensitive: false), '预告'),
    (RegExp(r'(?:花絮|幕后|特辑|制作特辑|采访|访谈|\bBehind\b|\bMaking\b|\bBonus\b|\bExtra\b)', caseSensitive: false), '花絮'),
    (RegExp(r'(?:彩蛋|番外|特别篇|特典|SP\d*|\bSpecial\b)', caseSensitive: false), '番外'),
    (RegExp(r'(?:\bOVA\d*\b|\bOAD\d*\b)', caseSensitive: false), 'OVA'),
    (RegExp(r'(?:\bNCOP\d*\b|\bNCED\d*\b|\bOP\d*\b|\bED\d*\b|片头曲|片尾曲|主题曲|MV)', caseSensitive: false), 'OP/ED'),
  ];

  static final RegExp _seasonEpisodeRe = RegExp(
    r'[Ss](\d{1,2})\s*[-._]?\s*[Ee][Pp]?(\d{1,4})(?!\d)',
  );
  static final RegExp _seasonOnlyRe = RegExp(
    r'(?:(?<![a-zA-Z])[Ss](\d{1,2})(?![a-zA-Z0-9])|第\s*(\d{1,2}|[一二三四五六七八九十]+)\s*季)',
  );
  static final RegExp _cnEpisodeRe = RegExp(
    r'第\s*(\d{1,4}|[零〇一二两三四五六七八九十百千]+)\s*[集话話期回章篇]',
  );
  static final RegExp _epPrefixRe = RegExp(
    r'(?:^|[^a-zA-Z0-9])[Ee][Pp]?\.?\s*(\d{1,4})(?:[vV]\d)?(?=$|[^a-zA-Z0-9])',
  );
  static final RegExp _cnSuffixNumRe = RegExp(
    r'(?:^|[\s._\-\[\(【（])(\d{1,4})\s*[集话話期回章](?=$|[\s._\-\]\)】）])',
  );
  static final RegExp _bracketNumRe = RegExp(
    r'[\[\【\(（]\s*(\d{1,4})(?:[vV]\d)?\s*[\]\】\)）]',
  );
  static final RegExp _hashNumRe = RegExp(r'#\s*(\d{1,4})(?!\d)');
  static final RegExp _dashNumRe = RegExp(
    r'[-–—]\s*(\d{1,4})(?:[vV]\d)?(?=$|[\s._\-\[\(【（])',
  );
  static final RegExp _leadingNumRe = RegExp(r'^\s*(\d{1,4})(?:[vV]\d)?(?=$|[\s._\-])');
  static final RegExp _trailingNumRe = RegExp(
    r'(?:^|[\s._\-])(\d{1,4})(?:[vV]\d)?\s*$',
  );

  /// Stable storage key for persisting per-series [EpisodeScrapeOverride].
  static String storageKey({
    required String siteKey,
    required String videoId,
    required String videoTitle,
  }) {
    final cleanSite = siteKey.trim().toLowerCase();
    final cleanId = videoId.trim();
    if (cleanSite.isNotEmpty && cleanId.isNotEmpty) {
      return '$cleanSite::$cleanId';
    }
    return 'title::${normalizeSeriesTitle(videoTitle).toLowerCase()}';
  }

  /// Cleans noisy suffixes from a series title for metadata & danmaku matching.
  static String normalizeSeriesTitle(String rawTitle) {
    var s = rawTitle.trim();
    if (s.isEmpty) return '';
    s = s
        .replaceAll(RegExp(r'[\[【\(（][^\]】\)）]*(?:4K|HDR|杜比|原盘|蓝光|中字|国语|粤语|未删减|全\d+集|更新至|完结)[^\]】\)）]*[\]】\)）]', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[\s·\-—:：]+(?:更新至|更至|全\s*\d+\s*[集期话]|完结|HD|4K|1080[pP]).*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isEmpty ? rawTitle.trim() : s;
  }

  /// Parses Chinese numerals up to 9999 (e.g. `五` -> 5, `十二` -> 12, `二十三` -> 23).
  static int? parseChineseOrArabicNumber(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
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
    const units = <String, int>{'十': 10, '百': 100, '千': 1000};
    var total = 0;
    var current = 0;
    var matchedAny = false;
    for (var i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];
      if (digits.containsKey(ch)) {
        current = digits[ch]!;
        matchedAny = true;
      } else if (units.containsKey(ch)) {
        final unit = units[ch]!;
        total += (current == 0 ? 1 : current) * unit;
        current = 0;
        matchedAny = true;
      } else {
        return null;
      }
    }
    total += current;
    return matchedAny && total > 0 ? total : null;
  }

  /// Extracts a positive episode number from [episodeName], or returns
  /// [fallbackIndex] + 1 if none can be reliably identified.
  static int extractEpisodeNumber(String episodeName, int fallbackIndex) {
    final info = parseEpisode(episodeName, rawIndex: fallbackIndex);
    if (!info.isSpecial && info.parsedEpisodeNumber != null) {
      return info.parsedEpisodeNumber!;
    }
    return fallbackIndex + 1;
  }

  /// Parses one episode name into structured [ScrapedEpisodeInfo].
  static ScrapedEpisodeInfo parseEpisode(
    String rawName, {
    required int rawIndex,
    int episodeOffset = 0,
    int? manualEpisodeNumber,
    String seriesTitle = '',
  }) {
    final trimmed = rawName.trim();
    final qualityMatch = _qualityMapRe.firstMatch(trimmed);
    String? qualityBadge;
    if (qualityMatch != null) {
      final rawQ = qualityMatch.group(1)!.toUpperCase();
      if (rawQ.contains('杜比') || rawQ.contains('DOLBY') || rawQ == 'DV') {
        qualityBadge = '杜比视界';
      } else if (rawQ.contains('4K') || rawQ.contains('2160')) {
        qualityBadge = '4K';
      } else if (rawQ.contains('HDR')) {
        qualityBadge = 'HDR';
      } else if (rawQ.contains('原盘') || rawQ.contains('REMUX')) {
        qualityBadge = '原盘';
      } else if (rawQ.contains('1080')) {
        qualityBadge = '1080P';
      } else if (rawQ.contains('720')) {
        qualityBadge = '720P';
      } else if (rawQ.contains('蓝光') || rawQ.contains('BLU')) {
        qualityBadge = '蓝光';
      }
    }

    // Separate folder path vs file basename so folder names (e.g. `k-可能的爱/`)
    // don't pollute episode number matching, while still allowing `S02/05.mp4`
    // to retain its season number.
    final slashParts = trimmed.split(RegExp(r'[/\\]+'));
    final basename = slashParts.last.trim().isNotEmpty
        ? slashParts.last.trim()
        : trimmed;
    final noExt = basename.replaceFirst(_extRe, '').trim();

    int? seasonNum;
    final fullSe = _seasonEpisodeRe.firstMatch(trimmed);
    if (fullSe != null) {
      seasonNum = int.tryParse(fullSe.group(1) ?? '');
    } else {
      final sMatch = _seasonOnlyRe.firstMatch(trimmed);
      if (sMatch != null) {
        final g1 = sMatch.group(1);
        final g2 = sMatch.group(2);
        seasonNum = parseChineseOrArabicNumber(g1 ?? g2 ?? '');
      }
    }

    // Detect specials/trailers/extras on basename.
    String? specialTag;
    for (final (re, tag) in _specialPatterns) {
      if (re.hasMatch(noExt)) {
        specialTag = tag;
        break;
      }
    }
    final bool isSpecial = specialTag != null && manualEpisodeNumber == null;

    // Clean technical noise before running episode regex cascade.
    var cleanedForNum = noExt
        .replaceAll(_fileSizeRe, ' ')
        .replaceAll(_date8Re, ' ')
        .replaceAll(_techTokenRe, ' ')
        .replaceAll(_yearRe, ' ');

    // Remove series title prefix if it contains numbers (e.g. "9号秘事" / "庆余年2")
    // so numbers belonging to the show title are not misparsed as episode numbers.
    final normSeries = normalizeSeriesTitle(seriesTitle);
    if (normSeries.length >= 2) {
      final idx = cleanedForNum.toLowerCase().indexOf(normSeries.toLowerCase());
      if (idx == 0) {
        cleanedForNum = cleanedForNum.substring(normSeries.length);
      }
    }

    int? parsedNum;
    if (manualEpisodeNumber != null && manualEpisodeNumber > 0) {
      parsedNum = manualEpisodeNumber;
    } else if (!isSpecial) {
      parsedNum = _parseEpisodeNumberFromCleaned(noExt, cleanedForNum);
    }

    final int effectiveNum;
    if (manualEpisodeNumber != null && manualEpisodeNumber > 0) {
      effectiveNum = manualEpisodeNumber;
    } else if (isSpecial) {
      effectiveNum = 0;
    } else if (parsedNum != null) {
      effectiveNum = math.max(1, parsedNum + episodeOffset);
    } else {
      effectiveNum = math.max(1, rawIndex + 1 + episodeOffset);
    }

    final cleanSub = _buildCleanSubtitle(
      noExt,
      seriesTitle: normSeries,
      specialTag: specialTag,
    );

    return ScrapedEpisodeInfo(
      rawIndex: rawIndex,
      rawName: rawName,
      seasonNumber: seasonNum,
      parsedEpisodeNumber: parsedNum,
      effectiveEpisodeNumber: effectiveNum,
      isSpecial: isSpecial,
      specialTag: specialTag,
      qualityBadge: qualityBadge,
      cleanSubtitle: cleanSub,
    );
  }

  static bool _isPlausibleYearNumber(int? n) =>
      n != null && n >= 1900 && n <= 2099;

  static int? _parseEpisodeNumberFromCleaned(String noExt, String cleaned) {
    bool isPlausibleExplicit(int? n) => n != null && n > 0 && n <= 2000;
    bool isPlausibleLoose(int? n) =>
        n != null && n > 0 && n <= 2000 && !_isPlausibleYearNumber(n);

    // 1. Explicit S01E05 (checked against original noExt first in case cleaning touched anything)
    final se = _seasonEpisodeRe.firstMatch(noExt);
    if (se != null) {
      final n = int.tryParse(se.group(2) ?? '');
      if (isPlausibleExplicit(n)) return n;
    }

    // 2. Explicit Chinese episode marker (`第05集`, `第五集`, `第十二期`)
    final cn = _cnEpisodeRe.firstMatch(noExt);
    if (cn != null) {
      final n = parseChineseOrArabicNumber(cn.group(1) ?? '');
      if (isPlausibleExplicit(n)) return n;
    }

    // 3. Explicit `E05` / `EP05`
    final ep = _epPrefixRe.firstMatch(cleaned);
    if (ep != null) {
      final n = int.tryParse(ep.group(1) ?? '');
      if (isPlausibleExplicit(n)) return n;
    }

    // 4. `05集` / `05话`
    final cnSuffix = _cnSuffixNumRe.firstMatch(cleaned);
    if (cnSuffix != null) {
      final n = int.tryParse(cnSuffix.group(1) ?? '');
      if (isPlausibleExplicit(n)) return n;
    }

    // 5. Fansub bracketed pure number `[05]` / `【12】`
    for (final m in _bracketNumRe.allMatches(cleaned)) {
      final n = int.tryParse(m.group(1) ?? '');
      if (isPlausibleLoose(n)) return n;
    }

    // 6. `#05`
    final hash = _hashNumRe.firstMatch(cleaned);
    if (hash != null) {
      final n = int.tryParse(hash.group(1) ?? '');
      if (isPlausibleLoose(n)) return n;
    }

    // Strip non-numeric bracketed tags (`[官方中字]`, `(2026)`) before looser numeric matching.
    final withoutTags = cleaned
        .replaceAll(RegExp(r'[\[【\(（][^\]】\)）]*[\]】\)）]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 7. Dash-separated episode (`Title - 05`)
    final dashMatches = _dashNumRe.allMatches(withoutTags).toList();
    if (dashMatches.isNotEmpty) {
      final n = int.tryParse(dashMatches.last.group(1) ?? '');
      if (isPlausibleLoose(n)) return n;
    }

    // 8. Leading pure number (`05.mp4`, `05 标题`)
    final lead = _leadingNumRe.firstMatch(withoutTags);
    if (lead != null) {
      final n = int.tryParse(lead.group(1) ?? '');
      if (isPlausibleLoose(n)) return n;
    }

    // 9. Trailing standalone number (`Title 05`, `Title_05`)
    final trail = _trailingNumRe.firstMatch(withoutTags);
    if (trail != null) {
      final n = int.tryParse(trail.group(1) ?? '');
      if (isPlausibleLoose(n)) return n;
    }

    return null;
  }

  static String _buildCleanSubtitle(
    String noExt, {
    required String seriesTitle,
    required String? specialTag,
  }) {
    var s = noExt
        .replaceAll(_fileSizeRe, ' ')
        .replaceAll(_techTokenRe, ' ')
        .replaceAll(RegExp(r'[\[【\(（][^\]】\)）]*(?:中字|双语|简繁|国语|粤语|官方|特效|高码|高帧|杜比|无水印|完结)[^\]】\)）]*[\]】\)）]'), ' ')
        .replaceAll(RegExp(r'(?:官方中字|中英双字|中文字幕|国语中字|粤语中字|杜比视界|杜比全景声|高码率|无水印)'), ' ')
        .replaceAll(_yearRe, ' ')
        .replaceAll(_seasonEpisodeRe, ' ')
        .replaceAll(_cnEpisodeRe, ' ')
        .replaceAll(_epPrefixRe, ' ')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'^\s*[-–—·:：|]+\s*|\s*[-–—·:：|]+\s*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (seriesTitle.isNotEmpty &&
        s.toLowerCase() == seriesTitle.toLowerCase()) {
      return '';
    }
    if (specialTag != null && s == specialTag) return '';
    if (RegExp(r'^\d+$').hasMatch(s)) return '';
    return s;
  }

  /// Scrapes all episodes in [episodes] using optional [override] and [seriesTitle].
  static ScrapedLineResult scrapeLine(
    List<CmsEpisode> episodes, {
    EpisodeScrapeOverride override = const EpisodeScrapeOverride(),
    String seriesTitle = '',
  }) {
    final items = <ScrapedEpisodeInfo>[];
    var recognizedCount = 0;
    var specialCount = 0;
    var hasMismatch = false;
    int? prevRegularNum;

    for (var i = 0; i < episodes.length; i++) {
      final info = parseEpisode(
        episodes[i].name,
        rawIndex: i,
        episodeOffset: override.episodeOffset,
        manualEpisodeNumber: override.manualEpisodeMap[i],
        seriesTitle: seriesTitle,
      );
      items.add(info);
      if (info.isSpecial) {
        specialCount++;
        hasMismatch = true;
      } else {
        if (info.parsedEpisodeNumber != null) {
          recognizedCount++;
          if (info.effectiveEpisodeNumber != i + 1) {
            hasMismatch = true;
          }
          if (prevRegularNum != null &&
              info.effectiveEpisodeNumber < prevRegularNum) {
            hasMismatch = true;
          }
          prevRegularNum = info.effectiveEpisodeNumber;
        }
      }
    }

    var visible = <int>[
      for (var i = 0; i < items.length; i++)
        if (!override.hideSpecials || !items[i].isSpecial) i,
    ];
    // Never hide everything if every item looked like a special (e.g. a trailer-only line).
    if (visible.isEmpty && items.isNotEmpty) {
      visible = List<int>.generate(items.length, (i) => i);
    }

    if (override.sortByEpisodeNumber && visible.length > 1) {
      visible.sort((a, b) {
        final ia = items[a];
        final ib = items[b];
        if (ia.isSpecial != ib.isSpecial) {
          return ia.isSpecial ? 1 : -1;
        }
        final sa = ia.seasonNumber ?? 0;
        final sb = ib.seasonNumber ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        final ea = ia.effectiveEpisodeNumber;
        final eb = ib.effectiveEpisodeNumber;
        if (ea != eb) return ea.compareTo(eb);
        return a.compareTo(b);
      });
    }

    return ScrapedLineResult(
      items: items,
      visibleRawIndices: visible,
      recognizedCount: recognizedCount,
      specialCount: specialCount,
      hasOrderOrNumberMismatch: hasMismatch,
    );
  }

  static final RegExp _seriesCategoryOrRemarkRe = RegExp(
    r'(?:电视剧|连续剧|剧集|国产剧|美剧|韩剧|日剧|泰剧|港剧|台剧|英剧|海外剧|短剧|微短剧|番剧|新番|连载|电视动画|TV动画|综艺|真人秀|脱口秀|晚会|更新至|更至|全\s*\d+\s*[集期话話]|第\s*[一二三四五六七八九十\d]+\s*[季集期话])',
    caseSensitive: false,
  );

  static final RegExp _movieCategoryOrRemarkRe = RegExp(
    r'(?:电影|影片|院线|动作片|喜剧片|爱情片|科幻片|恐怖片|剧情片|战争片|犯罪片|悬疑片|惊悚片|奇幻片|冒险片|动画电影|剧场版|网络大电影|\bMovie\b)',
    caseSensitive: false,
  );

  static final RegExp _pureNumericEpisodeNameRe = RegExp(
    r'^\s*0*([1-9]\d{0,3})(?:[vV]\d)?\s*$',
  );

  static final RegExp _movieVersionMarkerRe = RegExp(
    r'(?:'
    r'杜比视界|杜比全景声|杜比|Dolby(?:\s*(?:Vision|Atmos))?|\bDV\b|DoVi|IMAX|'
    r'4K|8K|2160[pPiI]?|1440[pPiI]?|1080[pPiI]?|720[pPiI]?|HDR10\+?|HDR|HLG|SDR|'
    r'原盘|Remux|蓝光|Blu-?Ray|BDRip|BRRip|WEB-?DL|WEBRip|HDRip|DVDRip|HDTV|'
    r'高码率?|高帧率?|60\s*fps|120\s*fps|HFR|超清|高清|标清|抢先版?|枪版|\bUHD\b|\bFHD\b|\bHD\b|\bBD\b|\bTC\b|\bTS\b|'
    r'国语|粤语|英语|日语|韩语|法语|德语|俄语|泰语|原声|双语|多音轨|国配|台配|港配|配音|'
    r'中字|中英|双字|简繁|简体|繁体|内封|外挂|特效字幕|无水印|'
    r'全景声|Atmos|TrueHD|DTS(?:-?HD)?(?:\s*MA)?|DDP?\s*\d*(?:\.\d+)?|EAC-?3|AC-?3|AAC\d*(?:\.\d+)?|5\.1|7\.1|'
    r'正片|完整版|未删减|删减版|导演剪辑版?|导剪版?|加长版|公映版|剧场版|院线版|修复版|重制版|典藏版|纪念版|特供版|'
    r"Director'?s?\s*Cut|Extended|Unrated|Uncut|Theatrical|Remastered|Criterion"
    r')',
    caseSensitive: false,
  );

  static final RegExp _multiPartMarkerRe = RegExp(
    r'(?:(?<![a-zA-Z])(?:Part|Pt|Disc|CD|Vol)\.?\s*([1-9]\d?|[IVX]+)(?![a-zA-Z0-9])|'
    r'(?:^|[\s._\-\[\(【（])([上中下])\s*(?:部|集|篇|卷)?(?=$|[\s._\-\]\)】）]))',
    caseSensitive: false,
  );

  static final RegExp _trailingSequelNumRe = RegExp(
    r'(?:(?<=[\u4e00-\u9fff])|[\s._\-])([1-9]|1[0-5]|II|III|IV|V|VI)(?=$)',
  );

  static String _stripBasenameNoExt(String rawName) {
    final slashParts = rawName.trim().split(RegExp(r'[/\\]+'));
    final basename = slashParts.last.trim().isNotEmpty
        ? slashParts.last.trim()
        : rawName.trim();
    return basename.replaceFirst(_extRe, '').trim();
  }

  /// Returns `true` when [rawName] carries an unambiguous TV/anime episode
  /// marker (`S01E02`, `第02集`, `EP02`, `02集`, `[02]`, or bare `01`/`02`).
  /// Bare 4-digit years such as `2024.mkv` are explicitly rejected.
  static bool hasExplicitEpisodicMarker(String rawName) {
    final noExt = _stripBasenameNoExt(rawName);
    if (noExt.isEmpty) return false;
    if (_seasonEpisodeRe.hasMatch(noExt)) return true;
    if (_cnEpisodeRe.hasMatch(noExt)) return true;
    if (_epPrefixRe.hasMatch(noExt)) return true;
    if (_cnSuffixNumRe.hasMatch(noExt)) return true;
    final pureNum = _pureNumericEpisodeNameRe.firstMatch(noExt);
    if (pureNum != null) {
      final n = int.tryParse(pureNum.group(1) ?? '');
      if (n != null && n > 0 && n <= 2000 && !_isPlausibleYearNumber(n)) {
        return true;
      }
      return false;
    }
    final cleaned = noExt
        .replaceAll(_fileSizeRe, ' ')
        .replaceAll(_date8Re, ' ')
        .replaceAll(_techTokenRe, ' ')
        .replaceAll(_yearRe, ' ');
    for (final m in _bracketNumRe.allMatches(cleaned)) {
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null && n > 0 && n <= 500 && !_isPlausibleYearNumber(n)) {
        return true;
      }
    }
    return false;
  }

  /// Determines whether a multi-item line actually represents **different encodes
  /// / quality versions / language tracks / extras of a single Movie** (such as a
  /// Quark share with `4K DV.mkv` + `1080P.mp4` + `花絮.mp4`, or a CMS movie line
  /// with `HD中字` + `国语版`) rather than episodic TV, documentaries, mini-series,
  /// or multi-film sequel collections.
  static bool isLikelyMultiVersionMovie(
    List<CmsEpisode> episodes, {
    String seriesTitle = '',
    String categoryOrTags = '',
    String remarks = '',
    String videoTitle = '',
    String videoTag = '',
    String videoRemarks = '',
    EpisodeScrapeOverride override = const EpisodeScrapeOverride(),
  }) {
    if (episodes.length <= 1) return false;
    if (!override.isDefault) return false;
    final effectiveTitle =
        seriesTitle.trim().isNotEmpty ? seriesTitle : videoTitle;
    final effectiveTags =
        categoryOrTags.trim().isNotEmpty ? categoryOrTags : videoTag;
    final effectiveRemarks =
        remarks.trim().isNotEmpty ? remarks : videoRemarks;
    final metaBlob = '$effectiveTitle $effectiveTags $effectiveRemarks';
    if (_seriesCategoryOrRemarkRe.hasMatch(metaBlob)) {
      return false;
    }
    for (final ep in episodes) {
      if (hasExplicitEpisodicMarker(ep.name)) {
        return false;
      }
    }
    final isExplicitMovie = _movieCategoryOrRemarkRe.hasMatch(metaBlob);
    if (!isExplicitMovie && episodes.length > 12) return false;

    final normSeries = normalizeSeriesTitle(effectiveTitle).toLowerCase();
    final normSeriesCompact =
        normSeries.replaceAll(RegExp(r'[\s._\-:：·]+'), '');

    var versionMarkedCount = 0;
    var extraCount = 0;
    var nonExtraCount = 0;
    final distinctYears = <String>{};
    final distinctPartMarkers = <String>{};
    final distinctSequelTokens = <String>{};
    final allNonEmptyCompactStems = <String>{};
    final distinctNonEmptyStems = <String>{};
    final distinctVersionSignatures = <String>{};
    var hasEmptyNonExtraStem = false;

    for (final ep in episodes) {
      final noExt = _stripBasenameNoExt(ep.name);
      if (noExt.isEmpty) continue;
      final isExtra = _specialPatterns.any((pair) => pair.$1.hasMatch(noExt));
      if (isExtra) {
        extraCount++;
        continue;
      }
      nonExtraCount++;

      final versionTokens = <String>[
        for (final m in _movieVersionMarkerRe.allMatches(noExt))
          m.group(0)!.trim().toLowerCase(),
      ];
      if (versionTokens.isNotEmpty) {
        versionMarkedCount++;
        distinctVersionSignatures.add(versionTokens.join('|'));
      }

      for (final ym in _yearRe.allMatches(noExt)) {
        distinctYears.add(ym.group(0)!);
      }

      for (final pm in _multiPartMarkerRe.allMatches(noExt)) {
        final token = (pm.group(1) ?? pm.group(2) ?? '').trim().toLowerCase();
        if (token.isNotEmpty) distinctPartMarkers.add(token);
      }

      var stem = noExt
          .replaceAll(_fileSizeRe, ' ')
          .replaceAll(_date8Re, ' ')
          .replaceAll(_techTokenRe, ' ')
          .replaceAll(_movieVersionMarkerRe, ' ')
          .replaceAll(_yearRe, ' ')
          .replaceAll(RegExp(r'[\[【\(（][^\]】\)）]*[\]】\)）]'), ' ')
          .replaceAll(RegExp(r'[\s._\-:：·/\\|]+'), ' ')
          .trim()
          .toLowerCase();

      if (stem.isNotEmpty) {
        final sequelMatch = _trailingSequelNumRe.firstMatch(stem);
        if (sequelMatch != null) {
          final baseBeforeSeq =
              stem.substring(0, sequelMatch.start).trim();
          final seqTok = sequelMatch.group(1)!.toLowerCase();
          if (baseBeforeSeq.isNotEmpty) {
            distinctSequelTokens.add('$baseBeforeSeq::$seqTok');
          }
        }
        final compactStem = stem.replaceAll(RegExp(r'\s+'), '');
        allNonEmptyCompactStems.add(compactStem);
        final matchesSeries = normSeriesCompact.isNotEmpty &&
            (compactStem == normSeriesCompact ||
                compactStem.startsWith(normSeriesCompact) &&
                    compactStem.length - normSeriesCompact.length <= 0);
        if (!matchesSeries) {
          distinctNonEmptyStems.add(compactStem);
        }
      } else {
        hasEmptyNonExtraStem = true;
      }
    }

    // Multiple release years (e.g. 2021 + 2024), multi-part splits (Part 1/2,
    // 上/下), or sequel collections (教父1/2/3, 沙丘/沙丘2) are separate works or
    // sequential parts — keep auto-next enabled instead of folding as versions.
    if (distinctYears.length >= 2) return false;
    if (distinctPartMarkers.length >= 2) return false;
    if (distinctSequelTokens.length >= 2) return false;

    final sequelCheckStems = <String>{
      ...allNonEmptyCompactStems,
      if (hasEmptyNonExtraStem && normSeriesCompact.isNotEmpty)
        normSeriesCompact,
    };
    final hasSequelSubset = sequelCheckStems.any(
      (a) => sequelCheckStems.any(
        (b) =>
            a != b &&
            b.startsWith(a) &&
            RegExp(
              r'^(?:第?(?:[1-9]|1[0-5]|[二三四五六七八九十])部?|ii|iii|iv|v)$',
            ).hasMatch(b.substring(a.length)),
      ),
    );
    if (hasSequelSubset) return false;

    if (nonExtraCount == 0) {
      return isExplicitMovie && extraCount >= 2;
    }
    if (nonExtraCount == 1 && extraCount >= 1) {
      return true;
    }

    // Distinct thematic stems (e.g. documentary episodes `森林` / `海洋` or
    // mini-series titles `圣朱尼佩罗 1080P` / `急转直下 1080P`) must NOT be folded
    // into one movie unless explicitly tagged as Movie AND each file carries a
    // distinct version/quality/audio signature (e.g. EN title 4K vs CN title 1080P).
    if (allNonEmptyCompactStems.length >= 2) {
      if (isExplicitMovie &&
          versionMarkedCount == nonExtraCount &&
          distinctVersionSignatures.length >= 2) {
        return true;
      }
      return false;
    }

    // All non-extra items share the same stem (or bare version labels).
    // Require positive version/edition/quality/language/extra evidence!
    if (versionMarkedCount >= 2 ||
        (versionMarkedCount >= 1 && extraCount >= 1)) {
      return true;
    }
    if (versionMarkedCount >= 1 && distinctNonEmptyStems.isEmpty) {
      // E.g. `[2024.mkv, 4K杜比.mkv]` or `[沙丘2.mkv, 沙丘2 4K.mkv]`
      final scraped = scrapeLine(episodes, seriesTitle: effectiveTitle);
      if (scraped.recognizedCount == 0) {
        return true;
      }
    }
    return false;
  }
}

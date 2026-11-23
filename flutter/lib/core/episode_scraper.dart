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
  String compactLabel({bool isVariety = false, bool singleItemMovie = false}) {
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

  static int? _parseEpisodeNumberFromCleaned(String noExt, String cleaned) {
    bool isPlausible(int? n) => n != null && n > 0 && n <= 2000;

    // 1. Explicit S01E05 (checked against original noExt first in case cleaning touched anything)
    final se = _seasonEpisodeRe.firstMatch(noExt);
    if (se != null) {
      final n = int.tryParse(se.group(2) ?? '');
      if (isPlausible(n)) return n;
    }

    // 2. Explicit Chinese episode marker (`第05集`, `第五集`, `第十二期`)
    final cn = _cnEpisodeRe.firstMatch(noExt);
    if (cn != null) {
      final n = parseChineseOrArabicNumber(cn.group(1) ?? '');
      if (isPlausible(n)) return n;
    }

    // 3. Explicit `E05` / `EP05`
    final ep = _epPrefixRe.firstMatch(cleaned);
    if (ep != null) {
      final n = int.tryParse(ep.group(1) ?? '');
      if (isPlausible(n)) return n;
    }

    // 4. `05集` / `05话`
    final cnSuffix = _cnSuffixNumRe.firstMatch(cleaned);
    if (cnSuffix != null) {
      final n = int.tryParse(cnSuffix.group(1) ?? '');
      if (isPlausible(n)) return n;
    }

    // 5. Fansub bracketed pure number `[05]` / `【12】`
    for (final m in _bracketNumRe.allMatches(cleaned)) {
      final n = int.tryParse(m.group(1) ?? '');
      if (isPlausible(n)) return n;
    }

    // 6. `#05`
    final hash = _hashNumRe.firstMatch(cleaned);
    if (hash != null) {
      final n = int.tryParse(hash.group(1) ?? '');
      if (isPlausible(n)) return n;
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
      if (isPlausible(n)) return n;
    }

    // 8. Leading pure number (`05.mp4`, `05 标题`)
    final lead = _leadingNumRe.firstMatch(withoutTags);
    if (lead != null) {
      final n = int.tryParse(lead.group(1) ?? '');
      if (isPlausible(n)) return n;
    }

    // 9. Trailing standalone number (`Title 05`, `Title_05`)
    final trail = _trailingNumRe.firstMatch(withoutTags);
    if (trail != null) {
      final n = int.tryParse(trail.group(1) ?? '');
      if (isPlausible(n)) return n;
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
}

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ai_service.dart';

/// Cleaned metadata resolved from a raw WebDAV / SMB / netdisk filename.
@immutable
class CleanedMediaTitle {
  final String rawName;
  final String title;
  final String year;
  final int? season;
  final int? episode;
  final bool fromAi;

  const CleanedMediaTitle({
    required this.rawName,
    required this.title,
    this.year = '',
    this.season,
    this.episode,
    this.fromAi = false,
  });

  /// Canonical season/episode badge (`S01E03`, `第 3 集`, `第 1 季`, or `null`).
  String? get episodeBadge {
    final s = season;
    final e = episode;
    if (s != null && s > 0 && e != null && e > 0) {
      return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    }
    if (e != null && e > 0) {
      return '第 $e 集';
    }
    if (s != null && s > 0) {
      return '第 $s 季';
    }
    return null;
  }
}

/// Non-blocking smart filename/title cleaner combining a fast deterministic
/// baseline parser with optional batched BYO-API LLM refinement (max 20 items
/// per request, strict JSON schema & anti-URL validation, and normalized caching).
class AiTitleCleaner {
  static const int maxBatchSize = 20;
  static const int maxMemoryCacheEntries = 400;

  static final AiTitleCleaner instance = AiTitleCleaner();

  AiService _aiService;
  final LinkedHashMap<String, CleanedMediaTitle> _memoryCache =
      LinkedHashMap<String, CleanedMediaTitle>();

  AiTitleCleaner({AiService? aiService})
      : _aiService = aiService ?? AiService.instance;

  @visibleForTesting
  void configureForTest({AiService? aiService, bool clearCache = false}) {
    if (aiService != null) _aiService = aiService;
    if (clearCache) _memoryCache.clear();
  }

  void clearMemoryCache() {
    _memoryCache.clear();
  }

  static final RegExp _videoExtensionRe = RegExp(
    r'\.(?:mkv|mp4|avi|mov|m4v|ts|m2ts|flv|wmv|webm|mpg|mpeg|iso|strm)$',
    caseSensitive: false,
  );

  static final RegExp _leadingBracketGroupRe = RegExp(
    r'^(?:\s*(?:\[[^\]]{1,40}\]|【[^】]{1,40}】))+\s*',
  );

  static final RegExp _seasonEpisodeEnRe = RegExp(
    r'(?<![A-Za-z0-9])S(\d{1,2})\s*[\.\-_ ]?\s*E(\d{1,4})(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static final RegExp _seasonEpisodeZhRe = RegExp(
    r'第\s*(\d{1,2})\s*季[\s·\-_]*第\s*(\d{1,4})\s*[集话期篇章]',
  );

  static final RegExp _episodeOnlyEnRe = RegExp(
    r'(?<![A-Za-z0-9])(?:EP?|Episode)\s*(\d{1,4})(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static final RegExp _episodeOnlyZhRe = RegExp(
    r'第\s*(\d{1,4})\s*[集话期篇章]',
  );

  static final RegExp _seasonOnlyZhRe = RegExp(
    r'第\s*(\d{1,2})\s*季',
  );

  static final RegExp _seasonOnlyEnRe = RegExp(
    r'(?<![A-Za-z0-9])(?:Season\s*|S)(\d{1,2})(?![A-Za-z0-9])',
    caseSensitive: false,
  );

  static final RegExp _yearTokenRe = RegExp(
    r'(?<![0-9])((?:19[2-9]\d|20[0-3]\d))(?![0-9pPiI])',
  );

  static final RegExp _releaseNoiseCutRe = RegExp(
    r'(?<![A-Za-z0-9])(?:'
    r'2160p|1080p|1080i|720p|480p|4k|uhd|web[\-\.]?dl|webrip|bluray|blu[\-\.]?ray|'
    r'bdrip|remux|hdrip|dvdrip|hdtv|x264|x265|h[\.]?264|h[\.]?265|hevc|avc|av1|'
    r'10bit|8bit|hdr10\+?|hdr|dv|dovi|dolby|atmos|truehd|dts[\-\.]?hd|dts|aac|flac|ddp5|ac3'
    r')(?![A-Za-z0-9]).*$',
    caseSensitive: false,
  );

  static final RegExp _trailingSubLangRe = RegExp(
    r'[\s\.\-_]*(?:\[?(?:CHS|CHT|ENG|GB|BIG5|JAP|JPN|中英双字|中字|简繁|国粤双语|国语|粤语|双语|内封|内嵌|无水印|未删减版?)\]?\s*)+$',
    caseSensitive: false,
  );

  /// Canonical cache key for a raw filename/title.
  static String normalizeRawKey(String rawName) =>
      rawName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Synchronous deterministic filename cleaner used immediately before (or
  /// without) any LLM call, and as the guaranteed fallback on any failure.
  static CleanedMediaTitle cleanBaseline(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      return const CleanedMediaTitle(rawName: '', title: '');
    }

    var working = trimmed.replaceFirst(_videoExtensionRe, '').trim();
    final strippedBrackets = working.replaceFirst(_leadingBracketGroupRe, '').trim();
    if (strippedBrackets.isNotEmpty) {
      working = strippedBrackets;
    }

    int? season;
    int? episode;
    int? epMatchStart;

    final seEn = _seasonEpisodeEnRe.firstMatch(working);
    final seZh = _seasonEpisodeZhRe.firstMatch(working);
    if (seEn != null) {
      season = int.tryParse(seEn.group(1)!);
      episode = int.tryParse(seEn.group(2)!);
      epMatchStart = seEn.start;
    } else if (seZh != null) {
      season = int.tryParse(seZh.group(1)!);
      episode = int.tryParse(seZh.group(2)!);
      epMatchStart = seZh.start;
    } else {
      final epZh = _episodeOnlyZhRe.firstMatch(working);
      final epEn = _episodeOnlyEnRe.firstMatch(working);
      if (epZh != null) {
        episode = int.tryParse(epZh.group(1)!);
        epMatchStart = epZh.start;
      } else if (epEn != null) {
        episode = int.tryParse(epEn.group(1)!);
        epMatchStart = epEn.start;
      }
      final sZh = _seasonOnlyZhRe.firstMatch(working);
      final sEn = _seasonOnlyEnRe.firstMatch(working);
      if (sZh != null) {
        season = int.tryParse(sZh.group(1)!);
      } else if (sEn != null) {
        season = int.tryParse(sEn.group(1)!);
      }
    }

    String year = '';
    int? yearStart;
    for (final m in _yearTokenRe.allMatches(working)) {
      final candidateYear = m.group(1)!;
      // Avoid mistaking a pure numeric title at index 0 (e.g. "1917.2019.1080p")
      // for the release year when another year follows.
      if (m.start == 0 && _yearTokenRe.allMatches(working).length > 1) {
        continue;
      }
      year = candidateYear;
      yearStart = m.start;
      break;
    }

    var titleSlice = working;
    var cutAt = titleSlice.length;
    if (epMatchStart != null && epMatchStart > 0 && epMatchStart < cutAt) {
      cutAt = epMatchStart;
    }
    if (yearStart != null && yearStart > 1 && yearStart < cutAt) {
      cutAt = yearStart;
    }
    titleSlice = titleSlice.substring(0, cutAt);
    titleSlice = titleSlice.replaceFirst(_releaseNoiseCutRe, '');
    titleSlice = titleSlice
        .replaceAll(RegExp(r'[\._]+'), ' ')
        .replaceFirst(_trailingSubLangRe, '')
        .replaceAll(RegExp(r'[\s\(\[\{（【\-_·]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (titleSlice.isEmpty) {
      titleSlice = working
          .replaceFirst(_releaseNoiseCutRe, '')
          .replaceAll(RegExp(r'[\._]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    if (titleSlice.isEmpty) {
      titleSlice = trimmed;
    }

    return CleanedMediaTitle(
      rawName: rawName,
      title: titleSlice,
      year: year,
      season: (season != null && season > 0) ? season : null,
      episode: (episode != null && episode > 0) ? episode : null,
      fromAi: false,
    );
  }

  /// Returns an already-resolved AI title from memory cache if available.
  CleanedMediaTitle? peekCached(String rawName) {
    final key = normalizeRawKey(rawName);
    if (key.isEmpty) return null;
    final hit = _memoryCache.remove(key);
    if (hit != null) {
      _memoryCache[key] = hit;
    }
    return hit;
  }

  static const String _batchSystemPrompt =
      '你是本地影视文件名清洗助手。请将输入的原始影视文件名列表解析为干净的作品标准片名、年份及季集序号。\n'
      '严格只输出纯 JSON 数组，每个元素格式为：'
      '{"index":0,"title":"干净片名","year":"2014","season":1,"episode":3}（电影或无季集信息时 season 与 episode 填 null，无年份时 year 填 ""）。\n'
      '安全与合规硬性约束：只允许输出 index、title、year、season、episode 五个元数据字段；'
      '严禁生成或包含任何网址、URL、域名、网盘链接或播放地址；不要输出 Markdown 代码块或任何解释。';

  /// Cleans [rawNames] asynchronously in chunks of at most [maxBatchSize] (20).
  /// Never throws: falls back to [cleanBaseline] when AI is disabled,
  /// unconfigured, in Privacy Space, or when an HTTP / schema error occurs.
  Future<List<CleanedMediaTitle>> cleanBatch(
    List<String> rawNames, {
    bool isPrivateSession = false,
  }) async {
    if (rawNames.isEmpty) return const <CleanedMediaTitle>[];
    final results = List<CleanedMediaTitle>.generate(
      rawNames.length,
      (i) => cleanBaseline(rawNames[i]),
      growable: false,
    );
    if (isPrivateSession) return results;

    await _aiService.ensureLoaded();
    if (!_aiService.isConfigured || !_aiService.config.titleCleanupEnabled) {
      return results;
    }

    // Resolve memory-cached items first and collect unique uncached keys.
    final pendingByNormKey = <String, ({String sampleRaw, List<int> indices})>{};
    for (var i = 0; i < rawNames.length; i++) {
      final raw = rawNames[i];
      final norm = normalizeRawKey(raw);
      if (norm.isEmpty) continue;
      final cached = peekCached(raw);
      if (cached != null) {
        results[i] = CleanedMediaTitle(
          rawName: raw,
          title: cached.title,
          year: cached.year,
          season: cached.season,
          episode: cached.episode,
          fromAi: cached.fromAi,
        );
        continue;
      }
      final bucket = pendingByNormKey.putIfAbsent(
        norm,
        () => (sampleRaw: raw.trim(), indices: <int>[]),
      );
      bucket.indices.add(i);
    }

    if (pendingByNormKey.isEmpty) return results;

    final pendingEntries = pendingByNormKey.entries.toList(growable: false);
    for (var offset = 0;
        offset < pendingEntries.length;
        offset += maxBatchSize) {
      final end = (offset + maxBatchSize < pendingEntries.length)
          ? offset + maxBatchSize
          : pendingEntries.length;
      final chunk = pendingEntries.sublist(offset, end);
      final inputPayload = <Map<String, Object>>[
        for (var j = 0; j < chunk.length; j++)
          <String, Object>{
            'index': j,
            'name': chunk[j].value.sampleRaw,
          },
      ];

      try {
        final completion = await _aiService.complete(
          feature: 'title_cleanup_v1',
          systemPrompt: _batchSystemPrompt,
          userPrompt: jsonEncode(inputPayload),
          modelOverride: _aiService.config.effectiveFastModel,
          temperature: 0.1,
          maxTokens: 1024,
          useCache: true,
          isPrivateSession: isPrivateSession,
        );
        final parsedByIndex = parseBatchCleanupJson(
          completion.text,
          batchLength: chunk.length,
        );
        for (final entry in parsedByIndex.entries) {
          final chunkItem = chunk[entry.key];
          final resolved = entry.value;
          final canonical = CleanedMediaTitle(
            rawName: chunkItem.value.sampleRaw,
            title: resolved.title,
            year: resolved.year,
            season: resolved.season,
            episode: resolved.episode,
            fromAi: true,
          );
          _putMemoryCache(chunkItem.key, canonical);
          for (final originalIdx in chunkItem.value.indices) {
            results[originalIdx] = CleanedMediaTitle(
              rawName: rawNames[originalIdx],
              title: canonical.title,
              year: canonical.year,
              season: canonical.season,
              episode: canonical.episode,
              fromAi: true,
            );
          }
        }
      } catch (_) {
        // Non-blocking progressive enhancement: preserve deterministic baseline.
      }
    }

    return results;
  }

  void _putMemoryCache(String normKey, CleanedMediaTitle value) {
    _memoryCache.remove(normKey);
    if (_memoryCache.length >= maxMemoryCacheEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[normKey] = value;
  }

  /// Strictly validates the LLM batch JSON response (`[{"index": 0, "title": "...", ...}]`)
  /// and rejects any entry containing URLs or invalid schema fields.
  static Map<int, ({String title, String year, int? season, int? episode})>
      parseBatchCleanupJson(
    String rawResponse, {
    required int batchLength,
  }) {
    final slice = AiService.extractJsonArraySlice(rawResponse);
    final dynamic decoded = jsonDecode(slice);
    if (decoded is! List) {
      throw const FormatException('文件名清洗结果不是 JSON 数组');
    }

    final out = <int, ({String title, String year, int? season, int? episode})>{};
    for (final item in decoded) {
      if (item is! Map) continue;

      // Reject the entire item if ANY field carries a URL/link or unexpected URL key.
      var hasForbiddenUrl = false;
      for (final kv in item.entries) {
        final fieldName = kv.key.toString().trim().toLowerCase();
        if (fieldName == 'url' ||
            fieldName == 'link' ||
            fieldName == 'play_url' ||
            fieldName == 'stream') {
          if ((kv.value ?? '').toString().trim().isNotEmpty) {
            hasForbiddenUrl = true;
            break;
          }
        }
        if (kv.value is String &&
            AiService.containsForbiddenUrl(kv.value as String)) {
          hasForbiddenUrl = true;
          break;
        }
      }
      if (hasForbiddenUrl) continue;

      final idx = (item['index'] as num?)?.toInt() ??
          int.tryParse((item['index'] ?? '').toString());
      if (idx == null || idx < 0 || idx >= batchLength) continue;

      final rawTitle = (item['title'] ?? '').toString().trim();
      if (rawTitle.isEmpty ||
          rawTitle.length > 120 ||
          AiService.containsForbiddenUrl(rawTitle)) {
        continue;
      }

      final rawYear = (item['year'] ?? '').toString().trim();
      final cleanYear =
          RegExp(r'^(?:19|20)\d{2}$').hasMatch(rawYear) ? rawYear : '';

      final rawSeason = (item['season'] as num?)?.toInt() ??
          int.tryParse((item['season'] ?? '').toString());
      final cleanSeason =
          (rawSeason != null && rawSeason > 0 && rawSeason <= 99)
              ? rawSeason
              : null;

      final rawEpisode = (item['episode'] as num?)?.toInt() ??
          int.tryParse((item['episode'] ?? '').toString());
      final cleanEpisode =
          (rawEpisode != null && rawEpisode > 0 && rawEpisode <= 9999)
              ? rawEpisode
              : null;

      out[idx] = (
        title: rawTitle,
        year: cleanYear,
        season: cleanSeason,
        episode: cleanEpisode,
      );
    }
    return out;
  }
}

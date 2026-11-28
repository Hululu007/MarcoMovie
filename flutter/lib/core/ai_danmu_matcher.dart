// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibCodec, gzip, zlib;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';
import 'danmu/dandanplay_provider.dart';
import 'danmu/danmu_prefs.dart';
import 'danmu/provider.dart';
import 'ohos_runtime.dart';
import 'series_scraper.dart';

/// Structured search query extracted by AI (or local fallback) for online danmaku matching.
@immutable
class AiDanmuQueryPlan {
  final String canonicalTitle;
  final List<String> altTitles;
  final int? seasonNumber;
  final int episodeNumber;
  final String year;
  final bool isMovie;
  final bool usedAi;

  const AiDanmuQueryPlan({
    required this.canonicalTitle,
    this.altTitles = const <String>[],
    this.seasonNumber,
    this.episodeNumber = 1,
    this.year = '',
    this.isMovie = false,
    this.usedAi = false,
  });
}

/// Online danmaku candidate discovered from public sources or user-configured origins.
@immutable
class AiOnlineDanmuCandidate {
  final String id;
  final String sourceKey;
  final String sourceLabel;
  final String workTitle;
  final String episodeTitle;
  final int episodeNumber;
  final int durationSec;
  final double confidence;
  final String fetchKind; // 'bilibili_cid' | 'dandan_ep'
  final String fetchTarget;
  final String origin;

  const AiOnlineDanmuCandidate({
    required this.id,
    required this.sourceKey,
    required this.sourceLabel,
    required this.workTitle,
    required this.episodeTitle,
    required this.episodeNumber,
    this.durationSec = 0,
    required this.confidence,
    required this.fetchKind,
    required this.fetchTarget,
    required this.origin,
  });

  DanmuCandidate toDanmuCandidate() => DanmuCandidate(
        sourceOrigin: origin,
        animeId: id,
        animeTitle: workTitle,
        boundEpisodeId: 'ai_online:$sourceKey:$fetchTarget',
        episodeTitle: episodeTitle,
        confidence: confidence,
      );
}

/// Combined outcome returned by [AiDanmuMatcher.autoMatchAndLoad].
@immutable
class AiDanmuMatchOutcome {
  final AiDanmuQueryPlan plan;
  final List<AiOnlineDanmuCandidate> candidates;
  final AiOnlineDanmuCandidate? selected;
  final List<DanmuItem> items;
  final String messageZh;

  const AiDanmuMatchOutcome({
    required this.plan,
    required this.candidates,
    required this.selected,
    required this.items,
    required this.messageZh,
  });
}

/// AI-powered online danmaku matcher supporting query extraction, public danmaku
/// search (`api.bilibili.com`, `api.dandanplay.net`, plus user-configured
/// `DanmuSettings` origins), RFC 1951 raw-deflate / gzip XML & JSON decoding,
/// and AI timeline alignment hints.
class AiDanmuMatcher {
  @visibleForTesting
  static http.Client? debugHttpClientOverride;

  static const Duration _requestTimeout = Duration(seconds: 6);
  static const Map<String, String> _bilibiliHeaders = <String, String>{
    'Accept': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15',
    'Referer': 'https://www.bilibili.com/',
  };

  final AiService _ai;
  final http.Client? _injectedClient;
  http.Client? _ownedClient;

  AiDanmuMatcher({
    AiService? aiService,
    http.Client? httpClient,
  })  : _ai = aiService ?? AiService.instance,
        _injectedClient = httpClient;

  http.Client get _client =>
      _injectedClient ??
      debugHttpClientOverride ??
      (_ownedClient ??= http.Client());

  void dispose() {
    _ownedClient?.close();
    _ownedClient = null;
  }

  void _ensureAuthorized({required bool isPrivateSession}) {
    if (OhosRuntime.isOhos) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        '当前环境不支持在线弹幕匹配',
      );
    }
    if (isPrivateSession || _ai.isPrivacySessionActive) {
      throw const AiServiceException(
        AiErrorCode.privacySpaceBlocked,
        '隐私空间已硬性禁用外部弹幕搜索与 AI 请求',
      );
    }
    if (!_ai.isLabUnlocked) {
      throw const AiServiceException(
        AiErrorCode.disabled,
        'AI 观影实验室尚未通过内测口令解锁',
      );
    }
  }

  static final RegExp _htmlTagRe = RegExp(r'<[^>]+>');

  static String _stripEmTags(String raw) =>
      raw.replaceAll(_htmlTagRe, '').replaceAll('&amp;', '&').trim();

  static bool _looksLikeMessyFilename(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return false;
    return RegExp(
      r'(?:1080p|2160p|4k|x264|x265|hevc|webrip|bluray|aac|\.mkv|\.mp4|\[|\])',
      caseSensitive: false,
    ).hasMatch(s);
  }

  static int? _parseFlexibleDurationSec(dynamic raw) {
    if (raw is int) return raw > 10000 ? raw ~/ 1000 : raw;
    if (raw is num) {
      final n = raw.round();
      return n > 10000 ? n ~/ 1000 : n;
    }
    final str = (raw ?? '').toString().trim();
    if (str.isEmpty) return null;
    final parts = str.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0].trim());
      final s = int.tryParse(parts[1].trim());
      if (m != null && s != null) return m * 60 + s;
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0].trim());
      final m = int.tryParse(parts[1].trim());
      final s = int.tryParse(parts[2].trim());
      if (h != null && m != null && s != null) return h * 3600 + m * 60 + s;
    }
    return int.tryParse(str);
  }

  /// Decodes Bilibili `list.so` danmaku XML bytes (plain UTF-8, gzip, or raw RFC-1951 deflate).
  static String decodeBilibiliDanmuXml(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    // Plain UTF-8 or UTF-8 BOM + '<'
    if (bytes[0] == 0x3C) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF &&
        bytes[3] == 0x3C) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    // Gzip header (0x1F 0x8B)
    if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      try {
        return utf8.decode(gzip.decode(bytes), allowMalformed: true);
      } catch (_) {}
    }
    // Bilibili `list.so` uses raw RFC-1951 deflate without zlib wrapper
    try {
      return utf8.decode(
        ZLibCodec(raw: true).decode(bytes),
        allowMalformed: true,
      );
    } catch (_) {}
    try {
      return utf8.decode(zlib.decode(bytes), allowMalformed: true);
    } catch (_) {}
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Extracts a clean search query plan (canonical title, aliases, season/episode)
  /// using AI when configured and falls back cleanly to local scraping.
  Future<AiDanmuQueryPlan> extractQueryPlan({
    required String rawTitle,
    String rawEpisodeName = '',
    int fallbackEpisodeIndex = 1,
    String year = '',
    int durationSec = 0,
    String manualKeywordOverride = '',
    int? manualEpisodeOverride,
    bool isPrivateSession = false,
  }) async {
    _ensureAuthorized(isPrivateSession: isPrivateSession);

    final scrapedEp = SeriesScraper.scrapeEpisodeName(
      rawEpisodeName,
      seriesTitle: rawTitle,
    );
    final localTitle = SeriesScraper.cleanSearchTitle(rawTitle).trim();
    final baselineTitle = localTitle.isNotEmpty ? localTitle : rawTitle.trim();
    final localEp = manualEpisodeOverride ??
        (scrapedEp.rawEpisodeNumber != null && scrapedEp.rawEpisodeNumber! > 0
            ? scrapedEp.rawEpisodeNumber!
            : (fallbackEpisodeIndex > 0 ? fallbackEpisodeIndex : 1));
    final localSeason = scrapedEp.seasonNumber;

    final manualKw = manualKeywordOverride.trim();
    if (manualKw.isNotEmpty && !_looksLikeMessyFilename(manualKw)) {
      return AiDanmuQueryPlan(
        canonicalTitle: manualKw,
        altTitles: baselineTitle.isNotEmpty && baselineTitle != manualKw
            ? <String>[baselineTitle]
            : const <String>[],
        seasonNumber: localSeason,
        episodeNumber: localEp,
        year: year.trim(),
        isMovie: durationSec >= 3900 && localEp <= 1 && rawEpisodeName.trim().isEmpty,
        usedAi: false,
      );
    }

    final cfg = _ai.config;
    if (!_ai.isConfigured || !cfg.enabled || !cfg.danmuMatchEnabled) {
      return AiDanmuQueryPlan(
        canonicalTitle: manualKw.isNotEmpty ? manualKw : baselineTitle,
        altTitles: const <String>[],
        seasonNumber: localSeason,
        episodeNumber: localEp,
        year: year.trim(),
        isMovie: durationSec >= 3900 && localEp <= 1,
        usedAi: false,
      );
    }

    try {
      final promptTitle = manualKw.isNotEmpty ? manualKw : rawTitle.trim();
      final result = await _ai.complete(
        feature: 'ai_danmu_match_v1',
        modelOverride:
            cfg.fastModel.trim().isNotEmpty ? cfg.fastModel.trim() : null,
        isPrivateSession: isPrivateSession,
        systemPrompt: '你是影视作品与弹幕搜索关键词提炼助手。'
            '只输出合法 JSON，不要任何解释、Markdown 代码块或链接，字段为：'
            '{"title":"最标准中文主片名","alt_titles":["英文/日文/常用别名"],"season":1,"episode":1,"year":"2024","is_movie":false}。'
            '去掉清晰度、压制组、字幕组、网盘标识等杂质。',
        userPrompt: '原始片名：$promptTitle\n'
            '当前分集名：${rawEpisodeName.trim()}\n'
            '本地识别集号：$localEp\n'
            '年份：${year.trim()}\n'
            '时长（秒）：$durationSec',
      );
      _ensureAuthorized(isPrivateSession: isPrivateSession);
      final jsonSlice = AiService.extractJsonObjectSlice(result.text);
      if (jsonSlice != null && !AiService.containsForbiddenUrl(jsonSlice)) {
        final decoded = jsonDecode(jsonSlice);
        if (decoded is Map) {
          final parsedTitle = (decoded['title'] ?? '').toString().trim();
          final alts = <String>[];
          if (decoded['alt_titles'] is List) {
            for (final a in decoded['alt_titles'] as List) {
              final s = a.toString().trim();
              if (s.isNotEmpty &&
                  s != parsedTitle &&
                  !AiService.containsForbiddenUrl(s)) {
                alts.add(s);
              }
            }
          }
          if (baselineTitle.isNotEmpty &&
              baselineTitle != parsedTitle &&
              !alts.contains(baselineTitle)) {
            alts.add(baselineTitle);
          }
          final aiSeason = (decoded['season'] as num?)?.toInt();
          final aiEp = manualEpisodeOverride ??
              ((decoded['episode'] as num?)?.toInt() ?? localEp);
          final aiYear = (decoded['year'] ?? year).toString().trim();
          final isMovie = decoded['is_movie'] == true;
          return AiDanmuQueryPlan(
            canonicalTitle: parsedTitle.isNotEmpty ? parsedTitle : baselineTitle,
            altTitles: List<String>.unmodifiable(alts.take(3)),
            seasonNumber: aiSeason ?? localSeason,
            episodeNumber: aiEp > 0 ? aiEp : 1,
            year: aiYear,
            isMovie: isMovie,
            usedAi: parsedTitle.isNotEmpty,
          );
        }
      }
    } on AiServiceException catch (e) {
      if (e.code == AiErrorCode.privacySpaceBlocked ||
          e.code == AiErrorCode.disabled) {
        rethrow;
      }
    } catch (_) {}

    return AiDanmuQueryPlan(
      canonicalTitle: manualKw.isNotEmpty ? manualKw : baselineTitle,
      altTitles: const <String>[],
      seasonNumber: localSeason,
      episodeNumber: localEp,
      year: year.trim(),
      isMovie: durationSec >= 3900 && localEp <= 1,
      usedAi: false,
    );
  }

  /// Searches online danmaku candidates across user-configured origins,
  /// Bilibili PGC (`media_bangumi`/`media_ft`), Dandanplay, and Bilibili UGC.
  Future<List<AiOnlineDanmuCandidate>> searchCandidates(
    AiDanmuQueryPlan plan, {
    DanmuSettings? danmuSettings,
    int durationSec = 0,
    bool isPrivateSession = false,
  }) async {
    _ensureAuthorized(isPrivateSession: isPrivateSession);

    final keywords = <String>[
      if (plan.canonicalTitle.trim().isNotEmpty) plan.canonicalTitle.trim(),
      for (final alt in plan.altTitles)
        if (alt.trim().isNotEmpty && alt.trim() != plan.canonicalTitle.trim())
          alt.trim(),
    ];
    if (keywords.isEmpty) return const <AiOnlineDanmuCandidate>[];

    final searchKeywords = keywords.take(2).toList();
    final collected = <AiOnlineDanmuCandidate>[];
    final customOrigins = danmuSettings?.normalizedOrigins ?? const <String>[];

    final primaryTasks = <Future<List<AiOnlineDanmuCandidate>>>[
      for (final origin in customOrigins)
        _searchDandanCompatibleOrigin(
          origin: origin,
          sourceKey: 'custom_origin',
          sourceLabel: '自定弹幕源',
          keyword: searchKeywords.first,
          plan: plan,
          durationSec: durationSec,
          danmuSettings: danmuSettings,
          isPrivateSession: isPrivateSession,
        ),
      for (final kw in searchKeywords) ...[
        _searchBilibiliPgc(
          keyword: kw,
          searchType: 'media_bangumi',
          sourceLabel: '哔哩哔哩番剧',
          plan: plan,
          durationSec: durationSec,
          isPrivateSession: isPrivateSession,
        ),
        _searchBilibiliPgc(
          keyword: kw,
          searchType: 'media_ft',
          sourceLabel: '哔哩哔哩影视',
          plan: plan,
          durationSec: durationSec,
          isPrivateSession: isPrivateSession,
        ),
      ],
      if (!customOrigins.contains('https://api.dandanplay.net'))
        _searchDandanCompatibleOrigin(
          origin: 'https://api.dandanplay.net',
          sourceKey: 'dandanplay',
          sourceLabel: '弹弹Play',
          keyword: searchKeywords.first,
          plan: plan,
          durationSec: durationSec,
          danmuSettings: danmuSettings,
          isPrivateSession: isPrivateSession,
        ),
    ];

    final primaryResults = await Future.wait(primaryTasks);
    _ensureAuthorized(isPrivateSession: isPrivateSession);
    for (final list in primaryResults) {
      collected.addAll(list);
    }

    final strongCount = collected.where((c) => c.confidence >= 0.65).length;
    if (strongCount < 2) {
      final ugcKw = (!plan.isMovie && plan.episodeNumber > 0)
          ? '${searchKeywords.first} 第${plan.episodeNumber}集'
          : searchKeywords.first;
      final ugcResults = await _searchBilibiliUgc(
        keyword: ugcKw,
        plan: plan,
        durationSec: durationSec,
        isPrivateSession: isPrivateSession,
      );
      collected.addAll(ugcResults);
    }

    // Deduplicate by (sourceKey + fetchTarget) keeping highest confidence.
    final dedup = <String, AiOnlineDanmuCandidate>{};
    for (final cand in collected) {
      final key = '${cand.sourceKey}|${cand.fetchKind}|${cand.fetchTarget}';
      final prev = dedup[key];
      if (prev == null || cand.confidence > prev.confidence) {
        dedup[key] = cand;
      }
    }
    final sorted = dedup.values.toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return List<AiOnlineDanmuCandidate>.unmodifiable(sorted);
  }

  Future<http.Response> _safeGet(
    Uri uri, {
    required Map<String, String> headers,
    required bool isPrivateSession,
  }) async {
    _ensureAuthorized(isPrivateSession: isPrivateSession);
    return _client.get(uri, headers: headers).timeout(_requestTimeout);
  }

  Map<String, String> _buildDandanHeaders({
    required String origin,
    required String urlPath,
    DanmuSettings? settings,
  }) {
    final headers = <String, String>{'Accept': 'application/json'};
    if (settings != null &&
        settings.appId.isNotEmpty &&
        settings.appSecret.isNotEmpty) {
      final authOrigins = settings.authorizedCredentialOrigins;
      final allowed = authOrigins == null || authOrigins.contains(origin);
      if (allowed) {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        headers['X-AppId'] = settings.appId;
        headers['X-Timestamp'] = '$ts';
        headers['X-Signature'] = DandanplayProvider.computeOpenApiSignature(
          appId: settings.appId,
          timestampSec: ts,
          urlPath: urlPath,
          appSecret: settings.appSecret,
        );
      }
    }
    return headers;
  }

  Future<List<AiOnlineDanmuCandidate>> _searchDandanCompatibleOrigin({
    required String origin,
    required String sourceKey,
    required String sourceLabel,
    required String keyword,
    required AiDanmuQueryPlan plan,
    required int durationSec,
    DanmuSettings? danmuSettings,
    required bool isPrivateSession,
  }) async {
    try {
      const path = '/api/v2/search/episodes';
      final base = Uri.parse(origin);
      final uri = base.replace(
        path: '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}$path',
        queryParameters: <String, String>{
          'anime': keyword,
          if (plan.episodeNumber > 0) 'episode': '${plan.episodeNumber}',
        },
      );
      final resp = await _safeGet(
        uri,
        headers: _buildDandanHeaders(
          origin: origin,
          urlPath: path,
          settings: danmuSettings,
        ),
        isPrivateSession: isPrivateSession,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is! Map || decoded['animes'] is! List) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final out = <AiOnlineDanmuCandidate>[];
      for (final anime in decoded['animes'] as List) {
        if (anime is! Map) continue;
        final animeTitle = (anime['animeTitle'] ?? '').toString().trim();
        final episodes = anime['episodes'];
        if (episodes is! List) continue;
        for (final ep in episodes) {
          if (ep is! Map) continue;
          final epId = (ep['episodeId'] ?? '').toString().trim();
          final epTitle = (ep['episodeTitle'] ?? '').toString().trim();
          if (epId.isEmpty) continue;
          final parsedEp = SeriesScraper.scrapeEpisodeName(
            epTitle,
            seriesTitle: animeTitle,
          );
          final epNum = parsedEp.rawEpisodeNumber ?? 0;
          final score = _scoreCandidate(
            plan: plan,
            candidateWorkTitle: animeTitle,
            candidateEpisodeTitle: epTitle,
            candidateEpisodeNum: epNum,
            candidateDurationSec: 0,
            targetDurationSec: durationSec,
            sourceBonus: sourceKey == 'custom_origin' ? 0.14 : 0.10,
          );
          out.add(
            AiOnlineDanmuCandidate(
              id: '${sourceKey}_$epId',
              sourceKey: sourceKey,
              sourceLabel: sourceLabel,
              workTitle: animeTitle.isNotEmpty ? animeTitle : keyword,
              episodeTitle: epTitle.isNotEmpty ? epTitle : '第${epNum > 0 ? epNum : plan.episodeNumber}集',
              episodeNumber: epNum,
              durationSec: 0,
              confidence: score,
              fetchKind: 'dandan_ep',
              fetchTarget: epId,
              origin: origin,
            ),
          );
        }
      }
      return out;
    } on AiServiceException {
      rethrow;
    } catch (_) {
      return const <AiOnlineDanmuCandidate>[];
    }
  }

  Future<List<AiOnlineDanmuCandidate>> _searchBilibiliPgc({
    required String keyword,
    required String searchType,
    required String sourceLabel,
    required AiDanmuQueryPlan plan,
    required int durationSec,
    required bool isPrivateSession,
  }) async {
    try {
      final searchUri = Uri.https(
        'api.bilibili.com',
        '/x/web-interface/search/type',
        <String, String>{
          'search_type': searchType,
          'keyword': keyword,
        },
      );
      final searchResp = await _safeGet(
        searchUri,
        headers: _bilibiliHeaders,
        isPrivateSession: isPrivateSession,
      );
      if (searchResp.statusCode < 200 || searchResp.statusCode >= 300) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final searchJson =
          jsonDecode(utf8.decode(searchResp.bodyBytes, allowMalformed: true));
      if (searchJson is! Map) return const <AiOnlineDanmuCandidate>[];
      final data = searchJson['data'];
      if (data is! Map || data['result'] is! List) {
        return const <AiOnlineDanmuCandidate>[];
      }

      final seasonFutures = <Future<List<AiOnlineDanmuCandidate>>>[];
      var pickedSeasons = 0;
      for (final item in data['result'] as List) {
        if (item is! Map) continue;
        final sid = (item['season_id'] ?? '').toString().trim();
        if (sid.isEmpty) continue;
        final workTitle = _stripEmTags((item['title'] ?? '').toString());
        seasonFutures.add(
          _fetchBilibiliSeasonEpisodes(
            seasonId: sid,
            fallbackWorkTitle: workTitle,
            sourceKey: 'bilibili_pgc',
            sourceLabel: sourceLabel,
            plan: plan,
            durationSec: durationSec,
            isPrivateSession: isPrivateSession,
          ),
        );
        pickedSeasons++;
        if (pickedSeasons >= 3) break;
      }
      if (seasonFutures.isEmpty) return const <AiOnlineDanmuCandidate>[];
      final lists = await Future.wait(seasonFutures);
      return <AiOnlineDanmuCandidate>[for (final l in lists) ...l];
    } on AiServiceException {
      rethrow;
    } catch (_) {
      return const <AiOnlineDanmuCandidate>[];
    }
  }

  Future<List<AiOnlineDanmuCandidate>> _fetchBilibiliSeasonEpisodes({
    required String seasonId,
    required String fallbackWorkTitle,
    required String sourceKey,
    required String sourceLabel,
    required AiDanmuQueryPlan plan,
    required int durationSec,
    required bool isPrivateSession,
  }) async {
    try {
      final uri = Uri.https(
        'api.bilibili.com',
        '/pgc/view/web/season',
        <String, String>{'season_id': seasonId},
      );
      final resp = await _safeGet(
        uri,
        headers: _bilibiliHeaders,
        isPrivateSession: isPrivateSession,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is! Map || decoded['result'] is! Map) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final result = decoded['result'] as Map;
      final workTitle =
          (result['season_title'] ?? result['title'] ?? fallbackWorkTitle)
              .toString()
              .trim();
      final episodes = result['episodes'];
      if (episodes is! List) return const <AiOnlineDanmuCandidate>[];

      final out = <AiOnlineDanmuCandidate>[];
      for (var i = 0; i < episodes.length; i++) {
        final ep = episodes[i];
        if (ep is! Map) continue;
        final cid = (ep['cid'] ?? '').toString().trim();
        if (cid.isEmpty || cid == '0') continue;
        final rawEpTitle = (ep['title'] ?? '').toString().trim();
        final longTitle = (ep['long_title'] ?? '').toString().trim();
        final displayEp = longTitle.isNotEmpty
            ? (rawEpTitle.isNotEmpty ? '$rawEpTitle $longTitle' : longTitle)
            : (rawEpTitle.isNotEmpty ? rawEpTitle : '第${i + 1}集');
        final parsedEpNum = int.tryParse(rawEpTitle) ??
            SeriesScraper.scrapeEpisodeName(
              displayEp,
              seriesTitle: workTitle,
            ).rawEpisodeNumber ??
            (i + 1);
        final epDur = _parseFlexibleDurationSec(ep['duration']) ?? 0;
        final score = _scoreCandidate(
          plan: plan,
          candidateWorkTitle: workTitle,
          candidateEpisodeTitle: displayEp,
          candidateEpisodeNum: parsedEpNum,
          candidateDurationSec: epDur,
          targetDurationSec: durationSec,
          sourceBonus: 0.12,
        );
        out.add(
          AiOnlineDanmuCandidate(
            id: 'bili_pgc_$cid',
            sourceKey: sourceKey,
            sourceLabel: sourceLabel,
            workTitle: workTitle.isNotEmpty ? workTitle : fallbackWorkTitle,
            episodeTitle: displayEp,
            episodeNumber: parsedEpNum,
            durationSec: epDur,
            confidence: score,
            fetchKind: 'bilibili_cid',
            fetchTarget: cid,
            origin: 'https://api.bilibili.com',
          ),
        );
      }
      return out;
    } on AiServiceException {
      rethrow;
    } catch (_) {
      return const <AiOnlineDanmuCandidate>[];
    }
  }

  Future<List<AiOnlineDanmuCandidate>> _searchBilibiliUgc({
    required String keyword,
    required AiDanmuQueryPlan plan,
    required int durationSec,
    required bool isPrivateSession,
  }) async {
    try {
      final uri = Uri.https(
        'api.bilibili.com',
        '/x/web-interface/search/type',
        <String, String>{
          'search_type': 'video',
          'keyword': keyword,
        },
      );
      final resp = await _safeGet(
        uri,
        headers: _bilibiliHeaders,
        isPrivateSession: isPrivateSession,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is! Map) return const <AiOnlineDanmuCandidate>[];
      final data = decoded['data'];
      if (data is! Map || data['result'] is! List) {
        return const <AiOnlineDanmuCandidate>[];
      }

      final pageFutures = <Future<List<AiOnlineDanmuCandidate>>>[];
      var count = 0;
      for (final item in data['result'] as List) {
        if (item is! Map) continue;
        final bvid = (item['bvid'] ?? '').toString().trim();
        if (bvid.isEmpty) continue;
        final videoTitle = _stripEmTags((item['title'] ?? '').toString());
        final itemDur = _parseFlexibleDurationSec(item['duration']) ?? 0;
        pageFutures.add(
          _fetchBilibiliUgcPages(
            bvid: bvid,
            videoTitle: videoTitle,
            fallbackDurationSec: itemDur,
            plan: plan,
            targetDurationSec: durationSec,
            isPrivateSession: isPrivateSession,
          ),
        );
        count++;
        if (count >= 3) break;
      }
      if (pageFutures.isEmpty) return const <AiOnlineDanmuCandidate>[];
      final lists = await Future.wait(pageFutures);
      return <AiOnlineDanmuCandidate>[for (final l in lists) ...l];
    } on AiServiceException {
      rethrow;
    } catch (_) {
      return const <AiOnlineDanmuCandidate>[];
    }
  }

  Future<List<AiOnlineDanmuCandidate>> _fetchBilibiliUgcPages({
    required String bvid,
    required String videoTitle,
    required int fallbackDurationSec,
    required AiDanmuQueryPlan plan,
    required int targetDurationSec,
    required bool isPrivateSession,
  }) async {
    try {
      final uri = Uri.https(
        'api.bilibili.com',
        '/x/player/pagelist',
        <String, String>{'bvid': bvid},
      );
      final resp = await _safeGet(
        uri,
        headers: _bilibiliHeaders,
        isPrivateSession: isPrivateSession,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is! Map || decoded['data'] is! List) {
        return const <AiOnlineDanmuCandidate>[];
      }
      final out = <AiOnlineDanmuCandidate>[];
      final pages = decoded['data'] as List;
      for (var i = 0; i < pages.length; i++) {
        final p = pages[i];
        if (p is! Map) continue;
        final cid = (p['cid'] ?? '').toString().trim();
        if (cid.isEmpty || cid == '0') continue;
        final part = (p['part'] ?? '').toString().trim();
        final epLabel = part.isNotEmpty ? part : 'P${i + 1}';
        final pageDur = _parseFlexibleDurationSec(p['duration']) ?? fallbackDurationSec;
        final scraped = SeriesScraper.scrapeEpisodeName(
          pages.length == 1 ? videoTitle : part,
          seriesTitle: plan.canonicalTitle,
        );
        final epNum = scraped.rawEpisodeNumber ?? (pages.length == 1 ? plan.episodeNumber : i + 1);
        final score = _scoreCandidate(
          plan: plan,
          candidateWorkTitle: videoTitle,
          candidateEpisodeTitle: epLabel,
          candidateEpisodeNum: epNum,
          candidateDurationSec: pageDur,
          targetDurationSec: targetDurationSec,
          sourceBonus: 0.0,
        );
        out.add(
          AiOnlineDanmuCandidate(
            id: 'bili_ugc_$cid',
            sourceKey: 'bilibili_ugc',
            sourceLabel: '哔哩哔哩视频',
            workTitle: videoTitle,
            episodeTitle: epLabel,
            episodeNumber: epNum,
            durationSec: pageDur,
            confidence: score,
            fetchKind: 'bilibili_cid',
            fetchTarget: cid,
            origin: 'https://api.bilibili.com',
          ),
        );
      }
      return out;
    } on AiServiceException {
      rethrow;
    } catch (_) {
      return const <AiOnlineDanmuCandidate>[];
    }
  }

  static double _scoreCandidate({
    required AiDanmuQueryPlan plan,
    required String candidateWorkTitle,
    required String candidateEpisodeTitle,
    required int candidateEpisodeNum,
    required int candidateDurationSec,
    required int targetDurationSec,
    required double sourceBonus,
  }) {
    var score = 0.25 + sourceBonus;
    final normQuery = SeriesScraper.cleanSearchTitle(plan.canonicalTitle).toLowerCase();
    final normCand = SeriesScraper.cleanSearchTitle(candidateWorkTitle).toLowerCase();
    if (normQuery.isNotEmpty && normCand.isNotEmpty) {
      if (SeriesScraper.areWorkTitlesEquivalent(
            plan.canonicalTitle,
            candidateWorkTitle,
            seasonNumber: plan.seasonNumber,
          ) ||
          normQuery == normCand) {
        score += 0.35;
      } else if (normCand.contains(normQuery) || normQuery.contains(normCand)) {
        score += 0.22;
      } else {
        for (final alt in plan.altTitles) {
          final normAlt = SeriesScraper.cleanSearchTitle(alt).toLowerCase();
          if (normAlt.isNotEmpty &&
              (normCand.contains(normAlt) || normAlt.contains(normCand))) {
            score += 0.22;
            break;
          }
        }
      }
    }

    if (plan.isMovie && plan.episodeNumber <= 1) {
      if (candidateEpisodeNum <= 1) score += 0.20;
    } else if (plan.episodeNumber > 0) {
      if (candidateEpisodeNum == plan.episodeNumber) {
        score += 0.28;
      } else if (candidateEpisodeNum > 0 &&
          (candidateEpisodeNum - plan.episodeNumber).abs() == 1) {
        score -= 0.08;
      } else if (candidateEpisodeNum > 0) {
        score -= 0.18;
      }
    }

    if (targetDurationSec > 60 && candidateDurationSec > 60) {
      final diff = (targetDurationSec - candidateDurationSec).abs();
      if (diff <= 30) {
        score += 0.12;
      } else if (diff <= 150) {
        score += 0.06;
      } else if (diff > 600) {
        score -= 0.12;
      }
    }

    if (candidateEpisodeTitle.contains('预告') ||
        candidateWorkTitle.contains('解说') ||
        candidateWorkTitle.contains('速看')) {
      score -= 0.25;
    }

    return score.clamp(0.0, 1.0);
  }

  /// Fetches and decodes danmaku comments for [candidate].
  Future<List<DanmuItem>> fetchCandidateDanmu(
    AiOnlineDanmuCandidate candidate, {
    DanmuSettings? danmuSettings,
    bool isPrivateSession = false,
  }) async {
    _ensureAuthorized(isPrivateSession: isPrivateSession);

    if (candidate.fetchKind == 'bilibili_cid') {
      final uri = Uri.https(
        'api.bilibili.com',
        '/x/v1/dm/list.so',
        <String, String>{'oid': candidate.fetchTarget},
      );
      final resp = await _safeGet(
        uri,
        headers: const <String, String>{
          'Accept': '*/*',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15',
          'Referer': 'https://www.bilibili.com/',
        },
        isPrivateSession: isPrivateSession,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <DanmuItem>[];
      }
      final xml = decodeBilibiliDanmuXml(resp.bodyBytes);
      if (xml.trim().isEmpty) return const <DanmuItem>[];
      return DandanplayProvider.parseDanmuPayload(
        xml,
        maxItems: DandanplayProvider.maxFullEpisodeItems,
      );
    }

    if (candidate.fetchKind == 'dandan_ep') {
      final path = '/api/v2/comment/${Uri.encodeComponent(candidate.fetchTarget)}';
      final base = Uri.parse(candidate.origin);
      final uri = base.replace(
        path: '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}$path',
        queryParameters: const <String, String>{
          'withRelated': 'true',
          'chConvert': '1',
        },
      );
      final resp = await _safeGet(
        uri,
        headers: _buildDandanHeaders(
          origin: candidate.origin,
          urlPath: path,
          settings: danmuSettings,
        ),
        isPrivateSession: isPrivateSession,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const <DanmuItem>[];
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return DandanplayProvider.parseDanmuPayload(
        body,
        maxItems: DandanplayProvider.maxFullEpisodeItems,
      );
    }

    return const <DanmuItem>[];
  }

  /// End-to-end auto match: extracts query plan, searches candidates, and loads
  /// the best non-empty danmaku track (falling back to runner-up if empty).
  Future<AiDanmuMatchOutcome> autoMatchAndLoad({
    required String rawTitle,
    String rawEpisodeName = '',
    int fallbackEpisodeIndex = 1,
    String year = '',
    int durationSec = 0,
    String manualKeywordOverride = '',
    int? manualEpisodeOverride,
    DanmuSettings? danmuSettings,
    bool isPrivateSession = false,
  }) async {
    _ensureAuthorized(isPrivateSession: isPrivateSession);

    final plan = await extractQueryPlan(
      rawTitle: rawTitle,
      rawEpisodeName: rawEpisodeName,
      fallbackEpisodeIndex: fallbackEpisodeIndex,
      year: year,
      durationSec: durationSec,
      manualKeywordOverride: manualKeywordOverride,
      manualEpisodeOverride: manualEpisodeOverride,
      isPrivateSession: isPrivateSession,
    );

    final candidates = await searchCandidates(
      plan,
      danmuSettings: danmuSettings,
      durationSec: durationSec,
      isPrivateSession: isPrivateSession,
    );
    if (candidates.isEmpty) {
      return AiDanmuMatchOutcome(
        plan: plan,
        candidates: const <AiOnlineDanmuCandidate>[],
        selected: null,
        items: const <DanmuItem>[],
        messageZh: '暂未检索到「${plan.canonicalTitle}」匹配的在线弹幕，可尝试简化片名重新搜索',
      );
    }

    AiOnlineDanmuCandidate? chosen;
    List<DanmuItem> items = const <DanmuItem>[];
    final tryCount = math.min(2, candidates.length);
    for (var i = 0; i < tryCount; i++) {
      final cand = candidates[i];
      final loaded = await fetchCandidateDanmu(
        cand,
        danmuSettings: danmuSettings,
        isPrivateSession: isPrivateSession,
      );
      if (loaded.isNotEmpty) {
        chosen = cand;
        items = loaded;
        break;
      }
      chosen ??= cand;
    }

    if (items.isEmpty) {
      return AiDanmuMatchOutcome(
        plan: plan,
        candidates: candidates,
        selected: chosen,
        items: const <DanmuItem>[],
        messageZh: '已找到 ${candidates.length} 条片源记录，但弹幕池暂无评论或需要自定弹幕源凭证',
      );
    }

    return AiDanmuMatchOutcome(
      plan: plan,
      candidates: candidates,
      selected: chosen,
      items: items,
      messageZh:
          '已自动匹配并加载 ${items.length} 条弹幕 · ${chosen!.sourceLabel}（${chosen.workTitle}）',
    );
  }

  /// Suggests timeline synchronization offset (in ms, clamped to `-30000..30000`)
  /// where `effectiveMs = rawPositionMs + timeOffsetMs` (`+` = advance danmaku earlier).
  Future<({int offsetMs, String reasonZh})> suggestTimelineOffset({
    required String title,
    String episodeLabel = '',
    int videoDurationSec = 0,
    int candidateDurationSec = 0,
    List<({int timeMs, String text})> sampleSubtitles = const [],
    List<DanmuItem> danmuItems = const <DanmuItem>[],
    bool isPrivateSession = false,
  }) async {
    _ensureAuthorized(isPrivateSession: isPrivateSession);

    if (danmuItems.isEmpty) {
      return (offsetMs: 0, reasonZh: '当前暂无弹幕可供校对');
    }

    // Heuristic baseline when duration differs modestly (OP/ad intro lead)
    var heuristicOffsetMs = 0;
    var heuristicReason = '未检测到明显片头时长差异，保持原时间轴';
    if (videoDurationSec > 120 && candidateDurationSec > 120) {
      final diffSec = candidateDurationSec - videoDurationSec;
      if (diffSec.abs() >= 5 && diffSec.abs() <= 120) {
        heuristicOffsetMs = (diffSec * 1000).clamp(-30000, 30000);
        heuristicReason = diffSec > 0
            ? '在线弹幕源比当前片源长 ${diffSec}s，建议提前 ${diffSec}s 跳过片头广告差异'
            : '当前片源比弹幕源长 ${diffSec.abs()}s，建议延后 ${diffSec.abs()}s 对齐正片';
      }
    }

    final cfg = _ai.config;
    if (!_ai.isConfigured || !cfg.enabled || !cfg.danmuMatchEnabled) {
      return (offsetMs: heuristicOffsetMs, reasonZh: heuristicReason);
    }

    try {
      final subLines = sampleSubtitles.take(15).map((s) {
        final sec = (s.timeMs / 1000).toStringAsFixed(1);
        return '[${sec}s] ${s.text.trim()}';
      }).join('\n');

      final step = math.max(1, danmuItems.length ~/ 25);
      final dmLines = <String>[];
      for (var i = 0; i < danmuItems.length && dmLines.length < 25; i += step) {
        final d = danmuItems[i];
        final sec = (d.timeMs / 1000).toStringAsFixed(1);
        dmLines.add('[${sec}s] ${d.text.trim()}');
      }

      final res = await _ai.complete(
        feature: 'ai_danmu_offset_v1',
        modelOverride:
            cfg.fastModel.trim().isNotEmpty ? cfg.fastModel.trim() : null,
        isPrivateSession: isPrivateSession,
        systemPrompt: '你是影视弹幕时间轴同步校对助手。根据总时长差与台词/弹幕时间戳样本估算偏移毫秒数。'
            '公式为 effectiveMs = 播放位置Ms + offset_ms（正数表示让弹幕提前出现，负数表示让弹幕延后出现）。'
            '只输出合法 JSON：{"offset_ms": 0, "reason": "不超过24字中文说明"}，范围限制在 -30000 到 30000。',
        userPrompt: '片名：$title $episodeLabel\n'
            '当前视频时长：${videoDurationSec}s\n'
            '弹幕源时长：${candidateDurationSec}s\n'
            '${subLines.isNotEmpty ? "字幕样本：\n$subLines\n" : ""}'
            '弹幕时间样本：\n${dmLines.join('\n')}',
      );
      _ensureAuthorized(isPrivateSession: isPrivateSession);
      final slice = AiService.extractJsonObjectSlice(res.text);
      if (slice != null && !AiService.containsForbiddenUrl(slice)) {
        final decoded = jsonDecode(slice);
        if (decoded is Map) {
          final offset = ((decoded['offset_ms'] as num?)?.round() ??
                  heuristicOffsetMs)
              .clamp(-30000, 30000);
          final reason = (decoded['reason'] ?? '').toString().trim();
          return (
            offsetMs: offset,
            reasonZh: reason.isNotEmpty ? reason : heuristicReason,
          );
        }
      }
    } on AiServiceException catch (e) {
      if (e.code == AiErrorCode.privacySpaceBlocked ||
          e.code == AiErrorCode.disabled) {
        rethrow;
      }
    } catch (_) {}

    return (offsetMs: heuristicOffsetMs, reasonZh: heuristicReason);
  }
}
